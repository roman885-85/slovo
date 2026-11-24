#!/usr/bin/python3
"""Кольори пікселів зі знімка PNG без сторонніх бібліотек.
pixels.py файл.png x,y [x,y …]  — координати в пунктах (знімок Mac — удвічі більший)
Ключ --px: координати в пікселях."""
import sys, zlib, struct

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w, h, ct, bd = 8, b'', 0, 0, 0, 0
    while pos < len(data):
        ln, = struct.unpack('>I', data[pos:pos+4]); typ = data[pos+4:pos+8]; body = data[pos+8:pos+8+ln]
        if typ == b'IHDR': w, h, bd, ct = struct.unpack('>IIBB', body[:10])
        elif typ == b'IDAT': idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    bpp = {6: 4, 2: 3, 0: 1, 4: 2}[ct] * (bd // 8)
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for y in range(h):
        f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, bpp, rows

args = sys.argv[1:]
px = '--px' in args; args = [a for a in args if a != '--px']
w, h, bpp, rows = read_png(args[0])
scale = 1 if px else 2
for spec in args[1:]:
    x, y = (float(v) for v in spec.split(','))
    X, Y = int(x * scale), int(y * scale)
    p = rows[Y][X*bpp:(X+1)*bpp]
    print(f"{spec:>12}  #{p[0]:02X}{p[1]:02X}{p[2]:02X}" + (f" a{p[3]}" if bpp == 4 else ""))
