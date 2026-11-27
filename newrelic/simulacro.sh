#!/usr/bin/env bash
# Rompe algo a propósito en dev para mostrar que New Relic lo ve y manda el mail. Pensado para la demo de la
# defensa: cada escenario dice qué mostrar en la UI y en New Relic mientras espera, y deja todo como estaba.
#
# Uso, parado en el repo infra:
#   bash newrelic/simulacro.sh preparar                # antes de la demo: ¿está todo arriba y sin incidentes abiertos?
#   bash newrelic/simulacro.sh caida [servicio]        # baja un servicio, espera el mail, lo sube y espera el de cierre
#   bash newrelic/simulacro.sh deploy-roto [servicio]  # despliega una imagen que no existe y mira el rollback
#   bash newrelic/simulacro.sh volver [servicio]       # sube lo que haya quedado en 0 réplicas
#   bash newrelic/simulacro.sh estado
#
# Como deploy.sh, corre en tu máquina contra el docker de la VM por un docker context (por defecto snippet-dev).
# Solo funciona contra dev: se niega si el context se llama *prod* o si el stack corre imágenes :prod.
#
# Por qué "preparar": cada política de alertas tiene un solo incidente abierto a la vez, y el mail sale cuando se abre
# y cuando se cierra. Si al romper algo ya hay uno abierto en "snippet-searcher-dev caídas" (por ejemplo, de cuando se
# apagó la VM), la caída se suma a ese y no llega ningún mail. preparar lo encuentra y ofrece cerrarlo.
# Para hablar con New Relic usa una User key (NRAK-...): NEW_RELIC_API_KEY o el archivo ~/.config/newrelic/user-key, y
# el account id: NEW_RELIC_ACCOUNT_ID o el de newrelic/dev.tfvars. Sin eso, el simulacro igual rompe y arregla, pero no
# puede revisar incidentes ni medir cuándo salió el mail.
#
# Antes: la VM de dev prendida hace unos 10 minutos (con el stack recién arrancado, un update puede hacer rollback
# solo por falta de CPU) y el dashboard y Alerts → Issues abiertos en New Relic. Las condiciones están en la sección
# "Alertas" de newrelic/README.md.
set -euo pipefail

STACK=snippet
export DOCKER_CONTEXT="${DOCKER_CONTEXT:-snippet-dev}"
BACKENDS="snippet-service permission-service language-service asset-service"
# El account id sale de NEW_RELIC_ACCOUNT_ID o del dev.tfvars de al lado (no versionado), como en el tofu apply.
NR_ACCOUNT_ID="${NEW_RELIC_ACCOUNT_ID:-$(awk -F= '/^account_id/ { gsub(/[ "]/, "", $2); print $2 }' \
    "$(dirname "$0")/dev.tfvars" 2>/dev/null || true)}"
NR_PREFIX="snippet-searcher-dev"
POLICY_CAIDAS="$NR_PREFIX caídas"
POLICY_DEGRADACION="$NR_PREFIX degradación"

usage() {
    sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
mmss() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

require_backend() {
    case " $BACKENDS " in
        *" $1 "*) ;;
        *) echo "Servicio desconocido: $1 (uno de: $BACKENDS)" >&2; exit 1 ;;
    esac
}

# Dos cerrojos para no romper prod por error: el nombre del context y la imagen que corre de verdad.
require_dev() {
    case "$DOCKER_CONTEXT" in
        *prod*) echo "El context $DOCKER_CONTEXT parece de prod. Este script solo corre contra dev." >&2; exit 1 ;;
    esac
    local image
    if ! image=$(docker service inspect "${STACK}_snippet-service" \
            --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null); then
        echo "No se pudo hablar con el stack por el context $DOCKER_CONTEXT. ¿La VM de dev está prendida?" >&2
        exit 1
    fi
    case "${image%%@*}" in
        *:dev) ;;
        *) echo "snippet-service corre $image, no una imagen :dev. No toco nada." >&2; exit 1 ;;
    esac
}

