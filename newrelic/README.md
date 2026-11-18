# Observabilidad con New Relic

Lo que pidió la cátedra: métricas que digan algo, monitores sintéticos que fallen, alertas que salten si se cae un servicio (también en medio de un deploy), dashboards que muestren qué está pasando, los puntos de falla de la arquitectura, y el trace de crear un snippet pasando por todos los servicios.

Se mira el sistema desde varios lados:

| Lado | Qué es | Qué ve | Dónde está |
|---|---|---|---|
| **Desde afuera** | Monitores sintéticos de New Relic | Si un usuario puede usarlo: la UI, el health de cada servicio, crear un snippet de punta a punta, el certificado | `synthetics.tf` |
| **Desde cada servicio** | Agente Java de New Relic (APM) en `snippet-service`, `permission-service`, `language-service` y `asset-service` | Pedidos, errores, tiempos, llamados entre servicios, consultas a Postgres y Redis, logs, **traces distribuidos** | `newrelic/newrelic.yml` y el `Dockerfile` de cada servicio; `docker-stack.yml` |
| **Desde el navegador** | Agente de browser de New Relic (`@newrelic/browser-agent`) dentro del build de printscript-ui, que reporta a la aplicación `printscript-ui-<entorno>` | Cuánto tarda en cargar la UI, los errores de JavaScript, los pedidos a `/api` (que arrancan el trace distribuido) y las navegaciones dentro de la SPA | `browser.tf`; `src/observability/newRelic.ts` en printscript-ui |
| **Desde la VM** | Agente de infraestructura (`newrelic-infra`, lo levanta `deploy.sh` fuera del stack) | CPU, memoria y disco de la VM; memoria, CPU y recreaciones de cada container | `deploy.sh` |
| **Desde los datos** | Eventos que reporta snippet-service con la API del agente | Cuántos snippets hay (cada minuto), quién crea, comparte y borra, a quién se le muestra vacía la lista teniendo snippets, y cuánto espera en cada stream de Redis | `observability/` y `streams/StreamBacklogReporter.kt` en snippet-service |

Los SLO (`slo.tf`), las alertas (`alerts.tf`), el dashboard (`dashboard.tf`) y la aplicación de browser (`browser.tf`) se arman con Terraform: los dos entornos quedan iguales y cualquiera del equipo los puede volver a crear.

## SLO y error budget

Un SLI es el % de eventos que anduvieron bien; el SLO, cuánto tiene que dar en los últimos 28 días (la ventana más larga de New Relic); el error budget, cuánto se puede fallar sin romperlo. Están en la página **SLOs** del dashboard, con el budget que queda.

| SLO | Qué cuenta como bien | Objetivo | Por qué |
|---|---|---|---|
| Disponibilidad desde afuera | Los checks de los monitores de la UI y de snippet-service que pasan | 99,5 % (3 h 21 min de budget) | Es lo que ve un usuario, y se mide aunque no haya tráfico. snippet-service da DOWN si se cae su base o Redis. |
| Disponibilidad de la API | Los pedidos a snippet-service que no terminan en 5xx o excepción (sin los health checks) | 99,5 % | Los 4xx no cuentan: un snippet inválido es una respuesta correcta. |
| Lecturas rápidas | Los GET a snippet-service que responden en menos de 500 ms | 99 % | 500 ms y no 300: listar lee el código de cada snippet de la página en asset-service, uno por uno. |

Los dos de la API se crean en el primer `apply` después de que snippet-service reporte a New Relic, porque necesitan su entidad de APM.

Cada SLO tiene su alerta de **fast burn**: salta si en la última hora se gastó más del 2% del budget de los 28 días, que a ese ritmo se termina en unos dos días. Así se avisa cuando el SLO está en riesgo, y no por cada cosa que se ve rara.

Ninguno de los tres hubiera visto los snippets «desaparecidos»: todo respondía 200, y rápido. Para eso están las alertas de los datos.

## La arquitectura y por dónde pasa crear un snippet

```mermaid
flowchart LR
    user([Navegador]) -->|HTTPS| nginx[nginx<br/>proxy]
    synth([Monitores<br/>sintéticos]) -->|HTTPS| nginx
    user -.->|login| auth0[(Auth0)]
    nginx -->|/| ui[printscript-ui]
    nginx -->|/api| snippet[snippet-service]
    nginx -.->|/health/*| permission & language & asset
    snippet -->|1. validar| language[language-service]
    snippet -->|2. metadata| sdb[(snippet-db)]
    snippet -->|3. código| asset[asset-service] --> azurite[(Azurite)]
    snippet -->|4. owner| permission[permission-service] --> pdb[(permission-db)]
    snippet -->|5. encola linteo| redis[(Redis Streams)]
    redis -->|6. worker| snippet
    snippet -.->|6. lint| language
    snippet -.->|JWKS| auth0
```

