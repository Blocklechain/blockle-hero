#!/usr/bin/env python3
"""Generate the Trail of Heroes app icon: the Blockle "B" mark on brand dark.

The mark is NOT invented here.  Its geometry was reverse-engineered by fitting
straight lines to the shipped Blockle brand assets and is reproduced
parametrically below:

    /Volumes/ExtremePro/blockle/src/assets/logo-512.png              mark 142 px wide
    /Volumes/ExtremePro/blockle/blocklings-web/public/icon-512.png   mark 268 px wide

Every landmark below was measured on the larger of the two and cross-checked
against the smaller; the two agree to within ~1% of the mark half-width.

CONSTRUCTION
------------
A pointy-top hexagon -- the silhouette of a cube in isometric projection --
drawn as a ribbon, with three features that turn it into a B:

  * a V-notch bitten out of the right side, which splits the two bowls;
  * a "waist" band running down-left from the notch, the cube's top-face seam,
    which terminates in mid-air at XA instead of reaching the stem (the gap it
    leaves is the thin slit beside the stem in the real mark);
  * a darker parallelogram hanging under the waist's left end: the cube's
    inner vertical wall, which is what makes the mark read as 3D.

All diagonals run at the isometric 30 degrees (dx/dy = sqrt(3)); the sources
measure 1.73-1.85 and are slightly sheared by their renderer.

Units: half-width a = 1, origin at the hexagon centre, +y downward.

    a   half width            1
    B_  half vertical side    0.792    measured 0.825 / 0.794
    c   cap height            1/sqrt(3)
    W   ribbon width          0.40     measured 0.410 (stem), 0.381 (diagonal)
    TV  inner-edge y offset   0.41     measured 0.40-0.44
    WV  waist y thickness     0.522    measured 70/134 -- the waist is
                                       deliberately fatter than the ribbon
    XN  notch apex x          0.62     measured 0.627
    XA  waist left terminus  -0.455    measured -0.455 / -0.448
    XD  cube front corner x  -0.067    measured -0.067 / -0.056
    XK  lower-bowl apex x     0.310    measured 0.310

Palette, sampled from logo-512.png:

    mark top        #71F98C      mark bottom     #00D08C
    inner wall      #0E8A5F  ->  #03694A         (measured #036849 mid-height)
    background      #0B0B14      (--bg on blockle.org)

Outputs:

    branding/blockle-b-icon.svg   vector source
    icon.png                      1024x1024 RGB, no alpha, square corners

`icon.png` is referenced by project.godot as application/config/icon, which is
what the Godot iOS exporter falls back to for every icon slot it needs
(icons/app_store_1024x1024, icons/iphone_180x180, icons/iphone_120x120).

Usage:  python3 branding/make_icon.py
"""

from __future__ import annotations

import math
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

SIZE = 1024                 # icon edge, px
MARK_HEIGHT_FRAC = 0.70     # mark height / icon edge; matches sibling Blockle icons

# ---------------------------------------------------------------- geometry ---
R3 = math.sqrt(3.0)

A = 1.0            # half width
B_ = 0.792         # half height of the vertical sides
C = 1.0 / R3       # cap: how far the apex sits above a side vertex
H = B_ + C         # half height of the whole mark            1.36935

W = 0.40           # ribbon width
IX = A - W         # x of the ribbon's inner vertical edges    0.60
TV = 0.41          # vertical offset from an outer diagonal to its inner one
WV = 0.522         # vertical thickness of the waist band

XN = 0.62          # notch apex x
XA = -0.455        # x where the waist band stops and the wall drops
XD = -0.067        # x of the cube's front vertical edge
XK = 0.310         # x of the lower bowl's top apex

# --- outer hexagon ---
T = (0.0, -H)
UR = (A, -B_)
LR = (A, B_)
BM = (0.0, H)
LL = (-A, B_)
UL = (-A, -B_)


def _outer_upper_y(x: float) -> float:
    """y of the outer upper diagonals at |x|."""
    return -B_ - (A - abs(x)) / R3


# --- inner hexagon: the outer diagonals dropped by TV, verticals pulled in by W
IUR = (IX, _outer_upper_y(IX) + TV)
IUL = (-IX, IUR[1])
ILR = (IX, -IUR[1])
ILL = (-IX, -IUR[1])
IT = (0.0, -H + TV)
IB = (0.0, H - TV)


