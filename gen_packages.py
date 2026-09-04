#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描 debs/ 目录，生成 Packages / Packages.gz / Packages.bz2 / Release。

修复点（旧版只认 control.tar.gz，导致 xz 格式的 deb 解析出空 control，
Packages 缺 Package/Version 等字段，源在 Sileo/Zebra/Cydia 里显示空）：
  - 用通用 ar 解析读取 control.tar.{gz,xz,zst}，不再硬编码 .gz
  - 生成完索引后同步刷新 Release 的 MD5Sum/SHA1/SHA256 与 Date
"""
import os
import io
import re
import gzip
import bz2
import time
import hashlib
import tarfile
import email.utils

HERE = os.path.dirname(os.path.abspath(__file__))
DEBS_DIR = os.path.join(HERE, 'debs')
PACKAGES_PATH = os.path.join(HERE, 'Packages')
RELEASE_PATH = os.path.join(HERE, 'Release')

FIELD_ORDER = [
    'Package', 'Name', 'Version', 'Architecture', 'Priority', 'Section',
    'Author', 'Maintainer', 'Depends', 'Pre-Depends', 'Conflicts',
    'Replaces', 'Provides', 'Description', 'Tag', 'Icon',
]


def parse_ar(data):
    """极简 GNU ar 解析 -> {member_name: bytes}"""
    assert data[:8] == b'!<arch>\n', 'not an ar archive'
    members = {}
    off = 8
    while off + 60 <= len(data):
        header = data[off:off + 60]
        name = header[0:16].decode('utf-8', 'replace').rstrip()
        if name.endswith('/'):
            name = name[:-1]
        size = int(header[48:58].decode().strip() or '0')
        off += 60
        body = data[off:off + size]
        off += size
        if size % 2 == 1:
            off += 1  # ar 2 字节对齐填充
        if name in ('', '/', '//'):
            continue
        members[name] = body
    return members


def extract_control(deb_path):
    """从 .deb 中提取 DEBIAN/control 内容（兼容 gz / xz / zst）"""
    with open(deb_path, 'rb') as f:
        data = f.read()
    members = parse_ar(data)
    ctrl_name = next((n for n in members if n.startswith('control.tar')), None)
    if not ctrl_name:
        return ''
    raw = members[ctrl_name]
    if ctrl_name.endswith('.xz'):
        mode = 'r:xz'
    elif ctrl_name.endswith('.gz'):
        mode = 'r:gz'
    elif ctrl_name.endswith('.zst'):
        # stdlib 不支持 zst；如需要可安装 zstandard 后处理
        return ''
    else:
        mode = 'r:'
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode=mode) as tar:
            for name in ('./control', 'control'):
                try:
                    f = tar.extractfile(name)
                except KeyError:
                    f = None
                if f:
                    return f.read().decode('utf-8', 'replace')
    except Exception as e:
        print(f'  ! 解压 {ctrl_name} 失败: {e}')
    return ''


def parse_control(text):
    d = {}
    last = None
    for line in text.splitlines():
        if line and not line[0].isspace() and ':' in line:
            key, val = line.split(':', 1)
            d[key.strip()] = val.strip()
            last = key.strip()
        elif line[:1] in (' ', '\t') and last:
            d[last] += '\n ' + line.strip()
    return d


def get_deb_info(deb_path):
    info = parse_control(extract_control(deb_path))
    filename = os.path.relpath(deb_path, HERE).replace('\\', '/')
    size = os.path.getsize(deb_path)
    with open(deb_path, 'rb') as f:
        data = f.read()
    info['Filename'] = filename
    info['Size'] = str(size)
    info['MD5sum'] = hashlib.md5(data).hexdigest()
    info['SHA1'] = hashlib.sha1(data).hexdigest()
    info['SHA256'] = hashlib.sha256(data).hexdigest()
    return data, info


def format_entry(info):
    lines = []
    for k in FIELD_ORDER:
        if k in info:
            val = info[k]
            if '\n' in val:
                first, rest = val.split('\n', 1)
                lines.append(f'{k}: {first}')
                for r in rest.split('\n'):
                    lines.append(' ' + r.strip())
            else:
                lines.append(f'{k}: {val}')
    for k in ('Filename', 'Size', 'MD5sum', 'SHA1', 'SHA256'):
        lines.append(f'{k}: {info[k]}')
    return '\n'.join(lines) + '\n\n'


def build_release(content_str):
    header = ''
    if os.path.exists(RELEASE_PATH):
        with open(RELEASE_PATH, 'r', encoding='utf-8') as f:
            old = f.read()
        # 保留 Date 之前的所有头字段，丢弃旧的 Date 与校验和块
        head = old.split('MD5Sum:')[0]
        head = '\n'.join(l for l in head.splitlines() if not l.startswith('Date:'))
        header = head.strip() + '\n'
    date = email.utils.formatdate(time.time(), usegmt=True)
    packages_bytes = content_str.encode('utf-8')
    files = {
        'Packages': packages_bytes,
        'Packages.gz': gzip.compress(packages_bytes, 9),
        'Packages.bz2': bz2.compress(packages_bytes, 9),
    }
    for fn, b in files.items():
        p = os.path.join(HERE, fn)
        if fn == 'Packages':
            with open(p, 'w', encoding='utf-8') as f:
                f.write(content_str)
        else:
            with open(p, 'wb') as f:
                f.write(b)

    def block(algo):
        out = []
        for fn, b in files.items():
            if algo == 'MD5Sum':
                h = hashlib.md5(b).hexdigest()
            elif algo == 'SHA1':
                h = hashlib.sha1(b).hexdigest()
            elif algo == 'SHA256':
                h = hashlib.sha256(b).hexdigest()
            else:
                h = hashlib.new(algo.lower()).hexdigest(b)
            out.append(f' {h} {len(b)} {fn}')
        return f'{algo}:\n' + '\n'.join(out)

    release = header + f'Date: {date}\n\n'
    release += block('MD5Sum') + '\n'
    release += block('SHA1') + '\n'
    release += block('SHA256') + '\n'
    with open(RELEASE_PATH, 'w', encoding='utf-8') as f:
        f.write(release)
    return files


def main():
    entries = []
    count = 0
    for fname in sorted(os.listdir(DEBS_DIR)):
        if not fname.endswith('.deb'):
            continue
        path = os.path.join(DEBS_DIR, fname)
        data, info = get_deb_info(path)
        if 'Package' not in info or 'Version' not in info:
            print(f'  ! 跳过（control 解析失败，缺 Package/Version）: {fname}')
            continue
        entries.append(format_entry(info))
        count += 1
        print(f'  + {info.get("Package")} {info.get("Version")}  [{fname}]')

    content = ''.join(entries)
    with open(PACKAGES_PATH, 'w', encoding='utf-8') as f:
        f.write(content)

    files = build_release(content)

    print(f'\n  Packages: {len(content)} bytes, {count} 个包')
    print(f'  Packages.gz: {len(files["Packages.gz"])} bytes')
    print(f'  Packages.bz2: {len(files["Packages.bz2"])} bytes')
    print('  Release: 已同步校验和')
    print('  Done!')


if __name__ == '__main__':
    main()
