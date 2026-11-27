#!/usr/bin/env bash
# Muestra el CD de un servicio en vivo y prueba que un deploy toca solo ese servicio.
#
# No hace falta un commit nuevo: busca el último deploy que GitHub registró para ese servicio en ese entorno
# (Settings → Environments), vuelve a correr solo su job "Deploy to VM" y compara las tareas del stack antes y
# después. Ese job entra por SSH a la VM con la deploy key del environment y corre un único comando:
#   docker service update --with-registry-auth --image ghcr.io/ingsis-2026/<svc>:sha-<commit> snippet_<svc>
#
# Uso:   bash demo-deploy.sh <servicio> [dev|prod]        (por defecto dev)
#        servicio: snippet-service | permission-service | language-service | printscript-ui
#
# Necesita: gh logueado con acceso a Ingsis-2026, y el docker context snippet-dev o snippet-prod.
# Antes: la VM prendida hace unos 10 minutos (con el stack recién arrancado, un update puede hacer rollback).
# Se niega si el último deploy no es el commit de la punta de la rama: re-correrlo volvería a una versión vieja.
set -euo pipefail

SVC="${1:-}"
ENV="${2:-dev}"
ORG="Ingsis-2026"
STACK="snippet"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

case "$SVC" in
    snippet-service | permission-service | language-service | printscript-ui) ;;
    *) die "Uso: bash $(basename "$0") <snippet-service|permission-service|language-service|printscript-ui> [dev|prod]" ;;
esac
case "$ENV" in
    dev) BRANCH="dev" ;;
    prod) BRANCH="main"; [ "$SVC" = "printscript-ui" ] && BRANCH="master" ;;
    *) die "Entorno desconocido: $ENV (dev o prod)" ;;
esac
REPO="$ORG/$SVC"
CTX="${DOCKER_CONTEXT:-snippet-$ENV}"

docker --context "$CTX" service ls > /dev/null 2>&1 ||
    die "No se pudo hablar con la VM por el context $CTX. ¿Está prendida?"

# El último deploy a este environment y el job que lo hizo (su log_url apunta a .../runs/<run>/job/<job>).
deployment=$(gh api "repos/$REPO/deployments?environment=$ENV&per_page=1" --jq '.[0].id // empty')
[ -n "$deployment" ] || die "$REPO no tiene deploys registrados en $ENV."
log_url=$(gh api "repos/$REPO/deployments/$deployment/statuses" --jq '[.[] | select(.log_url != null and .log_url != "")][0].log_url // empty')
[[ "$log_url" =~ /runs/([0-9]+)/job/([0-9]+) ]] || die "No encontré el job de ese deploy ($log_url)."
RUN="${BASH_REMATCH[1]}"
JOB="${BASH_REMATCH[2]}"

# Qué imagen despliega ese job, y si sigue siendo la punta de la rama.
tag=$(gh run view -R "$REPO" --job "$JOB" --log 2> /dev/null | grep -oE 'TAG: sha-[0-9a-f]{8}' | head -1 | cut -c6- || true)
tip=$(gh api "repos/$REPO/commits/$BRANCH" --jq '.sha[0:8]')
[ -n "$tag" ] || die "No pude leer qué imagen desplegó el job $JOB (¿logs vencidos?)."
[ "$tag" = "sha-$tip" ] ||
    die "El último deploy a $ENV fue $tag, pero $BRANCH ya está en $tip: re-correrlo volvería atrás. Para un deploy nuevo, mergeá algo a $BRANCH."

# Si el servicio ya corre esa misma imagen, el update no cambia la spec y Swarm no crea ninguna tarea: no hay nada que mostrar.
running=$(docker --context "$CTX" service inspect "${STACK}_$SVC" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
if [ "${running%@*}" = "ghcr.io/ingsis-2026/$SVC:$tag" ]; then
    note "${STACK}_$SVC ya corre $tag: re-correr el deploy no cambiaría nada. Elegí otro servicio, o volvelo antes al tag"
    note "del stack (eso también lo reinicia):"
    note "  docker --context $CTX service update --detach --with-registry-auth --image ghcr.io/ingsis-2026/$SVC:$ENV ${STACK}_$SVC"
    exit 1
fi

if [ "$ENV" = "prod" ]; then
    read -r -p "Esto actualiza $SVC en PROD (mismo código, imagen $tag). ¿Seguir? [s/N] " answer < /dev/tty
    [ "$answer" = "s" ] || die "Cancelado."
fi

snapshot() {
    local name
    for name in $(docker --context "$CTX" service ls --format '{{.Name}}'); do
        docker --context "$CTX" service ps "$name" --filter desired-state=running \
            --format "$name	{{.ID}}	{{.Image}}	{{.CurrentState}}" | head -1
    done | sort
}

say "Deploy de $SVC a $ENV"
note "Repo $REPO, rama $BRANCH en $tip; imagen ghcr.io/ingsis-2026/$SVC:$tag"
note "Run: https://github.com/$REPO/actions/runs/$RUN"

say "Antes: la tarea que corre en cada servicio"
before=$(snapshot)
printf '%s\n' "$before" | column -t -s $'\t' | sed 's/^/  /'

say "Re-corro solo el job \"Deploy to VM\""
attempt=$(gh run view "$RUN" -R "$REPO" --json attempt --jq .attempt)
gh run rerun "$RUN" -R "$REPO" --job "$JOB" > /dev/null
started=$(date +%s)
note "Mostrá el run en Actions mientras tanto: environment $ENV, un paso de SSH, un comando."
# Hasta que GitHub registra el intento nuevo, el run sigue mostrando el resultado del anterior (que pudo haber fallado).
for _ in $(seq 1 30); do
    [ "$(gh run view "$RUN" -R "$REPO" --json attempt --jq .attempt)" -gt "$attempt" ] && break
    sleep 2
done
gh run watch "$RUN" -R "$REPO" --exit-status --interval 10 > /dev/null 2>&1 ||
    die "El job falló. Mirá el run: https://github.com/$REPO/actions/runs/$RUN"
note "Terminó en $(($(date +%s) - started)) s."

say "Después"
after=$(snapshot)
printf '%s\n' "$after" | column -t -s $'\t' | sed 's/^/  /'

say "Qué cambió"
changed=0
unchanged=0
while IFS=$'\t' read -r name id image _; do
    old=$(printf '%s\n' "$before" | awk -F'\t' -v n="$name" '$1 == n {print $2 "\t" $3}')
    if [ "$old" = "$id	$image" ]; then
        unchanged=$((unchanged + 1))
    else
        changed=$((changed + 1))
        note "$name: tarea ${old%%	*} → $id, imagen ${old#*	} → $image"
    fi
done <<< "$after"
note "$changed servicio(s) con tarea nueva; $unchanged sin tocar (misma tarea que antes)."

say "Historial de ${STACK}_$SVC (la tarea vieja queda Shutdown debajo de la nueva)"
docker --context "$CTX" service ps "${STACK}_$SVC" --format '{{.Name}}	{{.Image}}	{{.DesiredState}}	{{.CurrentState}}' |
    head -4 | column -t -s $'\t' | sed 's/^/  /'
