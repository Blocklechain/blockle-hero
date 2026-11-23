#!/usr/bin/env python3
"""Trail of Heroes — spoken narration, rendered on this Mac with Kokoro-82M.

Same property as the rest of this project's assets: generated, not bought. The
world, the sound effects, the app icon and the concept art are all produced
locally and can be rebuilt from scratch, and the voice is too — no API key, no
per-character billing, no licence attached to a shipped wav. Kokoro-82M runs
out of ~/.cache/huggingface, so this works with the network off.

WHAT IT RENDERS IS DECIDED BY THE GAME, NOT BY THIS SCRIPT.

  scripts/game/Story.gd       the words (canon)
  assets/voice/lines.json     the casting: role -> voice/speed/mix, and the
                              filename pattern for each of Story's beats
  scripts/game/Narration.gd   turns those two into a table of
                              {key, text, voice, speed} — and is the ONLY
                              implementation of the key scheme

This script asks Narration.render_table() (through a throwaway headless Godot
script) and renders exactly what it is handed. It parses no GDScript, holds no
prose, and derives no filenames. The alternative — teaching Python the key
scheme — is a second implementation of it, and the day the two disagree a line
goes silent while every individual piece still looks correct. That class of bug
has cost this project five shipped-but-wired-to-nothing features; see
tools/classcheck.gd for the GDScript-side version of the same lesson.

RE-RUNS ARE CHEAP, which matters because rendering everything is minutes of
compute and this gets run after every wording tweak. A line is rendered when
its wav is missing or empty, or when the text/voice/speed it was rendered from
is not what the table says now — recorded per line in assets/voice/.render.json.
Editing one line of Story.gd therefore re-renders one line.

PEAK-NORMALISED to a fixed ceiling, because Kokoro's output level varies with
the voice and the sentence. Unnormalised, the narrator audibly jumps in volume
between acts and the boss is quieter than the menu. Per-beat loudness is a mix
decision instead, applied in-game from `gain_db` in the manifest.

  python3 tools/gen_voice.py                 # everything missing or changed
  python3 tools/gen_voice.py --list          # what would happen; no Kokoro
  python3 tools/gen_voice.py --force         # re-render all of it
  python3 tools/gen_voice.py --only act_01_open_1
  python3 tools/gen_voice.py --prune         # delete wavs no line claims
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
MANIFEST = PROJECT / "assets" / "voice" / "lines.json"
STORY = PROJECT / "scripts" / "game" / "Story.gd"
NARRATION = PROJECT / "scripts" / "game" / "Narration.gd"
OUT_DIR = PROJECT / "assets" / "voice"

# What was rendered last time: key -> {hash, voice, speed, ...}. Lets a one-word
# edit re-render one line instead of the whole table.
LEDGER_NAME = ".render.json"

RATE = 24000

# Kokoro's g2p is per-dialect and is chosen by the voice's prefix, not by a
# flag: am_/af_ are American ('a'), bm_/bf_ are British ('b'). Rendering
# bm_george through the American front-end still produces audio, which is why
# this is worth stating — it is wrong in a way that only sounds slightly off.
LANG_OF_PREFIX = {"a": "a", "b": "b"}

# -1.5 dBFS. Not 0: PCM_16 rounding on a sample already at full scale clips, and
# a clipped narrator reads as a broken file rather than as a loud one.
PEAK = 0.84

KEY_RE = re.compile(r"^[a-z0-9_]+$")

GODOT_CANDIDATES = ("/opt/homebrew/bin/godot", "godot", "godot4")


def die(msg: str) -> None:
    print(f"gen_voice: {msg}", file=sys.stderr)
    raise SystemExit(2)


# ------------------------------------------------------------------------------
# Asking the game what to render
# ------------------------------------------------------------------------------

# Writes Narration's render table to a file as JSON and quits. Generated per
# run, into a DOT-PREFIXED path so that tools/classcheck.gd skips it if a crash
# ever leaves one behind, and deleted in a finally.
#
# It writes a file rather than printing, because Godot's own banner and any
# push_error from the table share stdout, and a JSON parser fed a banner reports
# the wrong problem.
DUMP_TEMPLATE = """extends SceneTree
const NarrationS := preload("res://scripts/game/Narration.gd")

