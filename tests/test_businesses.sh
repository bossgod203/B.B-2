#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/test_guard.sh" || exit 1

# Tests for the Businesses API: create (POST /api/businesses) and list
# (GET /api/businesses). Run against a server started with an isolated DB
# (never beebo.db):
#   ./test_businesses.sh
# Uses unique per-run emails and business names, so it needs no direct DB
# access and is safe to re-run against the same test database.

BASE_URL="http://127.0.0.1:5050"
PASSED=0
FAILED=0
RUN_ID="$(date +%s)$$"
EMAIL_A="biz_a_${RUN_ID}@example.com"
EMAIL_B="biz_b_${RUN_ID}@example.com"
JAR_A="biz_cookie_a_${RUN_ID}.txt"
JAR_B="biz_cookie_b_${RUN_ID}.txt"
JAR_ANON="biz_cookie_anon_${RUN_ID}.txt"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
info() { echo -e "${YELLOW}ℹ INFO${NC}: $1"; }
cleanup() { rm -f "$JAR_A" "$JAR_B" "$JAR_ANON"; }
trap cleanup EXIT

# json_get '<json>' 'python expression on d' -> prints value
json_get() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); print($2)" "$1" 2>/dev/null; }

signup() { # jar email -> csrf token
    curl -s -c "$1" -b "$1" -X POST "$BASE_URL/api/signup" \
        -H "Content-Type: application/json" \
        -d "{\"full_name\":\"Biz Tester\",\"email\":\"$2\",\"password\":\"testpass123\"}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('csrf_token',''))"
}

# payload NAME [python statements that modify dict p] -> JSON request body
payload() {
    python3 - "$1" "${2:-}" <<'PY'
import json, sys
days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']
p = {
    'name': sys.argv[1], 'category': 'Food & Drinks', 'location': 'Main gate',
    'description': 'Fresh food for students.',
    'hours': {d: {'open': i < 5, 'from': '09:00', 'to': '17:00'} for i, d in enumerate(days)},
    'services': ['Delivery', 'Catering'],
    'contact': {'phone': '', 'email': '', 'website': ''},
    'social': {'instagram': '', 'facebook': '', 'x': '', 'tiktok': ''},
}
exec(sys.argv[2])
print(json.dumps(p))
PY
}

post_biz() { # jar csrf body -> "<body>\n<status>"
    curl -s -w "\n%{http_code}" -b "$1" -X POST "$BASE_URL/api/businesses" \
        -H "Content-Type: application/json" -H "X-CSRF-Token: $2" -d "$3"
}

info "Starting Businesses tests"

# --- Auth required ---
ANON_CSRF=$(curl -s -c "$JAR_ANON" "$BASE_URL/api/session" | python3 -c "import json,sys; print(json.load(sys.stdin).get('csrf_token',''))")
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$JAR_ANON" "$BASE_URL/api/businesses")
[[ "$CODE" == "401" ]] && pass "GET /api/businesses requires login (401)" || fail "GET should be 401 logged out, got $CODE"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$JAR_ANON" -X POST "$BASE_URL/api/businesses" \
    -H "Content-Type: application/json" -H "X-CSRF-Token: $ANON_CSRF" -d "$(payload "Anon $RUN_ID")")
[[ "$CODE" == "401" ]] && pass "POST /api/businesses requires login (401)" || fail "POST should be 401 logged out, got $CODE"

CSRF_A=$(signup "$JAR_A" "$EMAIL_A")
[[ -n "$CSRF_A" ]] && pass "Signed up user A" || { fail "Signup failed - aborting"; exit 1; }
CSRF_B=$(signup "$JAR_B" "$EMAIL_B")
[[ -n "$CSRF_B" ]] && pass "Signed up user B" || { fail "Signup B failed - aborting"; exit 1; }
UID_A=$(json_get "$(curl -s -b "$JAR_A" "$BASE_URL/api/session")" "d['user']['id']")

# --- CSRF ---
NAME_NOCSRF="NoCsrf $RUN_ID"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$JAR_A" -X POST "$BASE_URL/api/businesses" \
    -H "Content-Type: application/json" -d "$(payload "$NAME_NOCSRF")")
[[ "$CODE" == "403" ]] && pass "POST without CSRF token rejected (403)" || fail "Expected 403 without CSRF, got $CODE"

# --- Create ---
NAME_A="Alpha $RUN_ID"
RESP=$(post_biz "$JAR_A" "$CSRF_A" "$(payload "$NAME_A" "p['owner_id'] = 999999999")")
BODY=$(echo "$RESP" | sed '$d'); CODE=$(echo "$RESP" | tail -n1)
[[ "$CODE" == "201" ]] && pass "Create business succeeds (201)" || fail "Expected 201, got $CODE: $BODY"
[[ "$(json_get "$BODY" "all(k in d['business'] for k in ['id','owner_id','name','category','location','description','hours','services','contact','social','created_at'])")" == "True" ]] \
    && pass "Response has every profile field" || fail "Missing fields: $BODY"
[[ "$(json_get "$BODY" "d['business']['name']")" == "$NAME_A" && "$(json_get "$BODY" "d['business']['services']")" == "['Delivery', 'Catering']" \
    && "$(json_get "$BODY" "d['business']['hours']['sat']['open']")" == "False" ]] \
    && pass "Values round-trip (name, services, hours)" || fail "Values changed: $BODY"
