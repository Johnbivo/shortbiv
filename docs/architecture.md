# shortbiv — Architecture

Design record for a read-heavy URL shortener. Resolves [issue #1](https://github.com/Johnbivo/shortbiv/issues/1).

**In scope:** create link, redirect, custom alias, expiry, click count.
**Out:** accounts, deletion, analytics dashboard, UI.

## Estimates

2M redirects/day, 100:1 read/write.

| | |
| --- | --- |
| Redirect rate | 2M ÷ 86,400 = **23 rps** (~230 at 10× peak) |
| Create rate | 20,000/day = **0.23 rps** |
| Links after 5 years | 36.5M → **~9 GB** at ~250 B/row |
| Redis working set | ~200k entries ≈ **44 MB**, provision 512 MB |
| Keyspace | 62⁶ = 56.8B (7,781 years) · 62⁷ = 3.52T (482,413 years) |

Seven characters isn't a capacity decision — six would outlast the project. It's fixed width plus a
large permutation domain.

23 reads/sec is small, and Redis cuts what reaches Postgres to a fraction of it. The redundancy here is
for **availability, not throughput**.

## Topology

```
Internet → Traefik (TLS, per-IP rate limit) → shortbiv × 3 (stateless)
                                                 ↓              ↓
                                    Redis (cache, counters)   Postgres (source of truth)
```

**Create:** validate → id from in-memory block → `base62(feistel(id))` → `INSERT` → write cache entry → `201`.
Writing the cache on create means the first redirect is a hit, and new links are the ones about to get traffic.

**Redirect:** Redis → on miss check negative cache → on miss Postgres → backfill → `302`.
Expired → `410`. Absent → cache the miss 60s, `404`. Then `INCR` the click counter.

## Decisions

| Decision | Why | Trade-off |
| --- | --- | --- |
| One deployable, not microservices | Both paths share a model and cache; stateless, so the read path can still scale alone | One deploy touches both |
| Postgres as source of truth | Expiry sweeps, alias uniqueness and aggregation are relational; the unique constraint settles collisions | More ops surface than a KV store |
| Single primary, no read replica | Redis absorbs most reads — a replica adds failover complexity for no throughput gain | Adding one later needs read-your-writes handling |
| Redis cache-aside, non-authoritative | Cache errors count as misses, so a dead Redis is a slowdown not an outage | One extra read after each change |
| Negative-cache unknown codes, 60s | Codes are unguessable, so scanners generate pure misses that would all hit Postgres | Stale 404 for up to a minute |
| `302` + `Cache-Control: private, no-store`, not `301` | A 301 is cached forever: targets become uncorrectable and clicks stop being counted. The header is required — a bare 302 can still be cached by proxies | Every click reaches the service |
| Click counts in Redis, flushed every 30s | Keeps a write off the read path and avoids hot-row contention | Approximate; 30s loss window |
| No auth at all | Nothing destructive is left to protect once deletion is out | Click counts visible to anyone holding the link |
| Flyway, `ddl-auto` off | Reviewed like code, auditable, additive-only so rollback needs no restore | Destructive changes take two deploys |
| Testcontainers, not H2 | H2 diverges on exactly what matters: constraints, sequences, partial indexes | Docker in CI |
| Analytics store deferred | Click events are time-range aggregations, not key lookups → ClickHouse, not a document store | Raw events unavailable until built |

### Short codes

Counter → keyed permutation → base62, 7 chars. Single-shot: no uniqueness check, no retry loop.

```sql
CREATE SEQUENCE link_id_seq START WITH 56800235584 INCREMENT BY 1000;
```

Each pod claims a block of 1,000 and serves from memory — at 0.23 writes/sec that's one `nextval` every
72 minutes. Starting at 62⁶ keeps every code exactly 7 characters. Restart gaps don't matter at 3.5
trillion codes.

The permutation is a 4-round Feistel network (HMAC-SHA256, keyed), applied before encoding so codes
aren't enumerable. It's a bijection, so it can't introduce collisions. 62⁷ isn't a power of two, so it
runs on 2⁴² and cycle-walks outputs ≥ 62⁷ — 80.07% accept, ~1.25 iterations.

*Rejected — hashing the URL:* at 36.5M links over 62⁷, expected collisions ≈ n²/2N ≈ **189**, so every
insert needs a check and a retry. Identical URLs would also yield identical codes.
*Rejected — pre-generated key pool:* same result, but adds a service, a table of unused keys, and
`FOR UPDATE SKIP LOCKED` handout logic.
*Rejected — 3 dedicated ID services:* three processes that can restart holding in-memory state and
reissue ids, putting the retry path back in.

### Rate limiting

| Layer | Where | Scope |
| --- | --- | --- |
| Per-IP cap, 50 rps burst 100 | Traefik `RateLimit` middleware (ships with k3s) | All routes |
| ~10/min per IP | App filter, Redis token bucket via Lua | `POST /api/v1/links` |
| 404 throttle | App filter | Enumeration defence |

One gateway cap can't tell a cheap redirect from an expensive create: loose enough for 23 rps of
redirects, it allows 50 creates/sec from one IP. Route-aware limits belong in the app. Token bucket over
sliding-window-log — tolerates bursts, one record per key instead of a timestamp per request.

Watch `sourceCriterion.ipStrategy`: read the wrong address behind a proxy and every user shares one
bucket. On AWS the per-IP equivalent is WAF rate-based rules, not API Gateway, whose usage plans throttle
per API key and we issue none.

### Takedown

No user deletion, but an operator needs to pull phishing and malware. Expiry already does it:

```sql
UPDATE links SET expires_at = now() WHERE short_code = 'abc1234';
```

Then `DEL l:abc1234`. Out-of-band SQL; no admin UI in scope.

## Data model

```sql
CREATE TABLE links (
    id           BIGINT      PRIMARY KEY,          -- raw link_id_seq value, never exposed
    short_code   VARCHAR(7)  NOT NULL,             -- base62(feistel(id)), or custom alias
    long_url     TEXT        NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ,                      -- NULL = never; also the takedown lever
    click_count  BIGINT      NOT NULL DEFAULT 0    -- flushed from Redis, approximate
);

CREATE UNIQUE INDEX links_short_code_key ON links (short_code);
CREATE INDEX links_expires_at_idx ON links (expires_at) WHERE expires_at IS NOT NULL;
```

The unique index on `short_code` *is* the redirect path's index. `long_url` is deliberately not indexed —
long, variable, nothing filters on it; for dedup, index a hash column. The partial index serves the
expiry sweep and stays small because most links never expire.

## API

| Method | Path | Success | Errors |
| --- | --- | --- | --- |
| `POST` | `/api/v1/links` | `201` + `Location` | `400` bad URL, `409` alias taken, `422`, `429` |
| `GET` | `/{code}` | `302` + `Location` + `Cache-Control: private, no-store` | `404` unknown, `410` expired |
| `GET` | `/api/v1/links/{code}` | `200` metadata + clicks | `404` |
| `GET` | `/actuator/health`, `/actuator/prometheus` | `200` | — |

```http
POST /api/v1/links
{ "url": "https://example.com/long/path", "customAlias": "launch", "expiresAt": "2027-01-01T00:00:00Z" }

201 Created  ·  Location: https://shortbiv.bivolaris.com/launch
{ "shortCode": "launch", "shortUrl": "...", "longUrl": "...", "createdAt": "...", "expiresAt": "..." }
```

Errors use RFC 9457 `application/problem+json`. Codes live at the root, so `/api` and `/actuator` are
reserved and custom aliases are checked against a blocklist. `410` reveals a code once existed — accepted,
since codes are unguessable.

## Deployment

| Component | Local (Floci) | k3s on a VPS | Real AWS |
| --- | --- | --- | --- |
| shortbiv | `mvnw spring-boot:test-run` | Deployment × 3, HPA | Deployment × 3 |
| Postgres | Floci RDS (`postgres:16-alpine`) | StatefulSet + PVC | RDS |
| Redis | Floci ElastiCache (`valkey/valkey:8`) | Deployment, no persistence | ElastiCache |
| Secrets | Floci Secrets Manager | k8s Secret | Secrets Manager |
| Ingress | — | Traefik + cert-manager | ALB |

Postgres in-cluster on a PVC is fine for a learning deployment but is the one component production should
hand to a managed service — backups, PITR and failover aren't a StatefulSet's job.

Readiness must fail when Postgres is unreachable and must **not** fail on Redis: the service is still
correct without the cache, so failing there turns a slowdown into an outage.

Terraform splits along the same line: `host/` provisions the VPS, DNS, firewall, k3s and cluster add-ons;
`aws/` provisions RDS, ElastiCache, S3 and Secrets Manager and runs against Floci or a real account with
nothing changed but the endpoints. App manifests stay out, so shipping code never needs a Terraform run.

*No Ansible.* One node, and everything above the OS is already declarative — Terraform for infra,
manifests for the app. Ansible would own only packages and hardening on a single box, which cloud-init in
`user_data` covers. It earns its place at fleet scale or against long-lived pets, neither of which is this.

## Floci — local AWS

[Floci](https://github.com/floci-io/floci) is a free MIT-licensed AWS emulator on `localhost:4566`, the
live successor to LocalStack Community. It's for **provisioning, not serving**: the Terraform that creates
RDS, ElastiCache, S3 and Secrets Manager runs locally for free and then points at a real account unchanged.

It costs the app nothing because Floci backs stateful services with real containers — RDS is
`postgres:16-alpine`, ElastiCache is `valkey/valkey:8`. Postgres is Postgres and Redis is Redis in every
environment, so Floci changes the provisioning story, not the runtime one. The app takes one variable,
`AWS_ENDPOINT_URL`.

`FLOCI_STORAGE_MODE=hybrid` locally, `memory` in CI. Floci also emulates EKS (on `rancher/k3s:latest`),
but that exists to test EKS provisioning, not to host a workload — plain k3s gives the same Kubernetes
learning without nested Docker.

## Observability

Micrometer → `/actuator/prometheus`, scraped by a `ServiceMonitor`, dashboards in Grafana.

`http_server_requests_seconds` (built in) for latency percentiles and error rate, plus
`shortbiv_cache_lookups_total{result}` (hit ratio), `shortbiv_redirects_total{outcome}`,
`shortbiv_links_created_total`, `shortbiv_cache_errors_total`.

**SLOs:** p99 redirect < 50 ms on cache hit · 99.9% read availability · cache hit ratio > 90%.

`shortbiv_cache_errors_total` gets its own alert, because Redis failures are designed to be invisible to
users — without it the service silently runs on the database.

## CI/CD — GitHub Actions

`mvn verify` (unit + Testcontainers) → image via Jib, no Dockerfile → push to GHCR on `main` → deploy to
k3s. Image tags are the commit SHA, never `latest`, so rollback is a tag change. A parallel job runs
`terraform plan` on the `aws/` stack against Floci, so infrastructure code is checked on every PR without
an AWS account.

## Backlog

Issue #1 is this document. These are the follow-ups it produced. **Needs** is the work that must land first.

| Issue | Ticket | Needs |
| --- | --- | --- |
| [#3](../../issues/3) | Flyway baseline: `links`, indexes, `link_id_seq` | — |
| [#4](../../issues/4) | `Link` entity, repository, integration test | #3 |
| [#5](../../issues/5) | Base62 codec + Feistel + tests | — |
| [#6](../../issues/6) | ID block allocator | #3, #5 |
| [#7](../../issues/7) | `POST /api/v1/links` | #4, #6 |
| [#8](../../issues/8) | `GET /{code}` — Postgres only | #4 |
| [#9](../../issues/9) | Redis cache-aside + negative cache | #7, #8 |
| [#10](../../issues/10) | Click counting: `INCR` + flush job | #9 |
| [#11](../../issues/11) | Traefik rate-limit middleware | — |
| [#12](../../issues/12) | App rate limiting + 404 throttle | #9 |
| [#13](../../issues/13) | Metrics + Grafana dashboard | #9, #10 |
| [#14](../../issues/14) | Expiry sweep job | #4 |
| [#15](../../issues/15) | `GET /api/v1/links/{code}` | #7 |
| [#16](../../issues/16) | Jib image + GitHub Actions CI | #4 |
| [#17](../../issues/17) | k3s manifests: Deployment, Service, Ingress, TLS, probes, HPA | #16 |
| [#18](../../issues/18) | Terraform `host/` | #17 |
| [#19](../../issues/19) | Floci in compose | — |
| [#20](../../issues/20) | Terraform `aws/`, applied against Floci | #19 |
| [#21](../../issues/21) | Secrets Manager for DB password + Feistel key | #20 |
| [#22](../../issues/22) | `pg_dump` → S3 backup job | #20 |

#3–#10 give a working shortener · #11–#15 harden it · #16–#18 deploy it · #19–#22 add the AWS layer,
independently. Start with #3 and #5 in parallel: #5 is self-contained logic, #3 unblocks everything else.
