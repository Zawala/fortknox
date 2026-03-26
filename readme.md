# FortKnox — ZW (Auth & API Gateway)

**FortKnox** is a payments-oriented microservices security platform. **ZW** is its authentication and API gateway service — the single public-facing entry point that every external request must pass through before reaching any internal service.

ZW handles:

- User registration and identity management
- JWT-based authentication (access + refresh tokens)
- Request routing via Spring Cloud Gateway (WebMVC)
- Per-IP rate limiting

All downstream microservices trust tokens issued by ZW. They validate the `Authorization: Bearer <token>` header independently using the shared JWT secret — no token introspection call back to ZW is needed.

---

## Architecture

```
                        ┌──────────────────────────────────┐
  Client ──────────────▶│           ZW (this service)       │
                        │  Auth + Gateway + Rate Limiter    │
                        └────────────┬─────────────────────┘
                                     │  routes + JWT
                        ┌────────────▼─────────────────────┐
                        │         Internal Network          │
                        ├──────────────┬────────────────────┤
                        ▼              ▼                    ▼
                   Service A      Service B           Service N
                 (trusts JWT)   (trusts JWT)        (trusts JWT)
```

**ZW sits at the edge.** No downstream service is exposed to the public internet. Every external request passes through ZW, which:

1. **Rate-limits** by client IP before anything else is evaluated
2. **Authenticates** the request by validating the JWT
3. **Routes** the request to the appropriate internal service

Downstream services only need to verify the JWT signature using the shared secret. They do not call back to ZW. This makes the architecture horizontally scalable — ZW can run as multiple instances behind a load balancer with no shared state (tokens are self-contained, refresh tokens are stored in the DB).

### Why a separate auth service?

In a microservices setup, centralising authentication has clear benefits:

- A single place to change token policies, secrets, or hashing algorithms
- Downstream services stay thin — they only do authorisation (checking roles/claims), not authentication
- Rate limiting and abuse protection are enforced uniformly at the edge
- Adding a new service requires no auth plumbing — just validate the JWT

---

## Technology Stack

| Concern | Technology |
|---|---|
| Framework | Spring Boot 4 / Spring MVC |
| Gateway | Spring Cloud Gateway Server WebMVC |
| Security | Spring Security 7 |
| Auth tokens | JJWT 0.12 (HMAC-SHA256) |
| Rate limiting | Bucket4j 8 (token bucket, in-memory) |
| ORM | Spring Data JPA / Hibernate 7 |
| DB (dev) | H2 in-memory |
| DB (prod) | PostgreSQL |

---

## Profiles

Activate with `-P <profile>` on any Maven command, or set `spring.profiles.active` at runtime.

| Profile | DB | `ddl-auto` | Rate limit |
|---|---|---|---|
| `dev` (default) | H2 in-memory | `create-drop` | 50 req/60s |
| `uat` | PostgreSQL `fortknox_uat` | `validate` | 100 req/60s |
| `prod` | PostgreSQL `fortknox` | `validate` | 100 req/60s |

### `dev` (default)

- In-memory H2 database, schema recreated on every restart
- H2 console available at `http://localhost:8080/h2-console`
- `JWT_SECRET` falls back to a hardcoded dev value if not set

### `uat`

- PostgreSQL at `localhost:5432/fortknox_uat`
- `JWT_SECRET`, `DB_USERNAME`, `DB_PASSWORD` configurable via environment variables

### `prod`

- PostgreSQL at `localhost:5432/fortknox`
- `JWT_SECRET`, `DB_USERNAME`, `DB_PASSWORD` **required** as environment variables — no defaults

---

## Configuration Reference

All values can be overridden per profile in the corresponding `application-<profile>.properties`.

### JWT

| Property | Default | Description |
|---|---|---|
| `jwt.secret` | — | HMAC signing secret (min 32 chars) |
| `jwt.access-token-expiry` | `900000` | Access token lifetime in ms (15 min) |
| `jwt.refresh-token-expiry` | `604800000` | Refresh token lifetime in ms (7 days) |

### Rate Limiting

| Property | Default (dev) | Default (uat/prod) | Description |
|---|---|---|---|
| `rate-limit.capacity` | `50` | `100` | Max burst size (tokens in bucket) |
| `rate-limit.refill-amount` | `50` | `100` | Tokens refilled per window |
| `rate-limit.refill-period-seconds` | `60` | `60` | Refill window in seconds |