replicas() {
    docker service ls --filter "name=${STACK}_$1" --format '{{.Name}} {{.Replicas}}' |
        awk -v n="${STACK}_$1" '$1 == n { print $2 }'
}

# Espera a que el servicio tenga 1/1, o hasta 5 minutos (un servicio de Java tarda más de uno en arrancar).
wait_running() {
    local svc=$1 waited=0
    while [ "$(replicas "$svc")" != "1/1" ]; do
        if [ "$waited" -ge 300 ]; then
            echo "  $svc sigue en $(replicas "$svc") después de 5 minutos. Mirá: docker service ps ${STACK}_$svc" >&2
            return 1
        fi
        sleep 10
        waited=$((waited + 10))
        note "$(printf '%3ds' "$waited")  $svc: $(replicas "$svc")"
    done
}

# --- New Relic ------------------------------------------------------------------------------------------------------
# NerdGraph (la API GraphQL de New Relic) con python3, que viene con macOS y casi todo Linux: sin jq ni nada que instalar.

nr_key() {
    if [ -n "${NEW_RELIC_API_KEY:-}" ]; then
        printf '%s' "$NEW_RELIC_API_KEY"
    elif [ -r "$HOME/.config/newrelic/user-key" ]; then
        tr -d '[:space:]' < "$HOME/.config/newrelic/user-key"
    fi
}

NR_PY=$(cat <<'PY'
import json, sys, time, urllib.request

key, account, cmd, *args = sys.argv[1:]
account = int(account)

def gql(query):
    req = urllib.request.Request(
        "https://api.newrelic.com/graphql",
        data=json.dumps({"query": query}).encode(),
        headers={"API-Key": key, "Content-Type": "application/json"},
    )
    data = json.load(urllib.request.urlopen(req, timeout=20))
    if data.get("errors"):
        sys.exit("New Relic: " + data["errors"][0]["message"])
    return data["data"]

def nrql(query):
    q = "{ actor { account(id: %d) { nrql(query: %s) { results } } } }" % (account, json.dumps(query))
    return gql(q)["actor"]["account"]["nrql"]["results"]

def hhmmss(ms):
    return time.strftime("%H:%M:%S", time.localtime(ms / 1000))

if cmd == "issues":
    # Los issues abiertos de las políticas que empiezan con el prefijo: id, política, desde cuándo, qué condiciones.
    prefix = args[0]
    acc = gql("""{ actor { account(id: %d) {
        alerts { policiesSearch(searchCriteria: {nameLike: %s}) { policies { id name } } }
        aiIssues { issues(filter: {states: [ACTIVATED, CREATED]}) {
            issues { issueId policyIds activatedAt createdAt conditionName } } } } } }"""
        % (account, json.dumps(prefix)))["actor"]["account"]
    policies = {int(p["id"]): p["name"] for p in acc["alerts"]["policiesSearch"]["policies"]
                if p["name"].startswith(prefix + " ")}
    for issue in acc["aiIssues"]["issues"]["issues"]:
        mine = [policies[p] for p in issue["policyIds"] if p in policies]
        if mine:
            since = hhmmss(issue["activatedAt"] or issue["createdAt"])
            print("\t".join([issue["issueId"], mine[0], since, ", ".join(sorted(set(issue["conditionName"])))]))

elif cmd == "close":
    res = gql("mutation { aiIssuesResolveIssue(accountId: %d, issueId: %s) { error result { issueId } } }"
              % (account, json.dumps(args[0])))["aiIssuesResolveIssue"]
    if res.get("error"):
        sys.exit("New Relic no lo cerró: %s" % res["error"])

elif cmd == "mail":
    # El primer mail que mandó el workflow de la política desde since_ms, de apertura o de cierre: "ms HH:MM:SS estado".
    policy, since_ms, kind = args
    triggers = "'STATE_CHANGE'" if kind == "open" else "'INCIDENT_CLOSED', 'CLOSE_TTL'"
    rows = nrql("SELECT timestamp, status FROM NrAiNotification WHERE workflowName = %s AND trigger IN (%s) "
                "AND timestamp >= %s SINCE 1 day ago LIMIT 100"
                % (json.dumps(policy + " avisos").replace('"', "'"), triggers, since_ms))
    if rows:
        first = min(rows, key=lambda r: r["timestamp"])
        print(int(first["timestamp"]), hhmmss(first["timestamp"]), first["status"])

elif cmd == "monitors":
    # El último resultado de cada monitor sintético del entorno en los últimos 5 minutos: "nombre<TAB>resultado".
    for row in nrql("SELECT latest(result) FROM SyntheticCheck WHERE monitorName LIKE '%s%%' "
                    "FACET monitorName SINCE 5 minutes ago LIMIT 50" % args[0]):
        print("%s\t%s" % (row["monitorName"], row["latest.result"]))
PY
)

