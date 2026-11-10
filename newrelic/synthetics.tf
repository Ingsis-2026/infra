# Los monitores sintéticos: New Relic le pega a la VM desde afuera, como un usuario. Son lo único que se entera si
# se cae la VM entera, nginx, el DNS o el certificado: en esos casos los agentes no pueden avisar nada.

# Un ping por cada cosa que se puede caer sola. Los de los servicios internos pasan por las rutas /health/... de
# nginx/locations.conf, porque desde afuera solo se llega a snippet-service. Los ping son gratis y corren cada minuto.
locals {
  health_checks = {
    "ui"                 = { path = "/", validation = "" }
    "snippet-service"    = { path = "/api/actuator/health", validation = "\"UP\"" }
    "permission-service" = { path = "/health/permission-service", validation = "\"UP\"" }
    "language-service"   = { path = "/health/language-service", validation = "\"UP\"" }
    "asset-service"      = { path = "/health/asset-service", validation = "\"UP\"" }
  }
}

resource "newrelic_synthetics_monitor" "health" {
  for_each = local.health_checks

  name             = "${local.prefix} ${each.key} health"
  type             = "SIMPLE"
  status           = "ENABLED"
  period           = "EVERY_MINUTE"
  uri              = "${local.base_url}${each.value.path}"
  locations_public = var.synthetics_locations

  # Un servicio caído hace que nginx responda 502/504 y Spring responde 503 si está DOWN: los dos fallan el check.
  validation_string         = each.value.validation != "" ? each.value.validation : null
  verify_ssl                = true
  treat_redirect_as_failure = false
}

# El flujo principal de punta a punta: pide un token a Auth0, crea un snippet, lo lee y lo borra. Pasa por
# nginx, snippet-service, language-service (validar), snippet-db, asset-service, Azurite, permission-service y
# Redis (el linteo en segundo plano), así que cada corrida deja un trace distribuido completo en New Relic.
resource "newrelic_synthetics_secure_credential" "auth0_client_secret" {
  count = var.auth0_synthetics_client_id == "" ? 0 : 1

  key         = "SNIPPET_SEARCHER_${upper(var.environment)}_AUTH0_SECRET"
  value       = var.auth0_synthetics_client_secret
  description = "Client secret de la aplicación M2M de Auth0 que usa el monitor ${local.prefix} snippet flow"
}

resource "newrelic_synthetics_script_monitor" "snippet_flow" {
  count = var.auth0_synthetics_client_id == "" ? 0 : 1

  name                 = "${local.prefix} snippet flow"
  type                 = "SCRIPT_API"
  status               = "ENABLED"
  period               = var.flow_check_period
  locations_public     = slice(var.synthetics_locations, 0, 1)
  script_language      = "JAVASCRIPT"
  runtime_type         = "NODE_API"
  runtime_type_version = "22.20.0"

  script = templatefile("${path.module}/scripts/snippet-flow.js", {
    base_url       = local.base_url
    auth0_domain   = var.auth0_domain
    auth0_audience = var.auth0_audience
    client_id      = var.auth0_synthetics_client_id
    secret_key     = newrelic_synthetics_secure_credential.auth0_client_secret[0].key
  })
}

# El certificado de Let's Encrypt dura 90 días y deploy.sh solo lo renueva cuando corre: si no hubo deploys en
# dos meses y medio, vence y el navegador deja de entrar. Avisa con 15 días de margen.
resource "newrelic_synthetics_cert_check_monitor" "certificate" {
  name                   = "${local.prefix} certificate"
  domain                 = var.domain
  status                 = "ENABLED"
  period                 = "EVERY_DAY"
  certificate_expiration = 15
  locations_public       = slice(var.synthetics_locations, 0, 1)
  runtime_type           = "NODE_API"
  runtime_type_version   = "22.20.0"

  # New Relic actualiza solo el runtime de los cert checks a la última versión de Node 22 (22.23.4, por ejemplo).
  lifecycle {
    ignore_changes = [runtime_type_version]
  }
}
