#!/usr/bin/env python3
"""Extract only a bounded, regular Payload from an IPA for signature checks."""

import pathlib
import stat
import sys
import zipfile


def extract(ipa, destination):
    destination = pathlib.Path(destination)
    total = 0
    apps = set()
    with zipfile.ZipFile(ipa) as archive:
        for member in archive.infolist():
            name = member.filename
            parts = name.rstrip("/").split("/")
            mode = member.external_attr >> 16
            if (not name or name.startswith("/") or "\\" in name or
                    any(part in ("", ".", "..") for part in parts) or
                    stat.S_ISLNK(mode)):
                raise ValueError("IPA contains an unsafe path or symbolic link")
            if len(parts) >= 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                apps.add(parts[1])
            if parts[0] != "Payload":
                continue
            total += member.file_size
            if total > 1024 * 1024 * 1024:
                raise ValueError("IPA expanded Payload exceeds 1 GiB")
            target = destination.joinpath(*parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, target.open("wb") as output:
                remaining = member.file_size
                while chunk := source.read(min(1024 * 1024, remaining + 1)):
                    remaining -= len(chunk)
                    if remaining < 0:
                        raise ValueError("IPA member exceeds declared size")
                    output.write(chunk)
            target.chmod(mode & 0o777 if mode else 0o644)
    if len(apps) != 1:
        raise ValueError("IPA must contain one top-level app")
    return destination / "Payload" / apps.pop()


if __name__ == "__main__":
    try:
        print(extract(sys.argv[1], sys.argv[2]))
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        sys.exit(f"error: {error}")
