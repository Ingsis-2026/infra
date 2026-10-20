#!/usr/bin/env sh
# Despliega (o actualiza) el stack "snippet" en el Swarm de esta VM.
# Corre en la VM, en ~/snippet-searcher, al lado del .env de ese entorno. Lo llama el workflow deploy.yml.
set -eu
cd "$(dirname "$0")"

# docker stack deploy no lee el .env: lo exportamos para que reemplace las ${VARIABLES} del stack.
set -a
# shellcheck source=/dev/null
. ./.env
set +a

docker stack deploy -c docker-stack.yml --with-registry-auth --prune snippet
docker stack services snippet
