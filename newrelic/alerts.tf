# Las alertas: una política por entorno, con condiciones que miran el sistema desde tres lados.
#   - Desde afuera (monitores sintéticos): ¿un usuario puede usarlo?
#   - Desde cada servicio (agente APM): ¿está vivo, falla o anda lento?
#   - Desde la VM (agente de infraestructura): ¿el container corre, se reinicia, se queda sin memoria? ¿la VM responde?
# Si un servicio se cae en un deploy, avisan al menos dos: su health check y la pérdida de señal de su agente.

resource "newrelic_alert_policy" "snippet_searcher" {
  name = local.prefix
  # Un incidente por condición y por cada servicio/monitor: si se caen dos servicios, son dos avisos distintos.
  incident_preference = "PER_CONDITION_AND_TARGET"
}

# --- Desde afuera ---------------------------------------------------------------------------------------------------

# Cualquier monitor que falle dos minutos seguidos desde al menos una de las ubicaciones. Un solo check fallado no
# alcanza (puede ser la red de la ubicación); dos minutos seguidos ya no es casualidad.
resource "newrelic_nrql_alert_condition" "synthetic_failure" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Monitor sintético fallando"
  description = "El monitor {{tag.monitorName}} falla desde fuera de la VM: lo que chequea no le responde a los usuarios."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT percentage(count(*), WHERE result = 'FAILED') FROM SyntheticCheck WHERE monitorName LIKE '${local.prefix}%' FACET monitorName"
  }

  critical {
    operator              = "above_or_equals"
    threshold             = 50
    threshold_duration    = 120
    threshold_occurrences = "all"
  }

  aggregation_window = 60
  aggregation_method = "event_timer"
  aggregation_timer  = 60

  # Si un monitor deja de tener resultados (lo pausaron), no es una caída.
  violation_time_limit_seconds = 86400
}

# --- Desde cada servicio --------------------------------------------------------------------------------------------

# El agente manda métricas de la JVM cada minuto aunque no haya pedidos. Si un servicio deja de mandarlas, el proceso
# no está: se cayó, lo mató un OOM, o el deploy lo bajó y el nuevo no levantó. Una condición, un incidente por servicio.
resource "newrelic_nrql_alert_condition" "service_not_reporting" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Servicio sin reportar"
  description = "{{tag.appName}} dejó de mandar datos a New Relic hace 3 minutos: el proceso no está corriendo."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT count(newrelic.timeslice.value) FROM Metric WHERE metricTimesliceName = 'Memory/Physical' AND appName IN (${local.app_names}) FACET appName"
  }

  # Mientras reporta, nunca cruza esto: la que abre el incidente es la pérdida de señal.
  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 180
    threshold_occurrences = "all"
  }

  aggregation_window             = 60
  aggregation_method             = "event_flow"
  aggregation_delay              = 120
  expiration_duration            = 180
  open_violation_on_expiration   = true
  close_violations_on_expiration = false
  violation_time_limit_seconds   = 86400
}

# Más del 5% de los pedidos terminan en error (5xx o excepción) durante 5 minutos. Los 4xx no cuentan
# (ignore_status_codes en newrelic.yml): un snippet inválido es una respuesta correcta.
resource "newrelic_nrql_alert_condition" "error_rate" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Tasa de errores alta"
  description = "Más del 5% de los pedidos a {{tag.appName}} fallan. Ver Errors Inbox y los traces con error."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName IN (${local.app_names}) FACET appName"
  }

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "all"
  }
  warning {
    operator              = "above"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# El 95% de los pedidos web tarda más de 3 segundos durante 5 minutos. Suele ser un servicio de abajo que no
# responde: snippet-service espera sin timeout a los que llama.
resource "newrelic_nrql_alert_condition" "slow_responses" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Respuestas lentas"
  description = "El p95 de {{tag.appName}} pasa los 3 s. Mirar en un trace lento qué llamado se lleva el tiempo."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT percentile(duration, 95) FROM Transaction WHERE transactionType = 'Web' AND appName IN (${local.app_names}) FACET appName"
  }

  critical {
    operator              = "above"
    threshold             = 3
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# Los linteos en segundo plano (Redis Streams) que fallan: el snippet queda en PENDING hasta que se reintente.
resource "newrelic_nrql_alert_condition" "background_failures" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Linteo o formateo en segundo plano fallando"
  description = "Fallan los mensajes de {{tag.name}}: los snippets quedan en PENDING. Suele ser language-service o Redis caídos."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT count(*) FROM TransactionError WHERE appName = '${local.apps["snippet-service"]}' AND transactionName LIKE 'OtherTransaction/RedisStream/%' FACET transactionName"
  }

  critical {
    operator              = "above"
    threshold             = 5
    threshold_duration    = 300
    threshold_occurrences = "at_least_once"
  }

  aggregation_window           = 300
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# --- Desde los datos -----------------------------------------------------------------------------------------------
# «Mis snippets desaparecieron»: todo responde 200 y rápido, así que ni los monitores ni los SLO lo ven. snippet-service
# reporta cada minuto cuántos snippets hay (SnippetInventory), cada create y delete (SnippetActivity), y los listados
# que vuelven vacíos a un usuario que tiene snippets en la base (SnippetsHidden).