`POST /api/snippets` (desde el editor o subiendo un archivo):

1. nginx le pasa el pedido a **snippet-service**, que valida el token de Auth0.
2. **language-service** `/validate`: si el parser no lo acepta, 422 y no se guarda nada.
3. **snippet-db**: guarda la metadata (dentro de una transacción).
4. **asset-service** `PUT /v1/asset/snippets/{id}` → **Azurite**: guarda el código.
5. **permission-service** `POST /permissions` → **permission-db**: registra al owner. Si falla, la transacción se deshace.
6. Después del commit, encola el snippet en el stream `lint-requests` de **Redis**. El worker de snippet-service lo toma, lee el código de asset-service, lo valida y lo lintea en **language-service** con las reglas del owner, y guarda el estado.

### Ver el trace

El agente agrega los headers `traceparent` y `newrelic` a cada llamado HTTP entre servicios, así que los pasos 1 a 5 quedan en un mismo trace. El paso 6 es asíncrono: `RedisStreams.kt` guarda esos headers en el mensaje del stream y el worker los retoma, así el linteo en segundo plano aparece **en el mismo trace** como una transacción `RedisStream/lint-requests`.

1. Crear un snippet desde la UI (o esperar una corrida del monitor `snippet flow`, que crea uno, lo lee y lo borra).
2. En New Relic: **APM & Services → snippet-service-dev → Distributed tracing**, filtrar por `request.uri = '/snippets'` y abrir el trace de un `POST`.
3. Se ve el árbol: snippet-service → language-service (`/validate`) → Postgres (`INSERT`) → asset-service (→ Azurite) → permission-service (→ Postgres), y más abajo `RedisStream/lint-requests` → asset-service (`GET`) → language-service (`/validate`, `/lint`) → Postgres (`UPDATE`).

El dashboard tiene una página **Crear un snippet** con los últimos `trace.id`, el tiempo de cada paso y qué servicios tocó cada creación.

## Puntos de falla

Lo que se puede romper, qué pasa entonces y cómo nos enteramos. *Pendiente* es lo que hoy no está resuelto.

