# infra

Levanta **Snippet Searcher** entero con Docker Compose: los tres servicios y sus bases de datos.

| Container | Imagen | Puerto en tu máquina |
|---|---|---|
| `snippet-service` | `ghcr.io/ingsis-2026/snippet-service` | `8080` |
| `snippet-db` | `postgres:17` | `5432` |
| `permission-service` | `ghcr.io/ingsis-2026/permission-service` | `8081` |
| `permission-db` | `postgres:17` | `5433` |
| `language-service` | `ghcr.io/ingsis-2026/language-service` | `8082` |

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

Para trabajar en un servicio desde el IDE, levantá solo su base (por ejemplo `docker compose up -d snippet-db`) y corré el servicio con `./gradlew bootRun`. Los valores de `.env.example` coinciden con los defaults de cada servicio, así que no hace falta configurar nada.

El health check de cada servicio está en `/actuator/health`, por ejemplo http://localhost:8080/actuator/health.

## CI

`ci.yml` valida que `docker-compose.yml` sea correcto en cada push y PR.
