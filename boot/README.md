# `boot/` — the minimal bootable target, built and tested

A `FROM scratch` image containing only what one non-interactive `hermes -z`
turn provably touches, plus a mock inference endpoint and an assertion suite
that makes the image prove it.

The image is defined by a **recorded closure**, not by a hand-written file list:
`record_closure.py` instruments `sys.modules` and an `open` audit hook during a
real tool-calling turn, and `collect_rootfs.sh` copies exactly those files. A
wrong manifest does not produce a smaller image, it produces one that does not
run — so the byte ledger is verified by construction.

```sh
bash boot/scripts/build.sh      # -> hermes-min:latest, hermes-mock:latest
bash boot/scripts/verify.sh     # 9 assertions across 5 scenarios
bash boot/scripts/measure.sh    # the byte ledger, from the built image
```

## Measured result

```
row                   files          bytes      MiB      %
--------------------------------------------------------------
interpreter               4      5,369,412      5.1    6.4
stdlib                 1580     25,872,330     24.7   31.0
wheels (tier-4)        1503     18,374,559     17.5   22.0
repo                    500     16,925,366     16.1   20.3
busybox                  28      1,206,733      1.2    1.4
syslibs                  66     15,603,210     14.9   18.7
etc + trust               7             96      0.0    0.0
--------------------------------------------------------------
TOTAL                  3690     83,351,706     79.5  100.0
```

**79.5 MiB of userland, 30.9× the 2,697,936 B floor comparator.** All 9
assertions pass, including a turn in which the model calls a tool, the agent
reassembles fragmented SSE argument deltas, executes it, and returns
`role: tool`.

`collect_rootfs.sh` reports 85,244,080 B for the same tree because `du -sb`
bills directory inodes; `measure.sh` sums file sizes only. Both are correct
under their own definition — the file-sum is the one quoted above.

**Docker shares the host kernel, so the ~2.8 MiB kernel row is neither included
above nor tested here.** See `boot/kernel/README.md`; that row remains an
estimate and the "bare metal" claim is untested until the QEMU step there runs.

## What building it corrected

Every line below replaced an estimate with a measurement, and four of them
changed the answer.

| Claim | Estimated | Measured | Verdict |
|---|---|---|---|
| repo source on the turn path | 16,641,955 B / 436 files | **16,744,323 B / 440 files** | confirmed, +0.6% |
| repo data files | 180,692 B | **180,781 B** | confirmed, +0.05% |
| `/bin/bash` needed for tool execution | +1,654,352 B | **not needed** | **wrong** — busybox `ash` ran the `terminal` tool; the image has no bash |
| `toolsets.enabled: [terminal]` constrains tools | partition enforced | **18 tools advertised** | **wrong** — the key does not constrain the advertised set |
| egress per turn | "3 connects, 2 requests" | **12–14 requests / 9–10 connections** | **wrong by ~5×** |
| interpreter | 6,639,992 B | **5,369,412 B** | differs — `python:slim` is a 14 KB stub + 5.35 MB `libpython3.11.so` |
| `.pyc`-only would roughly halve the source rows | — | **saves 1,203,395 B (3.5%)** | **wrong** — 33.1 MiB of `-OO` bytecode vs 34.3 MiB of source |

The egress finding is the one worth reading twice. One turn against a single
configured `base_url` produces:

```
  4 /api/v1/models          <- OpenRouter-shaped path
  2 /v1/models
  2 /v1/models/mock-model
  2 /v1/chat/completions    <- the actual work
  2 /api/show               <- Ollama's model-info endpoint
```

Two of the twelve requests are the turn. The rest is provider capability
probing, including probes for two providers that were never configured. All of
it goes to the one configured host, so the single-host property holds — but
"reaches an inference endpoint" costs 6× more round trips than the work itself.

## Scenarios

`verify.sh` runs five. Three of them exist to test the behaviour the 3 MB floor
comparator does *not* have, because that is where the extra bytes are supposed
to be earning their place:

| Scenario | Asserts |
|---|---|
| `plain` | turn completes on the scratch rootfs; `state.db` is created (SQLite reachable) |
| `toolcall` | fragmented SSE tool-call args reassemble; tool executes; `role: tool` returns; busybox `ash` sufficed |
| `retry` | recovers from HTTP 429 + `Retry-After` |
| `reset` | recovers from a connection killed mid-stream |
| `egress` | all traffic reaches exactly one host; reports request/connection counts and probed paths |

`retry` and `reset` pass. That is the concrete form of the claim that the
floor's single round trip is not the same object as this repo's turn: one TCP
reset ends the floor's run, and does not end this one.

## Files

| Path | What it is |
|---|---|
| `Dockerfile.min` | 4 stages: builder (tier-4 wheels), collector (closure copy + ldd), `min` (scratch), `mock` |
| `Dockerfile.min.dockerignore` | **allowlist** context — the root `.dockerignore` excludes `*.md`, which silently drops `AGENTS.md`, a file the agent opens on the turn path |
| `requirements-tier4.txt` | the 7 pins a recorded turn imports, of the 27 in `[project].dependencies` |
| `closure.txt` / `closure.json` | 499 repo files the recorded turn touched, and the byte report |
| `config/config.yaml` | the minimum config, with each key's justification |
| `mock/mock_endpoint.py` | stdlib-only OpenAI-compatible endpoint; runs on the minimal rootfs itself |
| `scripts/record_closure.py` | regenerates `closure.txt` |
| `scripts/collect_rootfs.sh` | assembles the rootfs; fails the build on a missing manifest entry or a dangling symlink |
| `scripts/build.sh` · `verify.sh` · `measure.sh` | build, assert, weigh |
| `kernel/minimal.config` · `kernel/README.md` | the untested kernel row |

## Regenerating the closure

Required whenever the import graph moves. Needs a running mock:

```sh
python boot/mock/mock_endpoint.py --scenario toolcall --tool-name terminal &
export HERMES_HOME=/tmp/hh && mkdir -p $HERMES_HOME && chmod 700 $HERMES_HOME
cp boot/config/config.yaml $HERMES_HOME/          # edit base_url to 127.0.0.1:8099
OPENAI_API_KEY=sk-mock python boot/scripts/record_closure.py \
    --out boot/closure.txt --json-out boot/closure.json -- "run the terminal tool"
```

Record against the `toolcall` scenario: it is a superset of `plain`, and a
manifest recorded without a tool call omits the tool-execution path.

Two traps, both hit while building this. `hermes -z` ends in
`hermes_cli/main.py:_exit_after_oneshot`, which calls `os._exit` to skip CPython
finalization (it guards a SIGABRT from a native extension's finalizer) — that
skips `atexit` and anything after `main()`, so the recorder hooks `os._exit`
itself. And clear `__pycache__` first, or stale `.pyc` files from an earlier run
double-bill every module they were compiled from.

## Known-unverified

- The kernel row. Nothing here booted a kernel.
- Real bare metal. Docker is not it, and neither is the QEMU step in
  `kernel/README.md`.
- TLS. Every scenario runs plaintext HTTP against the mock. The mock accepts
  `--certfile/--keyfile`, but no scenario uses them yet, so `agent/ssl_guard.py`
  and certificate validation are exercised only by the earlier
  local measurements, not by this suite.
- Steady state. Every turn starts from a fresh `$HERMES_HOME`; second-turn
  egress and state growth are unmeasured.
