#!/bin/sh
# Assemble the minimal rootfs for `FROM scratch`, one ledger row at a time.
#
# Every file that lands in $OUT is here because something measured demanded it:
# the repo files come from boot/closure.txt (recorded by record_closure.py during
# a real tool-calling turn), and the shared libraries come from an ldd closure
# over every ELF object actually shipped. Nothing is copied "just in case" —
# if a row is wrong the resulting image does not run, which is the point.
#
# Run inside the collector stage of boot/Dockerfile.min.
set -eu

OUT=${OUT:-/out}
SRC=${SRC:-/src}
VENV=${VENV:-/opt/venv}
PYVER=${PYVER:-3.11}
PYHOME=${PYHOME:-/usr/local}

mkdir -p "$OUT"/bin "$OUT"/etc "$OUT"/lib "$OUT"/lib64 "$OUT"/tmp \
         "$OUT"/opt/hermes "$OUT"/opt/data "$OUT$PYHOME/bin" "$OUT$PYHOME/lib"
chmod 1777 "$OUT/tmp"

say() { printf '[collect] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- interpreter
say "CPython $PYVER"
cp -aL "$PYHOME/bin/python$PYVER" "$OUT$PYHOME/bin/python$PYVER"
ln -sf "python$PYVER" "$OUT$PYHOME/bin/python3"
ln -sf "python$PYVER" "$OUT$PYHOME/bin/python"
cp -a "$PYHOME/lib/python$PYVER" "$OUT$PYHOME/lib/"

# Stdlib pruning. These are the packages a headless agent turn provably never
# imports (verified against boot/closure.json's stdlib list); everything else
# stays, because guessing wrong here fails at runtime rather than at build time.
for junk in test idlelib tkinter turtledemo lib2to3 ensurepip pydoc_data \
            distutils/command config-"$PYVER"-x86_64-linux-gnu; do
    rm -rf "$OUT$PYHOME/lib/python$PYVER/$junk"
done
rm -f "$OUT$PYHOME/lib/python$PYVER/turtle.py"
find "$OUT$PYHOME/lib/python$PYVER" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find "$OUT$PYHOME/lib/python$PYVER/lib-dynload" \
     \( -name '_test*' -o -name '_tkinter*' -o -name '_xxtestfuzz*' -o -name 'xx*' \) \
     -delete 2>/dev/null || true

# ---------------------------------------------------------------- tier-4 venv
say "tier-4 site-packages"
mkdir -p "$OUT$VENV"
cp -a "$VENV/lib" "$OUT$VENV/"
find "$OUT$VENV" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
# Wheel metadata and bundled test suites are inert at runtime.
find "$OUT$VENV" -type d \( -name 'tests' -o -name 'test' \) -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT$VENV" -name '*.dist-info' -type d -exec sh -c '
    for d; do find "$d" -type f ! -name "METADATA" ! -name "RECORD" -delete 2>/dev/null || true; done
' sh {} + 2>/dev/null || true

# ------------------------------------------------------------------ repo files
say "repo closure from boot/closure.txt"
if [ ! -s "$SRC/boot/closure.txt" ]; then
    echo "[collect] FATAL: boot/closure.txt missing or empty." >&2
    echo "[collect] Regenerate with boot/scripts/record_closure.py before building." >&2
    exit 1
fi
missing=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "$SRC/$rel" ]; then
        say "MISSING from source tree: $rel"
        missing=$((missing + 1))
        continue
    fi
    mkdir -p "$OUT/opt/hermes/$(dirname "$rel")"
    cp -a "$SRC/$rel" "$OUT/opt/hermes/$rel"
done < "$SRC/boot/closure.txt"
[ "$missing" -eq 0 ] || { echo "[collect] FATAL: $missing manifest entries absent" >&2; exit 1; }

# The launcher the manifest cannot know about: closure.txt records imports, and
# `hermes` itself is exec'd, never imported.
cp -a "$SRC/hermes" "$OUT/opt/hermes/hermes" 2>/dev/null || true

# ------------------------------------------------------------------- busybox
# /init, the mount tooling, and /bin/sh for the terminal tool. Whether busybox
# ash is sufficient (versus a 1.4 MB bash) is what boot/scripts/verify.sh
# scenario `shell` measures.
say "busybox"
BB=$(command -v busybox || echo /bin/busybox)
cp -a "$BB" "$OUT/bin/busybox"
for applet in sh ash mount umount ls cat env mkdir rm ln sleep ps kill printf \
              date hostname ip cp mv grep sed awk head tail wc touch chmod; do
    ln -sf busybox "$OUT/bin/$applet"