# Snippets que se fueron de la base sin que nadie los borrara: al principio de la ventana había N; si se crearon C y se
# borraron B, al final tendría que haber N + C − B. Lo que falta desapareció (una base que se recreó vacía, un volumen
# que no estaba, un proceso que borró de más). Un create en los segundos entre el último reporte y el final de la
# ventana cuenta como uno de más, por eso se avisa desde 3.
resource "newrelic_nrql_alert_condition" "snippets_vanished" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Snippets que desaparecieron"
  description = "Faltan snippets en la base que nadie borró (ver \"Datos y colas\" en el dashboard). Revisar si se reinició snippet-db y si estaba su volumen."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT earliest(total) + filter(count(*), WHERE action = 'created') - filter(count(*), WHERE action = 'deleted') - latest(total) FROM SnippetInventory, SnippetActivity WHERE appName = '${local.apps["snippet-service"]}'"
  }

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 600
    threshold_occurrences = "at_least_once"
  }

  fill_option                  = "none"
  aggregation_window           = 600
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  slide_by                     = 60
  violation_time_limit_seconds = 86400
}

# Un usuario con snippets en la base a quien permission-service no le devuelve ninguno: los ve vacíos aunque estén.
# Pasa si se perdieron los permisos (permission-db vacía) o si cambió su id de Auth0 (el sub del token).
resource "newrelic_nrql_alert_condition" "snippets_hidden" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Snippets que un usuario no puede ver"
  description = "Hay usuarios que tienen snippets en la base pero permission-service no les devuelve ninguno. Ver la tabla en \"Datos y colas\" y revisar permission-db."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT count(*) FROM SnippetsHidden WHERE appName = '${local.apps["snippet-service"]}'"
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = 60
    threshold_occurrences = "at_least_once"
  }

  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# La saturación del segundo plano: los mensajes de un stream de Redis que esperan (sin entregar, o entregados y sin
# confirmar). Si no bajan en 15 minutos, los workers no dan abasto o están fallando, y los snippets quedan en PENDING.
resource "newrelic_nrql_alert_condition" "stream_backlog" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Cola de Redis atrasada"
  description = "Más de ${var.stream_backlog_threshold} mensajes esperando en {{tag.stream}} hace 15 minutos. Ver si language-service responde y si hay errores en el linteo en segundo plano."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT latest(lag) + latest(pending) FROM SnippetStreamBacklog WHERE appName = '${local.apps["snippet-service"]}' FACET stream"
  }

  critical {
    operator              = "above"
    threshold             = var.stream_backlog_threshold
    threshold_duration    = 900
    threshold_occurrences = "all"
  }

  aggregation_window           = 60
  aggregation_method           = "event_flow"
  aggregation_delay            = 120
  violation_time_limit_seconds = 86400
}

# --- Desde la VM ----------------------------------------------------------------------------------------------------

# La VM dejó de reportar: está apagada (Azure la desasignó), se colgó, o se cayó el agente de infraestructura.
resource "newrelic_nrql_alert_condition" "host_not_reporting" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "VM sin reportar"
  description = "La VM ${local.host} no manda métricas hace 5 minutos. Revisar en Azure si está prendida."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT count(*) FROM SystemSample WHERE ${local.infra_filter}"
  }

  critical {
    operator              = "below"
    threshold             = 1
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window             = 60
  aggregation_method             = "event_flow"
  aggregation_delay              = 120
  expiration_duration            = 300
  open_violation_on_expiration   = true
  close_violations_on_expiration = false
  violation_time_limit_seconds   = 86400
}

