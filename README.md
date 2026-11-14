# infra

Levanta **Snippet Searcher** entero con Docker Compose: el reverse proxy, la UI, los tres servicios, sus bases de datos, el asset-service de la cátedra con su Azurite, y Redis.

| Container | Imagen | Puerto en tu máquina |
|---|---|---|
| `proxy` | `nginx:1.27-alpine` | `80` |
| `printscript-ui` | `ghcr.io/ingsis-2026/printscript-ui` | — |
| `snippet-service` | `ghcr.io/ingsis-2026/snippet-service` | `8080` |
| `snippet-db` | `postgres:17` | `5432` |
| `permission-service` | `ghcr.io/ingsis-2026/permission-service` | `8081` |
| `permission-db` | `postgres:17` | `5433` |
| `language-service` | `ghcr.io/ingsis-2026/language-service` | `8082` |
| `asset-service` | `ghcr.io/austral-ingsis/snippet-asset-service:main.18` | `8083` |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite:3.37.0` | `10000` |
| `redis` | `redis:7` | `6379` |

El código de cada snippet lo guarda `snippet-service` en `asset-service`, el [servicio de assets de la cátedra](https://github.com/austral-ingsis/asset-service), y la metadata queda en `snippet-db`. `asset-service` es el único que habla con Azurite, el emulador de Azure Blob Storage, con la cuenta de desarrollo que trae Azurite (`devstoreaccount1`), que es pública. Su imagen no es nuestra: no tiene versiones ni tags `dev`/`prod`, solo un tag `main.<número>` por cada build de la cátedra; usamos uno fijo, para que no cambie sin que nos enteremos. Su API está en http://localhost:8083/swagger-ui.

Redis tiene el stream `lint-requests`: cuando un usuario cambia sus reglas de lint, `snippet-service` encola ahí cada uno de sus snippets y los lintea en segundo plano (US15). Corre con AOF (`--appendonly yes`) para que lo encolado sobreviva a un reinicio.

Cada servicio tiene su propio `Dockerfile` en su repo. El CD de cada uno construye la imagen y la publica en `ghcr.io/ingsis-2026`, y este compose la baja de ahí. Adentro de la red de Docker, los servicios se llaman por nombre (por ejemplo `http://permission-service:8080`).

## Uso

```sh
cp .env.example .env
docker compose up -d        # levanta todo
docker compose ps           # estado de cada container
docker compose logs -f snippet-service
docker compose stop         # apaga todo sin perder los datos de las bases
docker compose down -v      # borra todo, incluidos los datos
```

Con todo levantado, la UI está en http://localhost y la API en http://localhost/api (por ejemplo http://localhost/api/actuator/health). Si el `80` está ocupado, cambiá `PROXY_PORT` en el `.env`.

Para trabajar en un servicio desde el IDE, levantá solo lo que necesita (por ejemplo `docker compose up -d snippet-db asset-service redis`) y corré el servicio con `./gradlew bootRun`. Los valores de `.env.example` coinciden con los defaults de cada servicio, así que no hace falta configurar nada.

El health check de cada servicio está en `/actuator/health`, por ejemplo http://localhost:8080/actuator/health.

## Reverse proxy (nginx)

nginx es la única puerta de entrada: recibe todos los pedidos y, según la ruta, los manda a un servicio.

| Ruta | Va a | |
|---|---|---|
| `/api/...` | `snippet-service:8080` | Sin el `/api`: `/api/snippets` llega como `/snippets`. |
| `/...` | `printscript-ui:80` | La UI. |

- Las rutas están en [`nginx/locations.conf`](nginx/locations.conf) y son las mismas en el compose y en las VMs. Lo que cambia es el `server` que las incluye: [`local.conf`](nginx/local.conf) (solo HTTP) y [`vm.conf.template`](nginx/vm.conf.template) (HTTPS con el dominio de DuckDNS).
- `permission-service` y `language-service` no tienen ruta: solo les habla `snippet-service`, desde adentro.
- Es un **reverse proxy, no un load balancer**: nginx elige el servicio, no la réplica. Cada nombre resuelve a la IP virtual del servicio en Swarm, y Swarm reparte entre sus réplicas.
- La UI y la API comparten dominio, así que el browser no necesita CORS.

## Entornos y ramas

