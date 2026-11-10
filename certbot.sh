#!/usr/bin/env sh
# El certificado HTTPS de <DUCKDNS_SUBDOMAIN>.duckdns.org. certbot es un container que corre una vez y termina.
# Corre en la VM, en ~/snippet-searcher. Lo llama deploy.sh en cada deploy, en dos pasos:
#
#   sh certbot.sh self-signed   antes del deploy. nginx no arranca sin un certificado para el 443, y el de
#                               Let's Encrypt se pide con nginx ya andando (valida el dominio por el 80):
#                               si todavía no hay ninguno, deja uno autofirmado en su lugar.
#   sh certbot.sh               después del deploy. Le pide el certificado a Let's Encrypt y recarga nginx.
#                               Si ya hay uno y le faltan más de 30 días para vencer, no pide nada; si le
#                               falta menos, lo renueva.
set -eu
cd "$(dirname "$0")"

set -a
# shellcheck source=/dev/null
. ./.env
set +a

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

if [ "${1:-}" = "self-signed" ]; then
    self_signed
    exit 0
fi

# Espera a que nginx responda en el 80, que es por donde valida Let's Encrypt.
echo "Esperando a nginx en el puerto 80..."
tries=0
until curl -s -o /dev/null http://127.0.0.1/; do
    tries=$((tries + 1))
    if [ "$tries" -ge 30 ]; then
        echo "nginx no responde en el puerto 80" >&2
        exit 1
    fi
    sleep 2
done

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
