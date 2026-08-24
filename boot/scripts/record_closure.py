#!/usr/bin/env python3
"""Record the exact file closure one ``hermes -z`` turn touches.

The byte ledger in ``boot/README.md`` claims a turn loads ~41% of the repo's
non-test source.  Rather than trust that, this records it: an audit hook logs
every ``open`` and every imported module during a real turn against the mock
endpoint, and the resulting manifest is what ``Dockerfile.min`` copies into a
``FROM scratch`` image.  If the manifest is wrong the image does not run, so
the ledger is verified by construction rather than by assertion.

Usage:
    python boot/scripts/record_closure.py --out boot/closure.txt -- <prompt>

Emits, relative to the repo root, one path per line, plus a JSON sidecar with
byte totals per category.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

# Files opened at import time that we must keep, versus scratch/state writes
# under HERMES_HOME which belong to the writable volume, not the image.
SKIP_PREFIXES = ("/proc", "/sys", "/dev", "/tmp", "/var", "/run")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO / "boot" / "closure.txt"))
    ap.add_argument("--json-out", default="")
    ap.add_argument("prompt", nargs="*", default=["say MINIMAL_BOOT"])
    args = ap.parse_args()

    hermes_home = os.path.abspath(os.environ.get("HERMES_HOME", ""))
    opened: set[str] = set()

    def hook(event: str, payload) -> None:
        if event != "open":
            return
        path = payload[0]
        if not isinstance(path, str) or not path:
            return
        if path.startswith(SKIP_PREFIXES):
            return
        if hermes_home and os.path.abspath(path).startswith(hermes_home):
            return
        opened.add(path)

    sys.addaudithook(hook)

    prompt = " ".join(args.prompt) or "say MINIMAL_BOOT"
    sys.argv = ["hermes", "-z", prompt]
    rc = 0

    # ``hermes -z`` ends in ``hermes_cli.main._exit_after_oneshot``, which calls
    # ``os._exit`` to skip CPython finalization (it guards a SIGABRT raised by a
    # native extension's finalizer, #30387/#43055).  That also skips atexit and
    # anything after ``hermes_main()`` here, so the manifest has to be written
    # from inside the exit path rather than after it.
    real_exit = os._exit

    def _exit_with_report(code: int):  # type: ignore[no-untyped-def]
        try:
            _write_report(args, prompt, int(code or 0), opened)
        except Exception as exc:  # never let recording change the exit code
            sys.stderr.write(f"[record_closure] report failed: {exc}\n")
        real_exit(code)

    os._exit = _exit_with_report  # type: ignore[assignment]
    try:
        from hermes_cli.main import main as hermes_main

        hermes_main()
    except SystemExit as exc:
        rc = int(exc.code or 0)
    finally:
        os._exit = real_exit  # type: ignore[assignment]

    _write_report(args, prompt, rc, opened)
    return rc


def _write_report(args, prompt: str, rc: int, opened: set[str]) -> None:
    # sys.modules is the authoritative import record; the audit hook catches
    # data files (plugin manifests, prompt templates) that never appear there.
    module_files: set[str] = set()
    for mod in list(sys.modules.values()):
        origin = getattr(getattr(mod, "__spec__", None), "origin", None) or getattr(
            mod, "__file__", None
        )
        if isinstance(origin, str) and origin and not origin.startswith("<"):
            module_files.add(origin)

    categories: dict[str, dict] = {}
    manifest: set[str] = set()

    def classify(path: str) -> str | None:
        try:
            real = os.path.realpath(path)
        except Exception:
            return None
        if not os.path.isfile(real):
            return None
        if real.startswith(str(REPO) + os.sep):
            rel = os.path.relpath(real, REPO)
            if rel.startswith(("boot/", ".git/", "tests/")):
                return None
            # ``__pycache__`` is a build artifact of a previous run, not repo
            # content.  Counting it alongside the ``.py`` it was compiled from
            # double-bills the same module; the image ships one or the other.
            if "__pycache__" in rel or rel.endswith(".pyc"):
                return "repo_pycache"
            manifest.add(rel)
            return "repo_source" if rel.endswith(".py") else "repo_data"
        if "site-packages" in real:
            return "wheels"
        if real.endswith(".so"):
            return "stdlib_ext"
        return "stdlib"

    for path in module_files | opened:
        cat = classify(path)
        if not cat:
            continue
        try:
            size = os.path.getsize(os.path.realpath(path))
        except OSError:
            continue
        slot = categories.setdefault(cat, {"files": 0, "bytes": 0})
        slot["files"] += 1
        slot["bytes"] += size

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(sorted(manifest)) + "\n", encoding="utf-8")

    report = {
        "rc": rc,
        "prompt": prompt,
        "modules_loaded": len(sys.modules),
        "repo_files_in_manifest": len(manifest),
        "categories": categories,
        "total_bytes": sum(c["bytes"] for c in categories.values()),
    }
    blob = json.dumps(report, indent=2, sort_keys=True)
    if args.json_out:
        Path(args.json_out).write_text(blob + "\n", encoding="utf-8")
    sys.stderr.write(blob + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
