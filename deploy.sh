#!/usr/bin/env sh
# Despliega (o actualiza) el stack "snippet" en el Swarm de esta VM y después pide el certificado HTTPS.
# Corre en la VM, en ~/snippet-searcher, al lado del .env de ese entorno. Lo llama el workflow deploy.yml.
set -eu
cd "$(dirname "$0")"

# docker stack deploy no lee el .env: lo exportamos para que reemplace las ${VARIABLES} del stack.
set -a
# shellcheck source=/dev/null
. ./.env
set +a

# Un config de Swarm no se puede modificar: si cambia la config de nginx, tiene que ser un config con otro nombre.
# El nombre lleva un hash de los archivos de nginx/, así cambia solo cuando cambian ellos.
NGINX_CONFIG_VERSION=$(cat nginx/* | sha256sum | cut -c1-12)
export NGINX_CONFIG_VERSION

# nginx no arranca sin un certificado para el 443: si todavía no hay ninguno, uno autofirmado.
sh ./certbot.sh self-signed

docker stack deploy -c docker-stack.yml --with-registry-auth --prune snippet
docker stack services snippet

# Borra los configs de nginx que quedaron de deploys anteriores. Los que están en uso no se pueden borrar:
# docker se niega y quedan para el próximo deploy.
docker config ls -q -f name=snippet-nginx- | xargs -r docker config rm > /dev/null 2>&1 || true

# El agente de infraestructura de New Relic: CPU, memoria y disco de la VM y de cada container (ContainerSample),
# con su límite de memoria y sus reinicios. Es lo que avisa cuando un container se cae o se reinicia en loop aunque
# el servicio no llegue a reportar nada: un OOM, una imagen que no arranca en un deploy.
# No es un servicio del stack porque necesita ver los cgroups y los procesos de la VM (--cgroupns=host, --pid=host,
# --privileged) y Swarm no admite ninguna de esas opciones: dentro del stack, con cgroups v2, ve la memoria de
# todos los containers en 0. Se recrea en cada deploy, así toma la license key y la imagen nuevas.
docker rm -f newrelic-infra > /dev/null 2>&1 || true
if [ -n "${NEW_RELIC_LICENSE_KEY:-}" ]; then
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
# autofirmado y se reintenta en el próximo deploy, o a mano con: sh ~/snippet-searcher/certbot.sh
if ! sh ./certbot.sh; then
    echo "No se pudo conseguir el certificado de Let's Encrypt: nginx sigue con el autofirmado." >&2
fi
