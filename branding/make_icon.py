#!/usr/bin/env python3
"""Generate the Blockle Hero app icon: the Blockle "B" in steel, on a riveted plate.

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

WHY THIS ONE IS GREY, WHEN THE BRAND MARK IS GREEN
--------------------------------------------------
Blockle Hero sits on a home screen beside the wallet and Blockle Protect, which
both use the green mark.  Shared silhouette, different material: the SHAPE
carries the brand, and the steel-on-riveted-plate treatment says "this is the
game" at a glance and suits an action RPG about armour and weapons.

The metal is sold by two things, neither of which is "a shinier gradient" -- a
smooth two-stop ramp reads as plastic however bright its top is:

  * a HARD VALUE REVERSAL at the horizon, where the surface stops reflecting
    sky and starts reflecting ground.  Hence the abrupt stop pair at 0.49/0.51;
    across a ~700 px mark that is a crisp line, and that line is the effect.
  * an inner BEVEL, drawn as a gradient-filled stroke clipped to the mark, so
    every top-facing edge is lit and every bottom-facing one is dark from a
    single path -- a real bevel rather than a drop shadow imitating one.

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
MARK_HEIGHT_FRAC = 0.62     # mark height / icon edge; leaves room for the plate

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
WALL_POLY = [(XA, PTR[1] - (XD - XA) / R3), PTR, PBR, PBL]

# ----------------------------------------------------------------- palette ---
# Steel for the mark, gunmetal for the plate. (offset, colour) pairs.

# EVERY STOP HERE STAYS WELL ABOVE PLATE VALUE. The first cut let the mark's
# base fall to #2A2F35 against a #3C4249 plate, so at 60 px the bottom of the B
# simply dissolved into the background and the icon read as a grey blob. The
# horizon still reverses — it just reverses between two LIGHT values, which is
# what polished steel does anyway; only rough iron goes black in shadow.
MARK_STOPS = [
    (0.00, "#F8FAFC"),   # specular: the sky itself
    (0.15, "#D6DEE6"),   # lit face
    (0.42, "#8E99A4"),   # the face turning away
    (0.49, "#5A646E"),   # |
    (0.51, "#909AA4"),   # | THE HORIZON -- abrupt, on purpose
    (0.74, "#C2CBD4"),   # ground bounce, brightest just below the horizon
    (1.00, "#8893A0"),   # settles, but never near the plate
]

# The cube's inner wall: same steel in shade, with its own small horizon so it
# does not flatten into a silhouette. Light enough to still read as a surface.
WALL_STOPS = [
    (0.00, "#78838E"),
    (0.46, "#464F58"),
    (0.52, "#646E78"),
    (1.00, "#39424A"),
]

# The plate is deliberately much darker than the mark — the separation between
# the two is what carries the icon at small sizes.
PLATE_EDGE = "#0B0D10"     # vignetted border of the plate
PLATE_MID = "#232930"      # lit centre of the plate
PLATE_SEAM = "#070909"     # the inset groove line

RIVET_LIGHT = "#A9B3BD"
RIVET_DARK = "#454C54"
RIVET_SPEC = "#E2E9EF"
RIVET_SEAT = "#0E1114"

RIM_LIGHT = "#FBFDFF"
RIM_DARK = "#1A1E22"
RIM_W = 0.055               # bevel width, as a fraction of mark height
SHEEN = 0.06                # peak opacity; above ~0.1 it reads as fog, not shine

# Rivets: the four corners plus the midpoint of each side. Eight is enough to
# read as "plate" and few enough that at 60 px they stay as distinct dots
# instead of smearing into a grey border.
RIVET_INSET = 0.085         # fraction of the icon edge
RIVET_R = 0.042             # fraction of the icon edge; smaller vanishes at 60 px


def _rivet_centres() -> list[tuple[float, float]]:
    lo = SIZE * RIVET_INSET
    hi = SIZE - lo
    mid = SIZE / 2.0
    return [(lo, lo), (hi, lo), (lo, hi), (hi, hi),
            (mid, lo), (mid, hi), (lo, mid), (hi, mid)]


def _stops(stops) -> str:
    return "".join(
        f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops
    )


def build_svg() -> str:
    scale = SIZE * MARK_HEIGHT_FRAC / (2 * H)
    cx = cy = SIZE / 2.0

    def pt(p):
        return f"{cx + p[0] * scale:.2f},{cy + p[1] * scale:.2f}"

    def path(pts):
        return "M " + " L ".join(pt(q) for q in pts) + " Z"

    top = cy - H * scale
    bot = cy + H * scale
    mark_path = f"{path(OUTER)} {path(COUNTER)}"
    rim_w = 2 * H * scale * RIM_W

    rivets = "".join(
        f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{SIZE * RIVET_R:.1f}" fill="url(#seat)"/>'
        f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{SIZE * RIVET_R * 0.82:.1f}" fill="url(#rivet)"/>'
        for x, y in _rivet_centres()
    )

    # Brushed-metal streaks: a few dozen faint horizontal lines. Procedural,
    # deterministic, and enough to stop the plate reading as flat colour.
    streaks = "".join(
        f'<rect x="0" y="{i * SIZE / 96.0:.1f}" width="{SIZE}" height="1.6" '
        f'fill="#FFFFFF" opacity="{0.012 + 0.010 * ((i * 7) % 5) / 4.0:.3f}"/>'
        for i in range(96)
    )

    seam = SIZE * 0.046

    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
  <title>Blockle Hero</title>
  <defs>
    <radialGradient id="plate" cx="50%" cy="34%" r="78%">
      <stop offset="0" stop-color="{PLATE_MID}"/>
      <stop offset="1" stop-color="{PLATE_EDGE}"/>
    </radialGradient>
    <linearGradient id="mark" x1="0" y1="{top:.1f}" x2="0" y2="{bot:.1f}" gradientUnits="userSpaceOnUse">
      {_stops(MARK_STOPS)}
    </linearGradient>
    <linearGradient id="wall" x1="0" y1="{top:.1f}" x2="0" y2="{bot:.1f}" gradientUnits="userSpaceOnUse">
      {_stops(WALL_STOPS)}
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="{top:.1f}" x2="0" y2="{bot:.1f}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="{RIM_LIGHT}" stop-opacity="0.95"/>
      <stop offset="0.45" stop-color="{RIM_LIGHT}" stop-opacity="0"/>
      <stop offset="0.55" stop-color="{RIM_DARK}" stop-opacity="0"/>
      <stop offset="1" stop-color="{RIM_DARK}" stop-opacity="0.9"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="{SIZE}" y2="{SIZE}" gradientUnits="userSpaceOnUse">
      <stop offset="0.18" stop-color="#FFFFFF" stop-opacity="0"/>
      <stop offset="0.34" stop-color="#FFFFFF" stop-opacity="{SHEEN}"/>
      <stop offset="0.46" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="rivet" cx="34%" cy="30%" r="78%">
      <stop offset="0" stop-color="{RIVET_SPEC}"/>
      <stop offset="0.45" stop-color="{RIVET_LIGHT}"/>
      <stop offset="1" stop-color="{RIVET_DARK}"/>
    </radialGradient>
    <radialGradient id="seat" cx="50%" cy="50%" r="50%">
      <stop offset="0.6" stop-color="{RIVET_SEAT}"/>
      <stop offset="1" stop-color="{RIVET_SEAT}" stop-opacity="0.35"/>
    </radialGradient>
    <clipPath id="markClip">
      <path fill-rule="evenodd" d="{mark_path}"/>
    </clipPath>
  </defs>

  <rect width="{SIZE}" height="{SIZE}" fill="{PLATE_EDGE}"/>
  <rect width="{SIZE}" height="{SIZE}" fill="url(#plate)"/>
  {streaks}

  <!-- inset groove: frames the plate and gives the rivets something to sit on -->
  <rect x="{seam:.1f}" y="{seam:.1f}" width="{SIZE - 2 * seam:.1f}" height="{SIZE - 2 * seam:.1f}"
        fill="none" stroke="{PLATE_SEAM}" stroke-width="{SIZE * 0.009:.1f}" opacity="0.85"/>
  {rivets}

  <!-- the mark: base metal, shaded wall, then the bevel and sheen clipped to it -->
  <path fill-rule="evenodd" fill="url(#mark)" d="{mark_path}"/>
  <path fill="url(#wall)" d="{path(WALL_POLY)}"/>
  <g clip-path="url(#markClip)">
    <path fill="none" stroke="url(#rim)" stroke-width="{rim_w:.1f}" d="{mark_path}"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#sheen)"/>
  </g>
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
        flat = Image.new("RGB", im.size, PLATE_EDGE)
        flat.paste(im, mask=im.split()[-1] if "A" in im.mode else None)
        im = flat
    im.save(png_path, format="PNG", optimize=True)

    # Also write a 60 px copy — the size the icon is actually judged at on a
    # home screen. Every version of this has to be checked there, not at 1024.
    im.resize((60, 60), Image.LANCZOS).save(HERE / "preview-60.png")

    print(f"wrote {svg_path}")
    print(f"wrote {png_path}  {im.size} {im.mode}")
    print(f"wrote {HERE / 'preview-60.png'}  (60x60 legibility check)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
