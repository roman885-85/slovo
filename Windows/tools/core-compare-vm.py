#!/usr/bin/env python3
# =============================================================================
#  core-compare-vm.py — вивід ядра з Windows 11 (vm/full-check.ps1, --core-check)
#  проти еталона Mac (tools/slovo-ref, Swift) і проти того самого C# на Mac
# =============================================================================
#  core-compare.sh звіряє Swift і C# на Mac; цей — що у справжній Windows ядро
#  друкує те саме: шляхи Windows (C:\…\Temp\slovo-core-check-…\Slovo\…, у JSON —
#  з подвоєними \\) вирівнюються до DATA/…, UUID — до UUID. Розділи — за рядками «# назва».
#  Виклик: core-compare-vm.py <windows core-check.txt> <ref.txt Swift> [<win.txt C# на Mac>]
# =============================================================================
import re, sys, difflib

def norm(text):
    out = []
    for line in text.splitlines():
        line = line.replace('\\/', '/')
        # Windows: C:\Users\…\Temp\slovo-core-check-<hex>\Slovo\a\b (у JSON — \\)
        def win(m):
            return 'DATA' + m.group(2).replace('\\\\', '/').replace('\\', '/')
        line = re.sub(r'[A-Za-z]:(?:\\\\|\\)[^"\s]*?slovo-core-check-[0-9a-f]+(?:\\\\|\\)Slovo((?:(?:\\\\|\\)[^"\\\s|]+(?: [^"\\\s|]+)*)*)', lambda m: 'DATA' + m.group(1).replace('\\\\', '/').replace('\\', '/'), line)
        line = re.sub(r'(?:/private)?/var/folders/[^"\s]*?/slovo-core-check-[0-9a-f]+/Slovo', 'DATA', line)
        line = re.sub(r'(?:/private)?/[^"\s]*?/core-cmp2?/data', 'DATA', line)
        line = re.sub(r'(?:/private)?/var/folders/[^ ]*/slovo-check-res-[0-9A-F-]+', 'TMP', line)
        line = re.sub(r'[A-Za-z]:(?:\\\\|\\)[^"\s]*?(?:\\\\|\\)slovo-check-res-[0-9A-Fa-f-]+', 'TMP', line)
        line = re.sub(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}', 'UUID', line)
        out.append(line)
    return out

def sections(lines):
    result, name = {}, '000-head'
    for line in lines:
        if line.startswith('# '):
            name = re.sub(r'[^A-Za-z0-9_-]', '_', line[2:])
        result.setdefault(name, []).append(line)
    return result

def compare(a_name, a, b_name, b):
    sa, sb = sections(a), sections(b)
    bad = 0
    for name in sorted(set(sa) | set(sb)):
        x, y = sa.get(name), sb.get(name)
        if x is None or y is None:
            print(f'  • {name}: лише в {"Windows" if y is None else b_name}')
            continue
        diff = [d for d in difflib.unified_diff(x, y, lineterm='', n=0) if d[:1] in '+-' and d[:3] not in ('+++', '---')]
        if not diff:
            print(f'  ✓ {name} ({len(x)} рядків)')
        elif name == 'ourwords':
            print(f'  ≈ {name}: {len(diff)} рядків — очікувано (свої слова Windows і вбудований en.json)')
        else:
            bad += 1
            print(f'  ✗ {name}: розбіжних {len(diff)}')
            for d in diff[:6]: print('      ' + d[:200])
    return bad

win = norm(open(sys.argv[1], encoding='utf-8', errors='replace').read())
ref = norm(open(sys.argv[2], encoding='utf-8', errors='replace').read())
print(f'Windows 11 ({len(win)} рядків) проти еталона Mac Swift ({len(ref)} рядків):')
bad = compare('Windows', win, 'Mac', ref)
if len(sys.argv) > 3:
    mac = norm(open(sys.argv[3], encoding='utf-8', errors='replace').read())
    print(f'Windows 11 проти того самого C# на Mac ({len(mac)} рядків):')
    bad += compare('Windows', win, 'Mac C#', mac)
sys.exit(1 if bad else 0)
