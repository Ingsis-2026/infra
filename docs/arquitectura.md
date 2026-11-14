# Arquitectura

Cómo se arma **Snippet Searcher** y qué pasa en sus flujos principales. Está sacado del código de cada repo (`snippet-service`, `permission-service`, `language-service`, `printscript-ui`) y de este; si algo cambia allá, hay que actualizarlo acá.

Las flechas que dicen **token M2M** llevan el access token machine-to-machine con el que `snippet-service` se presenta ante `permission-service` y `language-service` (client credentials de Auth0, audience `https://snippet-searcher/internal`). En el compose local esos dos servicios pueden correr sin pedirlo (`INTERNAL_AUTH_ENABLED=false`).

## Componentes

```mermaid
flowchart LR
    user(["Usuario<br/>(browser con la SPA)"])

    subgraph ext["Servicios externos"]
        auth0["Auth0<br/>login, JWKS,<br/>Management API"]
        nr["New Relic<br/>APM, infra,<br/>monitores sintéticos"]
        le["Let's Encrypt"]
        duck["DuckDNS"]
    end

    subgraph vm["VM de Azure: Docker Swarm de un nodo, stack snippet"]
        proxy["proxy<br/>nginx, 80 y 443"]
        ui["printscript-ui<br/>nginx con los estáticos"]
        snippet["snippet-service<br/>API, orquesta al resto<br/>y workers de los streams"]
        perm["permission-service<br/>quién puede qué"]
        lang["language-service<br/>PrintScript: validar, lint,<br/>formatear, ejecutar"]
        asset["asset-service<br/>de la cátedra"]
        azurite[("Azurite<br/>el código de cada snippet")]
        sdb[("snippet-db<br/>Postgres: snippets,<br/>reglas, tests")]
        pdb[("permission-db<br/>Postgres: permisos")]
        redis[("Redis<br/>streams lint-requests<br/>y format-requests")]
        certbot["certbot<br/>renueva el certificado"]
        duckdns["duckdns"]
        nri["newrelic-infra<br/>(fuera del stack)"]
    end

    user -->|"login"| auth0
    user -->|"HTTPS y WSS"| proxy
    proxy -->|"/"| ui
    proxy -->|"/api/... (REST)<br/>/api/execution (WebSocket)"| snippet
    snippet -->|"REST, token M2M"| perm
    snippet -->|"REST y WebSocket,<br/>token M2M"| lang
    snippet -->|"REST"| asset
    asset --> azurite
    snippet --> sdb
    perm --> pdb
    snippet -->|"XADD, XREADGROUP, XACK"| redis
    snippet -->|"JWKS, client credentials,<br/>búsqueda de usuarios"| auth0
    perm -.->|"JWKS"| auth0
    lang -.->|"JWKS"| auth0
    certbot -->|"ACME"| le
    le -->|"valida el dominio por el 80"| proxy
    certbot -.->|"certificado en un volumen<br/>que lee nginx"| proxy
    duckdns -->|"IP pública de la VM"| duck
    snippet & perm & lang & asset -.->|"agente Java"| nr
    nri -.->|"VM y containers"| nr
    nr -.->|"sintéticos desde afuera"| proxy
```

