#!/usr/bin/env bash
# Exercise the minimal rootfs against the mock endpoint and assert on what it did.
#
#   bash boot/scripts/verify.sh            # all scenarios
#   bash boot/scripts/verify.sh toolcall   # one scenario
#
# Each scenario is a claim from boot/README.md's ledger rendered as a test. The
# interesting ones are the network-failure cases: `retry` and `reset` are the
# behaviours the 3 MB floor comparator does not have, so if they do not pass,
# the bytes spent on them are not buying what the README says they buy.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

NET=hermes-min-net
MOCK=hermes-min-mock
IMAGE=${IMAGE:-hermes-min:latest}
MOCK_IMAGE=${MOCK_IMAGE:-hermes-mock:latest}
WORK=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    docker rm -f "$MOCK" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '       %s\n' "$*"; }

for img in "$IMAGE" "$MOCK_IMAGE"; do
    docker image inspect "$img" >/dev/null 2>&1 || {
        echo "missing image $img — run: bash boot/scripts/build.sh" >&2
        exit 1
    }
done

docker network create "$NET" >/dev/null 2>&1 || true

new_home() {
    local dir="$WORK/home-$1"
    mkdir -p "$dir" && chmod 700 "$dir"
    cat > "$dir/config.yaml" <<'EOF'
model:
  provider: custom
  base_url: http://hermes-min-mock:8099/v1
  default: mock-model
security:
  allow_lazy_installs: false
toolsets:
  enabled: [terminal]
EOF
    echo "$dir"
}

start_mock() {
    docker rm -f "$MOCK" >/dev/null 2>&1 || true
    docker run -d --name "$MOCK" --network "$NET" "$MOCK_IMAGE" \
        --scenario "$1" --tool-name terminal --log /tmp/wire.jsonl "${@:2}" >/dev/null
    for _ in $(seq 1 25); do
        docker logs "$MOCK" 2>&1 | grep -q '\[mock\]' && return 0
        sleep 0.4
    done
    echo "mock failed to start" >&2
    docker logs "$MOCK" 2>&1 | tail -5 >&2
    return 1
}

wire() { docker exec "$MOCK" /usr/local/bin/python3.11 -c '
import json, sys
for line in open("/tmp/wire.jsonl"):
    print(json.dumps(json.loads(line)))
' 2>/dev/null; }

run_turn() {
    local home="$1" prompt="$2"
    docker run --rm --network "$NET" \
        -e OPENAI_API_KEY=sk-mock -e HERMES_HOME=/opt/data \
        -v "$home:/opt/data" "$IMAGE" -z "$prompt" 2>&1
}

# --------------------------------------------------------------- scenarios

scenario_plain() {
    echo "[plain] one text turn, no tools invoked"
    start_mock plain || return
    local home; home=$(new_home plain)
    local out; out=$(run_turn "$home" "say MINIMAL_BOOT")
    [[ "$out" == *MINIMAL_BOOT_OK* ]] && ok "turn completed on the scratch rootfs" \
        || { bad "no reply from the agent"; note "$out"; }
    [ -f "$home/state.db" ] && ok "transcript persisted to state.db (SQLite reachable)" \
        || bad "state.db absent — SQLite did not initialise"
}

scenario_toolcall() {
    echo "[toolcall] model calls a tool; args arrive as fragmented SSE deltas"
    start_mock toolcall || return
    local home; home=$(new_home toolcall)
    local out; out=$(run_turn "$home" "run the terminal tool")
    local w; w=$(wire)

    [[ "$out" == *MINIMAL_BOOT_OK* ]] && ok "turn completed after the tool round trip" \
        || { bad "turn did not complete"; note "$out"; }
    grep -q '"kind": *"toolcall_issued"' <<<"$w" && ok "server issued a tool call" \
        || bad "server never issued a tool call"
    grep -q '"has_tool_result": *true' <<<"$w" \
        && ok "agent executed the tool and sent role=tool back (SSE args reassembled)" \
        || bad "no role=tool message returned — fragment reassembly or execution failed"

    # The image ships busybox ash and no bash; if the tool ran, ash sufficed.
    if docker run --rm --entrypoint /bin/busybox "$IMAGE" test -e /bin/bash 2>/dev/null; then
        note "note: /bin/bash present in image"
    else
        ok "tool executed with busybox ash only — no /bin/bash in the image"
    fi

    local tools
    tools=$(grep -o '"tool_count": *[0-9]*' <<<"$w" | grep -o '[0-9]*' | sort -rn | head -1)
    note "tools advertised to the model: ${tools:-0} (config requested toolsets.enabled=[terminal])"
    [ "${tools:-0}" -gt 1 ] && note "  -> toolsets.enabled does NOT constrain the advertised set"
}

scenario_retry() {
    echo "[retry] first request is 429 + Retry-After; the floor comparator has no retry"
    start_mock retry --fail-times 1 || return
    local home; home=$(new_home retry)
    local out; out=$(run_turn "$home" "say MINIMAL_BOOT")
    [[ "$out" == *MINIMAL_BOOT_OK* ]] && ok "recovered from HTTP 429 and completed" \
        || { bad "did not recover from a 429"; note "$out"; }
}

scenario_reset() {
    echo "[reset] connection dies mid-stream; tests reconnect, not just retry"
    start_mock reset || return
    local home; home=$(new_home reset)
    local out; out=$(run_turn "$home" "say MINIMAL_BOOT")
    [[ "$out" == *MINIMAL_BOOT_OK* ]] && ok "recovered from a mid-stream disconnect" \
        || { bad "did not recover from a mid-stream disconnect"; note "$out"; }
}

scenario_egress() {
    echo "[egress] a minimal appliance should talk to exactly one host"
    start_mock plain || return
    local home; home=$(new_home egress)
    run_turn "$home" "say MINIMAL_BOOT" >/dev/null
    local w; w=$(wire)
    local reqs conns hosts paths
    reqs=$(grep -c '"kind"' <<<"$w")
    hosts=$(grep -o '"host": *"[^"]*"' <<<"$w" | sed 's/.*"host": *"//;s/"//' | sort -u | grep -v '^$')
    conns=$(docker exec "$MOCK" /usr/local/bin/python3.11 -c \
        'import urllib.request,json;print(json.load(urllib.request.urlopen("http://127.0.0.1:8099/__stats"))["connections"])' 2>/dev/null)
    paths=$(grep -o '"path": *"[^"]*"' <<<"$w" | sed 's/.*"path": *"//;s/"//' | sort | uniq -c | sort -rn)

    [ "$(wc -l <<<"$hosts")" -eq 1 ] && ok "all traffic went to a single host ($hosts)" \
        || { bad "traffic reached more than one host"; note "$hosts"; }
    note "one turn = $reqs HTTP requests over ${conns:-?} TCP connections"
    note "distinct paths probed:"
    while read -r line; do note "    $line"; done <<<"$paths"
}

# ------------------------------------------------------------------- driver

SCENARIOS=("${@:-}")
[ -z "${SCENARIOS[0]:-}" ] && SCENARIOS=(plain toolcall retry reset egress)

echo "image: $IMAGE"
echo
for s in "${SCENARIOS[@]}"; do
    if declare -F "scenario_$s" >/dev/null; then
        "scenario_$s"
    else
        echo "unknown scenario: $s" >&2
        FAIL=$((FAIL + 1))
    fi
    echo
done

echo "-------------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