nr() {
    local key
    key=$(nr_key)
    [ -n "$key" ] && [ -n "$NR_ACCOUNT_ID" ] || return 2
    python3 -c "$NR_PY" "$key" "$NR_ACCOUNT_ID" "$@"
}

have_nr() { [ -n "$(nr_key)" ] && [ -n "$NR_ACCOUNT_ID" ]; }

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# Muestra los issues abiertos de una política y, con terminal, ofrece cerrarlos. Devuelve 1 si queda alguno abierto.
clear_issues() {
    local policy=$1 why=$2 issues id pol since conds answer left=0 tty=0
    [ -t 0 ] && tty=1
    issues=$(nr issues "$NR_PREFIX" | awk -F'\t' -v p="$policy" '$2 == p') || { note "No pude preguntarle a New Relic."; return 1; }
    [ -n "$issues" ] || { note "$policy: sin incidentes abiertos."; return 0; }
    while IFS=$'\t' read -r id pol since conds; do
        note "$pol: incidente abierto desde las $since ($conds)."
        note "$why"
        # El loop lee la lista de issues por stdin: la respuesta se lee de la terminal.
        if [ "$tty" = 1 ] && read -r -p "  ¿Lo cierro? Llega el mail de cierre. [s/N] " answer < /dev/tty &&
                [ "$answer" = s ]; then
            nr close "$id" && note "Cerrado." || left=1
        else
            left=1
        fi
    done <<< "$issues"
    return "$left"
}

# Pregunta cada 15 s si salió el mail de la política hasta que salga o pasen max segundos.
# Imprime "HH:MM:SS estado" y cuánto tardó desde since_ms. Devuelve 1 si no salió.
wait_mail() {
    local policy=$1 since_ms=$2 kind=$3 max=$4 label=$5 waited=0 found
    while [ "$waited" -le "$max" ]; do
        if found=$(nr mail "$policy" "$since_ms" "$kind") && [ -n "$found" ]; then
            set -- $found
            note "Mail de $label enviado a las $2 ($3), $(mmss $((($1 - since_ms) / 1000))) después."
            return 0
        fi
        sleep 15
        waited=$((waited + 15))
        note "$(mmss "$waited")  todavía no salió el mail de $label"
    done
    return 1
}

# --- Comandos -------------------------------------------------------------------------------------------------------

cmd_estado() {
    say "Stack $STACK por el context $DOCKER_CONTEXT"
    docker service ls --filter "name=${STACK}_" --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}'
}

