# shortbiv

### About this project
shortbiv is an exercise in building a system end to end, not a service with users. The
goal is working familiarity with system design and the delivery chain around it: Spring
Boot, PostgreSQL and Redis on the application side; Kubernetes, Terraform, GitHub Actions
and AWS services on the infrastructure side.

It is designed against a concrete load — 2 million redirects a day, roughly 100 reads per
write — not because that traffic exists, but because designing against it forces real
problems into the open instead of letting them be hand-waved:

- **Issuing ids across replicas.** Three pods creating links cannot use `MAX(id) + 1`;
  two read the same value in the same millisecond and one insert fails. Solved with a
  Postgres sequence that hands each pod a block of 1,000 ids to serve from memory.
- **Guessable short codes.** A plain counter produces `1000001`, `1000002`, and anyone
  can walk the keyspace and read every link in the database. Solved with a keyed Feistel
  permutation applied before base62 encoding.
- **Cache failure.** Redis absorbs most reads, so treating it as authoritative would turn
  a cache outage into a total outage. It is deliberately non-authoritative: cache errors
  are counted as misses.

Every decision, including the rejected alternatives and what each one costs, is recorded
in [docs/architecture.md](docs/architecture.md).
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
