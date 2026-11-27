#!/usr/bin/env python3
"""Builds a .deb from a directory tree without dpkg, so the Mac can package Linux releases.

  make-deb.py --root DIR --output FILE --package NAME --version V --arch amd64|arm64 \
              --maintainer "Name <mail>" --description "One line" [--homepage URL] [--depends "a, b"]

DIR is the installed file system (usr/bin/...). Files are owned by root; executables
are 0755, other files 0644. The output is reproducible for the same inputs
(timestamps come from SOURCE_DATE_EPOCH, default 0).
"""
import argparse, gzip, hashlib, io, os, re, sys, tarfile

def ar_member(name, data, mtime):
    header = f"{name + '/':<16}{mtime:<12d}{0:<6d}{0:<6d}{'100644':<8}{len(data):<10d}`\n".encode()
    assert len(header) == 60
    return header + data + (b"\n" if len(data) % 2 else b"")

def tar_gz(entries, mtime):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for name, kind, mode, data in entries:
            info = tarfile.TarInfo(name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = mtime
            info.mode = mode
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                tar.addfile(info)
            else:
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=mtime) as gz:
        gz.write(raw.getvalue())
    return out.getvalue()

def main():
    p = argparse.ArgumentParser()
    for flag in ("root", "output", "package", "version", "arch", "maintainer", "description"):
        p.add_argument("--" + flag, required=True)
    p.add_argument("--homepage", default="")
    p.add_argument("--depends", default="")
    a = p.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", a.package): sys.exit("bad package name")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+([+~.-][A-Za-z0-9.+~-]+)?", a.version): sys.exit("bad version")
    if a.arch not in ("amd64", "arm64"): sys.exit("arch must be amd64 or arm64")
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    entries, md5s, size = [], [], 0
    dirs = set()
    for base, subdirs, files in os.walk(a.root):
        subdirs.sort()
        rel = os.path.relpath(base, a.root)
        if rel != ".":
            parts = rel.split(os.sep)
            for i in range(1, len(parts) + 1): dirs.add("/".join(parts[:i]))
        for f in sorted(files):
            path = os.path.join(base, f)
            if os.path.islink(path): sys.exit(f"symlinks are not supported: {path}")
            data = open(path, "rb").read()
            name = os.path.relpath(path, a.root).replace(os.sep, "/")
            mode = 0o755 if os.stat(path).st_mode & 0o111 else 0o644
            entries.append((name, "file", mode, data))
            md5s.append(f"{hashlib.md5(data).hexdigest()}  {name}\n")
            size += len(data)
    data_entries = [("./", "dir", 0o755, b"")] + [("./" + d + "/", "dir", 0o755, b"") for d in sorted(dirs)] + \
                   [("./" + n, k, m, d) for n, k, m, d in sorted(entries)]
    control = f"Package: {a.package}\nVersion: {a.version}\nArchitecture: {a.arch}\nMaintainer: {a.maintainer}\n" \
              f"Installed-Size: {(size + 1023) // 1024}\nSection: utils\nPriority: optional\n"
    if a.depends: control += f"Depends: {a.depends}\n"
    if a.homepage: control += f"Homepage: {a.homepage}\n"
    control += f"Description: {a.description}\n"
    ctl = tar_gz([("./", "dir", 0o755, b""), ("./control", "file", 0o644, control.encode()),
                  ("./md5sums", "file", 0o644, "".join(md5s).encode())], mtime)
    deb = b"!<arch>\n" + ar_member("debian-binary", b"2.0\n", mtime) + ar_member("control.tar.gz", ctl, mtime) \
          + ar_member("data.tar.gz", tar_gz(data_entries, mtime), mtime)
    os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
    open(a.output, "wb").write(deb)
    print(a.output)

if __name__ == "__main__":
    main()
