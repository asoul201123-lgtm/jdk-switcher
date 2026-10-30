#!/usr/bin/env python3
"""Build a Linux zipapp and tar.gz from an explicit, privacy-checked file list."""
from __future__ import annotations

import argparse
import getpass
import gzip
import hashlib
import io
import os
from pathlib import Path
import platform
import re
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LINUX = ROOT / "linux"
VERSION = "1.1.0"
SOURCES = (
    "README.md", "Start.sh", "jdk_switcher.py", "package.py", "tests/test_core.py",
    "jdk_switcher/__init__.py", "jdk_switcher/core.py", "jdk_switcher/cli.py", "jdk_switcher/gui.py",
)


def check_privacy(name: str, content: bytes) -> None:
    text = content.decode("utf-8")
    tokens = (str(ROOT), ROOT.as_posix(), str(Path.home()), getpass.getuser(), platform.node())
    if any(token and len(token) >= 3 and token.casefold() in text.casefold() for token in tokens):
        raise RuntimeError("Private local identifier found in release input: " + name)
    patterns = (
        r"(?i)[a-z]:[\\/]+Users[\\/]+(?!Public[\\/]|Default[\\/])[^\\/\s<>%]+",
        r"(?i)/(?:home|Users)/[a-z0-9_.-]+/",
        r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        r"\bgh[pousr]_[A-Za-z0-9]{30,}\b", r"\bgithub_pat_[A-Za-z0-9_]{30,}\b",
        r"\bAKIA[0-9A-Z]{16}\b", r"\bsk-[A-Za-z0-9_-]{32,}\b",
    )
    if any(re.search(pattern, text) for pattern in patterns):
        raise RuntimeError("Possible private path or secret found in release input: " + name)


def load_sources() -> dict[str, bytes]:
    files = {}
    for name in SOURCES:
        path = LINUX / name
        if any(parent.is_symlink() for parent in (path, *path.parents) if parent != ROOT.parent):
            raise RuntimeError("Release source paths must not contain symbolic links.")
        content = path.read_bytes()
        check_privacy(name, content)
        files[name] = content
    for name in ("LICENSE", "SECURITY.md"):
        if (ROOT / name).is_symlink():
            raise RuntimeError("Release inputs must not be symbolic links.")
        content = (ROOT / name).read_bytes()
        check_privacy(name, content)
        files[name] = content
    return files


def build() -> tuple[Path, Path]:
    files = load_sources()
    stream = io.BytesIO()
    stream.write(b"#!/usr/bin/env python3\n")
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        module_files = {name: content for name, content in files.items() if name.startswith("jdk_switcher/")}
        module_files["__main__.py"] = b"from jdk_switcher.cli import main\nraise SystemExit(main())\n"
        for name, content in sorted(module_files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.external_attr = (0o100644 << 16)
            archive.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED)
    application = stream.getvalue()
    with zipfile.ZipFile(io.BytesIO(application)) as archive:
        if set(archive.namelist()) != set(module_files):
            raise RuntimeError("Unexpected zipapp entries")
        for name in archive.namelist():
            check_privacy(name, archive.read(name))
    release = io.BytesIO()
    with gzip.GzipFile(fileobj=release, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name, content in sorted({**files, "jdk-switcher": application}.items()):
                info = tarfile.TarInfo("jdk-switcher-linux/" + name)
                info.size = len(content)
                info.mode = 0o755 if name in ("jdk-switcher", "Start.sh") else 0o644
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ""
                archive.addfile(info, io.BytesIO(content))
    payload = release.getvalue()
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        expected = {"jdk-switcher-linux/" + name for name in (*files, "jdk-switcher")}
        if set(archive.getnames()) != expected or any(not member.isfile() for member in archive.getmembers()):
            raise RuntimeError("Unexpected tarball entries")
        if archive.getmember("jdk-switcher-linux/jdk-switcher").mode != 0o755:
            raise RuntimeError("Linux launcher is not executable")
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    standalone = dist / "jdk-switcher-linux.pyz"
    tarball = dist / f"jdk-switcher-{VERSION}-linux.tar.gz"
    for path, content in ((standalone, application), (tarball, payload)):
        path.write_bytes(content)
        if os.name == "posix" and path == standalone:
            path.chmod(0o755)
        digest = hashlib.sha256(content).hexdigest()
        Path(str(path) + ".sha256").write_text(digest + "  " + path.name + "\n", encoding="ascii")
        print("Created dist/" + path.name + " | SHA256 " + digest)
    print("Privacy checks passed; sources and archive metadata contain no matched local identifiers.")
    return standalone, tarball


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    build()
