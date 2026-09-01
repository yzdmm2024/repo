#!/usr/bin/env python3
"""Process the jailbreak repo for self-hosting on Aliyun.

Run inside the checked-out repo root (GitHub Actions). It:
  1. rewrites every Packages `Icon:` to the absolute Aliyun URL (so icons load
     even though the repo's committed Packages may use jsdelivr/relative paths);
  2. (re)compresses Packages into Packages.gz / Packages.bz2;
  3. regenerates Release hashes;
  4. shrinks the 6 package icons to 128px so Sileo loads them fast.
After this, the apt files are copied to the server by scp-action.
"""
import os, re, gzip, bz2, hashlib
from PIL import Image

ROOT = os.path.dirname(os.path.abspath(__file__))
ICON_BASE = "http://101.200.189.251/repo/icons"
ICONS = ["superscreenshot.png", "batteryanalyzer.png", "notifymanager.png",
         "randopenapp.png", "kkgameautologin.png", "privacymanager.png"]

# 1) rewrite Packages Icons -> absolute Aliyun URL
pk = os.path.join(ROOT, "Packages")
s = open(pk, encoding="utf-8").read()

def repl(m):
    name = m.group(1).rsplit("/", 1)[-1]
    return "Icon: " + ICON_BASE + "/" + name

s = re.sub(r"^Icon:\s*(.+)$", repl, s, flags=re.M)
open(pk, "w", encoding="utf-8").write(s)

# 2) compress
data = open(pk, "rb").read()
open(os.path.join(ROOT, "Packages.gz"), "wb").write(gzip.compress(data, 9))
open(os.path.join(ROOT, "Packages.bz2"), "wb").write(bz2.compress(data, 9))

# 3) regenerate Release hashes
files = ["Packages", "Packages.gz", "Packages.bz2"]

def hh(a, d):
    return {"md5": hashlib.md5, "sha1": hashlib.sha1, "sha256": hashlib.sha256}[a](d).hexdigest()

sums = {a: [] for a in ["md5", "sha1", "sha256"]}
for fn in files:
    d = open(os.path.join(ROOT, fn), "rb").read()
    for a in sums:
        sums[a].append(f" {hh(a, d)} {len(d)} {fn}")

src = open(os.path.join(ROOT, "Release"), encoding="utf-8").read().splitlines()
out = []
i = 0
while i < len(src):
    l = src[i]
    if l.strip() in ("MD5Sum:", "SHA1:", "SHA256:"):
        break
    out.append(l)
    i += 1
out += ["MD5Sum:"] + sums["md5"] + ["SHA1:"] + sums["sha1"] + ["SHA256:"] + sums["sha256"]
open(os.path.join(ROOT, "Release"), "w", encoding="utf-8").write("\n".join(out) + "\n")

# 4) shrink icons
for n in ICONS:
    p = os.path.join(ROOT, "icons", n)
    im = Image.open(p).convert("RGBA")
    im.thumbnail((128, 128), Image.LANCZOS)
    im.save(p, "PNG", optimize=True)

print("process_repo done")