cmd_preparar() {
    require_dev
    local ok=0 down monitors failing

    say "Servicios"
    down=$(docker service ls --filter "name=${STACK}_" --format '{{.Name}} {{.Replicas}}' |
        awk '{ split($2, r, "/"); if (r[1] != r[2] || r[2] == 0) print "  " $1 " " $2 }')
    if [ -n "$down" ]; then
        echo "$down"
        note "Hay servicios que no están arriba: bash newrelic/simulacro.sh volver, o esperá si la VM recién arrancó."
        ok=1
    else
        note "Todos arriba."
    fi

    if ! have_nr; then
        say "New Relic"
        note "Sin User key (NEW_RELIC_API_KEY o ~/.config/newrelic/user-key) y account id (NEW_RELIC_ACCOUNT_ID o"
        note "newrelic/dev.tfvars) no puedo revisar los incidentes."
        note "Mirá a mano Alerts → Issues: no tiene que haber nada abierto en \"$POLICY_CAIDAS\"."
        return 1
    fi

    say "Monitores sintéticos (último resultado, 5 minutos)"
    monitors=$(nr monitors "$NR_PREFIX")
    failing=$(awk -F'\t' '$2 != "SUCCESS"' <<< "$monitors")
    if [ -z "$monitors" ]; then
        note "Ningún resultado en 5 minutos. ¿Están pausados los monitores?"
        ok=1
    elif [ -n "$failing" ]; then
        awk -F'\t' '{ print "  " $1 ": " $2 }' <<< "$failing"
        ok=1
    else
        note "Todos pasan ($(wc -l <<< "$monitors" | tr -d ' '))."
    fi

    say "Incidentes abiertos"
    clear_issues "$POLICY_CAIDAS" \
        "Mientras esté abierto, una caída se suma a este incidente y no manda mail." || ok=1
    clear_issues "$POLICY_DEGRADACION" \
        "No frena el mail de una caída, pero sí el de la tasa de errores que la acompaña." || true

    if [ "$ok" -eq 0 ]; then
        say "Listo para romper: bash newrelic/simulacro.sh caida [servicio]"
    else
        say "Todavía no: resolvé lo de arriba y volvé a correr preparar."
    fi
    return "$ok"
}

# Muestra el tiempo que pasó cada 30 s hasta que apretás Enter, y avisa cuando sale el mail de apertura.
# Sin terminal (CI, un pipe), no espera.
wait_for_enter() {
    local start=$SECONDS broke_ms=$1 found mailed=""
    if [ ! -t 0 ]; then
        note "Sin terminal: no espero. Cuando termines: bash newrelic/simulacro.sh volver"
        return 1
    fi
    note "Enter para volver a la normalidad."
    while ! read -r -t 30; do
        local line
        line="$(mmss $((SECONDS - start))) desde que se rompió"
        if [ -z "$mailed" ] && [ -n "$broke_ms" ] && found=$(nr mail "$POLICY_CAIDAS" "$broke_ms" open) && [ -n "$found" ]; then
            set -- $found
            mailed="$2"
            line="$line. Mail de apertura enviado a las $2 ($3), $(mmss $((($1 - broke_ms) / 1000))) después de romperlo."
        fi
        note "$line"
    done
    OPEN_MAIL_AT=$mailed
}

cmd_caida() {
    local svc=${1:-permission-service}
    require_backend "$svc"
    require_dev

    local broke_ms=""
    if have_nr; then
        say "Antes de romper"
        if ! clear_issues "$POLICY_CAIDAS" "Mientras esté abierto, esta caída se sumaría ahí y no llegaría ningún mail."; then
            echo "Cerralo (en Alerts → Issues o con preparar) y volvé a correr caida." >&2
            exit 1
        fi
    else
        note "Sin User key o account id de New Relic: no puedo revisar incidentes ni medir el mail (ver el encabezado)."
    fi

    say "Bajando $svc (docker service scale ${STACK}_$svc=0) a las $(date +%H:%M:%S)"
    have_nr && broke_ms=$(now_ms)
    docker service scale --detach "${STACK}_$svc=0" > /dev/null

    say "Qué mostrar mientras tanto"
    case "$svc" in
        permission-service)
            note "UI: listar o abrir un snippet falla (snippet-service responde 502: no puede preguntar permisos)."
            note "Es el costo de la card \"Two roles, checked on every request\": un llamado por pedido, sin cache." ;;
        language-service)
            note "UI: crear o editar un snippet falla (no se puede validar), y también todo lo que lintea,"
            note "formatea o ejecuta en el momento. Listar sigue andando."
            note "Cambiá una regla de linteo: responde al instante y los snippets quedan PENDING. En los logs de"
            note "snippet-service se ve el mensaje postergado con backoff, sin gastar intentos (card del worker)."
            note "Al volver language-service, se lintean solos." ;;
        snippet-service)
            note "UI: todo falla con 502 desde nginx. Es el único servicio público (single point of failure)." ;;
        asset-service)
            note "UI: abrir o crear un snippet falla (no hay código); el listado también, porque trae el código." ;;
    esac
    note "New Relic, en un minuto y medio a dos, en la política \"$POLICY_CAIDAS\": \"Monitor sintético fallando\""
    note "(el monitor \"$svc health\"), y unos minutos después \"Servicio sin reportar\" ($svc-dev). Un incidente, un mail."
    note "Si usás la UI mientras tanto, puede abrirse también \"Tasa de errores alta\" en \"$POLICY_DEGRADACION\"."
    note "En APM, el servicio que llama muestra la tasa de errores y el trace marca el llamado que falla."

    OPEN_MAIL_AT=""
    wait_for_enter "$broke_ms" || return 0
    if [ -n "$broke_ms" ] && [ -z "$OPEN_MAIL_AT" ]; then
        note "No vi salir el mail de apertura. Mirá Alerts → Issues: ¿se abrió el incidente?"
    fi

    say "Subiendo $svc"
    local back_ms=""
    have_nr && back_ms=$(now_ms)
    docker service scale --detach "${STACK}_$svc=1" > /dev/null
    wait_running "$svc"
    note "Arriba. El incidente se cierra solo cuando el monitor vuelve a pasar y el agente vuelve a reportar."

    if [ -n "$back_ms" ] && [ -n "$OPEN_MAIL_AT" ]; then
        say "Esperando el mail de cierre (hasta 10 minutos; Ctrl-C para no esperar, no rompe nada)"
        wait_mail "$POLICY_CAIDAS" "$back_ms" close 600 cierre ||
            note "No salió en 10 minutos. Mirá en Alerts → Issues qué condición sigue abierta."
    fi
}

