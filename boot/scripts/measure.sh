#!/usr/bin/env bash
# Derive the byte ledger from the image that was actually built.
#
#   bash boot/scripts/measure.sh
#
# Reads the exported rootfs rather than `docker images`, which reports a
# different number (it counts layer overhead and attestation manifests). The
# rootfs byte count is the one that answers "how big is the minimal OS", so it
# is the one reported here.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE=${IMAGE:-hermes-min:latest}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "missing image $IMAGE — run: bash boot/scripts/build.sh" >&2
    exit 1
}

echo "exporting $IMAGE ..." >&2
CID=$(docker create "$IMAGE")
docker export "$CID" > "$WORK/rootfs.tar"
docker rm "$CID" >/dev/null
mkdir -p "$WORK/fs"
tar -C "$WORK/fs" -xf "$WORK/rootfs.tar" 2>/dev/null || true

python3 - "$WORK/fs" "$IMAGE" <<'PY'
import os, sys

root, image = sys.argv[1], sys.argv[2]

# Ledger rows, in the order they appear in boot/README.md. First matching
# prefix wins, so order is significant.
ROWS = [
    ("interpreter",    ["usr/local/bin/python", "usr/local/lib/libpython"]),
    ("stdlib",         ["usr/local/lib/python3.11/lib-dynload"]),
    ("stdlib",         ["usr/local/lib/python3.11"]),
    ("wheels (tier-4)",["opt/venv"]),
    ("repo",           ["opt/hermes"]),
    ("busybox",        ["bin/"]),
    ("syslibs",        ["lib/", "lib64/", "usr/lib/"]),
    ("etc + trust",    ["etc/"]),
]

sizes = {}
counts = {}
unclassified = []
total = 0

for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        try:
            if os.path.islink(full):
                size = len(os.readlink(full))
            else:
                size = os.path.getsize(full)
        except OSError:
            continue
        total += size
        for label, prefixes in ROWS:
            if any(rel.startswith(p) for p in prefixes):
                sizes[label] = sizes.get(label, 0) + size
                counts[label] = counts.get(label, 0) + 1
                break
        else:
            unclassified.append((rel, size))
            sizes["other"] = sizes.get("other", 0) + size
            counts["other"] = counts.get("other", 0) + 1

order = []
for label, _ in ROWS:
    if label in sizes and label not in order:
        order.append(label)
if "other" in sizes:
    order.append("other")

print()
print(f"Minimal rootfs ledger — {image}")
print("=" * 62)
print(f"{'row':<20}{'files':>7}{'bytes':>15}{'MiB':>9}{'%':>7}")
print("-" * 62)
for label in order:
    b = sizes[label]
    print(f"{label:<20}{counts[label]:>7}{b:>15,}{b/1048576:>9.1f}{100*b/total:>7.1f}")
print("-" * 62)
print(f"{'TOTAL':<20}{sum(counts.values()):>7}{total:>15,}{total/1048576:>9.1f}{100.0:>7.1f}")
print()

FLOOR = 2_697_936  # measured bare-metal kernel + static musl mbedTLS client
print(f"3 MB floor comparator : {FLOOR:>15,} B  ({FLOOR/1048576:.1f} MiB)")
print(f"delta                 : {total-FLOOR:>15,} B  ({(total-FLOOR)/1048576:.1f} MiB)")
print(f"ratio                 : {total/FLOOR:>15.1f}x")
print()
print("Docker shares the host kernel, so row 1 of the README ledger (~2.8 MiB")
print("bzImage) is NOT included above and is NOT tested by this harness.")
if unclassified:
    print(f"\nunclassified ({len(unclassified)} files):")
    for rel, size in sorted(unclassified, key=lambda x: -x[1])[:10]:
        print(f"  {size:>12,}  {rel}")
PY
