#!/usr/bin/env python3
"""Blockle Hero — concept art for the 100-map campaign, generated on the Mac.

Runs SDXL-Turbo locally on Apple Silicon (MPS). No API, no cost per image, and
the art can be regenerated from scratch at any time, which is the same property
every other asset in this project has: the world, the sound and the app icon
are all generated rather than stored.

NOTHING HERE IS HAND-WRITTEN PER MAP, and nothing here re-derives the campaign.
`tools/dump_plates.gd` runs inside Godot and answers "which plates does the
campaign need" using the same Campaign/Biome/StageArt code the game reads:

  * the plate list is Campaign.biome_at x Campaign.dread_band (StageArt.BANDS),
    so 100 maps resolve onto 27 plates and a plate is only generated if a map
    can actually ask for it;
  * each plate's SUBJECT is the biome's own `mood` string out of Biome.gd
    ("drowned moorland, visibility nil"), written for the renderer's palette;
  * each plate's DREAD comes back measured — the real Campaign.dread range of
    the maps that share the plate — and picks a clause off one ladder, so late
    maps in a biome look genuinely more hostile than early ones instead of
    "scary" being tuned here by feel.

Change a mood in Biome.gd, or the act windows in Campaign.gd, and the art set
follows. That is why this does not parse the campaign itself in Python.

Deterministic: the seed is derived from the plate key, so re-running reproduces
the same images and a regenerated set does not churn git.

  python3 tools/gen_concept_art.py                    # everything missing
  python3 tools/gen_concept_art.py --force            # regenerate all of it
  python3 tools/gen_concept_art.py --only mistmoor    # one biome, its bands
  python3 tools/gen_concept_art.py --menus            # just the menu plates
  python3 tools/gen_concept_art.py --steps 4          # slower, usually better
  # off-grid, for eyeballing the dread ladder end to end (not shipped):
  python3 tools/gen_concept_art.py --only boneyard --band 0,4 --dest /tmp/look

Output: assets/art/stages/<biome>_d<band>.jpg, assets/art/menu/<name>.jpg
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import zlib
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")

ROOT = Path(__file__).resolve().parents[1]
STAGE_ART_GD = ROOT / "scripts" / "game" / "StageArt.gd"
DUMP_SCRIPT = "tools/dump_plates.gd"
OUT_STAGES = ROOT / "assets" / "art" / "stages"
OUT_MENU = ROOT / "assets" / "art" / "menu"

GODOT = os.environ.get(
    "GODOT", "/Applications/Godot.app/Contents/MacOS/Godot")

# SDXL-Turbo is already cached locally (~39 GB). Do NOT switch this to a model
# that needs downloading without checking free disk first — this machine sits
# at ~97% full on the boot volume (where the HF cache lives) and a failed
# half-download of SDXL base will wedge it.
MODEL = "stabilityai/sdxl-turbo"

# Refuse to start a batch without this much room on BOTH the output volume and
# the model cache volume. A plate is ~130 KB but torch will happily spill GBs
# of temporaries, and a full disk corrupts the HF cache rather than erroring.
MIN_FREE_MB = 2048

# 16:9-ish. The game runs 2532x1170 (~2.16:1) so plates are cropped at display
# time rather than generated ultra-wide; SDXL-Turbo degrades badly past about
# 2:1 and starts duplicating subjects across the frame.
W, H = 1024, 576
# Generated taller than it ships, then cropped from the top. SDXL-Turbo is a
# guidance-free model, so the negative prompt is ignored and it reliably
# scrawls an illegible signature-like smudge into a bottom corner. Cropping the
# bottom band removes it without touching the composition, which is cheaper
# than inpainting a hundred plates.
GEN_H = 640

# The house style. Keep it in ONE place: every plate sharing a style string is
# what makes thirty-two separately-generated images look like one art
# department. "no text" matters — diffusion models love to scrawl illegible
# runes on fantasy signage and it reads as a glitch behind real UI type.
#
# IT IS ALSO A TOKEN BUDGET, and that budget is the reason this is terser than
# the usual pile of artstation keywords. CLIP truncates at 77 tokens IN SILENCE
# (diffusers only prints a warning naming the dropped tail), and the previous
# style string was 66 tokens on its own: adding the dread clause below pushed
# the end of the style off the cliff, so the plates were generated with "no
# text, no watermark" removed — the one part that must not be dropped. Measured
# with the model's own tokenizer: style 40 + the longest mood 15 + the longest
# dread rung 20 = 75, which is every token the two encoders will read. The
# check in main() re-measures and refuses to generate rather than let a future
# edit go quietly over.
STYLE = (
    "epic dark-fantasy concept art, painterly matte painting, "
    "cinematic light, atmospheric haze, weathered stone, muted palette "
    "with one warm accent, wide establishing shot, no text, no watermark"
)

NEGATIVE = (
    "text, letters, watermark, signature, ui, hud, frame, border, "
    "blurry, lowres, oversaturated, cartoon, chibi, duplicated horizon"
)

# THE DREAD LADDER — one rung per StageArt.BANDS band, in order.
#
# This is the prompt half of the roadmap's "dread curve", and it moves the same
# three dials the renderer's palette shift moves (lower key, colder ambient,
# thicker fog) plus what is actually ON the ground, because a 1024-pixel plate
# cannot be made frightening by exposure alone. The index is the band the
# campaign reports — NOT a number chosen here — so map 90's plate cannot
# accidentally be lit like map 10's.
#
# The length is asserted against StageArt.BANDS at startup: changing the band
# count there fails loudly here instead of silently reusing rung 0.
# Each rung is <= 20 tokens; see the STYLE comment for why that is a hard cap.
DREAD_LADDER = [
    # band 0 — maps 1-20. Still somebody's country.
    "peaceful and lived-in, clear air, soft golden daylight, a waymarked road",
    # band 1 — the first ruins, light going flat.
    "emptying and unquiet, flat overcast light, cold wind, abandoned watchtowers",
    # band 2 — openly hostile.
    "war-torn, storm-dark sky, thick fog, siege ruins, scorched ground",
    # band 3 — nightmarish.
    "desecrated, very dark, blood-red light, choking fog, bone fields, embers",
    # band 4 — the end of the world.
    "apocalyptic, near-black torn sky, molten underlight, falling ash, broken land",
]

# Menu plates. These are not biomes, so they are the one hand-written set. The
# names must match StageArt.MENUS — checked at startup.
MENUS = {
    "title": "a lone armoured champion silhouetted on a cliff before a vast "
             "ruined fortress, storm light breaking through cloud",
    # NOT "a map": asking for a map of a continent gets a recognisable Earth
    # covered in scrawled pseudo-lettering, because SDXL-Turbo runs at guidance
    # 0 and reads "no text" as a suggestion. A lantern-lit stone RELIEF MODEL
    # with carved markers is the same information with nothing to label.
    "stage_select": "a dark war room, lantern-lit carved stone relief model "
                    "of a shattered mountainous continent, iron markers, "
                    "deep shadow",
    "roster": "a long hall of empty suits of ornate armour on plinths, "
              "shafts of light from high windows, dust in the air",
    "stash": "a vaulted treasury of weapons and relics on racks, "
             "warm forge light, deep shadow",
    "defeat": "a cracked battlefield at dusk, broken banners in the mud, "
              "cold blue light, rain",
}

# THE PLATES MUST NOT BLOW UP THE PCK. Godot imports a .jpg as a LOSSLESS
# CompressedTexture2D by default: measured on this project, a 136 KB plate
# became a 571 KB .ctex, so 32 plates would have cost ~18 MB inside an already
# 586 MiB bundle for pictures nobody can see the artefacts in behind UI. Lossy
# (WebP, quality 0.8) brings the same plate to 76 KB — a 7.5x saving for a
# full-screen background that is composited under text and a vignette.
#
# Written as a params-only .import next to the file; Godot fills in the [remap]
# and [deps] sections on the next --import and keeps these params. mipmaps off
# (these are drawn at ~1:1, never minified) and detect_3d/compress_to=0 so that
# accidentally handing a plate to a 3D material cannot silently re-import the
# whole set to VRAM compression.
IMPORT_STUB = """[params]

