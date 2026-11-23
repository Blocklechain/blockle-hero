extends SceneTree
# Stage-plate COVERAGE, asserted against what the two consumers actually
# resolve — not against a file list.
#
# The art set used to be exactly the campaign's current diagonal: one plate per
# (biome, band) pair that Campaign.biome_at x Campaign.dread_band happens to
# visit today, 27 of the 80 the grid allows. That passes tools/dump_plates.gd,
# which only asks "is every plate the campaign names on disk", and it hid two
# real failures:
#
#   * scripts/ui/StagePlate.gd quantises with its OWN `const BANDS := 4` while
#     StageArt.gd declares 5. A map therefore gets a DIFFERENT band from the two
#     files, so the UI asks for plates off the generated diagonal — and
#     StagePlate.texture_for only walks DOWNWARD, so when nothing lower exists
#     it returns null and the screen falls back to a flat biome colour. The
#     late-campaign maps were showing no art at all.
#   * any future move of the act windows in Campaign.gd lands on an ungenerated
#     pair, which degrades quietly to a wrong-dread painting.
#
# Both stop being possible once the grid is FULL, so that is what this asserts:
# every biome x every band, whatever either file thinks a band is.
#
# WHY IT COUNTS SECTIONS. A runtime error aborts the enclosing function and
# GDScript carries on to the next one, so a crash in the middle of a check would
# otherwise be reported as zero failures. Every section registers before it runs
# and confirms after, and a section that never confirmed is a failure.
#
#   /opt/homebrew/bin/godot --headless --path . --script tools/plateartest.gd

const DIR: String = "res://assets/art/stages"

## Generated at 1024x640 and cropped to this; see gen_concept_art.py's W/H.
const PLATE_W: int = 1024
const PLATE_H: int = 576

## A plate is a ~60-140 KB JPEG. The bounds are a SHIP GUARD, not a style
## check: these go in an iOS bundle, and the floor also catches a truncated or
## half-written file that still has a valid header.
const MIN_BYTES: int = 20 * 1024
const MAX_BYTES: int = 260 * 1024

var _fails: int = 0
var _opened: Array[String] = []
var _closed: Dictionary = {}


func _init() -> void:
	_grid_complete()
	_stageart_exact()
	_stageplate_resolves()
	_images_load()
	_byte_budget()

	# A section that opened and never closed died part-way through.
	for name in _opened:
		if not _closed.has(name):
			_fails += 1
			print("  FAIL  section %s  aborted part-way (runtime error)" % name)
	print("\n%d section(s) run, %d failure(s)" % [_opened.size(), _fails])
	quit(1 if _fails > 0 else 0)


func _open(name: String) -> void:
	_opened.append(name)


func _close(name: String) -> void:
	_closed[name] = true


func _check(ok: bool, label: String, note: String) -> void:
	if not ok:
		_fails += 1
	print("  %s  %-34s  %s" % ["PASS" if ok else "FAIL", label, note])


# ------------------------------------------------------------------------------
# 1. The grid. Every biome at every band, so neither consumer's idea of a band
#    can land on a hole.
# ------------------------------------------------------------------------------
func _grid_complete() -> void:
	_open("grid")
	# The widest band count either file uses, so a plate exists whichever is
	# right. StagePlate's 4 is a subset of StageArt's 5 only in COUNT — the
	# quantisation differs — but d0..d4 covers both's output range.
	var nbands: int = maxi(StageArt.BANDS, StagePlate.BANDS)
	var missing: PackedStringArray = PackedStringArray()
	for id in Biome.IDS:
		for b in range(nbands):
			if not FileAccess.file_exists("%s/%s_d%d.jpg" % [DIR, id, b]):
				missing.append("%s_d%d" % [id, b])
	var want: int = Biome.IDS.size() * nbands
	_check(missing.is_empty(), "grid %dx%d complete" % [Biome.IDS.size(), nbands],
		"%d/%d present%s" % [want - missing.size(), want,
			"" if missing.is_empty() else ", missing " + ", ".join(missing)])
	_close("grid")


# ------------------------------------------------------------------------------
# 2. StageArt resolves every map to its OWN band — no fallback taken.
#    stage_plate() searching outward is the safety net; with a full grid it must
#    never actually fire, and this is what proves the net is unused rather than
#    load-bearing.
# ------------------------------------------------------------------------------
func _stageart_exact() -> void:
	_open("stageart")
	var fell_back: int = 0
	var none: int = 0
	for i in range(Campaign.map_count()):
		var got: String = StageArt.stage_plate(i)
		if got == "":
			none += 1
		elif got != "%s/%s.jpg" % [DIR, StageArt.plate_key(i)]:
			fell_back += 1
	_check(none == 0 and fell_back == 0, "StageArt: exact plate per map",
		"%d maps, %d fell back to another band, %d with no art" % [
			Campaign.map_count(), fell_back, none])
	_close("stageart")


