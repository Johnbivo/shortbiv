# shortbiv

A URL shortener built for read-heavy traffic: ~23 redirects/sec sustained, sub-50ms p99 on cache hit,
and a durable record of every link.

**Status:** architecture settled, implementation not started. The app starts, Postgres and Redis are
wired for tests, and there is no domain code yet.

## Architecture

See **[docs/architecture.md](docs/architecture.md)** — requirements, capacity estimates, every design
decision with its trade-offs, the data model, the API spec, the k3s topology, and the implementation
backlog.

Short version: one stateless Spring Boot service behind Traefik, Postgres as system of record, Redis
as a non-authoritative cache in front of the redirect path. Short codes come from a Postgres sequence
passed through a keyed Feistel permutation and base62-encoded to 7 characters — collision-free without
retries, and not enumerable.

## Stack

| Concern | Choice |
| --- | --- |
| Language / runtime | Java 21 |
| Framework | Spring Boot 4.1.1, Spring MVC |
| Persistence | Spring Data JPA, PostgreSQL |
| Migrations | Flyway |
| Cache | Redis (Spring Data Redis) |
| Metrics | Actuator, Micrometer, Prometheus |
| Testing | JUnit 5, Testcontainers |
| Build | Maven (wrapper included) |
| Deployment | k3s, Traefik ingress, Terraform |
| Local AWS | [Floci](https://github.com/floci-io/floci) — RDS, ElastiCache, S3, Secrets Manager |

## Running locally

Requires JDK 21 and Docker.

```bash
cd shortbiv && ./mvnw spring-boot:test-run
```

Starts the app with the Testcontainers-backed Postgres and Redis from `TestcontainersConfiguration`,
so no local services are needed.

```bash
cd shortbiv && ./mvnw verify
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
