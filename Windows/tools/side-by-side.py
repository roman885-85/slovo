#!/usr/bin/env python3
"""Знімок Mac і знімок Windows поруч — для звірки інтерфейсу 1:1 (вимога 1 ПАРИТЕТ.md).

side-by-side.py mac.png win.png вихід.png [--crop x,y,w,h] [--scale 0.5] [--stack v]
  Знімки Mac — Retina (удвічі більші): за замовчанням зменшуються вдвічі, щоб пункти
  збігались із пікселями Windows. --crop — шматок у пунктах (однаковий для обох).
  --stack v — один під одним (для широких вікон)."""
import sys
from PIL import Image, ImageDraw

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name); value = args[i + 1]; del args[i:i + 2]; return value
    return default
crop = opt('--crop'); scale = float(opt('--scale', '0.5')); stack = opt('--stack', 'h')
mac_path, win_path, out_path = args[:3]
mac = Image.open(mac_path).convert('RGB')
if scale != 1: mac = mac.resize((round(mac.width * scale), round(mac.height * scale)), Image.LANCZOS)
win = Image.open(win_path).convert('RGB')
if crop:
    x, y, w, h = (int(v) for v in crop.split(','))
    mac = mac.crop((x, y, x + w, y + h)); win = win.crop((x, y, x + w, y + h))
label = 22
if stack == 'v':
    W = max(mac.width, win.width); H = mac.height + win.height + 2 * label
    out = Image.new('RGB', (W, H), (255, 0, 255))
    out.paste(mac, (0, label)); out.paste(win, (0, mac.height + 2 * label))
    d = ImageDraw.Draw(out); d.text((6, 4), 'Mac 1.3.9', fill=(255, 255, 255)); d.text((6, mac.height + label + 4), 'Windows', fill=(255, 255, 255))
else:
    W = mac.width + win.width + 8; H = max(mac.height, win.height) + label
    out = Image.new('RGB', (W, H), (255, 0, 255))
    out.paste(mac, (0, label)); out.paste(win, (mac.width + 8, label))
    d = ImageDraw.Draw(out); d.text((6, 4), 'Mac 1.3.9', fill=(255, 255, 255)); d.text((mac.width + 14, 4), 'Windows', fill=(255, 255, 255))
out.save(out_path)
print(f'{out_path}: Mac {mac.width}×{mac.height}, Windows {win.width}×{win.height}')