| Rama | Entorno | Imágenes | VM |
|---|---|---|---|
| `dev` | dev | `:dev` | VM de dev |
| `main` | prod | `:prod` | VM de prod |

Se trabaja en ramas `feat/*` que entran a `dev` por PR. Lo que llega a `dev` se despliega en la VM de dev; cuando está probado, un PR de `dev` a `main` lo lleva a prod. Cada imagen además se etiqueta con su commit (`:sha-xxxxxxxx`).

## Despliegue en las VMs (Docker Swarm)

Cada VM es un Swarm de un solo nodo (manager) que corre el stack `snippet`, definido en `docker-stack.yml`. Es el mismo sistema que el compose, con estas diferencias:
- **Solo el proxy publica puertos**, el `80` y el `443`. Los servicios, las bases, `asset-service`, Azurite y Redis solo se alcanzan desde adentro del stack. `asset-service` no tiene autenticación, así que no puede quedar expuesto.
- **HTTPS** con un certificado de Let's Encrypt para el dominio de DuckDNS. Por el `80` solo se valida el dominio; todo lo demás se redirige a HTTPS.
- **DuckDNS** mantiene el dominio apuntando a la IP pública de la VM, aunque cambie.
- Swarm reinicia lo que se cae.
- Si una imagen nueva no arranca, Swarm vuelve sola a la anterior.

| Entorno | Dominio |
|---|---|
| dev | `https://<DUCKDNS_SUBDOMAIN de dev>.duckdns.org` |
| prod | `https://<DUCKDNS_SUBDOMAIN de prod>.duckdns.org` |

### Una sola vez