done

# ----------------------------------------------------------------- ldd closure
# Resolve every shared object reachable from every ELF we ship. Iterating to a
# fixed point matters: lib-dynload modules pull libraries the interpreter alone
# does not (libsqlite3, libssl, libcrypto, libbz2, liblzma, libffi).
say "shared-library closure"
: > /tmp/elf.list
{
    echo "$OUT$PYHOME/bin/python$PYVER"
    echo "$OUT/bin/busybox"
    find "$OUT$PYHOME/lib/python$PYVER/lib-dynload" -name '*.so' 2>/dev/null || true
    find "$OUT$VENV" -name '*.so' 2>/dev/null || true
    find "$OUT$VENV" -name '*.so.*' 2>/dev/null || true
} >> /tmp/elf.list

: > /tmp/libs.list
while IFS= read -r elf; do
    [ -f "$elf" ] || continue
    ldd "$elf" 2>/dev/null | awk '
        /=> \// { print $3 }
        /^\t\/lib.*ld-linux/ { print $1 }
    ' >> /tmp/libs.list || true
done < /tmp/elf.list

# Two distinct things must land for each entry: the real object at its real
# path, and the SONAME path the loader looks up. Those often differ only by
# directory (/lib/x86_64-linux-gnu/libc.so.6 -> /usr/lib/x86_64-linux-gnu/
# libc.so.6), so comparing basenames is not enough to tell them apart — doing
# that produces a self-referential symlink and ELOOP at exec time.
sort -u /tmp/libs.list | while IFS= read -r lib; do
    [ -e "$lib" ] || continue
    real=$(readlink -f "$lib") || continue
    [ -f "$real" ] || continue

    mkdir -p "$OUT$(dirname "$real")"
    [ -e "$OUT$real" ] || cp -aL "$real" "$OUT$real"

    if [ "$real" != "$lib" ]; then
        mkdir -p "$OUT$(dirname "$lib")"
        # Absolute target: correct regardless of how the two directories relate.
        [ -e "$OUT$lib" ] || ln -s "$real" "$OUT$lib"
    fi
done

# The loader is named by absolute path in every ELF's PT_INTERP, so it must
# exist at that exact path whatever the distro symlinks it to.
for loader in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
    [ -e "$loader" ] || continue
    real=$(readlink -f "$loader")
    [ -f "$real" ] || continue
    mkdir -p "$OUT$(dirname "$loader")"
    [ -e "$OUT$loader" ] && [ ! -L "$OUT$loader" ] || { rm -f "$OUT$loader"; cp -aL "$real" "$OUT$loader"; }
done

# Fail the build rather than ship an image that cannot exec: a self-referential
# symlink here surfaces only at container start, as a bare ELOOP.
broken=$(find "$OUT" -xtype l 2>/dev/null | head -20 || true)
if [ -n "$broken" ]; then
    echo "[collect] FATAL: dangling or self-referential symlinks in rootfs:" >&2
    echo "$broken" >&2
    exit 1
fi

# ------------------------------------------------------------------ /etc floor
# glibc resolves hostnames through NSS, which dlopen()s libnss_* by name at
# runtime — they never appear in an ldd closure, so they are copied explicitly
# or DNS silently fails in the scratch image.
say "/etc + NSS"
for nss in /lib/x86_64-linux-gnu/libnss_dns.so.2 /lib/x86_64-linux-gnu/libnss_files.so.2 \
           /usr/lib/x86_64-linux-gnu/libnss_dns.so.2 /usr/lib/x86_64-linux-gnu/libnss_files.so.2; do
    [ -f "$nss" ] && { mkdir -p "$OUT$(dirname "$nss")"; cp -a "$nss" "$OUT$nss"; } || true
done
printf 'hosts: files dns\npasswd: files\ngroup: files\n' > "$OUT/etc/nsswitch.conf"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$OUT/etc/passwd"
printf 'root:x:0:\n' > "$OUT/etc/group"
printf '127.0.0.1 localhost\n::1 localhost\n' > "$OUT/etc/hosts"
cp -a /etc/ssl/certs/ca-certificates.crt "$OUT/etc/ssl/certs/ca-certificates.crt" 2>/dev/null \
    || mkdir -p "$OUT/etc/ssl/certs"

say "rootfs assembled: $(du -sb "$OUT" | cut -f1) bytes"
