# infra

Levanta **Snippet Searcher** entero con Docker Compose. Es el mismo archivo para dev y para prod: cada VM elige qué imágenes corre con `IMAGE_TAG` en su `.env`.

## Qué levanta

| Servicio | Imagen | Expuesto |
|---|---|---|
| `proxy` (nginx) | `nginx:stable-alpine` | `:80`: `/` a la UI y `/api/` a snippet-service |
| `printscript-ui` | `ghcr.io/ingsis-2026/printscript-ui` | solo a través del proxy |
| `snippet-service` + `snippet-db` | `ghcr.io/ingsis-2026/snippet-service` + `postgres:17` | la base en `127.0.0.1:5432` |
| `permission-service` + `permission-db` | `ghcr.io/ingsis-2026/permission-service` + `postgres:17` | la base en `127.0.0.1:5433` |
| `language-service` | `ghcr.io/ingsis-2026/language-service` | no |
| `redis` | `redis:7-alpine` | `127.0.0.1:6379` |
| `asset-service` + `azurite` | `ghcr.io/austral-ingsis/snippet-asset-service` (de la cátedra) | `127.0.0.1:8083` |

`permission-service` y `language-service` no pasan por nginx: solo los llama `snippet-service` por la red interna.

## Uso

```sh
cp .env.example .env
docker compose up -d
```

Para trabajar en un servicio desde el IDE, levantá solo lo que necesita. Con los defaults de `.env.example` no hace falta configurar nada en el servicio:

```sh
docker compose up -d snippet-db permission-db redis asset-service azurite
```

`snippet-service` no arranca sin `AUTH0_ISSUER_URI`: es el único que valida el JWT.

## Deploy

- **CI** (`ci.yml`): valida `docker-compose.yml` y la configuración de nginx.
- **Deploy** (`deploy.yml`): un push a `dev` o `main` entra por SSH a la VM correspondiente, actualiza `~/infra` y corre `docker compose pull && up -d`. Cada servicio, además, se redespliega solo desde su propio CD cuando publica una imagen nueva.

Los dos redeploys están apagados hasta que existan las VMs. Para prenderlos:

1. Crear la variable de organización `DEPLOY_ENABLED=true`.
2. En cada repo, crear los environments `dev` y `prod` con los secretos `SSH_HOST`, `SSH_USERNAME` y `SSH_KEY`.
3. En cada VM, clonar este repo en `~/infra` y crear su `.env`. Si las imágenes de ghcr quedan privadas, correr también `docker login ghcr.io`.

## Pendiente

- HTTPS: certbot con duckdns, como en 2025, cuando exista el dominio.