# ------------------------------------------------------------------------------
# 3. THE EFFECT, which is the only one of these a player can see: the UI node
#    hands back a real loaded Texture2D of the right band for every map.
#
#    Not "the file exists" and not "plate_key returned a string" — texture_for()
#    is the function the carousel calls, it quantises with StagePlate.BANDS
#    rather than StageArt.BANDS, and a null from it is the flat-colour fallback
#    on screen. It also goes through load(), so an unimported or corrupt plate
#    fails here even though FileAccess in section 1 was happy.
# ------------------------------------------------------------------------------
func _stageplate_resolves() -> void:
	_open("stageplate")
	var nulls: PackedStringArray = PackedStringArray()
	var off_band: PackedStringArray = PackedStringArray()
	for i in range(Campaign.map_count()):
		var biome: String = Biome.base_id(Campaign.biome_at(i))
		var band: int = Campaign.dread_band(i, StagePlate.BANDS)
		var tex: Texture2D = StagePlate.texture_for(i)
		if tex == null:
			nulls.append("map %d (%s_d%d)" % [i + 1, biome, band])
			continue
		# WHICH plate came back, read off the resource rather than recomputed:
		# texture_for walks downward, so a non-null answer is not proof it is
		# the right picture.
		var want: String = "%s/%s_d%d.jpg" % [DIR, biome, band]
		if tex.resource_path != want:
			off_band.append("map %d wanted %s_d%d, got %s" % [
				i + 1, biome, band, tex.resource_path.get_file()])
	_check(nulls.is_empty(), "StagePlate: a texture for every map",
		"%d maps, %d flat-colour fallbacks%s" % [Campaign.map_count(),
			nulls.size(), "" if nulls.is_empty()
				else " — " + ", ".join(nulls.slice(0, 6))])
	_check(off_band.is_empty(), "StagePlate: right band per map",
		"%d wrong-dread paintings%s" % [off_band.size(),
			"" if off_band.is_empty() else " — " + ", ".join(off_band.slice(0, 6))])
	_close("stageplate")


# ------------------------------------------------------------------------------
# 4. Every plate is a real image of the right size and is not blank.
#
#    Decoded from the file on disk, which is what catches the failure mode this
#    generator is known for: the fp16 SDXL VAE on MPS decodes to NaN and numpy
#    casts that to a SOLID BLACK JPEG of exactly the right dimensions, so a
#    header-and-size check alone passes a plate nobody can see anything in.
# ------------------------------------------------------------------------------
func _images_load() -> void:
	_open("images")
	var bad: PackedStringArray = PackedStringArray()
	var flat: PackedStringArray = PackedStringArray()
	var n: int = 0
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".jpg"):
			continue
		n += 1
		var img: Image = Image.load_from_file("%s/%s" % [DIR, f])
		if img == null or img.is_empty():
			bad.append("%s: not decodable" % f)
			continue
		if img.get_width() != PLATE_W or img.get_height() != PLATE_H:
			bad.append("%s: %dx%d" % [f, img.get_width(), img.get_height()])
			continue
		if _spread(img) < 0.04:
			flat.append("%s: spread %.3f" % [f, _spread(img)])
	_check(bad.is_empty(), "every plate decodes at %dx%d" % [PLATE_W, PLATE_H],
		"%d files%s" % [n, "" if bad.is_empty() else " — " + ", ".join(bad)])
	_check(flat.is_empty(), "no blank/black plate",
		"%d files%s" % [n, "" if flat.is_empty() else " — " + ", ".join(flat)])
	_close("images")


# The luminance range over a coarse sample. A NaN-decoded plate is uniform, so
# min==max; real matte paintings here measure 0.6-1.0.
func _spread(img: Image) -> float:
	var lo: float = 1.0
	var hi: float = 0.0
	var step: int = 16
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var l: float = img.get_pixel(x, y).get_luminance()
			lo = minf(lo, l)
			hi = maxf(hi, l)
	return hi - lo


# ------------------------------------------------------------------------------
# 5. The bundle budget. These ship inside the iOS app, so a plate that comes
#    back from a regeneration an order of magnitude bigger is a defect even if
#    it looks fine.
# ------------------------------------------------------------------------------
func _byte_budget() -> void:
	_open("bytes")
	var over: PackedStringArray = PackedStringArray()
	var total: int = 0
	var n: int = 0
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".jpg"):
			continue
		var fa: FileAccess = FileAccess.open("%s/%s" % [DIR, f], FileAccess.READ)
		if fa == null:
			over.append("%s: unreadable" % f)
			continue
		var size: int = int(fa.get_length())
		fa.close()
		total += size
		n += 1
		if size < MIN_BYTES or size > MAX_BYTES:
			over.append("%s: %d B" % [f, size])
	_check(over.is_empty(), "plate size within %d-%d KB" % [
		MIN_BYTES / 1024, MAX_BYTES / 1024],
		"%d plates, %.2f MiB total, mean %d KB%s" % [n,
			float(total) / 1048576.0, (total / maxi(n, 1)) / 1024,
			"" if over.is_empty() else " — " + ", ".join(over)])
	# An .import stub per plate, or Godot imports it LOSSLESS and a 76 KB
	# picture becomes a 571 KB .ctex in the bundle. See IMPORT_STUB in the
	# generator.
	var unstubbed: PackedStringArray = PackedStringArray()
	for f in DirAccess.get_files_at(DIR):
		if f.ends_with(".jpg") and not FileAccess.file_exists(
				"%s/%s.import" % [DIR, f]):
			unstubbed.append(f)
	_check(unstubbed.is_empty(), "every plate has an .import",
		"%d without%s" % [unstubbed.size(),
			"" if unstubbed.is_empty() else " — " + ", ".join(unstubbed)])
	_close("bytes")
