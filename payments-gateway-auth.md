# Payments Gateway — Authentication Integration Guide

This guide covers how the payments gateway service should authenticate with ZW, maintain sessions, and handle token lifecycle correctly.

---

## Overview

The payments gateway is a **downstream service** in the FortKnox architecture. It communicates with ZW in two distinct ways:

1. **Machine-to-machine** — the payments service authenticates as a service account to call other internal APIs (if needed)
2. **On behalf of a user** — the payments service receives a user's access token in an inbound request and forwards it downstream

In the common case, your payments gateway does not call `/auth/login` for every user request. Instead, it **validates the incoming `Authorization` header** and passes it through.

---

## Request Flow

```
Client (browser / mobile)
    │
    │  Authorization: Bearer <accessToken>
    ▼
ZW (this service)
    │  validates JWT, rate-limits, routes
    ▼
Payments Gateway  ◄──── you are here
    │
    │  Authorization: Bearer <accessToken>   (same token, forwarded)
    ▼
Other internal services
```

ZW validates the token before routing. By the time a request reaches the payments gateway, the JWT has already passed signature verification and expiry checks. Your service only needs to verify the JWT independently (no call back to ZW).

---

## What the Payments Gateway Must Do

### 1. Validate the JWT on every request

The payments gateway **must not trust requests blindly** just because they arrived on the internal network. Validate the token itself using the shared secret.

The token is a standard HMAC-SHA256 (HS256) JWT. Verification requires:

| Parameter | Value |
|---|---|
| Algorithm | HMAC-SHA256 (`HS256`) |
| Secret | Same `jwt.secret` value configured in ZW |
| Check expiry | Yes — reject tokens where `exp` is in the past |
| Check subject | Yes — extract `sub` claim to identify the user |

**Java example using JJWT 0.12:**

```java
SecretKey key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));

Claims claims = Jwts.parser()
    .verifyWith(key)
    .build()
    .parseSignedClaims(token)
    .getPayload();

String username = claims.getSubject();
```

If parsing throws an exception (expired, tampered, wrong secret), reject the request with `401 Unauthorized`.

### 2. Extract the `Authorization` header

```
Authorization: Bearer <accessToken>
```

Strip the `Bearer ` prefix (7 characters) to get the raw JWT string, then validate as above.

### 3. Forward the token to other internal services

When calling further downstream services, pass the original `Authorization` header unchanged:

```
Authorization: Bearer <accessToken>
```

Do not re-issue or re-sign tokens. All internal services share the same secret and validate independently.

---

## Service Account Authentication (Machine-to-Machine)

If the payments gateway needs to make authenticated calls on its own behalf (not on behalf of a user), it needs a service account registered in ZW.

### Step 1 — Register the service account (one-time setup)

```http
POST /auth/register
Content-Type: application/json

{
  "username": "svc-payments",
  "password": "<strong-random-password>"
}
```

Expected response: `201 Created`

### Step 2 — Log in to obtain tokens

```http
POST /auth/login
Content-Type: application/json

{
  "username": "svc-payments",
  "password": "<strong-random-password>"
}
```

Response `200 OK`:
```json
{
  "accessToken": "<jwt>",
  "refreshToken": "<jwt>"
}
```

Store both tokens securely. Do not log them.

### Step 3 — Use the access token

Attach the access token to every outbound request:

```
Authorization: Bearer <accessToken>
```

### Step 4 — Refresh before expiry

Access tokens expire after **15 minutes**. Before the access token expires, exchange the refresh token for a new pair:

```http
POST /auth/refresh
Content-Type: application/json

{
  "refreshToken": "<currentRefreshToken>"
}
```

Response `200 OK`:
```json
{
  "accessToken": "<newAccessToken>",
  "refreshToken": "<newRefreshToken>"
}
```

**Important:** The old refresh token is **immediately revoked** on use. Replace both tokens in your token store atomically. Discard the old pair.

### Step 5 — Logout on shutdown (optional but recommended)

Revoke the refresh token when the service shuts down gracefully:

```http
POST /auth/logout
Content-Type: application/json

{
  "refreshToken": "<refreshToken>"
}
```

Response: `204 No Content`

---

## Token Management — Implementation Checklist

- [ ] Store tokens in memory only (not on disk, not in logs)
- [ ] Refresh the access token **before** it expires, not after — check expiry with a buffer (e.g. refresh at 12 minutes, not 15)
- [ ] After a successful `/auth/refresh`, atomically replace both `accessToken` and `refreshToken`
- [ ] Handle `401` on any API call by attempting one refresh, then re-trying the original request once. If the refresh also returns `401`, re-authenticate from scratch
- [ ] Handle `429 Too Many Requests` with exponential backoff — do not hammer the endpoint
- [ ] On startup, check if stored tokens are still valid before using them; refresh or re-login if not

---

## Proactive Refresh Strategy

```
Service starts
    │
    ▼
Load stored tokens (if any)
    │
    ├─ access token valid and not expiring soon? ──▶ use it
    │
    ├─ access token expired / expiring in < 3 min?
    │       └─▶ POST /auth/refresh ──▶ store new pair
    │
    └─ no tokens or refresh failed?
            └─▶ POST /auth/login ──▶ store new pair
```

A background thread or scheduled task should check token expiry every minute and refresh proactively, rather than reacting to `401` responses in the hot path.

---

## Error Reference

| HTTP Status | Cause | Action |
|---|---|---|
| `401 Unauthorized` | Token missing, expired, or invalid signature | Refresh or re-login |
| `401 Unauthorized` on `/auth/refresh` | Refresh token revoked, expired, or not found | Re-login from scratch |
| `409 Conflict` on `/auth/register` | Username already taken | Use existing account |
| `429 Too Many Requests` | Rate limit exceeded (per IP) | Back off and retry |

---

## Rate Limiting Awareness

ZW rate-limits all requests **per client IP** before authentication. The payments gateway runs behind a fixed IP on the internal network, so all its outbound calls to ZW share the same bucket.

| Profile | Limit |
|---|---|
| Dev (H2) | 50 requests / 60 seconds |
| Prod (PostgreSQL) | 100 requests / 60 seconds |

To stay within limits:
- Use the proactive refresh strategy above (avoids unnecessary re-logins)
- Do not call `/auth/login` on every user request — re-login only when refresh fails
- Back off with jitter on `429` responses

---

## Security Notes

- **Never share the JWT secret** outside the internal network. Downstream services use it to verify tokens — if it leaks, any party can forge valid tokens.
- **Do not re-sign or modify tokens** in transit. Forward them as-is.
- **Change the default `zawala` / `changeme` credentials** and the service account password before any non-local deployment.
- Access tokens have a **15-minute lifetime**. A compromised access token is valid at most 15 minutes. Refresh tokens are stored in the DB and can be revoked immediately via `/auth/logout`.
