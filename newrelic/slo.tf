# Los SLO (Service Level Objectives): qué cuenta como "anda bien", cuánto tiene que andar bien y cuánto se puede
# fallar (el error budget). Cada SLI (Service Level Indicator) se define con eventos: los válidos y, de esos, los malos.
# New Relic calcula el porcentaje bueno en una ventana de los últimos 28 días.
#
#   - Disponibilidad desde afuera: los checks de la UI y de snippet-service (que da DOWN si se cae su base o Redis).
#     Es lo que ve un usuario, y es el único que existe aunque no haya tráfico.
#   - Disponibilidad de la API: los pedidos a snippet-service que no terminan en error (5xx o excepción). Los 4xx no
#     cuentan: un snippet inválido es una respuesta correcta.
#   - Latencia de las lecturas: los GET a snippet-service que responden en menos de var.latency_threshold_seconds.
#
# Los dos de la API se crean recién cuando snippet-service reporta a New Relic (necesitan su entidad de APM): hasta
# que se despliegue su imagen con el agente, un apply los saltea; el apply siguiente los crea.
#
# Ninguno de los tres hubiera visto los snippets "desaparecidos" (todo respondía 200, y rápido): para eso están el
# inventario y los snippets ocultos, en alerts.tf.

data "newrelic_entity" "snippet_service" {
  name             = local.apps["snippet-service"]
  type             = "APPLICATION"
  domain           = "APM"
  ignore_not_found = true
}

locals {
  # 28 días: la ventana más larga que admite New Relic (1, 7 o 28). Con 99,5 % son 3 h 21 min de error budget.
  slo_period = 28

  snippet_service_guid = data.newrelic_entity.snippet_service.guid == null ? "" : data.newrelic_entity.snippet_service.guid

  availability_monitors = join(", ", [
    for check in ["ui", "snippet-service"] : "'${newrelic_synthetics_monitor.health[check].name}'"
  ])
  # Los pedidos de los usuarios a la API: sin los health checks, que son de los monitores y del Swarm.
  api_requests = "appName = '${local.apps["snippet-service"]}' AND transactionType = 'Web' AND request.uri NOT LIKE '/actuator%'"

  service_levels = merge(
    {
      "disponibilidad-externa" = {
        name        = "Disponibilidad desde afuera"
        description = "Checks bien de los monitores de la UI y de snippet-service, desde fuera de la VM."
        guid        = newrelic_synthetics_monitor.health["snippet-service"].id
        target      = var.availability_target
        from        = "SyntheticCheck"
        valid       = "monitorName IN (${local.availability_monitors})"
        bad         = "monitorName IN (${local.availability_monitors}) AND result != 'SUCCESS'"
      }
    },
    # Un for con if en lugar de un ternario con {}: Terraform no acepta un ternario entre dos objetos distintos.
    { for key, slo in {
      "disponibilidad-api" = {
        name        = "Disponibilidad de la API"
        description = "Pedidos a la API que no terminan en un error del servidor (5xx o excepción)."
        guid        = local.snippet_service_guid
        target      = var.availability_target
        from        = "Transaction"
        valid       = local.api_requests
        bad         = "${local.api_requests} AND error IS TRUE"
      }
      "latencia-lecturas" = {
        name        = "Lecturas rápidas"
        description = "Lecturas (GET) de la API que responden en menos de ${var.latency_threshold_seconds * 1000} ms."
        guid        = local.snippet_service_guid
        target      = var.latency_target
        from        = "Transaction"
        valid       = "${local.api_requests} AND request.method = 'GET'"
        bad         = "${local.api_requests} AND request.method = 'GET' AND duration > ${var.latency_threshold_seconds}"
      }
    } : key => slo if local.snippet_service_guid != "" },
  )
}

resource "newrelic_service_level" "slo" {
  for_each = local.service_levels

  guid        = each.value.guid
  name        = "${local.prefix} ${each.value.name}"
  description = each.value.description

  events {
    account_id = var.account_id
    valid_events {
      from  = each.value.from
      where = each.value.valid
    }
    bad_events {
      from  = each.value.from
      where = each.value.bad
    }
  }

  objective {
    target = each.value.target
    time_window {
      rolling {
        count = local.slo_period
        unit  = "DAY"
      }
    }
  }
}

# "Alertá cuando estás por romper el SLO, no cuando algo se ve raro." Fast burn: en la última hora se gastó el 2% del
# error budget de los 28 días. A ese ritmo se termina en unos dos días: hay que mirarlo ya. Un pico corto no alcanza.
data "newrelic_service_level_alert_helper" "fast_burn" {
  for_each = local.service_levels

  alert_type    = "fast_burn"
  sli_guid      = newrelic_service_level.slo[each.key].sli_guid
  slo_target    = each.value.target
  slo_period    = local.slo_period
  is_bad_events = true
}

resource "newrelic_nrql_alert_condition" "slo_fast_burn" {
  for_each = local.service_levels

  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "SLO en riesgo: ${each.value.name}"
  description = "En la última hora se gastó más del 2% del error budget de \"${each.value.name}\" (objetivo ${each.value.target}% en ${local.slo_period} días). Ver la página SLOs del dashboard y, ahí, qué otra alerta está abierta."
  type        = "static"
  enabled     = true

  nrql {
    query = data.newrelic_service_level_alert_helper.fast_burn[each.key].nrql
  }

  critical {
    operator              = "above_or_equals"
    threshold             = data.newrelic_service_level_alert_helper.fast_burn[each.key].threshold
    threshold_duration    = 900
    threshold_occurrences = "at_least_once"
  }

  fill_option                  = "none"
  aggregation_window           = data.newrelic_service_level_alert_helper.fast_burn[each.key].evaluation_period
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  slide_by                     = 900
  violation_time_limit_seconds = 86400
}
