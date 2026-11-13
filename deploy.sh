#!/usr/bin/env sh
# Despliega (o actualiza) el stack "snippet" en el Swarm de la VM y después pide el certificado HTTPS.
# Uso: sh deploy.sh <dev|prod>. Lo llama el workflow deploy.yml.
#
# No corre en la VM sino en el runner (o en tu máquina), parado en este repo: cada comando de docker se ejecuta
# en el docker de la VM a través de un docker context por SSH. Por eso a la VM no se copia ningún archivo: el
# stack y la config de nginx los lee el cliente de docker de acá y se los manda a Swarm.
#
# En la VM no hay ningún .env. Lo que no es secreto sale de env/<entorno>.env, que está versionado. Lo secreto
# son Docker Secrets: se crean acá la primera vez, con las variables que pasa el workflow desde los secretos del
# environment de GitHub, y después viven solo dentro de Swarm (cifrados, y montados en /run/secrets de cada servicio).
set -eu
cd "$(dirname "$0")"

env_name="${1:-}"
if [ ! -f "env/$env_name.env" ]; then
    echo "Uso: sh deploy.sh <dev|prod>" >&2
    exit 1
fi

# docker stack deploy no lee archivos de variables: las exportamos para que reemplace las ${VARIABLES} del stack.
set -a
# shellcheck source=/dev/null
. "./env/$env_name.env"
set +a
if [ -z "${DUCKDNS_SUBDOMAIN:-}" ]; then
    echo "Falta DUCKDNS_SUBDOMAIN en env/$env_name.env" >&2
    exit 1
fi

# Crea el secreto si todavía no existe, con el valor de la variable. Si ya existe no lo toca: un secreto de Swarm
# no se puede modificar (para cambiarlo, ver "Cambiar un secreto" en el README). Va con printf y sin salto de
# línea al final, porque Spring usa el contenido del archivo tal cual.
ensure_secret() {
    name="$1"
    variable="$2"
    value="$3"
    if docker secret inspect "$name" > /dev/null 2>&1; then
        return 0
    fi
    if [ -z "$value" ]; then
        echo "No existe el secreto $name y no llegó $variable para crearlo." >&2
        return 1
    fi
    printf '%s' "$value" | docker secret create "$name" - > /dev/null
    echo "Secreto $name creado."
}

ensure_secret snippet-db-password SNIPPET_DB_PASSWORD "${SNIPPET_DB_PASSWORD:-}"
ensure_secret permission-db-password PERMISSION_DB_PASSWORD "${PERMISSION_DB_PASSWORD:-}"
ensure_secret duckdns-token DUCKDNS_TOKEN "${DUCKDNS_TOKEN:-}"
ensure_secret auth0-m2m-client-id AUTH0_M2M_CLIENT_ID "${AUTH0_M2M_CLIENT_ID:-}"
ensure_secret auth0-m2m-client-secret AUTH0_M2M_CLIENT_SECRET "${AUTH0_M2M_CLIENT_SECRET:-}"
# La license key de New Relic se guarda como la opción de java que la define: ver x-newrelic-env en el stack.
ensure_secret newrelic-java-options NEW_RELIC_LICENSE_KEY \
    "${NEW_RELIC_LICENSE_KEY:+-Dnewrelic.config.license_key=$NEW_RELIC_LICENSE_KEY}"

# Un config de Swarm no se puede modificar: si cambia la config de nginx, tiene que ser un config con otro nombre.
# El nombre lleva un hash de los archivos de nginx/, así cambia solo cuando cambian ellos.
# sha256sum en Linux (el runner); shasum en macOS, para un deploy a mano.
NGINX_CONFIG_VERSION=$(cat nginx/* | { sha256sum 2> /dev/null || shasum -a 256; } | cut -c1-12)
export NGINX_CONFIG_VERSION

# nginx no arranca sin un certificado para el 443: si todavía no hay ninguno, uno autofirmado.
sh ./certbot.sh "$env_name" self-signed

# Las imágenes de ghcr.io/ingsis-2026 son públicas: la VM no necesita docker login.
docker stack deploy -c docker-stack.yml --prune snippet
docker stack services snippet

# Borra los configs de nginx que quedaron de deploys anteriores. Los que están en uso no se pueden borrar:
# docker se niega y quedan para el próximo deploy.
docker config ls -q -f name=snippet-nginx- | xargs -r docker config rm > /dev/null 2>&1 || true

# El agente de infraestructura de New Relic: CPU, memoria y disco de la VM y de cada container (ContainerSample),
# con su límite de memoria y sus reinicios. Es lo que avisa cuando un container se cae o se reinicia en loop aunque
# el servicio no llegue a reportar nada: un OOM, una imagen que no arranca en un deploy.
# No es un servicio del stack porque necesita ver los cgroups y los procesos de la VM (--cgroupns=host, --pid=host,
# --privileged) y Swarm no admite ninguna de esas opciones: dentro del stack, con cgroups v2, ve la memoria de
# todos los containers en 0. Por lo mismo no puede leer un Docker Secret: recibe la key del workflow, en este
# deploy. Si la key no llega (un deploy a mano), el agente que ya está corriendo queda como está.
# Los paths de -v son de la VM: los resuelve el docker de allá, no el de quien corre este script.
if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
    docker rm -f newrelic-infra > /dev/null 2>&1 || true
    docker run -d --name newrelic-infra --restart unless-stopped \
        --network host --cgroupns host --pid host --privileged \
        --memory 256m \
        -v /:/host:ro -v /var/run/docker.sock:/var/run/docker.sock \
        -e NRIA_LICENSE_KEY="$NEW_RELIC_LICENSE_KEY" \
        -e NRIA_DISPLAY_NAME="snippet-searcher-$IMAGE_TAG" \
        -e NRIA_CUSTOM_ATTRIBUTES="{\"env\":\"$IMAGE_TAG\",\"stack\":\"snippet\"}" \
        newrelic/infrastructure:latest > /dev/null
    echo "Agente de infraestructura de New Relic corriendo (newrelic-infra)."
fi

# Si falla (por ejemplo, DuckDNS todavía no apunta a esta VM), el stack queda andando con el certificado
# autofirmado y se reintenta en el próximo deploy, o a mano con: sh certbot.sh <dev|prod> (ver el README)
if ! sh ./certbot.sh "$env_name"; then
    echo "No se pudo conseguir el certificado de Let's Encrypt: nginx sigue con el autofirmado." >&2
fi
