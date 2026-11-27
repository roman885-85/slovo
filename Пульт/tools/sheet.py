#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Стенд: аркуш знімків для власника — кілька знімків екрана в ряд, під кожним підпис.

    tools/sheet.py <вихід.jpg> "<заголовок>" <знімок.png> "<підпис>" [<знімок.png> "<підпис>" …]

Знімки зводяться до однакової висоти; аркуш — темний, як інтерфейс пульта.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"


def font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def wrap(draw, text, face, width):
    lines, line = [], ""
    for word in text.split():
        probe = (line + " " + word).strip()
        if draw.textlength(probe, font=face) <= width:
            line = probe
        else:
            if line:
                lines.append(line)
            line = word
    if line:
        lines.append(line)
    return lines


def main():
    out, title, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    pairs = [(rest[i], rest[i + 1]) for i in range(0, len(rest) - 1, 2)]
    height = 900
    shots = []
    for path, caption in pairs:
        image = Image.open(path).convert("RGB")
        width = int(image.width * height / image.height)
        shots.append((image.resize((width, height), Image.LANCZOS), caption))
    gap, margin, head, foot = 28, 36, 90, 130
    total = margin * 2 + sum(s.width for s, _ in shots) + gap * (len(shots) - 1)
    sheet = Image.new("RGB", (total, margin + head + height + foot), (11, 14, 19))
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, margin), title, fill=(243, 245, 248), font=font(38))
    x = margin
    small = font(22)
    for shot, caption in shots:
        sheet.paste(shot, (x, margin + head))
        y = margin + head + height + 14
        for line in wrap(draw, caption, small, shot.width)[:4]:
            draw.text((x, y), line, fill=(147, 160, 180), font=small)
            y += 28
        x += shot.width + gap
    sheet.save(out, "JPEG", quality=88)
    print(out, sheet.size)


if __name__ == "__main__":
    main()
