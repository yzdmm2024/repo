#!/usr/bin/env python3
"""扫描 debs/ 目录，生成 Packages / Packages.gz / Packages.bz2"""
import hashlib, os, gzip, bz2, shutil, tarfile, io

DEBS_DIR = os.path.join(os.path.dirname(__file__), 'debs')
PACKAGES_PATH = os.path.join(os.path.dirname(__file__), 'Packages')

def extract_control(deb_path):
    """从 .deb 中提取 DEBIAN/control 内容"""
    with open(deb_path, 'rb') as f:
        data = f.read()
    # .deb = ar archive, 跳过 debian-binary, 读 control.tar.gz
    # 找到第二个文件 (control.tar.gz) 的偏移
    idx = data.find(b'\n')
    if idx == -1: return ''
    # 跳过 debian-binary
    data = data[idx+1:]
    # 找 control.tar.gz 的头部
    # ar header: name (16) + timestamp (12) + owner (6) + group (6) + mode (8) + size (10) + \x60\x0a
    idx = data.find(b'control.tar.gz')
    if idx == -1: return ''
    hdr = data[idx:idx+60]
    size_str = hdr[48:58].strip()
    if not size_str: return ''
    size = int(size_str)
    offset = idx + 60
    tar_data = data[offset:offset+size]
    # 解压 control.tar.gz
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_data), mode='r:gz') as tar:
            try:
                f = tar.extractfile('control')
                if f:
                    return f.read().decode('utf-8')
            except KeyError:
                pass
            try:
                f = tar.extractfile('./control')
                if f:
                    return f.read().decode('utf-8')
            except KeyError:
                pass
    except:
        pass
    return ''

def parse_control(text):
    """将 control 文本解析为 dict"""
    d = {}
    for line in text.splitlines():
        if ':' in line:
            key, val = line.split(':', 1)
            d[key.strip()] = val.strip()
    return d

def get_deb_info(deb_path):
    """获取 deb 的元信息"""
    control_text = extract_control(deb_path)
    info = parse_control(control_text)
    
    filename = os.path.relpath(deb_path, os.path.dirname(PACKAGES_PATH)).replace('\\', '/')
    size = os.path.getsize(deb_path)
    with open(deb_path, 'rb') as f:
        data = f.read()
    
    info['Filename'] = filename
    info['Size'] = str(size)
    info['MD5sum'] = hashlib.md5(data).hexdigest()
    info['SHA1'] = hashlib.sha1(data).hexdigest()
    info['SHA256'] = hashlib.sha256(data).hexdigest()
    return info

def format_entry(info):
    """格式化一个 deb 条目"""
    lines = []
    keys = ['Package', 'Name', 'Version', 'Architecture', 'Priority', 'Section',
            'Author', 'Maintainer', 'Depends', 'Conflicts', 'Replaces',
            'Description', 'Tag', 'Filename', 'Size', 'MD5sum', 'SHA1', 'SHA256', 'Icon']
    for k in keys:
        if k in info:
            lines.append(f'{k}: {info[k]}')
    return '\n'.join(lines) + '\n\n'

def main():
    entries = []
    for fname in sorted(os.listdir(DEBS_DIR)):
        if not fname.endswith('.deb'):
            continue
        path = os.path.join(DEBS_DIR, fname)
        info = get_deb_info(path)
        entry = format_entry(info)
        entries.append(entry)
        print(f'  + {fname}')
    
    content = ''.join(entries)
    
    with open(PACKAGES_PATH, 'w', encoding='utf-8') as f:
        f.write(content)
    
    with gzip.open(PACKAGES_PATH + '.gz', 'wt', encoding='utf-8') as f:
        f.write(content)
    
    with bz2.open(PACKAGES_PATH + '.bz2', 'wt', encoding='utf-8') as f:
        f.write(content)
    
    print(f'\n  Packages: {len(content)} bytes')
    print(f'  Packages.gz: {os.path.getsize(PACKAGES_PATH + ".gz")} bytes')
    print(f'  Packages.bz2: {os.path.getsize(PACKAGES_PATH + ".bz2")} bytes')
    print(f'  Done! {len(entries)} packages')

if __name__ == '__main__':
    main()