[[ "$(json_get "$BODY" "d['business']['owner_id']")" == "$UID_A" ]] \
    && pass "owner_id comes from the session, not the body" || fail "owner_id wrong (expected $UID_A): $BODY"

# --- Validation: 400 and nothing stored ---
declare -A BAD=(
    ["short name"]="p['name'] = 'A'"
    ["bad category"]="p['category'] = 'Nope'"
    ["all days closed"]="p['hours'] = {d: {'open': False, 'from': '09:00', 'to': '17:00'} for d in p['hours']}"
    ["closing before opening"]="p['hours']['mon'] = {'open': True, 'from': '17:00', 'to': '09:00'}"
    ["bad email"]="p['contact']['email'] = 'nope'"
)
for LABEL in "${!BAD[@]}"; do
    NAME_BAD="Bad ${LABEL// /_} $RUN_ID"
    [[ "$LABEL" == "short name" ]] && BODY_BAD="$(payload "A")" || BODY_BAD="$(payload "$NAME_BAD" "${BAD[$LABEL]}")"
    RESP=$(post_biz "$JAR_A" "$CSRF_A" "$BODY_BAD")
    BODY=$(echo "$RESP" | sed '$d'); CODE=$(echo "$RESP" | tail -n1)
    [[ "$CODE" == "400" && -n "$(json_get "$BODY" "d['error']")" ]] \
        && pass "Rejected ($LABEL): 400 with error message" || fail "Expected 400 for $LABEL, got $CODE: $BODY"
done
RESP=$(curl -s -w "\n%{http_code}" -b "$JAR_A" -X POST "$BASE_URL/api/businesses" \
    -H "Content-Type: application/json" -H "X-CSRF-Token: $CSRF_A" -d '[1,2,3]')
[[ "$(echo "$RESP" | tail -n1)" == "400" ]] && pass "Non-object body rejected (400)" || fail "Expected 400 for array body: $RESP"
LIST=$(curl -s -b "$JAR_A" "$BASE_URL/api/businesses")
[[ "$(json_get "$LIST" "len([b for b in d['businesses'] if 'Bad ' in b['name'] and '$RUN_ID' in b['name']])")" == "0" ]] \
    && pass "Rejected requests stored nothing" || fail "A rejected business was stored: $LIST"

# --- Normalization ---
NAME_TRIM="Trim $RUN_ID"
RESP=$(post_biz "$JAR_A" "$CSRF_A" "$(payload "   $NAME_TRIM   " "p['services'] = ['  a  b ', 'A B', 'Fix']; del p['contact']; del p['social']")")
BODY=$(echo "$RESP" | sed '$d'); CODE=$(echo "$RESP" | tail -n1)
[[ "$CODE" == "201" && "$(json_get "$BODY" "d['business']['name']")" == "$NAME_TRIM" && "$(json_get "$BODY" "d['business']['services']")" == "['a b', 'Fix']" ]] \
    && pass "Name trimmed, services deduped, contact/social optional" || fail "Normalization wrong ($CODE): $BODY"

# --- List ---
NAME_B="Beta $RUN_ID"
post_biz "$JAR_B" "$CSRF_B" "$(payload "$NAME_B")" > /dev/null
R=$(curl -s -D - -b "$JAR_A" "$BASE_URL/api/businesses" | tr -d '\r')
[[ "$(echo "$R" | grep -i '^cache-control:')" == *"no-store"* ]] && pass "List is Cache-Control: no-store" || fail "Missing no-store header"
LIST=$(curl -s -b "$JAR_A" "$BASE_URL/api/businesses")
[[ "$(json_get "$LIST" "[b['name'] for b in d['businesses']].index('$NAME_B') < [b['name'] for b in d['businesses']].index('$NAME_A')")" == "True" ]] \
    && pass "List shows both users' businesses, newest first" || fail "Order or visibility wrong: $LIST"
[[ "$(json_get "$LIST" "len(d['businesses']) <= 50")" == "True" ]] && pass "List is capped at 50" || fail "List exceeds 50"
MINE=$(curl -s -b "$JAR_A" "$BASE_URL/api/businesses?mine=1")
[[ "$(json_get "$MINE" "all(b['owner_id'] == $UID_A for b in d['businesses']) and any(b['name'] == '$NAME_A' for b in d['businesses'])")" == "True" ]] \
    && pass "?mine=1 returns only the caller's businesses" || fail "mine filter wrong: $MINE"

# --- Persistence across sessions ---
curl -s -c "$JAR_A" -b "$JAR_A" -X POST "$BASE_URL/api/logout" -H "X-CSRF-Token: $CSRF_A" > /dev/null
LOGIN=$(curl -s -c "$JAR_A" -b "$JAR_A" -X POST "$BASE_URL/api/login" -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL_A\",\"password\":\"testpass123\"}")
CSRF_A=$(json_get "$LOGIN" "d.get('csrf_token','')")
LIST=$(curl -s -b "$JAR_A" "$BASE_URL/api/businesses")
[[ "$(json_get "$LIST" "any(b['name'] == '$NAME_A' for b in d['businesses'])")" == "True" ]] \
    && pass "Business persists across logout/login" || fail "Business lost after re-login: $LIST"

# --- Nothing here should have broken existing endpoints ---
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$JAR_A" "$BASE_URL/api/posts")
[[ "$CODE" == "200" ]] && pass "GET /api/posts still works" || fail "GET /api/posts returned $CODE"

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