func _init() -> void:
	var rows: Array = NarrationS.render_table()
	var payload: Dictionary = {
		"rows": rows,
		"uncast": NarrationS.uncast_story_beats(),
		"roles": NarrationS.speaking_roles(),
	}
	var f := FileAccess.open(%(out)s, FileAccess.WRITE)
	if f == null:
		# Concatenated, not interpolated: the path is substituted in as a
		# QUOTED GDScript literal, so dropping it inside another string closes
		# that string early and the whole dump script fails to parse.
		push_error("voice dump: cannot write " + %(out)s)
		quit(1)
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	quit(0)
"""


def find_godot(explicit: str | None) -> str:
    if explicit:
        if shutil.which(explicit) or Path(explicit).exists():
            return explicit
        die(f"--godot {explicit!r} is not executable")
    for cand in GODOT_CANDIDATES:
        found = shutil.which(cand) or (cand if Path(cand).exists() else None)
        if found:
            return found
    die("no godot binary found; pass --godot /path/to/godot")
    return ""


def dump_table(godot: str) -> dict:
    """Narration's render table, straight out of the engine."""
    out_json = Path(tempfile.mkdtemp(prefix="genvoice-")) / "table.json"
    # Must live under res:// for its preload to resolve, so it goes in the
    # project — hidden, uniquely named, and removed below.
    script = PROJECT / "tools" / f".gen_voice_table_{os.getpid()}.gd"
    script.write_text(DUMP_TEMPLATE % {"out": json.dumps(str(out_json))},
                      encoding="utf-8")
    try:
        proc = subprocess.run(
            [godot, "--headless", "--path", str(PROJECT),
             "--script", f"res://tools/{script.name}"],
            capture_output=True, text=True, timeout=180)
        if not out_json.exists():
            # The engine's own output is the diagnosis here (a parse error in
            # Narration.gd or Story.gd lands in it), so it is reproduced rather
            # than summarised.
            sys.stderr.write(proc.stdout)
            sys.stderr.write(proc.stderr)
            die(f"godot wrote no table (exit {proc.returncode}) — "
                "run tools/classcheck.gd")
        data = json.loads(out_json.read_text(encoding="utf-8"))
    finally:
        script.unlink(missing_ok=True)
        # .uid sidecars: Godot writes one next to any script it loads, and an
        # orphan pointing at a deleted file is noise in `git status`.
        Path(str(script) + ".uid").unlink(missing_ok=True)
        shutil.rmtree(out_json.parent, ignore_errors=True)

    rows = data.get("rows") or []
    if not rows:
        die("Narration.render_table() is empty — no lines to render")
    uncast = data.get("uncast") or []
    if uncast:
        # Fatal, not a warning. A beat Story advertises and the manifest does
        # not cast is a beat that will show its subtitle in silence forever,
        # and nothing else in the pipeline would ever mention it.
        die(f"{MANIFEST.name} does not cast story beat(s): {', '.join(uncast)}"
            " — add them under story.beats")

    jobs = []
    for row in rows:
        key = str(row.get("key", ""))
        # A key is a filename. A space or a slash renders to a path Narration
        # cannot load back, and the symptom is a silent line, not an error.
        if not KEY_RE.match(key):
            die(f"line key {key!r} is not filename-safe ([a-z0-9_])")
        text = (row.get("text") or "").strip()
        if not text:
            die(f"line {key!r} has no text")
        voice = str(row.get("voice") or "")
        if not voice:
            die(f"line {key!r} is cast as {row.get('beat')!r}, which declares "
                "no voice")
        jobs.append({
            "key": key,
            "beat": str(row.get("beat", "")),
            "source": str(row.get("source", "")),
            "text": text,
            "voice": voice,
            "speed": float(row.get("speed", 1.0)),
            "lang": LANG_OF_PREFIX.get(voice[:1], "a"),
        })
    jobs.sort(key=lambda j: j["key"])
    return {"jobs": jobs, "roles": data.get("roles") or []}


def fingerprint(job: dict) -> str:
    """Everything that changes the audio. Text, voice and speed — not the beat
    name, so recasting a role's label does not re-render a word of it."""
    blob = "\x1f".join([job["text"], job["voice"], f"{job['speed']:.4f}"])
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


# ------------------------------------------------------------------------------
# Freshness
# ------------------------------------------------------------------------------

def needs_render(job: dict, wav: Path, source_mtime: float,
                 ledger: dict, force: bool) -> str | None:
    """Reason to render, or None to skip."""
    if force:
        return "forced"
    if not wav.exists():
        return "missing"
    if wav.stat().st_size == 0:
        return "empty"
    was = ledger.get(job["key"]) or {}
    if was:
        # The ledger knows what this wav was made from, so the comparison is
        # exact and mtimes do not come into it: touching Story.gd re-renders
        # nothing, editing one line of it re-renders that line.
        return None if was.get("hash") == fingerprint(job) else "changed"
    # No record — a wav from before the ledger, or a lost ledger. Fall back to
    # the coarse test: newer than both sources is assumed to match them.
    return None if wav.stat().st_mtime >= source_mtime else "unrecorded"


