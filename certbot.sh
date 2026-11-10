#!/usr/bin/env sh
# El certificado HTTPS de <DUCKDNS_SUBDOMAIN>.duckdns.org. certbot es un container que corre una vez y termina.
# Como deploy.sh, corre en el runner contra el docker de la VM (un docker context). Lo llama deploy.sh en cada
# deploy, en dos pasos:
#
#   sh certbot.sh <dev|prod> self-signed
#                               antes del deploy. nginx no arranca sin un certificado para el 443, y el de
#                               Let's Encrypt se pide con nginx ya andando (valida el dominio por el 80):
#                               si todavía no hay ninguno, deja uno autofirmado en su lugar.
#   sh certbot.sh <dev|prod>    después del deploy. Le pide el certificado a Let's Encrypt y recarga nginx.
#                               Si ya hay uno y le faltan más de 30 días para vencer, no pide nada; si le
#                               falta menos, lo renueva.
set -eu
cd "$(dirname "$0")"

# El subdominio sale de env/<entorno>.env, que está versionado. LETSENCRYPT_EMAIL es opcional y llega del workflow:
# Let's Encrypt avisa ahí si el certificado está por vencer y no se renovó.
env_name="${1:-}"
if [ ! -f "env/$env_name.env" ]; then
    echo "Uso: sh certbot.sh <dev|prod> [self-signed]" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "./env/$env_name.env"

domain="$DUCKDNS_SUBDOMAIN.duckdns.org"
live="/etc/letsencrypt/live/$domain"

# Los mismos volúmenes que monta nginx: el stack les pone el prefijo "snippet_".
run_certbot() {
    docker run --rm \
        -v snippet_letsencrypt:/etc/letsencrypt \
        -v snippet_acme-challenge:/var/www/certbot \
        "$@"
}

# Deja un certificado autofirmado donde nginx busca el real, si ahí no hay ninguno. Usa el openssl de la
# imagen de certbot.
self_signed() {
    run_certbot --entrypoint sh certbot/certbot:v3.0.1 -c "
        if [ ! -f $live/fullchain.pem ]; then
            echo 'No hay certificado para $domain: dejo uno autofirmado'
            mkdir -p $live
            openssl req -x509 -nodes -newkey rsa:2048 -days 30 -subj /CN=$domain \
                -keyout $live/privkey.pem -out $live/fullchain.pem 2>/dev/null
        fi
    "
}

if [ "${2:-}" = "self-signed" ]; then
    self_signed
    exit 0
fi

# Espera a que nginx responda en el 80, que es por donde valida Let's Encrypt. El chequeo es un container en la
# red de la VM (--network host), porque este script no corre en ella. Cualquier respuesta HTTP sirve.
echo "Esperando a nginx en el puerto 80..."
if ! docker run --rm --network host --entrypoint python certbot/certbot:v3.0.1 -c "
import http.client, sys, time
for _ in range(30):
    try:
        connection = http.client.HTTPConnection('127.0.0.1', 80, timeout=3)
        connection.request('GET', '/')
        connection.getresponse()
        sys.exit(0)
    except Exception:
        time.sleep(2)
sys.exit(1)
"; then
    echo "nginx no responde en el puerto 80" >&2
    exit 1
fi

# Sin renewal/<dominio>.conf, lo que hay en live/<dominio> es el autofirmado: se borra para que certbot escriba
# el real en esa misma carpeta, que es la que lee nginx (si no, lo deja en <dominio>-0001). nginx sigue sirviendo
# con el que ya tiene cargado hasta que se lo recargue.
run_certbot --entrypoint sh certbot/certbot:v3.0.1 -c "
    if [ ! -f /etc/letsencrypt/renewal/$domain.conf ]; then
        rm -rf $live /etc/letsencrypt/archive/$domain
    fi
"

if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
    email="--email $LETSENCRYPT_EMAIL"
else
    email="--register-unsafely-without-email"
fi

# shellcheck disable=SC2086  # $email son dos palabras a propósito
if ! run_certbot certbot/certbot:v3.0.1 certonly --webroot -w /var/www/certbot \
    -d "$domain" --cert-name "$domain" $email \
    --agree-tos --no-eff-email --non-interactive --keep-until-expiring; then
    # Si se borró el autofirmado y no llegó el real, se vuelve a dejar uno, para que nginx pueda reiniciar.
    self_signed
    exit 1
fi

# Recarga nginx sin cortar conexiones para que tome el certificado. Durante un update puede haber dos containers.
for container in $(docker ps -q -f name=snippet_proxy); do
    docker exec "$container" nginx -s reload
done
echo "Certificado listo: https://$domain"