compress/mode=1
compress/high_quality=false
compress/lossy_quality=0.8
mipmaps/generate=false
detect_3d/compress_to=0
"""


def bands() -> int:
    """StageArt.BANDS — parsed, never guessed. See the module docstring."""
    m = re.search(r"^const BANDS:\s*int\s*=\s*(\d+)",
                  STAGE_ART_GD.read_text(encoding="utf-8"), re.MULTILINE)
    if not m:
        raise SystemExit("cannot find 'const BANDS' in scripts/game/StageArt.gd")
    return int(m.group(1))


def plates_from_godot() -> list[dict]:
    """Ask the game which plates it needs (tools/dump_plates.gd)."""
    if not Path(GODOT).exists():
        raise SystemExit(
            f"Godot not found at {GODOT}; set GODOT=/path/to/Godot. The plate "
            "list comes from Campaign/StageArt, so there is no offline guess.")
    proc = subprocess.run(
        [GODOT, "--headless", "--path", str(ROOT), "--script", DUMP_SCRIPT],
        capture_output=True, text=True, check=False)
    for line in proc.stdout.splitlines():
        if line.startswith("PLATES_JSON "):
            return json.loads(line[len("PLATES_JSON "):])
    raise SystemExit("dump_plates.gd printed no PLATES_JSON line:\n"
                     + proc.stdout[-2000:] + proc.stderr[-2000:])


def seed_for(key: str) -> int:
    """Stable across runs and across machines — Python's hash() is salted."""
    return zlib.crc32(key.encode()) & 0x7FFFFFFF