| # | Qué falla | Qué pasa | Cómo nos enteramos | Pendiente |
|---|---|---|---|---|
| 1 | **La VM** (es una sola, un solo nodo de Swarm) | Se cae todo junto. Pasa también si Azure la desasigna (auto-shutdown, la suscripción vence). | `VM sin reportar`, todos los monitores en rojo | Una sola VM por entorno: no hay a dónde mover nada. |
| 2 | **nginx** | Es la única entrada: sin él no hay UI ni API, aunque todo lo demás ande. | Monitores de UI y de health | — |
| 3 | **DuckDNS / el certificado** | Si el dominio deja de apuntar a la VM o vence el certificado, los usuarios no entran. El servicio `certbot` del stack lo renueva cada 12 h (y al arrancar la VM) y nginx se recarga cada 6 h para tomarlo. | Monitor `certificate` (15 días antes), monitores de health | Resuelto: servicio `certbot` en `docker-stack.yml`. El monitor queda para avisar si la renovación falla. |
| 4 | **Auth0** | Sin Auth0 no hay login ni se pueden validar tokens: la API responde 401 a todo. | Monitor `snippet flow` (falla en el paso del token) | Es externo: solo se puede detectar. |
| 5 | **snippet-service** | Es el orquestador y tiene una réplica: si se cae, no anda ninguna operación. | Health `snippet-service`, `Servicio sin reportar`, `Container reiniciándose` | — |
| 6 | **Un servicio lento o colgado** | Los clientes de snippet-service tienen timeout (`services.timeouts`: 2 s para conectar, 10 s de respuesta y 30 s para language-service). Si un servicio se cuelga, el pedido falla en vez de quedarse esperando, y en los streams el mensaje se posterga sin gastar intentos. Mientras tanto, cada pedido ocupa un thread de Tomcat y, dentro de `create`/`update`, una conexión de la base. | `Respuestas lentas`; en el trace se ve qué llamado se lleva el tiempo | Resuelto con los timeouts; si hiciera falta, un circuit breaker. |
| 7 | **language-service** | Sin él no se puede crear, editar, lintear, formatear ni correr nada. Además ejecuta código de usuarios. | Health `language-service`, `Servicio sin reportar`, `Linteo... fallando` | — |
| 8 | **permission-service / permission-db** | Sin él nadie ve ningún snippet (la lista falla con 502), ni se puede crear o compartir. | Health `permission-service` (da DOWN si se cae su base), `Servicio sin reportar` | — |
| 9 | **asset-service / Azurite** | Sin ellos no se lee ni se guarda ningún código. Azurite es un emulador: no es almacenamiento durable y no tiene backup. La imagen de la cátedra está fijada (`main.18`), así que no cambia sola en un redeploy. Logueaba el cuerpo de cada pedido (el código entero): ahora `AZURE_HTTP_LOG_LEVEL=BASIC`. | Health `asset-service`, monitor `snippet flow` (Azurite no tiene health propio) | Backup del volumen. |
| 10 | **snippet-db** | Sin metadata no anda nada. Volumen local, sin backups. | Health `snippet-service` (da DOWN si se cae su base), `Disco de la VM alta` | Backups (`pg_dump` programado). |
| 11 | **Redis** | No se pierde nada guardado, pero los snippets nuevos quedan en `PENDING` hasta que vuelva: no se lintean ni se formatean. | Health `snippet-service` (da DOWN si se cae Redis), `Linteo... fallando` | — |
| 12 | **Un snippet enorme** (por ejemplo, 3 GB) | nginx corta todo lo que pase de 1 MB con un 413 antes de que llegue a snippet-service. Pero snippet-service no tiene límite propio para el JSON, y el código vive entero en memoria varias veces (el `String`, el JSON a language-service, los bytes a asset-service, la respuesta): si alguien sube el límite de nginx o llega sin pasar por él, el container pasa su límite de 1 GB, Docker lo mata (OOM) y Swarm levanta otro. | `Container cerca del límite de memoria`, `Container reiniciándose`, `Servicio sin reportar`, health `snippet-service` | Limitar el tamaño también en snippet-service (`spring.servlet.multipart.max-file-size` y un límite para el body). |
| 13 | **Un deploy que no levanta** | Con `order: start-first` y `failure_action: rollback`, el container viejo sigue atendiendo hasta que el nuevo está arriba; si el nuevo no arranca, Swarm vuelve a la imagen anterior. Para el usuario no se cae nada, y justamente por eso nadie se enteraría. | `Container reiniciándose` (más de 2 containers en 10 minutos) | — |
| 14 | **Memoria de la VM** | 4 JVMs con límite de 1 GB, 2 Postgres, Redis, Azurite. En un deploy con `start-first` corren 2 JVMs del mismo servicio a la vez. | `Memoria de la VM alta` | — |
| 15 | **Cambio de versión del parser** | `ParserVersionWatcher` revalida todos los snippets de golpe: un pico de carga en language-service. | Dashboard (pedidos por minuto, linteos por minuto) | — |
| 16 | **Ejecutar un snippet** (WebSocket) | El agente no instrumenta WebSockets: las ejecuciones no aparecen como transacciones ni en los traces. | Solo los logs | Instrumentarlo a mano con la API del agente, si hace falta. |

## Alertas

Todas están en la política `snippet-searcher-<entorno>` y llegan por mail a `alert_emails` cuando se abren, se reconocen y se cierran. Un solo incidente por política: lo que falle mientras está abierto se suma a ese incidente (en New Relic se ve qué condiciones fallaron), así que llega un mail al abrirse y otro al cerrarse. Las VMs pasan la mayor parte del tiempo apagadas para no gastar crédito: apagar una manda un mail, no uno por cada servicio y monitor. Un incidente abierto dura hasta 30 días, así que con la VM apagada tampoco se repite cada día.