# --- waist band: a 30-degree ribbon whose top edge leaves the inner hexagon
#     exactly at IUR, so the band is flush with the ribbon it grows out of.
def waist_top(x: float) -> float:
    return IUR[1] - (x - IX) / R3


def waist_bot(x: float) -> float:
    return waist_top(x) + WV


def _down_right(p, x):
    """Follow a +30-degree line from p out to x."""
    return (x, p[1] + (x - p[0]) / R3)


NA = (XN, waist_bot(XN))                    # notch apex, sits on the waist's underside
N1 = (A, NA[1] - (A - XN) / R3)             # notch mouth, upper
N2 = (A, NA[1] + (A - XN) / R3)             # notch mouth, lower

PA = (XA, waist_top(XA))                    # waist terminus, top
PBL = (XA, waist_bot(XA))                   # waist terminus, bottom
PTR = (XD, waist_bot(XD))                   # front corner, top
PBR = _down_right(PBL, XD)                  # front corner, bottom

K = (XK, waist_bot(XK))                     # lower bowl's top apex
K2 = _down_right(K, IX)                     # where the lower bowl meets the ribbon

OUTER = [T, UR, N1, NA, N2, LR, BM, LL, UL]

# One counter, pinched to a point at the notch apex -- that pinch is how the
# upper bowl breathes out through the right-hand side in the real mark.
COUNTER = [IB, ILR, K2, K, PTR, PBR, PBL, PA, IUR, IT, IUL, ILL]

# The shaded wall: the parallelogram under the waist's left end.  Its top edge
# starts one ribbon-depth below PA, which leaves the small lit wedge the brand
# mark has at the top of the cube's front corner.
WALL = [(XA, PTR[1] - (XD - XA) / R3), PTR, PBR, PBL]

# ----------------------------------------------------------------- palette ---
BG = "#0B0B14"
BG_LIFT = "#16162A"
MARK_TOP = "#71F98C"
MARK_BOT = "#00D08C"
WALL_TOP = "#0E8A5F"
WALL_BOT = "#03694A"


def build_svg() -> str:
    scale = SIZE * MARK_HEIGHT_FRAC / (2 * H)
    cx = cy = SIZE / 2.0

    def pt(p):
        return f"{cx + p[0] * scale:.2f},{cy + p[1] * scale:.2f}"

    def path(pts):
        return "M " + " L ".join(pt(q) for q in pts) + " Z"

    top = cy - H * scale
    bot = cy + H * scale

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <title>Trail of Heroes</title>
  <defs>
    <radialGradient id="bg" cx="50%" cy="36%" r="80%">
      <stop offset="0" stop-color="{BG_LIFT}"/>
      <stop offset="1" stop-color="{BG}"/>
    </radialGradient>
    <linearGradient id="mark" x1="0" y1="{top:.1f}" x2="0" y2="{bot:.1f}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{MARK_TOP}"/>
      <stop offset="1" stop-color="{MARK_BOT}"/>
    </linearGradient>
    <linearGradient id="wall" x1="0" y1="{top:.1f}" x2="0" y2="{bot:.1f}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{WALL_TOP}"/>
      <stop offset="1" stop-color="{WALL_BOT}"/>
    </linearGradient>
  </defs>

  <rect width="{SIZE}" height="{SIZE}" fill="{BG}"/>
  <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>

  <path fill-rule="evenodd" fill="url(#mark)" d="{path(OUTER)} {path(COUNTER)}"/>
  <path fill="url(#wall)" d="{path(WALL)}"/>
</svg>
"""


def main() -> int:
    svg_path = HERE / "blockle-b-icon.svg"
    png_path = ROOT / "icon.png"

    svg = build_svg()
    svg_path.write_text(svg, encoding="utf-8")

    try:
        import cairosvg
    except ImportError:
        print("cairosvg is required: pip install cairosvg", file=sys.stderr)
        return 1

    cairosvg.svg2png(bytestring=svg.encode("utf-8"), write_to=str(png_path),
                     output_width=SIZE, output_height=SIZE)

    # iOS app icons must not carry an alpha channel.
    from PIL import Image
    im = Image.open(png_path)
    if im.mode != "RGB":
        flat = Image.new("RGB", im.size, BG)
        flat.paste(im, mask=im.split()[-1] if "A" in im.mode else None)
        im = flat
    im.save(png_path, format="PNG", optimize=True)

    print(f"wrote {svg_path}")
    print(f"wrote {png_path}  {im.size} {im.mode}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