def free_mb(path: Path) -> int:
    probe = path
    while not probe.exists():
        probe = probe.parent
    return shutil.disk_usage(probe).free // (1024 * 1024)


def write_import(path: Path) -> None:
    """Keep the plate lossy in the PCK. See IMPORT_STUB."""
    imp = Path(str(path) + ".import")
    if not imp.exists():
        imp.write_text(IMPORT_STUB, encoding="utf-8")
        return
    # Godot already imported it: patch the three params that matter and leave
    # its uid/remap alone, or the whole set re-imports under new ids.
    txt = imp.read_text(encoding="utf-8")
    for key, want in (("compress/mode", "1"),
                      ("compress/lossy_quality", "0.8"),
                      ("detect_3d/compress_to", "0")):
        txt = re.sub(rf"^{re.escape(key)}=.*$", f"{key}={want}",
                     txt, flags=re.MULTILINE)
    imp.write_text(txt, encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=MODEL)
    ap.add_argument("--steps", type=int, default=3,
                    help="SDXL-Turbo needs 1-4; more is slower, not always better")
    ap.add_argument("--only", default="", help="one biome id")
    ap.add_argument("--band", default="",
                    help="comma list of dread bands, overriding the campaign's "
                         "own pairing; for inspecting the ladder, not shipping")
    ap.add_argument("--menus", action="store_true", help="menu plates only")
    ap.add_argument("--stages", action="store_true", help="stage plates only")
    ap.add_argument("--dest", default="",
                    help="write somewhere other than assets/art (no .import)")
    ap.add_argument("--force", action="store_true",
                    help="regenerate plates that already exist")
    args = ap.parse_args()

    nbands = bands()
    if len(DREAD_LADDER) != nbands:
        raise SystemExit(
            f"StageArt.BANDS is {nbands} but DREAD_LADDER has "
            f"{len(DREAD_LADDER)} rungs — write the missing clause(s) rather "
            "than letting a band silently reuse rung 0.")

    dump = plates_from_godot()
    stages = [p for p in dump if not p.get("menu")]
    menu_names = [p["key"] for p in dump if p.get("menu")]
    if sorted(menu_names) != sorted(MENUS):
        raise SystemExit(f"StageArt.MENUS is {menu_names} but this script has "
                         f"{sorted(MENUS)} — they must match")

    # The ladder rung is the band the campaign reported. The measured dread
    # range only goes into the log, so a run shows which maps each plate serves.
    jobs: list[tuple[Path, str, str, str]] = []  # path, key, prompt, note
    if not args.menus:
        chosen = stages
        if args.only:
            chosen = [p for p in chosen if p["biome"] == args.only]
            if not chosen and not args.band:
                ids = sorted({p["biome"] for p in stages})
                raise SystemExit(f"no campaign plate for biome '{args.only}'; "
                                 f"the campaign visits {ids}")
        if args.band:
            # Off-grid: take the first plate of this biome for its mood, then
            # re-key it onto the requested bands.
            want = [int(b) for b in args.band.split(",") if b.strip() != ""]
            src = chosen[0] if chosen else None
            if src is None:
                raise SystemExit(f"biome '{args.only}' is not in the campaign, "
                                 "so there is no mood to borrow")
            chosen = []
            for b in want:
                if b < 0 or b >= nbands:
                    raise SystemExit(f"band {b} is outside 0..{nbands - 1}")
                p = dict(src)
                p["band"] = b
                p["key"] = "%s_d%d" % (p["biome"], b)
                p["maps"] = 0
                chosen.append(p)
        for p in chosen:
            subject = f"{p['mood']}, {p['name']}"
            prompt = f"{subject}, {DREAD_LADDER[int(p['band'])]}, {STYLE}"
            note = ("%2d maps, dread %.2f-%.2f" % (
                int(p["maps"]), float(p["dread_lo"]), float(p["dread_hi"]))
                if int(p["maps"]) else "off-grid sample")
            jobs.append((OUT_STAGES / f"{p['key']}.jpg", p["key"], prompt, note))
    if not args.stages and (not args.only or args.menus):
        chosen_menus = MENUS
        if args.only:
            # --menus --only stash: re-roll one plate without burning the other
            # four, which is how the menu prompts get iterated on.
            if args.only not in MENUS:
                raise SystemExit(f"no menu plate '{args.only}'; "
                                 f"have {sorted(MENUS)}")
            chosen_menus = {args.only: MENUS[args.only]}
        for name, subject in chosen_menus.items():
            jobs.append((OUT_MENU / f"{name}.jpg", f"menu_{name}",
                         f"{subject}, {STYLE}", "menu"))

    OUT_STAGES.mkdir(parents=True, exist_ok=True)
    OUT_MENU.mkdir(parents=True, exist_ok=True)
    dest = Path(args.dest).resolve() if args.dest else None
    if dest is not None:
        dest.mkdir(parents=True, exist_ok=True)
        jobs = [(dest / p.name, k, pr, n) for p, k, pr, n in jobs]

    if not args.force:
        jobs = [j for j in jobs if not j[0].exists()]
    if not jobs:
        print("every requested plate already exists; --force to regenerate")
        return 0

    # Disk BEFORE the model loads: see MIN_FREE_MB.
    cache = Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface"))
    for label, where in (("output", jobs[0][0].parent), ("hf cache", cache)):
        mb = free_mb(where)
        print(f"free on {label} volume: {mb} MB")
        if mb < MIN_FREE_MB:
            raise SystemExit(f"only {mb} MB free for {label}; "
                             f"want {MIN_FREE_MB} MB before a batch")

    import torch
    from PIL import Image
    from diffusers import AutoPipelineForText2Image

    if not torch.backends.mps.is_available():
        print("warning: MPS unavailable, this will be extremely slow on CPU")
    device = "mps" if torch.backends.mps.is_available() else "cpu"

    pipe = AutoPipelineForText2Image.from_pretrained(
        args.model, torch_dtype=torch.float16, variant="fp16")
    pipe = pipe.to(device)
    pipe.set_progress_bar_config(disable=True)
    # NO SLICING OF ANY KIND. Both attention slicing and VAE slicing produce
    # NaN on this fp16 MPS path — isolated runs without them came back clean at
    # every size tested, and with attention slicing on, the UNET itself emitted
    # NaN latents before the decoder was even reached. SDXL-Turbo at 1024x640
    # fits in 16 GB unsliced, so there is nothing to buy by re-enabling it.

    # THE SDXL VAE OVERFLOWS IN FLOAT16 ON MPS AND DECODES TO NaN, which numpy
    # then casts to a solid black JPEG while the pipeline reports success. The
    # only hint is a RuntimeWarning about an invalid cast; the file is the right
    # size and dimensions, so nothing downstream notices. Measured on this
    # machine, decoding the same latent three ways:
    #
    #     vae fp16 / mps   nan=True   min=nan    max=nan
    #     vae fp32 / mps   nan=False  min=-0.945 max=1.040
    #     vae fp32 / cpu   nan=False  min=-0.945 max=1.040
    #
    # pipe.upcast_vae() did NOT survive into the call, so the decode is done
    # here by hand instead of trusting the pipeline to keep the dtype. The UNet
    # stays fp16 — its latents were verified clean at every size, so only the
    # decoder pays the float32 cost.
    pipe.vae.to(dtype=torch.float32)

    # TRUNCATION IS SILENT, so measure it. CLIP stops at 77 tokens including
    # its two sentinels; diffusers prints the dropped tail as a warning in the
    # middle of a hundred other warnings and generates anyway, which is how the
    # style string lost "no text, no watermark" off its end. Measured against
    # the model's own tokenizer, and fatal: every rung of the ladder is
    # trimmable, so going over is a thing to fix, not to accept.
    limit = int(pipe.tokenizer.model_max_length)
    over = [(k, len(pipe.tokenizer(p)["input_ids"]))
            for _, k, p, _ in jobs
            if len(pipe.tokenizer(p)["input_ids"]) > limit]
    if over:
        for key, count in over:
            print(f"  {key}: {count} tokens, {count - limit} over")
        raise SystemExit(
            f"{len(over)} prompt(s) exceed CLIP's {limit} tokens and would be "
            "truncated from the end — shorten STYLE or the dread rung")

    written = 0
    total_bytes = 0
    for path, key, prompt, note in jobs:
        g = torch.Generator(device="cpu").manual_seed(seed_for(key))
        # Stop at the latent and decode below, so the float32 VAE is actually
        # the thing that runs. SDXL-Turbo is a guidance-free model, so the
        # negative prompt is deliberately not passed: at guidance_scale 0 it is
        # ignored anyway, and passing it only doubles the text encoder work.
        lat = pipe(prompt=prompt, num_inference_steps=args.steps,
                   guidance_scale=0.0, height=GEN_H, width=W,
                   generator=g, output_type="latent").images

        if torch.isnan(lat).any():
            print(f"  SKIP {key}: the UNET produced a NaN latent")
            continue
        with torch.no_grad():
            dec = pipe.vae.decode(
                lat.to(dtype=torch.float32) / pipe.vae.config.scaling_factor).sample
        if torch.isnan(dec).any():
            print(f"  SKIP {key}: decode produced NaN (vae dtype={pipe.vae.dtype}, "
                  f"device={pipe.vae.device}) — refusing to write a black plate")
            continue
        arr = ((dec / 2 + 0.5).clamp(0, 1)[0]
               .permute(1, 2, 0).float().cpu().numpy() * 255).astype("uint8")

        # A plate that is almost entirely one value is a failed generation, not
        # art. Catch it here rather than discovering it behind a menu.
        if float(arr.std()) < 6.0:
            print(f"  SKIP {key}: flat image (std {arr.std():.1f}) — not written")
            continue
        img = Image.fromarray(arr).crop((0, 0, W, H))
        # JPEG, not PNG: these are photographic plates behind UI, they go in a
        # 586 MiB PCK, and a lossless matte painting is ~2 MB for no benefit.
        img.save(path, format="JPEG", quality=88, optimize=True)
        if dest is None:
            write_import(path)
        size = path.stat().st_size
        written += 1
        total_bytes += size
        print(f"wrote {path.relative_to(ROOT) if dest is None else path}  "
              f"{img.size[0]}x{img.size[1]}  {size // 1024} KB  "
              f"seed={seed_for(key)}  [{note}]")

    print(f"\n{written}/{len(jobs)} plate(s) written, "
          f"{total_bytes} bytes ({total_bytes / 1024 / 1024:.2f} MiB) of JPEG")
    if dest is None and written:
        print("run Godot --import to rebuild the .ctex; the .import stubs keep "
              "them lossy (~0.55x the JPEG, not 4x it)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