1. **DuckDNS:** entrá a https://www.duckdns.org, creá un subdominio para cada entorno (por ejemplo `snippet-searcher-dev` y `snippet-searcher`) y copiá el token.
2. **Azure:** en el grupo de seguridad de red de cada VM, permití la entrada por TCP `80` y `443` desde cualquier origen (además del `22` para SSH).
3. **En cada VM:**

   ```sh
   docker swarm init --advertise-addr <IP privada de la VM>
   ```

   Nada más: en la VM no queda ninguna configuración ni ningún archivo del repo (ni el stack, ni scripts, ni `.env`, ni `docker login`: las imágenes son públicas). Lo único propio de la VM es `~/.ssh/`, que viene con ella. El deploy corre en el runner de GitHub y le habla al docker de la VM por SSH con un [docker context](https://docs.docker.com/engine/manage-resources/contexts/): la VM solo expone el `22`, el `80` y el `443`, nunca el puerto de la API de docker.
4. **En GitHub**, en los environments `dev` y `prod` del repo: los secretos `SSH_HOST`, `SSH_USERNAME`, `SSH_KEY`, `SNIPPET_DB_PASSWORD` y `PERMISSION_DB_PASSWORD` (contraseñas fuertes), `DUCKDNS_TOKEN`, `AUTH0_M2M_CLIENT_ID` y `AUTH0_M2M_CLIENT_SECRET` (la aplicación machine-to-machine de Auth0 con la que snippet-service busca con quién compartir) y `NEW_RELIC_LICENSE_KEY` (ver [Observabilidad](#observabilidad-new-relic)). Opcional, la variable `LETSENCRYPT_EMAIL`.

### Dónde vive la configuración

| Qué | Dónde |
|---|---|
| Lo que cambia entre entornos y no es secreto (`IMAGE_TAG`, `DUCKDNS_SUBDOMAIN`) | `env/dev.env` y `env/prod.env`, versionados |
| La config de nginx | `nginx/`, como configs de Swarm |
| Contraseñas, tokens y keys | [Docker Secrets](https://docs.docker.com/engine/swarm/secrets/): Swarm los guarda cifrados y se los monta a cada servicio como un archivo en `/run/secrets` |
| Los certificados HTTPS | un volumen de Docker, escrito por el container de certbot |

Los secretos los crea `deploy.sh` la primera vez, con los valores que el workflow le pasa desde los secretos del environment de GitHub. Cada servicio lee el suyo de un archivo: postgres con `POSTGRES_PASSWORD_FILE`, DuckDNS con `FILE__TOKEN`, los servicios de Spring con `SPRING_CONFIG_IMPORT=optional:configtree:/run/secrets/` y el agente de New Relic con `JDK_JAVA_OPTIONS=@archivo`. El único que no puede es `newrelic-infra`, que corre fuera de Swarm: recibe la key en cada deploy.

**Cambiar un secreto:** un secreto de Swarm no se puede modificar y `deploy.sh` no toca los que ya existen. Para cambiar uno, cambialo en GitHub, sacalo del servicio que lo usa y borralo en la VM, y volvé a desplegar:

```sh
docker service update --secret-rm duckdns-token snippet_duckdns
docker secret rm duckdns-token
```

La contraseña de una base además hay que cambiarla adentro de postgres (`ALTER USER`): la del secreto solo se usa al crear el volumen.

### Después, CI/CD

- **`infra`:** `deploy.yml` crea un docker context que apunta a la VM por SSH y corre `deploy.sh <dev|prod>` en el runner. Cada comando de docker del script se ejecuta en la VM, y a la VM no se copia nada. `deploy.sh`:
  1. crea los Docker Secrets que falten;
  1. si todavía no hay certificado, deja uno autofirmado (`certbot.sh self-signed`): sin ninguno nginx no levanta el `443`;
  2. despliega el stack;
  3. corre `certbot.sh`, que pide el certificado a Let's Encrypt y recarga nginx. Let's Encrypt valida el dominio por el `80`, por eso se pide con nginx ya andando.

  certbot es un container que corre una vez y termina: si ya hay un certificado y le faltan más de 30 días para vencer, no pide nada; si le falta menos, lo renueva.
- **Cada servicio y la UI:** su CD actualiza solo su servicio con `docker service update --image ...:sha-xxxxxxxx`.

Si el pedido a Let's Encrypt falla (por ejemplo, porque DuckDNS todavía no apunta a la VM), el deploy no falla: queda el autofirmado (el browser muestra un aviso) y se reintenta en el próximo deploy, o a mano:

```sh
# desde tu máquina, parado en este repo, con un context que apunte a la VM
docker context create snippet-dev --docker "host=ssh://<usuario>@<host de la VM>"
DOCKER_CONTEXT=snippet-dev sh certbot.sh dev   # o prod
```

Azurite no necesita nada en la VM: la imagen es pública, su volumen se crea solo y el container de los snippets lo crea `asset-service` con el primer guardado. Redis tampoco: el stream y su consumer group los crea `snippet-service`.

Para revisar el stack desde la VM:

```sh
docker stack services snippet               # réplicas de cada servicio
docker service ps snippet_snippet-service   # tareas, imagen y errores
docker service logs -f snippet_snippet-service
docker service logs -f snippet_proxy        # los pedidos que entran y a dónde van
docker service logs snippet_duckdns         # si DuckDNS aceptó la IP ("OK")
```

Y desde cualquier lado: `https://<subdominio>.duckdns.org/api/actuator/health`.

## Observabilidad (New Relic)

En las VMs, los cuatro servicios Java (los nuestros y `asset-service`) corren con el agente de New Relic y `deploy.sh` levanta al lado del stack un `newrelic-infra` que mide la VM y cada container. Los monitores sintéticos, las alertas y el dashboard están como código en [`newrelic/`](newrelic/README.md), junto con los puntos de falla de la arquitectura y cómo probar que las alertas saltan.

nginx le pone a cada pedido un header `X-Request-Id` (lo genera siempre él, aunque el pedido traiga uno), se lo pasa al servicio y lo devuelve en la respuesta. Los servicios de Spring lo ponen en sus logs, así un pedido se sigue desde nginx hasta el servicio que falló. El log de nginx es un JSON por pedido, con el id, el status, el tiempo de respuesta y el container al que fue (`docker service logs snippet_proxy`).

## CI/CD

- `ci.yml` valida en cada push y PR:
  - `docker-compose.yml`
  - `docker-stack.yml`
  - `deploy.sh` y `certbot.sh`, con shellcheck
  - la config de nginx del compose y la de las VMs, con `nginx -t`
- `deploy.yml` despliega el stack en la VM del entorno cuando CI pasa en un push a `dev` o `main`.
  - Está apagado hasta que la variable `DEPLOY_ENABLED` valga `true`.
  - Usa los secretos de los environments `dev` y `prod` (ver [Deploy en las VMs](#una-sola-vez)).