def load_ledger(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data.get("lines") or {}
    except (OSError, ValueError):
        # A missing or corrupt ledger must not stop a render — the worst it can
        # cost is one extra pass over lines whose wavs are already correct.
        return {}


def save_ledger(path: Path, lines: dict) -> None:
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump({"rate": RATE, "lines": lines}, fh, indent=1, sort_keys=True)
        fh.write("\n")
    tmp.replace(path)


# ------------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------------

class Renderer:
    """One KPipeline per dialect, built on first use.

    Lazy because importing torch and loading the 327 MB checkpoint costs ~10 s,
    and the common case for this script is "nothing changed" — paying that to
    print 'skipped 71' would make the cheap re-run expensive again.
    """

    def __init__(self) -> None:
        self._pipes: dict[str, object] = {}
        self._np = None
        self._sf = None

    def _boot(self) -> None:
        if self._np is not None:
            return
        # Before the import, not after: the HF client reads this at import time
        # and will otherwise try to reach the network for a repo it already has.
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
        import numpy
        import soundfile
        self._np = numpy
        self._sf = soundfile

    def pipeline(self, lang: str):
        self._boot()
        if lang not in self._pipes:
            from kokoro import KPipeline
            self._pipes[lang] = KPipeline(lang_code=lang,
                                          repo_id="hexgrad/Kokoro-82M")
        return self._pipes[lang]

    def render(self, job: dict, wav: Path, rate: int) -> tuple[float, int]:
        pipe = self.pipeline(job["lang"])
        chunks = [audio for _, _, audio in
                  pipe(job["text"], voice=job["voice"], speed=job["speed"])]
        if not chunks:
            raise RuntimeError("Kokoro returned no audio")
        samples = self._np.concatenate(chunks)
        if hasattr(samples, "detach"):          # torch tensor on some versions
            samples = samples.detach().cpu().numpy()
        samples = self._np.asarray(samples, dtype="float32").reshape(-1)
        peak = float(self._np.max(self._np.abs(samples))) if samples.size else 0.0
        if peak <= 1e-6:
            raise RuntimeError("Kokoro returned silence")
        samples *= PEAK / peak

        # Written to a temp name and moved into place, so an interrupted render
        # cannot leave a half-written wav that looks fresh to the next run.
        tmp = wav.with_suffix(".wav.part")
        # PCM_16 mono, not float: AudioStreamWAV.load_from_file reads 8/16-bit
        # integer PCM, and a 32-bit float wav loads as nothing at all in Godot.
        #
        # `format` IS PASSED EXPLICITLY. soundfile infers it from the extension,
        # and the extension here is `.part` — every line failed to write on the
        # first run of this script for that reason alone.
        self._sf.write(str(tmp), samples, rate, format="WAV", subtype="PCM_16")
        tmp.replace(wav)
        return float(samples.size) / float(rate), wav.stat().st_size


# ------------------------------------------------------------------------------
# Driver
# ------------------------------------------------------------------------------

def human(n: int) -> str:
    return f"{n / 1024.0:.0f} KiB" if n < 1024 * 1024 else f"{n / 1048576.0:.2f} MiB"


def wav_seconds(size: int, rate: int) -> float:
    """Duration from a file size: 44-byte canonical header, 16-bit mono. Good
    enough to report with, and it avoids opening 71 files through soundfile to
    print one sum."""
    return max(0.0, (size - 44) / 2.0) / float(rate)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=OUT_DIR,
                    help="where the wavs go (default assets/voice)")
    ap.add_argument("--godot", default=None,
                    help="godot binary (default: homebrew, then PATH)")
    ap.add_argument("--force", action="store_true",
                    help="re-render every line, fresh or not")
    ap.add_argument("--only", action="append", default=[], metavar="KEY",
                    help="render just these keys (repeatable)")
    ap.add_argument("--list", action="store_true",
                    help="report what would happen; never loads Kokoro")
    ap.add_argument("--prune", action="store_true",
                    help="delete wavs in --out that no line claims")
    args = ap.parse_args()

    for required in (MANIFEST, STORY, NARRATION):
        if not required.exists():
            die(f"missing {required.relative_to(PROJECT)}")

    table = dump_table(find_godot(args.godot))
    all_jobs = table["jobs"]
    rate = RATE
    jobs = all_jobs
    if args.only:
        wanted = set(args.only)
        unknown = wanted - {j["key"] for j in all_jobs}
        if unknown:
            die(f"--only names unknown line(s): {', '.join(sorted(unknown))}")
        jobs = [j for j in all_jobs if j["key"] in wanted]

    args.out.mkdir(parents=True, exist_ok=True)
    ledger_path = args.out / LEDGER_NAME
    ledger = load_ledger(ledger_path)
    # Both halves of the table are sources; a wav older than either is suspect.
    source_mtime = max(MANIFEST.stat().st_mtime, STORY.stat().st_mtime)

    plan = [(job, args.out / f"{job['key']}.wav") for job in jobs]
    plan = [(job, wav, needs_render(job, wav, source_mtime, ledger, args.force))
            for (job, wav) in plan]
    todo = [(j, w, r) for (j, w, r) in plan if r is not None]
    fresh = [j for (j, _w, r) in plan if r is None]

    by_source: dict[str, int] = {}
    for job in all_jobs:
        head = job["source"].split(":")[0] or "?"
        by_source[head] = by_source.get(head, 0) + 1

    print(f"words      : {STORY.relative_to(PROJECT)}")
    print(f"casting    : {MANIFEST.relative_to(PROJECT)}  "
          f"roles {', '.join(str(r) for r in table['roles'])}")
    print(f"output     : {args.out}  ({rate} Hz, mono, PCM_16)")
    print(f"lines      : {len(all_jobs)} "
          f"({', '.join(f'{v} {k}' for k, v in sorted(by_source.items()))})"
          f"   to render: {len(todo)}   already fresh: {len(fresh)}")

    # Orphans are expected after a key-scheme or wording change and are not an
    # error: an unclaimed wav is dead weight in the export, not a broken line.
    claimed = {f"{j['key']}.wav" for j in all_jobs}
    orphans = sorted(p for p in os.listdir(args.out)
                     if p.endswith(".wav") and p not in claimed)

    if args.list:
        for job, _wav, reason in plan:
            print(f"  {'RENDER' if reason else 'skip  '} {job['key']:<18}"
                  f" {job['beat']:<9} {job['voice']:<11} x{job['speed']:.2f}"
                  f"  {reason or 'fresh'}")
        if orphans:
            print(f"\nunclaimed ({len(orphans)}): {', '.join(orphans)}")
        return 0

    if orphans:
        if args.prune:
            for name in orphans:
                (args.out / name).unlink(missing_ok=True)
                ledger.pop(name[:-4], None)
            print(f"pruned     : {len(orphans)} unclaimed wav(s)")
        else:
            print(f"unclaimed  : {len(orphans)} wav(s) no line asks for "
                  f"(--prune to delete): {', '.join(orphans[:4])}"
                  f"{' ...' if len(orphans) > 4 else ''}")

    renderer = Renderer()
    failures: list[tuple[str, str]] = []
    rendered = 0
    secs_new = 0.0
    bytes_new = 0
    t0 = time.time()

    for job, wav, reason in todo:
        key = job["key"]
        try:
            secs, size = renderer.render(job, wav, rate)
        except Exception as exc:                      # one bad line, not a halt
            # Keep going. A table of 71 lines where one trips the phonemiser
            # should still deliver 70 wavs, and the report has to name which
            # line failed — "it crashed" sends the next person to the wrong
            # file.
            failures.append((key, f"{type(exc).__name__}: {exc}"))
            print(f"  FAIL   {key:<18} {reason:<11} {exc}")
            continue
        rendered += 1
        secs_new += secs
        bytes_new += size
        ledger[key] = {
            "hash": fingerprint(job), "voice": job["voice"],
            "speed": job["speed"], "beat": job["beat"],
            "seconds": round(secs, 3), "bytes": size,
        }
        print(f"  ok     {key:<18} {job['voice']:<11} {secs:5.2f}s"
              f" {size:>8} B  ({reason})")

    if rendered or (orphans and args.prune):
        save_ledger(ledger_path, ledger)

    # The totals cover EVERY line on disk, not just this run's, because the
    # question after a one-line re-render is still "how much audio does the
    # game ship".
    total_files = 0
    total_bytes = 0
    total_secs = 0.0
    missing = []
    for job in all_jobs:
        wav = args.out / f"{job['key']}.wav"
        if not wav.exists():
            missing.append(job["key"])
            continue
        total_files += 1
        size = wav.stat().st_size
        total_bytes += size
        total_secs += wav_seconds(size, rate)

    print(f"\nrendered {rendered} line(s) in {time.time() - t0:.1f}s"
          f"  (+{secs_new:.1f}s of audio, +{human(bytes_new)})")
    print(f"on disk  {total_files}/{len(all_jobs)} lines, "
          f"{total_secs:.1f}s of audio, {total_bytes} B ({human(total_bytes)})")
    if missing:
        # Not an error. Narration degrades to silence and still shows the text,
        # which is the whole reason the game can ship before every line exists.
        print(f"not yet rendered ({len(missing)}): {', '.join(missing)}")
    if failures:
        print(f"\n{len(failures)} line(s) FAILED:")
        for key, why in failures:
            print(f"  {key}: {why}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
