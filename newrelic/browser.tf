# La UI vista desde el navegador de cada usuario (browser monitoring): cuánto tarda en cargar, qué errores de
# JavaScript tira, cuánto tardan los pedidos a /api y las navegaciones dentro de la SPA. Una aplicación de browser
# por entorno, a la que reporta el agente de npm (@newrelic/browser-agent) que inicializa printscript-ui.
#
# El agente va dentro del build de la UI, así que lo que necesita sale de acá como outputs y se carga como variables
# de GitHub en printscript-ui (ver README, "Browser monitoring"). Nada de eso es secreto: la license key de browser
# viaja a cada navegador.

resource "newrelic_browser_application" "ui" {
  name = local.browser_app

  # SPA: también mide las navegaciones que hace react-router sin recargar la página.
  loader_type = "SPA"
  # Los pedidos a /api llevan los headers de distributed tracing: el trace de snippet-service arranca en el navegador.
  distributed_tracing_enabled = true
  cookies_enabled             = true
}

locals {
  # El nombre de la aplicación de browser, que es el appName de sus eventos (PageView, JavaScriptError, AjaxRequest).
  browser_app = "printscript-ui-${var.environment}"

  # js_config es la configuración del agente de npm en JSON: { "info": {...}, "loader_config": {...}, "init": {...} },
  # lo mismo que muestra el snippet de copy/paste de la aplicación. Los try cubren también una forma plana, por las
  # dudas; si no aparece ninguna, browser_js_config tiene el JSON entero para sacarlos a mano.
  browser_js_config = try(jsondecode(newrelic_browser_application.ui.js_config), {})

  browser = {
    application_id = newrelic_browser_application.ui.application_id
    account_id     = try(local.browser_js_config.loader_config.accountID, local.browser_js_config.accountID, tostring(var.account_id))
    # En una cuenta que no es subcuenta de otra, el trust key es el mismo account id.
    trust_key   = try(local.browser_js_config.loader_config.trustKey, local.browser_js_config.trustKey, tostring(var.account_id))
    license_key = try(local.browser_js_config.info.licenseKey, local.browser_js_config.loader_config.licenseKey, local.browser_js_config.licenseKey, null)
  }
}

output "browser_application_id" {
  description = "El id de la aplicación de browser de este entorno (no el GUID): VITE_NEW_RELIC_APPLICATION_ID."
  value       = local.browser.application_id
}

output "browser_account_id" {
  description = "VITE_NEW_RELIC_ACCOUNT_ID."
  value       = local.browser.account_id
}

output "browser_trust_key" {
  description = "VITE_NEW_RELIC_TRUST_KEY."
  value       = local.browser.trust_key
}

output "browser_license_key" {
  description = "La license key de browser (NRJS-...). Es pública: va en el JavaScript que baja cada navegador. VITE_NEW_RELIC_LICENSE_KEY."
  value       = local.browser.license_key
}

output "browser_js_config" {
  description = "La configuración completa del agente de npm, en JSON, tal como la devuelve New Relic."
  value       = newrelic_browser_application.ui.js_config
}

# Las variables de repositorio de printscript-ui, con sus nombres: la cuenta es la misma para dev y prod, y la
# aplicación cambia por entorno.
output "browser_github_variables" {
  description = "Las variables de GitHub que espera el CD de printscript-ui, con el valor de este entorno."

  value = {
    NEW_RELIC_ACCOUNT_ID                                         = local.browser.account_id
    NEW_RELIC_TRUST_KEY                                          = local.browser.trust_key
    NEW_RELIC_BROWSER_LICENSE_KEY                                = local.browser.license_key
    "NEW_RELIC_BROWSER_APPLICATION_ID_${upper(var.environment)}" = local.browser.application_id
  }
}
