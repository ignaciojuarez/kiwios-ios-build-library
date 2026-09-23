#!/usr/bin/env python3
"""Transfer a private development build over SSH, then replace and launch it."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


def send(app, host, destination, allow_adhoc=False):
    app = Path(app).resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("expected a built .app")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", host):
        raise ValueError("expected an SSH hostname or user@hostname")
    if not destination or not (destination.startswith("/") or destination.startswith("~/")):
        raise ValueError("destination must be absolute or start with ~/")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True)
    if not allow_adhoc and "Signature=adhoc" in signature.stderr:
        raise ValueError("Apple Development signing required (or explicitly set ALLOW_ADHOC_SEND=1)")
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", host]
    stage = subprocess.check_output(ssh + ["mktemp -d /tmp/kiwi-macos.XXXXXXXX"], text=True).strip()
    if not re.fullmatch(r"/tmp/kiwi-macos\.[A-Za-z0-9]+", stage):
        raise ValueError("unexpected remote staging path")
    root = Path(__file__).resolve().parent.parent
    try:
        subprocess.run(["rsync", "-a", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=8",
                        str(app) + "/", f"{host}:{stage}/App.app/"], check=True)
        subprocess.run(["rsync", "-a", "-e", "ssh -o BatchMode=yes -o ConnectTimeout=8",
                        str(root / "macos/receive.sh"), str(root / "macos/quit.swift"),
                        str(root / "lib/xcode.sh"), f"{host}:{stage}/"], check=True)
        command = shlex.join(["/bin/bash", f"{stage}/receive.sh", destination, app.name])
        subprocess.run(ssh + [command], check=True)
    finally:
        subprocess.run(ssh + [shlex.join(["rm", "-rf", "--", stage])], check=False)


if __name__ == "__main__":
    try:
        send(*sys.argv[1:4], allow_adhoc=len(sys.argv) > 4 and sys.argv[4] == "1")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"error: macOS delivery failed: {error}")
