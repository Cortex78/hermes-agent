#!/usr/bin/env bash
# Build the minimal rootfs image (and the mock endpoint that shares it).
#
#   bash boot/scripts/build.sh              # both images
#   bash boot/scripts/build.sh min          # just the agent image
#
# Handles two environment quirks so the build works on a laptop and inside a
# TLS-intercepting sandbox without editing the Dockerfile: a proxy bound to host
# loopback needs --network=host, and an intercepting proxy needs its CA passed
# as a BuildKit secret (never as a layer).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

TARGETS=("${@:-}")
[ -z "${TARGETS[0]:-}" ] && TARGETS=(min mock)

DOCKERFILE=boot/Dockerfile.min
BUILD_ARGS=(--progress=plain)

# A proxy on 127.0.0.1 is unreachable from the default bridge network.
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
if [[ "$PROXY" == *"127.0.0.1"* || "$PROXY" == *"localhost"* ]]; then
    echo "[build] proxy on host loopback ($PROXY) -> --network=host" >&2
    BUILD_ARGS+=(--network=host)
fi

# Pass a CA bundle only if one is configured; the Dockerfile treats it as
# optional and the build succeeds on a normal network without it.
CA="${SSL_CERT_FILE:-${REQUESTS_CA_BUNDLE:-${CURL_CA_BUNDLE:-}}}"
if [ -n "$CA" ] && [ -s "$CA" ]; then
    echo "[build] using CA bundle: $CA" >&2
    BUILD_ARGS+=(--secret "id=ca_bundle,src=$CA")
fi

if [ ! -s boot/closure.txt ]; then
    cat >&2 <<'EOF'
[build] boot/closure.txt is missing.

The image copies exactly the files a recorded turn touched. Record it first:

    boot/scripts/record_closure.py --out boot/closure.txt -- "run the terminal tool"

(see boot/README.md for the mock-endpoint setup that recording needs)
EOF
    exit 1
fi

for target in "${TARGETS[@]}"; do
    tag="hermes-${target}:latest"
    echo "[build] === $target -> $tag ===" >&2
    docker build "${BUILD_ARGS[@]}" -f "$DOCKERFILE" --target "$target" -t "$tag" . \
        2>&1 | tail -25
done

echo >&2
echo "[build] image sizes:" >&2
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' \
    | grep -E '^\s+hermes-(min|mock)' || true
