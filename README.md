# infra

Levanta **Snippet Searcher** entero con Docker Compose: los tres servicios, sus bases de datos y Azurite.

| Container | Imagen | Puerto en tu máquina |
|---|---|---|
| `snippet-service` | `ghcr.io/ingsis-2026/snippet-service` | `8080` |
| `snippet-db` | `postgres:17` | `5432` |
| `permission-service` | `ghcr.io/ingsis-2026/permission-service` | `8081` |
| `permission-db` | `postgres:17` | `5433` |
| `language-service` | `ghcr.io/ingsis-2026/language-service` | `8082` |
| `azurite` | `mcr.microsoft.com/azure-storage/azurite` | `10000` |

Azurite es el emulador de Azure Blob Storage. Ahí guarda `snippet-service` el código de cada snippet; la metadata queda en `snippet-db`. Usa la cuenta de desarrollo que trae Azurite (`devstoreaccount1`), que es pública.

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

Para trabajar en un servicio desde el IDE, levantá solo lo que necesita (por ejemplo `docker compose up -d snippet-db azurite`) y corré el servicio con `./gradlew bootRun`. Los valores de `.env.example` coinciden con los defaults de cada servicio, así que no hace falta configurar nada.

El health check de cada servicio está en `/actuator/health`, por ejemplo http://localhost:8080/actuator/health.

## Entornos y ramas

| Rama | Entorno | Imágenes | VM |
|---|---|---|---|
| `dev` | dev | `:dev` | VM de dev |
| `main` | prod | `:prod` | VM de prod |

Se trabaja en ramas `feat/*` que entran a `dev` por PR. Lo que llega a `dev` se despliega en la VM de dev; cuando está probado, un PR de `dev` a `main` lo lleva a prod. Cada imagen además se etiqueta con su commit (`:sha-xxxxxxxx`).

## Despliegue en las VMs (Docker Swarm)

Cada VM es un Swarm de un solo nodo (manager) que corre el stack `snippet`, definido en `docker-stack.yml`. Es el mismo sistema que el compose, con estas diferencias:
- Las bases y Azurite no publican puertos: solo se llega a ellos desde adentro del stack.
- Solo `snippet-service` queda expuesto, en el `8080`.
- Swarm reinicia lo que se cae.
- Si una imagen nueva no arranca, Swarm vuelve sola a la anterior.

En la VM, una sola vez:

```sh
docker swarm init --advertise-addr <IP privada de la VM>
docker login ghcr.io -u <usuario de GitHub>   # con un PAT con read:packages
mkdir -p ~/snippet-searcher                    # ahí va el .env de ese entorno (IMAGE_TAG=dev o prod)
```

Después despliega CI/CD:
- **`infra`:** `deploy.yml` copia `docker-stack.yml` y `deploy.sh` a `~/snippet-searcher` y corre `deploy.sh`.
- **Cada servicio:** su CD actualiza solo su servicio con `docker service update --image ...:sha-xxxxxxxx`.

Azurite no necesita nada en la VM: la imagen es pública, su volumen se crea solo y el container de los snippets lo crea `snippet-service` con el primer guardado.

Para revisar el stack desde la VM:

```sh
docker stack services snippet               # réplicas de cada servicio
docker service ps snippet_snippet-service   # tareas, imagen y errores
docker service logs -f snippet_snippet-service
```

Para llegar a la API sin abrir el puerto en Azure, usá un túnel SSH y entrá a http://localhost:18080/actuator/health:

```sh
ssh -N -L 127.0.0.1:18080:localhost:8080 <usuario>@<IP de la VM>
```

## CI/CD

- `ci.yml` valida en cada push y PR:
  - `docker-compose.yml`
  - `docker-stack.yml`
  - `deploy.sh`, con shellcheck
- `deploy.yml` despliega el stack en la VM del entorno cuando CI pasa en un push a `dev` o `main`.
  - Está apagado hasta que la variable `DEPLOY_ENABLED` valga `true`.
  - Usa los secretos `SSH_HOST`, `SSH_USERNAME` y `SSH_KEY` de los environments `dev` y `prod`.
