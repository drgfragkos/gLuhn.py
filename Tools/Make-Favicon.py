#!/usr/bin/env python3
"""Make-Favicon.py: write Docs/guide/favicon/favicon.ico procedurally.

The icon is the same drawing as favicon.svg (a rounded card tile with a check
mark, teal #0E6B6B on white) rasterised at 16, 32 and 48 px as 32-bpp BMP
images with an alpha channel. Only the Python standard library is used.

Usage:  python3 Tools/Make-Favicon.py [output.ico]
"""
import math
import os
import struct
import sys

TEAL = (0x0E, 0x6B, 0x6B)
WHITE = (0xFF, 0xFF, 0xFF)
SUPERSAMPLE = 4


def sd_round_rect(px, py, cx, cy, half_w, half_h, radius):
    """Signed distance from (px,py) to a rounded rectangle centred at (cx,cy)."""
    qx = abs(px - cx) - (half_w - radius)
    qy = abs(py - cy) - (half_h - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - radius


def sd_segment(px, py, ax, ay, bx, by):
    """Distance from (px,py) to the segment A-B."""
    abx, aby = bx - ax, by - ay
    apx, apy = px - ax, py - ay
    denom = abx * abx + aby * aby
    t = 0.0 if denom == 0 else max(0.0, min(1.0, (apx * abx + apy * aby) / denom))
    return math.hypot(apx - t * abx, apy - t * aby)


def sample(u, v):
    """Colour (r,g,b,a) at a point in the 64x64 design space (same as the SVG)."""
    # Card: rect x=4 y=4 w=56 h=56 rx=12, stroke 5 (centred on the edge).
    d = sd_round_rect(u, v, 32.0, 32.0, 28.0, 28.0, 12.0)
    if d > 2.5:
        return (0, 0, 0, 0)
    # Check mark: M19 33 L28 42 L46 23, stroke 7, round caps/joins.
    dc = min(sd_segment(u, v, 19.0, 33.0, 28.0, 42.0),
             sd_segment(u, v, 28.0, 42.0, 46.0, 23.0))
    if dc <= 3.5:
        return TEAL + (255,)
    if abs(d) <= 2.5:
        return TEAL + (255,)
    return WHITE + (255,)


def render(size):
    """Return rows (top to bottom) of (b,g,r,a) tuples for a size x size image."""
    rows = []
    scale = 64.0 / size
    n = SUPERSAMPLE
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(n):
                for sx in range(n):
                    u = (x + (sx + 0.5) / n) * scale
                    v = (y + (sy + 0.5) / n) * scale
                    r, g, b, a = sample(u, v)
                    w = a / 255.0
                    acc[0] += r * w
                    acc[1] += g * w
                    acc[2] += b * w
                    acc[3] += w
            cov = acc[3] / (n * n)
            if acc[3] > 0:
                r = int(round(acc[0] / acc[3]))
                g = int(round(acc[1] / acc[3]))
                b = int(round(acc[2] / acc[3]))
            else:
                r = g = b = 0
            row.append((b, g, r, int(round(cov * 255))))
        rows.append(row)
    return rows


def bmp_image(size):
    rows = render(size)
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0,
                         size * size * 4, 0, 0, 0, 0)
    pixels = bytearray()
    for row in reversed(rows):          # BMP rows are stored bottom-up
        for b, g, r, a in row:
            pixels += bytes((b, g, r, a))
    mask_stride = ((size + 31) // 32) * 4
    mask = bytes(mask_stride * size)    # AND mask: all opaque (alpha rules)
    return header + bytes(pixels) + mask


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, '..', 'Docs', 'guide', 'favicon', 'favicon.ico')
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.normpath(default)
    sizes = (16, 32, 48)
    images = [bmp_image(s) for s in sizes]
    offset = 6 + 16 * len(sizes)
    data = bytearray(struct.pack('<HHH', 0, 1, len(sizes)))
    for s, img in zip(sizes, images):
        data += struct.pack('<BBBBHHII', s, s, 0, 0, 1, 32, len(img), offset)
        offset += len(img)
    for img in images:
        data += img
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'wb') as fh:
        fh.write(data)
    print('wrote %s (%d bytes, sizes %s)' % (out, len(data), ', '.join(str(s) for s in sizes)))


if __name__ == '__main__':
    main()