| Condición | Salta cuando | Para qué |
|---|---|---|
| Monitor sintético fallando | Un monitor falla 2 minutos seguidos | Lo que ve el usuario |
| Servicio sin reportar | Un servicio no manda métricas de la JVM por 3 minutos (pérdida de señal) | El proceso no está: caída, OOM, deploy que lo bajó |
| Tasa de errores alta | Más del 5% de los pedidos con error por 5 minutos (warning: 1%) | Un servicio de abajo falla |
| Respuestas lentas | p95 de más de 3 s por 5 minutos | Un servicio colgado o lento (punto 6) |
| Linteo o formateo en segundo plano fallando | Más de 5 mensajes de Redis fallados en 5 minutos | Snippets que quedan en PENDING |
| Errores de JavaScript en la UI | Más de 10 errores de JavaScript en 5 minutos, en los navegadores de los usuarios | La UI rota aunque el backend responda bien |
| VM sin reportar | La VM no manda métricas por 5 minutos | La VM apagada o colgada |
| Container cerca del límite de memoria | Más del 90% de su límite por 2 minutos (warning: 80% por 5) | Un OOM por venir (punto 12) |
| Container reiniciándose | Más de 2 containers de un servicio en 10 minutos | Crash loop o deploy con rollback (punto 13) |
| CPU, Memoria, Disco de la VM alta | Más de 90% (disco: 85%) por 5 minutos | Recursos de la VM |
| SLO en riesgo: (uno por SLO) | En la última hora se gastó más del 2% del error budget de 28 días | Se está por romper un SLO |
| Snippets que desaparecieron | En 10 minutos faltan 3 o más snippets en la base que nadie borró (los de antes, más los creados, menos los borrados, contra los de ahora) | La base perdió datos: se recreó, no estaba su volumen (punto 10) |
| Snippets que un usuario no puede ver | Un usuario con snippets en la base lista y permission-service no le devuelve ninguno | Se perdieron los permisos (punto 8) o cambió el `sub` de su token |
| Cola de Redis atrasada | Más de 100 mensajes esperando en un stream por 15 minutos | Saturación del segundo plano: los workers no dan abasto o fallan (punto 11) |

## Puesta en marcha

Una sola vez por cuenta y por entorno.

