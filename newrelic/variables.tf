variable "account_id" {
  description = "El id de la cuenta de New Relic (el número que aparece en la URL de one.newrelic.com)."
  type        = number
}

variable "region" {
  description = "US o EU: dónde se creó la cuenta."
  type        = string
  default     = "US"
}

variable "environment" {
  description = "dev o prod. Tiene que coincidir con IMAGE_TAG en el .env de la VM: es parte del nombre de cada aplicación."
  type        = string
}

variable "domain" {
  description = "El dominio de la VM de este entorno, sin https://."
  type        = string
}

variable "alert_emails" {
  description = "A quiénes les llega un mail cuando se abre o se cierra una alerta."
  type        = list(string)
}

variable "synthetics_locations" {
  description = "Desde dónde corren los monitores sintéticos. São Paulo está cerca de la VM (Brazil South); Virginia confirma que no es un problema de una sola región."
  type        = list(string)
  default     = ["SA_EAST_1", "US_EAST_1"]
}

variable "flow_check_period" {
  description = <<-EOT
    Cada cuánto corre el monitor que crea, lee y borra un snippet de punta a punta. Los ping son gratis, pero este
    cuenta contra los checks del plan (500 por mes en el gratuito, por eso el default). Para la demo, EVERY_5_MINUTES.
  EOT
  type        = string
  default     = "EVERY_6_HOURS"
}

# La aplicación machine-to-machine de Auth0 con la que el monitor de punta a punta pide un token para la API de
# snippet-service (client credentials). Tiene que estar autorizada para la API https://snippet-searcher/api.
# Sin client id no se crea ese monitor; los demás no la necesitan.
variable "auth0_domain" {
  type    = string
  default = "dev-2fvmkxju8g70kqvs.us.auth0.com"
}

variable "auth0_audience" {
  type    = string
  default = "https://snippet-searcher/api"
}

variable "auth0_synthetics_client_id" {
  type    = string
  default = ""
}

variable "auth0_synthetics_client_secret" {
  description = "Se guarda como secure credential en New Relic: el script no lo ve en texto plano. Pasarlo con TF_VAR_auth0_synthetics_client_secret, no en el .tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

variable "availability_target" {
  description = "Objetivo de los SLO de disponibilidad, en % de los últimos 28 días. 99,5 deja 3 h 21 min de error budget."
  type        = number
  default     = 99.5
}

variable "latency_target" {
  description = "Objetivo del SLO de latencia: % de las lecturas que tienen que responder en menos de latency_threshold_seconds."
  type        = number
  default     = 99
}

variable "latency_threshold_seconds" {
  description = <<-EOT
    Cuánto puede tardar una lectura para contar como buena. Listar lee el código de cada snippet de la página en
    asset-service, uno por uno: por eso 500 ms y no los 300 de una lectura simple.
  EOT
  type        = number
  default     = 0.5
}

variable "stream_backlog_threshold" {
  description = "Cuántos mensajes esperando en un stream de Redis, durante 15 minutos, cuentan como cola atrasada."
  type        = number
  default     = 100
}
