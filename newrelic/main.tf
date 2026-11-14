# Lo que New Relic tiene que saber de Snippet Searcher, como código: los monitores sintéticos, las alertas, a quién
# avisan y el dashboard. Se aplica una vez por entorno (dev, prod) desde la máquina de cualquiera del equipo:
#
#   export NEW_RELIC_API_KEY=NRAK-...      # una User key de la cuenta (no la license key)
#   terraform init
#   terraform workspace select -or-create dev     # cada entorno, en su workspace (su propio estado)
#   terraform apply -var-file=dev.tfvars
#
# Ver README.md de esta carpeta.

terraform {
  required_version = ">= 1.5"

  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = "~> 3.50"
    }
  }
}

# La User key sale de NEW_RELIC_API_KEY: no va en ningún archivo.
provider "newrelic" {
  account_id = var.account_id
  region     = var.region
}

locals {
  # Todo lo que se crea lleva el entorno en el nombre: dev y prod conviven en la misma cuenta.
  prefix   = "snippet-searcher-${var.environment}"
  base_url = "https://${var.domain}"

  # Los nombres de las aplicaciones en APM: NEW_RELIC_APP_NAME en docker-stack.yml.
  apps = {
    for service in ["snippet-service", "permission-service", "language-service", "asset-service"] :
    service => "${service}-${var.environment}"
  }
  app_names = join(", ", [for app in values(local.apps) : "'${app}'"])

  # El nombre del host que reporta el agente de infraestructura (NRIA_DISPLAY_NAME en docker-stack.yml), y el filtro
  # por los atributos que le agrega a todo lo que manda (NRIA_CUSTOM_ATTRIBUTES).
  host         = "snippet-searcher-${var.environment}"
  infra_filter = "stack = 'snippet' AND env = '${var.environment}'"

  # Cuánto puede durar un incidente abierto antes de que New Relic lo cierre solo (y lo vuelva a abrir, con otro mail,
  # si sigue fallando): 30 días, el máximo. Con la VM apagada días enteros, menos que eso repetía los mails cada día.
  incident_time_limit = 2592000
}