1. **Cuenta de New Relic.** Con la cuenta gratuita alcanza. De **API keys** se necesitan dos: la **License key** (ingest, la que usan los agentes) y una **User key** (`NRAK-...`, la que usa Terraform). También el **account id**.
2. **La VM.** Cargar `NEW_RELIC_LICENSE_KEY` como secreto de los environments `dev` y `prod` de GitHub y desplegar el stack: `deploy.sh` la guarda como Docker Secret (ver [Dónde vive la configuración](../README.md#dónde-vive-la-configuración)). Los servicios necesitan las imágenes nuevas, que traen el agente: las publica el CD de cada servicio cuando se mergea su PR.
3. **Auth0, para el monitor de punta a punta** (opcional: sin esto se crean todos los demás). En Auth0 → Applications, crear una aplicación *Machine to Machine* autorizada para la API `https://snippet-searcher/api` con los permisos `read:snippets` y `write:snippets`: snippet-service los exige y, sin ellos, el monitor recibe 403. El monitor crea sus snippets con ese usuario (`<client id>@clients`) y los borra al terminar.
4. **Terraform** (o OpenTofu), desde esta carpeta:

   ```sh
   cp example.tfvars dev.tfvars                      # y completarlo (prod.tfvars para prod)
   export NEW_RELIC_API_KEY=NRAK-...                 # la User key
   export TF_VAR_auth0_synthetics_client_secret=...  # si se completó auth0_synthetics_client_id
   terraform init
   terraform workspace select -or-create dev         # un workspace por entorno, con su nombre
   terraform apply -var-file=dev.tfvars
   ```

   Para prod, lo mismo con `prod.tfvars` y `terraform workspace select -or-create prod`.

   Cada entorno tiene **su propio estado**, el de su workspace (`terraform.tfstate.d/<entorno>/terraform.tfstate`). Con un solo estado para los dos, aplicar `prod.tfvars` reemplazaría las alertas, los monitores y el dashboard de dev por los de prod. Por eso el plan falla si el workspace no se llama como `environment`.

   Al final imprime la URL del dashboard. El estado queda en la máquina de quien lo aplicó y guarda el client secret: no se commitea.
5. **Browser monitoring de la UI.** El `apply` de cada workspace crea la aplicación de browser `printscript-ui-<entorno>` (`browser.tf`) y saca como outputs lo que necesita el agente de la UI. El agente va dentro del build de printscript-ui, así que esos valores se cargan como **variables de repositorio** de `printscript-ui` (Settings → Secrets and variables → Actions → *Variables*):
   - **Variables y no secretos**: la license key de browser (`NRJS-...`) es pública, viaja en el JavaScript que baja cada navegador. No es la License key de ingest de los agentes de APM.
   - **De repositorio y no de los environments `dev`/`prod`**: el job del CD que arma la imagen no usa environment. La cuenta es una sola para los dos entornos; lo que cambia es la aplicación, por eso hay una variable de application id por entorno.

   ```sh
   terraform workspace select dev
   terraform output browser_github_variables   # NEW_RELIC_ACCOUNT_ID, NEW_RELIC_TRUST_KEY, NEW_RELIC_BROWSER_LICENSE_KEY y NEW_RELIC_BROWSER_APPLICATION_ID_DEV
   terraform workspace select prod
   terraform output browser_github_variables   # las mismas tres de la cuenta, y NEW_RELIC_BROWSER_APPLICATION_ID_PROD
   ```

   Se cargan a mano en GitHub, o con `gh` desde cada workspace (si está `jq`):

   ```sh
   terraform output -json browser_github_variables | jq -r 'to_entries[] | "\(.key) \(.value)"' |
     while read -r name value; do gh variable set "$name" --repo Ingsis-2026/printscript-ui --body "$value"; done
   ```

   El próximo CD de printscript-ui (un push a `dev` o `master`) arma la imagen con el agente; sin las variables, la UI no lo carga. Para verlo: usar la UI y mirar **Browser → printscript-ui-dev** en New Relic, o la página **Navegador** del dashboard. Si alguna de las claves de la cuenta sale `null` (New Relic devolvió la configuración con otra forma), están en `terraform output browser_js_config` o en Browser → la aplicación → *Application settings*, en el snippet de copy/paste (`accountID`, `trustKey`, `licenseKey`).

Los monitores de ping son gratis y corren cada minuto. El de punta a punta cuenta contra los checks del plan (500 por mes en el gratuito), por eso corre cada 6 horas; para la demo, `flow_check_period = "EVERY_5_MINUTES"` y otro `apply`.

## Probar que las alertas saltan

En la VM de dev, con el dashboard abierto. Cada prueba debería abrir el incidente que dice y mandar el mail; al volver todo a la normalidad, el incidente se cierra solo.

**Bajar un servicio** (lo que pasa si un deploy lo deja abajo):

```sh
docker service scale snippet_permission-service=0
# en 2-3 minutos: "Monitor sintético fallando" (permission-service health) y "Servicio sin reportar" (permission-service-dev)
docker service scale snippet_permission-service=1
```

**Un deploy con una imagen que no arranca** (Swarm hace rollback y el usuario no ve nada):

```sh
docker service update --image ghcr.io/ingsis-2026/language-service:no-existe snippet_language-service
# Swarm no puede bajar la imagen y vuelve a la anterior; un servicio que arranca y se cae en loop dispara "Container reiniciándose"
```

**Un snippet enorme.** Por la API pública, nginx lo corta antes de mirar el token:

```sh
head -c 3000000000 /dev/zero | tr '\0' 'a' > /tmp/huge.ps
curl -s -o /dev/null -w '%{http_code}\n' \
  -F name=huge -F description=huge -F language=printscript -F version=1.1 -F file=@/tmp/huge.ps \
  https://snippetsearcher-ingsis2026-dev.duckdns.org/api/snippets
# 413: nginx no lo deja pasar (client_max_body_size 1m) y snippet-service ni se entera.
```

Para ver qué pasaría sin ese límite (punto 12), se puede achicar el límite de memoria del container hasta que la JVM no entre, y ver cómo saltan `Container cerca del límite de memoria`, `Container reiniciándose` y `Servicio sin reportar`. Si el container nuevo no llega a arrancar, Swarm vuelve solo al límite anterior (rollback), que también dispara `Container reiniciándose`:

```sh
docker service update --limit-memory 300M snippet_snippet-service
# usar la app un rato (crear, listar, formatear); después, si no volvió solo, el límite del stack:
docker service update --limit-memory 1G snippet_snippet-service
```

**La VM apagada:** detenerla desde Azure. Saltan `VM sin reportar` y todos los monitores.

**Snippets que desaparecen** (el caso de las 3 AM). Borrarlos directo de la base, sin pasar por la API, es lo mismo que una base que perdió datos:

```sh
# crear antes al menos 3 snippets de prueba sin tests desde la UI; después:
docker exec $(docker ps -q -f name=snippet_snippet-db) psql -U snippet -d snippet \
  -c "DELETE FROM snippet WHERE id IN (SELECT id FROM snippet WHERE id NOT IN (SELECT snippet_id FROM test_case) LIMIT 3)"
# en unos 10 minutos: "Snippets que desaparecieron". Solo en dev, con snippets de prueba: no se recuperan.
```

**Una cola atrasada:** con language-service abajo, los linteos se acumulan en Redis.

```sh
docker service scale snippet_language-service=0
# crear o editar más de 100 snippets (o cambiar las reglas de lint de un usuario con muchos); en 15 minutos,
# "Cola de Redis atrasada". Después:
docker service scale snippet_language-service=1
```
