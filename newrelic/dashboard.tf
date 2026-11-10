# El dashboard del entorno: qué está pasando, de un vistazo. Cuatro páginas: estado general, el flujo de crear un
# snippet (con sus traces), los servicios uno por uno y la VM con sus containers.

locals {
  snippet_app = local.apps["snippet-service"]
  # La creación de un snippet, por editor (JSON) o por archivo (multipart): los dos son POST /snippets.
  create_filter = "appName = '${local.snippet_app}' AND request.method = 'POST' AND request.uri = '/snippets'"
}

resource "newrelic_one_dashboard" "snippet_searcher" {
  name        = "Snippet Searcher (${var.environment})"
  permissions = "public_read_only"

  page {
    name = "Estado general"

    widget_markdown {
      title  = "Cómo leer este dashboard"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = <<-EOT
        **${local.base_url}** · Alertas: política `${local.prefix}`. Un monitor en rojo es lo que ve un usuario; la pérdida de
        señal de un servicio y los containers que se recrean dicen cuál se cayó. El trace de un pedido se abre en
        *APM → ${local.snippet_app} → Distributed tracing*, o desde la página "Crear un snippet".
      EOT
    }

    widget_billboard {
      title  = "Monitores sintéticos (última hora, % de checks bien)"
      row    = 3
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT percentage(count(*), WHERE result = 'SUCCESS') FROM SyntheticCheck WHERE monitorName LIKE '${local.prefix}%' FACET monitorName SINCE 1 hour ago"
      }
    }

    widget_table {
      title  = "Incidentes de las últimas 24 h (Estado: open o close)"
      row    = 3
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT latest(event) AS 'Estado', latest(title) AS 'Qué pasa', latest(priority) AS 'Prioridad', earliest(timestamp) AS 'Desde' FROM NrAiIncident WHERE policyName = '${local.prefix}' FACET incidentId SINCE 1 day ago LIMIT 20"
      }
    }

    widget_line {
      title  = "Pedidos por minuto, por servicio"
      row    = 6
      column = 1
      width  = 4
      height = 3
      nrql_query {
        query = "SELECT rate(count(*), 1 minute) FROM Transaction WHERE appName IN (${local.app_names}) FACET appName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "% de pedidos con error, por servicio"
      row    = 6
      column = 5
      width  = 4
      height = 3
      nrql_query {
        query = "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName IN (${local.app_names}) FACET appName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "p95 de respuesta (s), por servicio"
      row    = 6
      column = 9
      width  = 4
      height = 3
      nrql_query {
        query = "SELECT percentile(duration, 95) FROM Transaction WHERE transactionType = 'Web' AND appName IN (${local.app_names}) FACET appName TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Duración de los health checks (ms): un hueco o un pico es una caída"
      row    = 9
      column = 1
      width  = 8
      height = 3
      nrql_query {
        query = "SELECT average(duration) FROM SyntheticCheck WHERE monitorName LIKE '${local.prefix}%' FACET monitorName TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Últimos checks fallados"
      row    = 9
      column = 9
      width  = 4
      height = 3
      nrql_query {
        query = "SELECT monitorName, locationLabel, error FROM SyntheticCheck WHERE monitorName LIKE '${local.prefix}%' AND result = 'FAILED' SINCE 1 day ago LIMIT 20"
      }
    }
  }

  page {
    name = "Crear un snippet"

    widget_markdown {
      title  = "El recorrido de una creación"
      row    = 1
      column = 1
      width  = 12
      height = 2
      text   = <<-EOT
        `POST /snippets` en snippet-service: valida en **language-service**, guarda la metadata en **snippet-db**, el código en
        **asset-service** (→ Azurite) y el owner en **permission-service** (→ permission-db). Después del commit encola el
        linteo en **Redis**, que lo procesa en segundo plano llamando otra vez a language-service: todo en el mismo trace.
        Para ver uno: copiar un `trace.id` de la tabla y buscarlo en *Distributed tracing*, o abrir *APM → ${local.snippet_app}
        → Distributed tracing* y filtrar por `request.uri = '/snippets'`.
      EOT
    }

    widget_billboard {
      title  = "Snippets creados (24 h)"
      row    = 3
      column = 1
      width  = 3
      height = 3
      nrql_query {
        query = "SELECT filter(count(*), WHERE http.statusCode = 201) AS 'Creados', filter(count(*), WHERE http.statusCode IN (400, 422)) AS 'Rechazados (inválidos)', filter(count(*), WHERE error IS true) AS 'Con error' FROM Transaction WHERE ${local.create_filter} SINCE 1 day ago"
      }
    }

    widget_line {
      title  = "Duración de la creación (s): mediana y p95"
      row    = 3
      column = 4
      width  = 5
      height = 3
      nrql_query {
        query = "SELECT percentile(duration, 50, 95) FROM Transaction WHERE ${local.create_filter} TIMESERIES AUTO"
      }
    }

    widget_bar {
      title  = "Dónde se va el tiempo de una creación (promedio por paso, ms)"
      row    = 3
      column = 9
      width  = 4
      height = 6
      nrql_query {
        query = "SELECT average(duration.ms) FROM Span WHERE trace.id IN (SELECT uniques(trace.id) FROM Transaction WHERE ${local.create_filter} SINCE 1 hour ago LIMIT MAX) FACET appName, name SINCE 1 hour ago LIMIT 25"
      }
    }

    widget_table {
      title  = "Últimas creaciones, con su trace"
      row    = 6
      column = 1
      width  = 8
      height = 3
      nrql_query {
        query = "SELECT timestamp, trace.id, duration, http.statusCode, request.headers.contentLength AS 'Bytes' FROM Transaction WHERE ${local.create_filter} SINCE 1 day ago LIMIT 20"
      }
    }

    widget_line {
      title  = "Linteo y formateo en segundo plano (Redis Streams): procesados y fallados por minuto"
      row    = 9
      column = 1
      width  = 8
      height = 3
      nrql_query {
        query = "SELECT rate(count(*), 1 minute) AS 'Procesados', rate(filter(count(*), WHERE error IS true), 1 minute) AS 'Fallados' FROM Transaction WHERE appName = '${local.snippet_app}' AND name LIKE 'OtherTransaction/RedisStream/%' FACET name TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Servicios que tocó cada creación (última hora)"
      row    = 9
      column = 9
      width  = 4
      height = 3
      nrql_query {
        query = "SELECT uniqueCount(trace.id) AS 'Traces' FROM Span WHERE trace.id IN (SELECT uniques(trace.id) FROM Transaction WHERE ${local.create_filter} SINCE 1 hour ago LIMIT MAX) FACET appName SINCE 1 hour ago"
      }
    }
  }

  page {
    name = "Servicios"

    widget_line {
      title  = "Llamados de snippet-service a los demás (ms promedio)"
      row    = 1
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(duration.ms) FROM Span WHERE appName = '${local.snippet_app}' AND category = 'http' FACET name TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Consultas a las bases y a Redis (ms promedio)"
      row    = 1
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(duration.ms) FROM Span WHERE appName IN (${local.app_names}) AND category = 'datastore' FACET appName, db.system TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Heap usado de la JVM (MB), por servicio"
      row    = 4
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(newrelic.timeslice.value) FROM Metric WHERE metricTimesliceName = 'Memory/Heap/Used' AND appName IN (${local.app_names}) FACET appName TIMESERIES AUTO"
      }
    }

    widget_table {
      title  = "Errores más frecuentes (24 h)"
      row    = 4
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM TransactionError WHERE appName IN (${local.app_names}) FACET appName, error.class, error.message SINCE 1 day ago LIMIT 20"
      }
    }

    widget_line {
      title  = "Logs de error y warning por servicio"
      row    = 7
      column = 1
      width  = 12
      height = 3
      nrql_query {
        query = "SELECT count(*) FROM Log WHERE entity.name IN (${local.app_names}) AND level IN ('ERROR', 'WARN') FACET entity.name, level TIMESERIES AUTO"
      }
    }
  }

  page {
    name = "VM y containers"

    widget_line {
      title  = "Memoria de cada container (% de su límite)"
      row    = 1
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT max(memoryUsageLimitPercent) FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name` TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "CPU de cada container (%)"
      row    = 1
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT average(cpuPercent) FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name` TIMESERIES AUTO"
      }
    }

    widget_line {
      title  = "Containers distintos por servicio (sube en cada deploy y en cada caída)"
      row    = 4
      column = 1
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT uniqueCount(containerId) FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name` TIMESERIES 5 minutes"
      }
    }

    widget_table {
      title  = "Containers ahora"
      row    = 4
      column = 7
      width  = 6
      height = 3
      nrql_query {
        query = "SELECT latest(state) AS 'Estado', latest(imageName) AS 'Imagen', latest(memoryUsageBytes) / 1e6 AS 'MB', latest(memoryUsageLimitPercent) AS '% límite' FROM ContainerSample WHERE ${local.infra_filter} FACET `label.com.docker.swarm.service.name` SINCE 2 minutes ago"
      }
    }

    widget_line {
      title  = "VM: CPU y memoria (%)"
      row    = 7
      column = 1
      width  = 12
      height = 3
      nrql_query {
        query = "SELECT average(cpuPercent) AS 'CPU', average(memoryUsedPercent) AS 'Memoria' FROM SystemSample WHERE ${local.infra_filter} TIMESERIES AUTO"
      }
    }
  }
}

output "dashboard_url" {
  value = newrelic_one_dashboard.snippet_searcher.permalink
}
