#!/usr/bin/python3
"""Значки для Windows-«Слова»: SF Symbols Mac-версії → відкриті значки Lucide (ISC).
icons.py <тека lucide/icons> icon-map.txt > Sources/App/Theme/IconData.cs"""
import sys, re, xml.etree.ElementTree as ET
icons_dir, map_file = sys.argv[1], sys.argv[2]

def num(v): return float(v)
def fmt(x): return ('%.3f' % x).rstrip('0').rstrip('.')

def to_path(el):
    tag = el.tag.split('}')[-1]; a = el.attrib
    if tag == 'path':
        d = a['d'].strip()
        # Кожен контур SVG починається з абсолютного переміщення; склеєні в один
        # рядок, «m» стало б відносним до кінця попереднього контуру.
        # Після «m» решта пар — відносні лінії («l»), після «M» були б абсолютні.
        if d.startswith('m'):
            pattern = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?'
            m = re.match(r'm\s*(' + pattern + r')[\s,]*(' + pattern + r')(.*)', d, re.S)
            if m:
                rest = m.group(3).strip()
                if rest and not rest[0].isalpha(): rest = 'l' + rest
                return f"M{m.group(1)} {m.group(2)}" + (' ' + rest if rest else '')
            return 'M' + d[1:]
        return d
    if tag == 'circle':
        cx, cy, r = num(a['cx']), num(a['cy']), num(a['r'])
        return f"M{fmt(cx-r)} {fmt(cy)}a{fmt(r)} {fmt(r)} 0 1 0 {fmt(2*r)} 0a{fmt(r)} {fmt(r)} 0 1 0 {fmt(-2*r)} 0z"
    if tag == 'ellipse':
        cx, cy, rx, ry = num(a['cx']), num(a['cy']), num(a['rx']), num(a['ry'])
        return f"M{fmt(cx-rx)} {fmt(cy)}a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(2*rx)} 0a{fmt(rx)} {fmt(ry)} 0 1 0 {fmt(-2*rx)} 0z"
    if tag == 'line':
        return f"M{a['x1']} {a['y1']}L{a['x2']} {a['y2']}"
    if tag in ('polyline', 'polygon'):
        pts = re.split(r'[\s,]+', a['points'].strip())
        pairs = [(pts[i], pts[i+1]) for i in range(0, len(pts) - 1, 2)]
        d = 'M' + ' L'.join(f"{x} {y}" for x, y in pairs)
        return d + ('z' if tag == 'polygon' else '')
    if tag == 'rect':
        x, y = num(a.get('x', 0)), num(a.get('y', 0)); w, h = num(a['width']), num(a['height'])
        rx = num(a.get('rx', a.get('ry', 0))); ry = num(a.get('ry', rx))
        if rx <= 0: return f"M{fmt(x)} {fmt(y)}h{fmt(w)}v{fmt(h)}h{fmt(-w)}z"
        return (f"M{fmt(x+rx)} {fmt(y)}h{fmt(w-2*rx)}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(ry)}"
                f"v{fmt(h-2*ry)}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(ry)}h{fmt(-(w-2*rx))}"
                f"a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(-rx)} {fmt(-ry)}v{fmt(-(h-2*ry))}a{fmt(rx)} {fmt(ry)} 0 0 1 {fmt(rx)} {fmt(-ry)}z")
    return None

out = ['// Згенеровано tools/icons.py з tools/icon-map.txt — не правити руками.',
       '// Значки Lucide (https://lucide.dev), ліцензія ISC: Copyright (c) Lucide Contributors 2022,',
       '// частково Cole Bemis 2013-2022 (Feather, MIT). Сітка 24×24, лінія 2, кінці округлі.',
       '', 'namespace Slovo.App;', '', 'public static partial class Icons', '{',
       '    static readonly Dictionary<string, (string Path, bool Fill)> Data = new()', '    {']
for line in open(map_file, encoding='utf-8'):
    line = line.strip()
    if not line or line.startswith('#'): continue
    parts = line.split()
    sf, lu = parts[0], parts[1]; fill = len(parts) > 2 and parts[2] == 'fill'
    # «own:ім'я» — свій значок у tools/icons-own (у Lucide немає схожого на SF Symbol).
    source = (f"{__import__('os').path.dirname(__file__)}/icons-own/{lu[4:]}.svg" if lu.startswith('own:')
              else f"{icons_dir}/{lu}.svg")
    try: root = ET.parse(source).getroot()
    except FileNotFoundError:
        print(f"// немає {lu}.svg для {sf}", file=sys.stderr); continue
    paths = [p for p in (to_path(el) for el in root.iter()) if p]
    d = ' '.join(paths).replace('"', '')
    out.append(f'        ["{sf}"] = ("{d}", {"true" if fill else "false"}),')
out += ['    };', '}', '']
print('\n'.join(out))
