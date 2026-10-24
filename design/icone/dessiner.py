"""Draws the app icon « Verre » (an atom around a glass heart) as two full-bleed 1024×1024 SVG layers, light and dark.

macOS cuts its own rounded square out of each layer (AppIcon.icon, the dark one in dark mode); scripts/make_icon.swift
cuts the same square for the .icns of older systems. The drawing is made on the 824-point square of the old icon grid
(100…924), then scaled to fill the canvas.
Usage: python3 design/icone/dessiner.py <folder>   then render each SVG to a 1024-pixel PNG in AppIcon.icon/Assets.
"""
import math
import os
import sys

C = 512
RX, RY = 300, 108
ROTS = [-30, 30, 90]
ELECTRON_T = [0.0, math.pi, 0.0]   # one electron per orbit: top right, top left, bottom
FRONT = (0.0, math.pi)             # the half of an orbit that passes in front of the heart
SCALE = 1024 / 824


def rot(x, y, deg):
    a = math.radians(deg)
    return x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)


def epoint(i, t):
    x, y = rot(RX * math.cos(t), RY * math.sin(t), ROTS[i])
    return C + x, C + y


def arc(i, t0, t1, n=90):
    pts = [epoint(i, t0 + (t1 - t0) * k / n) for k in range(n + 1)]
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def ring(i):
    return f'<ellipse cx="0" cy="0" rx="{RX}" ry="{RY}" transform="translate({C} {C}) rotate({ROTS[i]})"/>'


def heart_d(cx, cy, w):
    s = w / 100
    pts = [(50, 90), (46, 86), (0, 58), (0, 28), (0, 11), (13, 0), (28, 0), (38, 0), (46, 5), (50, 14),
           (54, 5), (62, 0), (72, 0), (87, 0), (100, 11), (100, 28), (100, 58), (54, 86), (50, 90)]
    ox, oy = cx - 50 * s, cy - 47 * s
    p = [(ox + x * s, oy + y * s) for x, y in pts]
    f = lambda q: f"{q[0]:.1f},{q[1]:.1f}"
    d = f"M{f(p[0])}"
    for k in range(1, len(p), 3):
        d += f" C{f(p[k])} {f(p[k + 1])} {f(p[k + 2])}"
    return d + " Z"


HEART = heart_d(C, C, 250)

# Each look: background, ink of the orbits, what shows inside the heart, how strongly the orbits show through it,
# the glass (top color and opacity, bottom color and opacity, color of its lower rim), the electrons, the shadow.
LOOKS = {
    "clair": dict(bg=("#FAFBFC", "#D5DBE4"), ink="#2B313C", tint="#FFE9EB", refraction=0.5,
                  glass=("#FF7A80", 0.6, "#D3203F", 0.9, "#FFD3D8"), electron="#3773EB", shadow=0.24),
    "sombre": dict(bg=("#2B2F38", "#111317"), ink="#E6EAF0", tint="#3B1A24", refraction=0.35,
                   glass=("#FF7883", 0.62, "#E0284A", 0.85, "#FF9AA8"), electron="#5B8DEF", shadow=0.24),
}


def layer(look):
    top, top_op, bottom, bot_op, edge_low = look["glass"]
    rings = "".join(ring(i) for i in range(3))
    front = "".join(f'<path d="{arc(i, *FRONT)}"/>' for i in range(3))
    gaps = "".join(f'<path d="{arc(i, 0.16 * math.pi, 0.84 * math.pi)}"/>' for i in range(3))
    ink = look["ink"]
    electrons = ""
    for i, t in enumerate(ELECTRON_T):
        x, y = epoint(i, t)
        electrons += (f'<circle cx="{x:.1f}" cy="{y:.1f}" r="22" fill="{look["electron"]}"/>'
                      f'<circle cx="{x - 7:.1f}" cy="{y - 8:.1f}" r="6" fill="#fff" opacity="0.85"/>')
    defs = (f'<linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="{look["bg"][0]}"/><stop offset="1" stop-color="{look["bg"][1]}"/></linearGradient>'
            '<linearGradient id="glass" x1="0" y1="0" x2="0.35" y2="1">'
            f'<stop offset="0" stop-color="{top}" stop-opacity="{top_op}"/><stop offset="1" stop-color="{bottom}" stop-opacity="{bot_op}"/></linearGradient>'
            '<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">'
            '<stop offset="0" stop-color="#fff" stop-opacity="0.95"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/>'
            f'<stop offset="1" stop-color="{edge_low}" stop-opacity="0.75"/></linearGradient>'
            f'<clipPath id="heartClip"><path d="{HEART}"/></clipPath>'
            '<filter id="refract" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.5"/></filter>'
            '<filter id="blur4" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>'
            '<filter id="hs" x="-40%" y="-40%" width="180%" height="190%">'
            '<feGaussianBlur in="SourceAlpha" stdDeviation="12"/><feOffset dy="14"/>'
            f'<feComponentTransfer><feFuncA type="linear" slope="{look["shadow"]}"/></feComponentTransfer></filter>')
    art = (f'<path d="{HEART}" fill="#000" filter="url(#hs)"/>'
           f'<g fill="none" stroke="{ink}" stroke-width="13">{rings}</g>'
           # behind the glass: the orbits, slightly enlarged as through a lens
           f'<g clip-path="url(#heartClip)"><rect x="300" y="300" width="424" height="424" fill="{look["tint"]}"/>'
           f'<g fill="none" stroke="{ink}" stroke-width="14" opacity="{look["refraction"]}" filter="url(#refract)" '
           f'transform="translate({C} {C + 6}) scale(1.08) translate({-C} {-C})">{rings}</g></g>'
           f'<path d="{HEART}" fill="url(#glass)"/>'
           f'<path d="{HEART}" fill="none" stroke="url(#edge)" stroke-width="5"/>'
           '<path d="M418,438 C424,410 452,398 474,410" fill="none" stroke="#fff" stroke-width="12" stroke-linecap="round" opacity="0.8" filter="url(#blur4)"/>'
           '<path d="M420,436 C426,414 448,404 466,410" fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" opacity="0.95"/>'
           '<path d="M590,560 C574,590 548,612 528,626" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round" opacity="0.45"/>'
           # the front halves, each set off by a gap of background where it crosses the rest
           f'<g fill="none" stroke="url(#bg)" stroke-width="31" stroke-linecap="butt">{gaps}</g>'
           f'<g fill="none" stroke="{ink}" stroke-linecap="round" stroke-width="13">{front}</g>'
           f'{electrons}')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><defs>{defs}</defs>'
            f'<g transform="translate({C} {C}) scale({SCALE:.6f}) translate({-C} {-C})">'
            f'<rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>{art}</g></svg>')


out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name, look in LOOKS.items():
    with open(os.path.join(out, f"{name}.svg"), "w") as fh:
        fh.write(layer(look))
    print(name)