- **nginx** es la única puerta de entrada (ver [Reverse proxy](../README.md#reverse-proxy-nginx)). A cada pedido le pone un `X-Request-Id` que sigue hasta el servicio.
- **snippet-service** es el único servicio que ve el browser: valida el JWT del usuario (Auth0, audience `https://snippet-searcher/api`) y llama al resto. `permission-service` y `language-service` no saben de usuarios ni se publican.
- El código de cada snippet vive en **Azurite**, detrás de `asset-service`; en `snippet-db` queda su metadata, las reglas de cada usuario y los tests.
- Lo que tarda (lintear y formatear muchos snippets) va por los **streams de Redis** y lo procesan workers dentro de `snippet-service`.

## Crear un snippet (US1, US3)

Solo se guarda un snippet que su parser acepta. Si no, el usuario ve qué regla incumplió y en qué línea y columna.

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuario
    participant B as Browser (UI)
    participant N as nginx
    participant S as snippet-service
    participant L as language-service
    participant DB as snippet-db
    participant A as asset-service
    participant P as permission-service
    participant R as Redis

    U->>B: Guarda el snippet (editor o archivo)
    B->>N: POST /api/snippets, Bearer con el token de Auth0
    N->>S: POST /snippets, con X-Request-Id
    Note over S: Spring Security valida el JWT:<br/>firma (JWKS de Auth0), issuer, vencimiento y audience
    S->>L: POST /validate (code, language, version), token M2M
    L-->>S: valid y errors [rule, line, column]
    alt El parser lo rechaza
        S-->>N: 422 ProblemDetail con errors [rule, line, column]
        N-->>B: 422
        B-->>U: La regla incumplida, con su línea y columna
    else Es válido
        Note over S,P: Todo en una transacción de snippet-db: si falla algo, no queda el snippet
        S->>DB: INSERT del snippet, con status PENDING
        S->>A: PUT /v1/asset/snippets/id (el código)
        A->>A: Lo guarda como blob en Azurite
        S->>P: POST /permissions (snippetId, userId, OWNER), token M2M
        P-->>S: 201
        S->>DB: COMMIT
        S->>R: XADD lint-requests (snippetId), recién después del commit
        S-->>N: 201 con el snippet (PENDING)
        N-->>B: 201
        Note over R: Un worker lo lintea en segundo plano<br/>(ver "Cambiar las reglas de lint")
    end
```

## Compartir un snippet (US7)

El owner busca al usuario por nombre o email en un listado que se filtra mientras escribe, y el elegido queda con permiso de lectura.

```mermaid
sequenceDiagram
    autonumber
    actor U as Owner
    participant B as Browser (UI)
    participant S as snippet-service
    participant Auth as Auth0
    participant P as permission-service
    participant DB as snippet-db

    Note over B,S: Todo pasa por nginx (/api/...), con el token de Auth0 del usuario
    U->>B: Abre "Share" y escribe un nombre
    loop Cada vez que deja de escribir (debounce)
        B->>S: GET /users?name=ju&page=0&size=5
        opt No tiene token para la Management API, o le falta menos de un minuto para vencer
            S->>Auth: POST /oauth/token (client credentials, audience de la Management API)
            Auth-->>S: access token, que se cachea
        end
        S->>Auth: GET /api/v2/users, q = (name:ju* OR email:ju*) AND NOT user_id del owner
        Auth-->>S: users (user_id, name, email) y total
        S-->>B: users (id, name, email) y total
    end
    U->>B: Elige un usuario
    B->>S: POST /snippets/id/share (userId)
    S->>DB: Busca el snippet (404 si no existe)
    S->>P: GET /permissions?snippetId&userId del owner, token M2M
    P-->>S: OWNER (si no, 403)
    S->>P: POST /permissions (snippetId, userId, READ), token M2M
    alt Ya tenía acceso
        P-->>S: 409
        S-->>B: 409 Conflict
    else
        P-->>S: 201
        S-->>B: 200 con el snippet
    end
```

Si Auth0 no responde o falta la aplicación machine-to-machine, la búsqueda da `503` y el resto de la API sigue andando.

## Ejecución interactiva (US10)

Es un WebSocket entre el browser y `snippet-service`, que abre otro con `language-service` y le pasa los mensajes en los dos sentidos. Correr uno de los tests del snippet (US9) es el mismo flujo, con el `testId` en el `start` y los inputs del test.

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuario
    participant B as Browser (UI)
    participant N as nginx
    participant S as snippet-service
    participant P as permission-service
    participant A as asset-service
    participant L as language-service

    U->>B: Run
    B->>B: getAccessTokenSilently() de Auth0
    B->>N: GET /api/execution, Upgrade: websocket (sin token)
    N->>S: GET /execution, Upgrade: websocket
    S-->>B: 101 Switching Protocols
    B->>S: start (token, snippetId)
    Note over S: El token va en el primer mensaje: el browser no puede mandar headers al abrir<br/>un WebSocket, y en la URL quedaría en los logs de nginx. Se valida con el mismo<br/>JwtDecoder que el resto de la API. Sin token válido: failure y cierra.
    S->>P: GET /permissions?snippetId&userId, token M2M
    P-->>S: OWNER o READ (si no, failure y cierra)
    S->>A: GET del código
    S->>L: Abre ws://language-service:8080/execution, Authorization con el token M2M
    S->>L: start (code, language, version, inputs vacíos, interactive)
    loop Mientras corre
        L-->>S: output (lo que imprimió)
        S-->>B: output
        L-->>S: input-request (el mensaje del readInput)
        S-->>B: input-request
        U->>B: Escribe el valor
        B->>S: input (value)
        S->>L: input (value)
    end
    L-->>S: done (error o null) y cierra
    S-->>B: done (error, passed null) y cierra
    Note over B,L: Si el browser cierra antes, snippet-service corta la ejecución en language-service.<br/>nginx deja la conexión abierta hasta 10 minutos sin tráfico, y language-service<br/>la corta antes, a los 5 minutos sin input.
```

## Cambiar las reglas de lint: re-linteo asincrónico (US15)

Quien cambia las reglas no espera a que se linteen todos sus snippets: quedan `PENDING` y se lintean de a uno en segundo plano. Cambiar las reglas de formato (US12) funciona igual, con el stream `format-requests`: el worker formatea el snippet, guarda el código y, si cambió, lo encola en `lint-requests`.

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuario
    participant B as Browser (UI)
    participant S as snippet-service (API)
    participant DB as snippet-db
    participant R as Redis
    participant W as snippet-service (worker)
    participant A as asset-service
    participant L as language-service

    U->>B: Prende, apaga o cambia reglas de lint
    B->>S: PUT /api/rules/linting [name, isActive, value]
    Note over S,DB: Una transacción
    S->>DB: Guarda las reglas del usuario
    S->>DB: Todos sus snippets pasan a PENDING
    S->>DB: COMMIT
    S->>R: XADD lint-requests, un mensaje por snippet (snippetId y el trace de New Relic)
    S-->>B: 200 con las reglas
    Note over W,R: Cada 500 ms, en cada réplica. Todas comparten el consumer group snippet-service,<br/>así cada mensaje lo procesa una sola.
    W->>R: XGROUP CREATE lint-requests snippet-service desde 0 (la primera vez, BUSYGROUP si ya existe)
    W->>R: XPENDING: los que llevan más de un minuto sin XACK
    alt Ya se entregó 3 veces
        W->>R: XACK sin procesarlo: se saltea, con un error en el log
    else
        W->>R: XCLAIM, y lo procesa como uno nuevo
    end
    W->>R: XREADGROUP GROUP snippet-service, COUNT 50, mensajes nuevos
    R-->>W: Hasta 50 mensajes
    loop Por cada snippet
        W->>A: GET del código, como está ahora
        W->>L: POST /validate, token M2M
        W->>DB: Las reglas de lint del owner, como están ahora
        W->>L: POST /lint (code, rules), token M2M
        W->>DB: status = COMPLIANT, NOT_COMPLIANT o INVALID
        W->>R: XACK
    end
    Note over W,R: Si algo falla no hay XACK: el mensaje queda pendiente y otra vuelta lo retoma al minuto.<br/>Lintear es idempotente: usa el código y las reglas del momento, así que da igual repetirlo.
    B->>S: GET /api/snippets (la lista muestra PENDING hasta que el worker termina)
```

## Renovación del certificado HTTPS

El primer certificado lo pide `certbot.sh` en el deploy; los siguientes los renueva el servicio `certbot` del stack, aunque no haya deploys (ver [Despliegue](../README.md#despliegue-en-las-vms-docker-swarm)).

```mermaid
sequenceDiagram
    autonumber
    participant C as certbot (servicio del stack)
    participant V as Volúmenes letsencrypt y acme-challenge
    participant LE as Let's Encrypt
    participant N as nginx

    loop Al arrancar la VM y después cada 12 horas (cada una hora si falló)
        C->>V: certbot renew: lee renewal/dominio.conf
        alt Le quedan más de 30 días, o todavía no hay certificado real
            C->>C: No hace nada
        else Le quedan menos de 30 días
            C->>LE: Pide el certificado nuevo (ACME)
            C->>V: Deja el challenge en /var/www/certbot
            LE->>N: GET /.well-known/acme-challenge/... por el 80
            N->>V: Lo lee del volumen
            N-->>LE: 200
            LE-->>C: Certificado nuevo
            C->>V: Lo escribe en live/dominio
        end
    end
    loop Cada 6 horas
        N->>N: nginx -s reload: toma el certificado del volumen, sin cortar conexiones
    end
```
