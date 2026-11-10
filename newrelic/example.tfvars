# Copiar a dev.tfvars (o prod.tfvars) y completar. Los .tfvars no se versionan, salvo este ejemplo.
# El client secret de Auth0 no va acá: export TF_VAR_auth0_synthetics_client_secret=...

account_id   = 1234567
region       = "US"
environment  = "dev"
domain       = "snippetsearcher-ingsis2026-dev.duckdns.org"
alert_emails = ["alguien@mail.austral.edu.ar"]

# La aplicación M2M de Auth0 del monitor de punta a punta. Vacío: ese monitor no se crea.
auth0_synthetics_client_id = ""

# Para la demo, que el monitor de punta a punta corra seguido (cuenta contra los checks del plan).
# flow_check_period = "EVERY_5_MINUTES"