cmd_deploy_roto() {
    local svc=${1:-language-service}
    require_backend "$svc"
    require_dev
    local image
    image=$(docker service inspect "${STACK}_$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')

    say "Desplegando ${image%%:*}:no-existe sobre ${STACK}_$svc"
    note "Imagen actual: $image"
    docker service update --detach --image "${image%%:*}:no-existe" "${STACK}_$svc" > /dev/null

    say "Qué mostrar mientras tanto"
    note "La UI sigue andando: con start-first la tarea vieja no se baja hasta que la nueva arranque, y la"
    note "nueva nunca arranca. Swarm hace rollback (failure_action: rollback). Card \"Deploys without a gap\"."
    note "Para mostrarlo: docker --context $DOCKER_CONTEXT service ps ${STACK}_$svc"
    note "No se espera mail: el usuario no vio nada. Ese es el punto."

    local waited=0 state=""
    while [ "$waited" -lt 300 ]; do
        state=$(docker service inspect "${STACK}_$svc" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')
        note "$(printf '%3ds' "$waited")  estado del update: ${state:-sin empezar}"
        case "$state" in rollback_completed | rollback_paused | paused | completed) break ;; esac
        sleep 15
        waited=$((waited + 15))
    done

    local now
    now=$(docker service inspect "${STACK}_$svc" --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')
    if [ "${now%%@*}" = "${image%%@*}" ]; then
        say "Swarm volvió solo a ${now%%@*}. Nadie fuera de la VM se enteró."
    else
        say "El servicio quedó con $now. Volviendo a mano a la imagen anterior."
        docker service rollback --detach "${STACK}_$svc" > /dev/null
        wait_running "$svc"
    fi
}

cmd_volver() {
    require_dev
    local services=${1:-$BACKENDS} svc
    for svc in $services; do
        require_backend "$svc"
        if [ "$(replicas "$svc")" = "0/0" ]; then
            say "Subiendo $svc"
            docker service scale --detach "${STACK}_$svc=1" > /dev/null
            wait_running "$svc"
        fi
    done
    cmd_estado
}

case "${1:-}" in
    preparar) cmd_preparar ;;
    estado) cmd_estado ;;
    caida) cmd_caida "${2:-}" ;;
    deploy-roto) cmd_deploy_roto "${2:-}" ;;
    volver) cmd_volver "${2:-}" ;;
    *) usage ;;
esac
