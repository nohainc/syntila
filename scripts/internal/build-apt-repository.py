#!/usr/bin/env python3
"""Adds .deb files to a signed static APT repository (suite stable, component main).

  build-apt-repository.py --repo DIR --signing-key FINGERPRINT [--prune PACKAGE ...] DEB...

DIR is a checkout of the apt-repository branch. Packages already in the pool are kept
(a version is immutable: a different file with the same name is refused). The index
is rebuilt from every .deb in the pool, read without dpkg. Needs gpg and the private
key in the current GNUPGHOME. No private key is written into DIR.
"""
import argparse, gzip, hashlib, io, re, shutil, subprocess, tarfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

ARCHES = ("amd64", "arm64")
KEYRING = "syntila-archive-keyring.gpg"

def read_ar(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"!<arch>\n", f"not a deb: {path}"
    pos, members = 8, {}
    while pos < len(data):
        header = data[pos:pos + 60]
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        members[name] = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size % 2)
    return members

def control_of(path):
    members = read_ar(path)
    name = next(n for n in members if n.startswith("control.tar"))
    with tarfile.open(fileobj=io.BytesIO(members[name])) as tar:
        member = next(m for m in tar.getmembers() if m.name.lstrip("./") == "control")
        text = tar.extractfile(member).read().decode().strip()
    fields = {}
    for line in text.splitlines():
        if not line.startswith(" ") and ": " in line:
            k, v = line.split(": ", 1); fields[k] = v
    return text, fields

def build(repo, debs, key, prune):
    pool = repo / "pool/main/s/syntila-connect"
    for source in debs:
        _, f = control_of(source)
        if f["Package"] != "syntila-connect" or f["Architecture"] not in ARCHES:
            raise SystemExit(f"unexpected package {source}: {f.get('Package')} {f.get('Architecture')}")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", f["Version"]):
            raise SystemExit("bad version")
        dest = pool / f"syntila-connect_{f['Version']}_{f['Architecture']}.deb"
        pool.mkdir(parents=True, exist_ok=True)
        if dest.exists() and dest.read_bytes() != Path(source).read_bytes():
            raise SystemExit(f"refusing to replace immutable package {dest.name}")
        shutil.copyfile(source, dest)
    for old in sorted((repo / "pool").rglob("*.deb")):
        _, f = control_of(old)
        if f["Package"] in prune:
            old.unlink()
    indexes = {a: [] for a in ARCHES}
    for deb in sorted((repo / "pool").rglob("*.deb")):
        text, f = control_of(deb)
        if f["Architecture"] not in ARCHES: continue
        content = deb.read_bytes()
        indexes[f["Architecture"]].append(
            f"{text}\nFilename: {deb.relative_to(repo).as_posix()}\nSize: {len(content)}\n"
            f"SHA256: {hashlib.sha256(content).hexdigest()}\n\n")
    suite = repo / "dists/stable"
    shutil.rmtree(suite, ignore_errors=True)
    hashes = []
    for arch, entries in indexes.items():
        rel = Path(f"main/binary-{arch}/Packages")
        raw = "".join(entries).encode()
        for suffix, content in (("", raw), (".gz", gzip.compress(raw, mtime=0))):
            target = suite / (str(rel) + suffix)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            by_hash = target.parent / "by-hash/SHA256" / digest
            by_hash.parent.mkdir(parents=True, exist_ok=True)
            by_hash.write_bytes(content)
            hashes.append(f" {digest} {len(content)} {rel}{suffix}")
    release = suite / "Release"
    release.write_text("Origin: Syntila\nLabel: Syntila Connect\nSuite: stable\nCodename: stable\n"
                       f"Date: {format_datetime(datetime.now(timezone.utc), usegmt=True)}\n"
                       "Architectures: amd64 arm64\nComponents: main\nAcquire-By-Hash: yes\n"
                       "Description: Syntila Connect packages\nSHA256:\n" + "\n".join(hashes) + "\n")
    public = subprocess.check_output(["gpg", "--batch", "--export", key])
    if not public: raise SystemExit("signing key has no public part in this keyring")
    (repo / KEYRING).write_bytes(public)
    for mode, target in (("--clearsign", suite / "InRelease"), ("--detach-sign", suite / "Release.gpg")):
        subprocess.run(["gpg", "--batch", "--yes", "--local-user", key, "--digest-algo", "SHA256",
                        "--output", str(target), mode, str(release)], check=True)
    (repo / ".nojekyll").touch()
    print(f"Signed APT repository updated: {repo}")

if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", type=Path, required=True)
    p.add_argument("--signing-key", required=True)
    p.add_argument("--prune", action="append", default=[])
    p.add_argument("debs", type=Path, nargs="*")
    a = p.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9]{40,64}", a.signing_key): p.error("use the full key fingerprint")
    build(a.repo, a.debs, a.signing_key, set(a.prune))
