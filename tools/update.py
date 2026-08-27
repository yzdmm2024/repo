#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
update.py — 扫描 debs/ 目录，重新生成 Cydia/Sileo 源的 Packages / Packages.gz /
            Packages.bz2 / Release。纯 Python 实现，可在 CI（macOS/Linux/Windows）运行，
            不依赖 dpkg。
用法：python3 tools/update.py   （在仓库根目录运行）
"""
import os
import io
import gzip
import bz2
import hashlib
import tarfile
import sys
import re
from email.utils import formatdate

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEBS = os.path.join(ROOT, "debs")
PACKAGES = os.path.join(ROOT, "Packages")
PACKAGES_GZ = PACKAGES + ".gz"
PACKAGES_BZ2 = PACKAGES + ".bz2"
RELEASE = os.path.join(ROOT, "Release")


# ---------- 读取 deb 里的 control（手工解析 ar + tar 压缩包） ----------

def read_ar_members(path):
    """读 ar 归档，返回 {名字: 字节}，兼容 GNU/BSD 风格及偶数对齐。"""
    members = {}
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("not an ar archive: %s" % path)
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode("ascii", "ignore").strip()
            size_s = hdr[48:58].strip().decode("ascii", "ignore")
            try:
                size = int(size_s)
            except ValueError:
                break
            data = f.read(size)
            if len(data) < size:
                break
            if size % 2 == 1:            # ar 按偶数字节对齐
                f.read(1)
            members[name.rstrip("/")] = data
    return members


def _lzma_auto_decompress(raw):
    """兼容 xz (FORMAT_XZ) 与裸 lzma (FORMAT_ALONE)。"""
    import lzma
    try:
        return lzma.decompress(raw)
    except lzma.LZMAError:
        return lzma.decompress(raw, format=lzma.FORMAT_ALONE)


def extract_control(deb_path):
    """从 .deb 中读取 control 文本（theos/标准 deb 均适用）。"""
    members = read_ar_members(deb_path)
    cname = None
    for n in members:
        if n.startswith("control.tar"):
            cname = n
            break
    if not cname:
        raise ValueError("no control.tar in %s" % deb_path)

    raw = members[cname]
    suffix = cname.rsplit(".", 1)[-1]
    if suffix == "gz":
        data = gzip.decompress(raw)
    elif suffix in ("xz", "lzma"):
        data = _lzma_auto_decompress(raw)
    elif suffix == "bz2":
        data = bz2.decompress(raw)
    elif suffix in ("zst", "zstd"):
        try:
            import zstandard as zstd
            data = zstd.ZstdDecompressor().decompress(raw)
        except Exception:
            raise ValueError("zstd 需要 python-zstandard: %s" % deb_path)
    else:
        data = raw

    tf = tarfile.open(fileobj=io.BytesIO(data))
    control_text = None
    for m in tf:
        if m.isfile() and os.path.basename(m.name) == "control":
            control_text = tf.extractfile(m).read().decode("utf-8", "replace")
            break
    tf.close()
    if control_text is None:
        raise ValueError("no control file in %s" % deb_path)
    return control_text


def build_entry(control_text, filename, size, md5, sha1, sha256):
    """保留 control 原有字段，追加 Cydia/Sileo 需要的 Filename/Size/哈希。"""
    keep = []
    skip = {"filename", "size", "md5sum", "sha1", "sha256"}
    for line in control_text.split("\n"):
        heads = line.split(":", 1)[0] if line else ""
        if heads.strip().lower() in skip:
            continue
        keep.append(line.rstrip())
    keep.append("Filename: ./debs/%s" % os.path.basename(filename))
    keep.append("Size: %d" % size)
    keep.append("MD5sum: %s" % md5)
    keep.append("SHA1: %s" % sha1)
    keep.append("SHA256: %s" % sha256)
    return "\n".join(keep)


def sha(data):
    return (hashlib.md5(data).hexdigest(),
            hashlib.sha1(data).hexdigest(),
            hashlib.sha256(data).hexdigest())


def fmtsum():
    """返回 (MD5Sum.., SHA1.., SHA256.., sizes) 三块文本 + 文件块行。"""
    blocks_md5 = []
    blocks_sha1 = []
    blocks_sha256 = []
    for p in (PACKAGES, PACKAGES_GZ, PACKAGES_BZ2):
        data = open(p, "rb").read()
        m5, s1, s256 = sha(data)
        blocks_md5.append(" %s %d %s" % (m5, len(data), os.path.basename(p)))
        blocks_sha1.append(" %s %d %s" % (s1, len(data), os.path.basename(p)))
        blocks_sha256.append(" %s %d %s" % (s256, len(data), os.path.basename(p)))
    return ("\n".join(blocks_md5), "\n".join(blocks_sha1), "\n".join(blocks_sha256))


def main():
    if not os.path.isdir(DEBS):
        print("no debs/ dir"); sys.exit(1)

    debs = sorted(fn for fn in os.listdir(DEBS) if fn.endswith(".deb"))
    if not debs:
        print("no .deb files"); sys.exit(1)

    entries = []
    for fn in debs:
        p = os.path.join(DEBS, fn)
        data = open(p, "rb").read()
        ctrl = extract_control(p)
        m5, s1, s256 = sha(data)
        entries.append(build_entry(ctrl, "debs/" + fn, len(data), m5, s1, s256))
        print("  + %s (%d B)" % (fn, len(data)))

    packages = ("\n\n".join(entries)) + "\n"
    with open(PACKAGES, "w", encoding="utf-8", newline="\n") as f:
        f.write(packages)
    with open(PACKAGES_GZ, "wb") as f:
        f.write(gzip.compress(packages.encode("utf-8"), 9))
    with open(PACKAGES_BZ2, "wb") as f:
        f.write(bz2.compress(packages.encode("utf-8"), 9))

    # 保留 Release 的静态字段，仅更新 Date 与三个哈希块
    if os.path.isfile(RELEASE):
        prev = open(RELEASE, encoding="utf-8", errors="replace").read()
        cut = re.compile(r"^(Date:.*)$", re.M)
        head = cut.sub("Date: " + formatdate(timeval=None, localtime=False, usegmt=True), prev, count=1)
        head = re.split(r"^MD5Sum:$", head, 1, re.M)[0]
    else:
        head = ("Origin: NTM\nLabel: NTM\nSuite: stable\nVersion: 1.0\n"
                "Codename: ios\nArchitectures: iphoneos-arm64\nComponents: main\n"
                "Description: NTM Source\nSupport: https://github.com/yzdmm2024/repo\n"
                "Date: " + formatdate(timeval=None, localtime=False, usegmt=True) + "\n")

    md5b, sha1b, sha256b = fmtsum()
    release = ("%sMD5Sum:\n%s\nSHA1:\n%s\nSHA256:\n%s\n"
               % (head.rstrip() + "\n", md5b, sha1b, sha256b))
    with open(RELEASE, "w", encoding="utf-8", newline="\n") as f:
        f.write(release)

    print("OK -> %d packages" % len(debs))


if __name__ == "__main__":
    main()