---

## Endpoints

All endpoints are relative to the service base URL (default: `http://localhost:8080`).

### Authentication (`/auth/**`) — public

---

#### `POST /auth/register`

Register a new user account.

**Request**
```json
{
  "username": "zawala",
  "password": "secret123"
}
```

**Responses**

| Status | Meaning |
|---|---|
| `201 Created` | User registered successfully |
| `409 Conflict` | Username is already taken |

---

#### `POST /auth/login`

Authenticate and receive JWT tokens. Revokes all existing refresh tokens for the user (single active session).

**Request**
```json
{
  "username": "zawala",
  "password": "secret123"
}
```

**Response `200 OK`**
```json
{
  "accessToken": "<jwt>",
  "refreshToken": "<jwt>"
}
```

**Responses**

| Status | Meaning |
|---|---|
| `200 OK` | Authenticated — tokens in body |
| `401 Unauthorized` | Invalid credentials |

---

#### `POST /auth/refresh`

Exchange a valid refresh token for a new access + refresh token pair (rotate on use — the submitted token is immediately revoked).

**Request**
```json
{
  "refreshToken": "<jwt>"
}
```

**Response `200 OK`**
```json
{
  "accessToken": "<jwt>",
  "refreshToken": "<jwt>"
}
```

**Responses**

| Status | Meaning |
|---|---|
| `200 OK` | New token pair issued |
| `401 Unauthorized` | Token invalid, expired, or already revoked |

---

#### `POST /auth/logout`

Revoke a refresh token. The access token remains valid until it expires naturally — clients should discard it.

**Request**
```json
{
  "refreshToken": "<jwt>"
}
```

**Responses**

| Status | Meaning |
|---|---|
| `204 No Content` | Token revoked (or was already invalid — idempotent) |

---

### Protected endpoints — require `Authorization: Bearer <accessToken>`

---

#### `GET /ping`

Health / connectivity check. Confirms the service is running and the token is valid.

**Response `200 OK`**
```
pong
```

**Responses**

| Status | Meaning |
|---|---|
| `200 OK` | Authenticated and service is healthy |
| `401 Unauthorized` | Missing or invalid token |
| `429 Too Many Requests` | Rate limit exceeded |

---

## Token Lifecycle

```
  POST /auth/login
        │
        ▼
  ┌─────────────┐      15 min      ┌──────────────────────┐
  │ accessToken │ ───────────────▶ │ expires (discard)    │
  └─────────────┘                  └──────────────────────┘

  ┌──────────────┐
  │ refreshToken │ ──▶ POST /auth/refresh ──▶ new accessToken + refreshToken
  └──────────────┘            │
                              └──▶ old refreshToken immediately revoked
```

- Access tokens are **short-lived (15 min)** and stateless — validation requires only the secret, no DB call
- Refresh tokens are **long-lived (7 days)** and stored in the DB — they can be revoked immediately
- Login revokes all existing refresh tokens for the user, enforcing a single active session
- Every refresh rotates the refresh token — a stolen token can only be used once

---

## Rate Limiting

Rate limiting is applied **per client IP** before authentication. The token bucket algorithm allows short bursts up to `capacity` then throttles sustained traffic.

| Header / Behaviour | Detail |
|---|---|
| Detection | `X-Forwarded-For` (first entry), falls back to `RemoteAddr` |
| Exceeded response | `429 Too Many Requests` |
| Scope | All endpoints including `/auth/**` |

---

## Default Users

On startup the service seeds the following user if it does not exist:

| Username | Password | Role |
|---|---|---|
| `zawala` | `changeme` | `ROLE_USER` |

Change the default password before deploying to any non-local environment.

---

## Running the Service

```bash
# Development (H2, default)
./mvnw spring-boot:run -P dev

# UAT (PostgreSQL fortknox_uat)
DB_USERNAME=postgres DB_PASSWORD=secret ./mvnw spring-boot:run -P uat

# Production (PostgreSQL fortknox)
JWT_SECRET=<secret> DB_USERNAME=postgres DB_PASSWORD=secret ./mvnw spring-boot:run -P prod

# Build a deployable JAR
mvn clean package -P prod -DskipTests
JWT_SECRET=<secret> java -jar target/zw-0.0.1-SNAPSHOT.jar

# Run the auth flow test
./test-auth-flow.sh
```
