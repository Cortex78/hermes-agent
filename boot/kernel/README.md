# Row 1: the kernel

**Nothing in this directory is tested by the Docker harness.** Containers share
the host kernel, so `boot/scripts/verify.sh` proves the *userland* rows of the
ledger and says nothing about this one. `minimal.config` is a config sketch
derived from reading the code, not a kernel that was built and booted. Treat
every number here as an estimate until someone runs the QEMU step below.

## What the userland measurably needs

These are not guesses — each was observed during the recorded turn that produced
`boot/closure.txt`, or is forced by a library the rootfs demonstrably links.

| Facility | Config symbol | Why the turn needs it |
|---|---|---|
| epoll | `EPOLL` | `selectors.DefaultSelector` is `EpollSelector`; the asyncio loop is built on it |
| futex | `FUTEX` | CPython's GIL and `threading`; the agent runs a stream watchdog thread |
| eventfd | `EVENTFD` | asyncio self-pipe wakeups |
| timerfd | `TIMERFD` | asyncio timers, the 180 s stale-stream watchdog |
| signalfd / signals | `SIGNALFD` | SIGINT/SIGTERM handling in the oneshot path |
| POSIX file locks | `FILE_LOCKING` | SQLite `fcntl(F_SETLK)` on `state.db`; a read-only mount gives `OSError: [Errno 30]` |
| tmpfs / shmem | `SHMEM`, `TMPFS` | SQLite WAL `-shm` mapping; `tempfile` |
| devtmpfs | `DEVTMPFS` | `/dev/null`, `/dev/urandom` |
| PTYs | `UNIX98_PTYS`, `DEVPTS_FS` | `ptyprocess` is a core pin; the terminal tool's environment path |
| ELF + script binfmt | `BINFMT_ELF`, `BINFMT_SCRIPT` | `execve` of busybox `ash` for the tool call |
| unix sockets | `UNIX` | `code_execution_tool.py` opens `AF_UNIX` for sandbox RPC on POSIX |
| /proc, /sys | `PROC_FS`, `SYSFS` | `psutil`, CPython startup |
| TCP/IPv4 | `INET` | the one HTTPS endpoint |
| getrandom | (always on) | OpenSSL 3.x DRBG seeds via **blocking** `getrandom` |
| membarrier | `MEMBARRIER` | glibc/CPython thread teardown |

Storage and NIC drivers depend on the target board. `virtio-net` + `virtio-blk`
is the cheap case; a real server NIC (i40e, ice, bnxt, mlx5) costs more and may
need a firmware blob that this ledger does not price.

## The entropy trap

`strace -e getrandom python3 -c pass` shows two `getrandom` calls at
interpreter startup, and OpenSSL seeds its DRBG through the **blocking**
variant. On a headless board with no HWRNG and no `RANDOM_TRUST_CPU`, first
TLS handshake stalls for minutes rather than failing — which reads as a hang,
not an error. Set `CONFIG_RANDOM_TRUST_CPU=y` or provide an HWRNG.

## Costs neither ledger row pays

| Item | Size | Basis |
|---|---:|---|
| UEFI firmware in SPI flash | ~3.5–4 MiB (edk2/OVMF), 16–32 MiB vendor | published image sizes; not measured here |
| FAT32 ESP minimum volume | 32.0 MiB | FAT32 requires ≥65,525 clusters × 512 B |
| RAM | ≥256 MiB | est. from RSS-per-loaded-source-byte; not measured on real hardware |

The ESP figure is the one worth keeping in view: a 2.6 MiB floor image still
cannot live on anything smaller than a 32 MiB FAT volume, and a `tinyconfig`
kernel has no FAT driver — it cannot read the medium it booted from.

## Actually testing this

Not done. The honest sequence:

```sh
# 1. build a kernel from the sketch
make tinyconfig
scripts/kconfig/merge_config.sh .config boot/kernel/minimal.config
make -j"$(nproc)" bzImage          # -> arch/x86/boot/bzImage, measure it

# 2. turn the verified rootfs into an initramfs
CID=$(docker create hermes-min:latest)
docker export "$CID" | (mkdir -p /tmp/initrd && tar -C /tmp/initrd -xf -)
docker rm "$CID"
# /init must exist: a busybox script that mounts /proc /sys /dev, brings up
# eth0, sets the clock via SNTP, then execs the agent.
( cd /tmp/initrd && find . | cpio -o -H newc | gzip -9 ) > /tmp/initrd.gz

# 3. boot it
qemu-system-x86_64 -kernel arch/x86/boot/bzImage -initrd /tmp/initrd.gz \
  -append "console=ttyS0 rdinit=/init" -nographic -m 512 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```

Until step 3 prints the agent's reply, row 1 of the ledger remains an estimate
and the "bare metal" claim in the README is a claim about a QEMU guest at best.
