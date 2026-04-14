#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
USERNAME="${USERNAME:-testuser_$$}"
PASSWORD="${PASSWORD:-Test@1234}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
step() { echo -e "\n${YELLOW}==>${NC} $1"; }

expect_status() {
  local label=$1 expected=$2 actual=$3
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (HTTP $actual)"
  else
    fail "$label — expected HTTP $expected, got HTTP $actual"
  fi
}

# ── 1. Register ──────────────────────────────────────────────────────────────
step "Register user '$USERNAME'"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
expect_status "Register" 201 "$STATUS"

# ── 2. Duplicate register (expect 409) ───────────────────────────────────────
step "Register same user again (expect 409)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
expect_status "Duplicate register" 409 "$STATUS"

# ── 3. Login ─────────────────────────────────────────────────────────────────
step "Login"
LOGIN_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}")
ACCESS_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
REFRESH_TOKEN=$(echo "$LOGIN_RESPONSE" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)

if [ -n "$ACCESS_TOKEN" ] && [ -n "$REFRESH_TOKEN" ]; then
  pass "Login — received access + refresh tokens"
else
  fail "Login — tokens missing in response: $LOGIN_RESPONSE"
fi

# ── 4. Access protected endpoint ─────────────────────────────────────────────
step "Access protected endpoint with valid token"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ping" \
  -H "Authorization: Bearer $ACCESS_TOKEN")
expect_status "Protected endpoint (valid token)" 200 "$STATUS"

# ── 5. Access protected endpoint without token ───────────────────────────────
step "Access protected endpoint without token (expect 401)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ping")
expect_status "Protected endpoint (no token)" 401 "$STATUS"

# ── 6. Refresh token ─────────────────────────────────────────────────────────
step "Refresh access token"
REFRESH_RESPONSE=$(curl -s -X POST "$BASE_URL/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$REFRESH_TOKEN\"}")
NEW_ACCESS_TOKEN=$(echo "$REFRESH_RESPONSE" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4)
NEW_REFRESH_TOKEN=$(echo "$REFRESH_RESPONSE" | grep -o '"refreshToken":"[^"]*"' | cut -d'"' -f4)

if [ -n "$NEW_ACCESS_TOKEN" ] && [ -n "$NEW_REFRESH_TOKEN" ]; then
  pass "Refresh — received new access + refresh tokens"
else
  fail "Refresh — tokens missing in response: $REFRESH_RESPONSE"
fi

# ── 7. Old refresh token is revoked ──────────────────────────────────────────
step "Reuse old refresh token (expect 401)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$REFRESH_TOKEN\"}")
expect_status "Old refresh token revoked" 401 "$STATUS"

# ── 8. New access token works ────────────────────────────────────────────────
step "Access protected endpoint with new access token"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/ping" \
  -H "Authorization: Bearer $NEW_ACCESS_TOKEN")
expect_status "Protected endpoint (new token)" 200 "$STATUS"

# ── 9. Logout ────────────────────────────────────────────────────────────────
step "Logout"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/logout" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$NEW_REFRESH_TOKEN\"}")
expect_status "Logout" 204 "$STATUS"

# ── 10. Refresh after logout is rejected ─────────────────────────────────────
step "Refresh after logout (expect 401)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/auth/refresh" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\":\"$NEW_REFRESH_TOKEN\"}")
expect_status "Refresh after logout" 401 "$STATUS"

echo -e "\n${GREEN}All tests passed.${NC}"