# Un container de Swarm cerca de su límite de memoria. Al llegar, Docker lo mata (OOM) y Swarm levanta otro: por ejemplo
# un snippet enorme que snippet-service tiene que tener entero en memoria, varias veces, para validarlo y guardarlo.
resource "newrelic_nrql_alert_condition" "container_memory" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Container cerca del límite de memoria"
  description = "{{tag.label.com.docker.swarm.service.name}} usa más del 90% de su límite: si llega, Docker lo mata."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT max(memoryUsageLimitPercent) FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name`"
  }

  critical {
    operator              = "above"
    threshold             = 90
    threshold_duration    = 120
    threshold_occurrences = "all"
  }
  warning {
    operator              = "above"
    threshold             = 80
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# Swarm no reinicia un container: crea uno nuevo. Un servicio con más de 2 containers distintos en 10 minutos se está
# cayendo y volviendo a levantar (crash loop), o un deploy no termina de levantar y hace rollback. Un deploy normal con
# start-first son 2: el viejo y el nuevo.
resource "newrelic_nrql_alert_condition" "container_churn" {
  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "Container reiniciándose"
  description = "{{tag.label.com.docker.swarm.service.name}} tuvo más de 2 containers en 10 minutos: se cae y Swarm lo vuelve a levantar."
  type        = "static"
  enabled     = true

  nrql {
    query = "SELECT uniqueCount(containerId) FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name`"
  }

  critical {
    operator              = "above"
    threshold             = 2
    threshold_duration    = 600
    threshold_occurrences = "at_least_once"
  }

  aggregation_window           = 600
  slide_by                     = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

resource "newrelic_nrql_alert_condition" "host_resources" {
  for_each = {
    cpu    = { query = "SELECT average(cpuPercent) FROM SystemSample", title = "CPU", threshold = 90 }
    memory = { query = "SELECT average(memoryUsedPercent) FROM SystemSample", title = "Memoria", threshold = 90 }
    disk   = { query = "SELECT max(diskUsedPercent) FROM StorageSample", title = "Disco", threshold = 85 }
  }

  policy_id   = newrelic_alert_policy.snippet_searcher.id
  name        = "${each.value.title} de la VM alta"
  description = "${each.value.title} de ${local.host} por encima del ${each.value.threshold}%. Con el disco lleno, Postgres y Redis dejan de escribir."
  type        = "static"
  enabled     = true

  nrql {
    query = "${each.value.query} WHERE ${local.infra_filter}"
  }

  critical {
    operator              = "above"
    threshold             = each.value.threshold
    threshold_duration    = 300
    threshold_occurrences = "all"
  }

  aggregation_window           = 60
  aggregation_method           = "event_timer"
  aggregation_timer            = 60
  violation_time_limit_seconds = 86400
}

# --- A quién se avisa -----------------------------------------------------------------------------------------------

resource "newrelic_notification_destination" "team_email" {
  name = "${local.prefix} equipo"
  type = "EMAIL"

  # New Relic guarda los mails en minúscula: así un apply no lo ve como un cambio cada vez.
  property {
    key   = "email"
    value = lower(join(",", var.alert_emails))
  }

  # New Relic agrega sola una propiedad link_sent_email (a quién mandó el link de alta). Sin esto, cada apply la borra.
  # Por eso cambiar alert_emails no se aplica solo: hay que recrearlo con
  # `tofu apply -var-file=dev.tfvars -replace=newrelic_notification_destination.team_email`.
  lifecycle {
    ignore_changes = [property]
  }
}

resource "newrelic_notification_channel" "team_email" {
  name           = "${local.prefix} mail"
  type           = "EMAIL"
  destination_id = newrelic_notification_destination.team_email.id
  product        = "IINT"

  property {
    key   = "subject"
    value = "[${local.prefix}] {{issueTitle}}"
  }
}

# Cada incidente de la política, cuando se abre, se reconoce y se cierra, llega por mail.
resource "newrelic_workflow" "team" {
  name                  = "${local.prefix} avisos"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "Política ${local.prefix}"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.snippet_searcher.id]
    }
  }

  destination {
    channel_id            = newrelic_notification_channel.team_email.id
    notification_triggers = ["ACTIVATED", "ACKNOWLEDGED", "CLOSED"]
  }
}
