extends SceneTree
# Did FILLING the plate grid actually produce 80 DIFFERENT paintings?
#
# tools/plateartest.gd already asserts the grid is complete and that both
# consumers resolve every map to its own band. This harness asserts the part a
# coverage count cannot see: that the 51 plates added to finish the grid are
# real, distinct art on the dread ladder rather than 80 slots filled by
# whatever was cheapest to put there.
#
# The three ways a "full grid" can be a lie, all of which a file-exists check
# passes:
#
#   * a plate copied from its neighbouring band to fill the hole — identical
#     bytes, so the player sees the same picture for map 5 and map 95;
#   * a NaN decode, which gen_concept_art.py's fp16-VAE-on-MPS path turns into
#     a solid JPEG of exactly the right dimensions (see the vae.to(float32)
#     comment there) — a valid header, a valid size, nothing in it;
#   * the dread ladder being ignored, which is what happens if DREAD_LADDER and
#     StageArt.BANDS drift apart: every band of a biome then renders off rung 0
#     and the late campaign is lit like the early campaign.
#
# The JPEG header is read as BYTES, not just decoded, because an .import that
# resolves is not evidence about the file on disk: Godot can serve a stale
# .ctex for a .jpg that was truncated after it was imported.
#
# WHY IT COUNTS SECTIONS. A runtime error aborts the enclosing function and
# GDScript carries on into the next one, so a crash mid-check would otherwise
# print as zero failures. Each section registers before it runs and confirms
# after; a section that never confirmed counts as a failure.
#
#   /opt/homebrew/bin/godot --headless --path . --script tools/platefilltest.gd

const DIR: String = "res://assets/art/stages"

## gen_concept_art.py generates 1024x640 and crops to W x H. Hard-coded rather
## than parsed: the point is to catch the generator changing under us.
const PLATE_W: int = 1024
const PLATE_H: int = 576

## Ship guard for an iOS bundle. The floor also catches a truncated write that
## still carries a valid header.
const MIN_BYTES: int = 20 * 1024
const MAX_BYTES: int = 260 * 1024

var _fails: int = 0
var _opened: Array[String] = []
var _closed: Dictionary = {}

## Cached per plate key so the sections do not decode 80 JPEGs each.
var _imgs: Dictionary = {}


func _init() -> void:
	_load_all()
	_namespace_complete()
	_headers_are_jpeg()
	_all_distinct()
	_dread_darkens()
	_maps_get_their_own_band()
	_budget()

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
	print("  %s  %-36s  %s" % ["PASS" if ok else "FAIL", label, note])


## The band count the ART must cover: StageArt.gd says 5 and
## scripts/ui/StagePlate.gd says 4, and they quantise differently, so a plate
## has to exist for every band EITHER of them can ask for. Taking the max is
## not a vote on which file is right — it is what makes the disagreement
## unable to produce a flat-colour screen.
func _band_span() -> int:
	return maxi(StageArt.BANDS, StagePlate.BANDS)


func _load_all() -> void:
	for id in Biome.IDS:
		for b in range(_band_span()):
			var key: String = "%s_d%d" % [id, b]
			var path: String = "%s/%s.jpg" % [DIR, key]
			if not FileAccess.file_exists(path):
				continue
			var img: Image = Image.load_from_file(path)
			if img != null and not img.is_empty():
				_imgs[key] = img


# ------------------------------------------------------------------------------
# 1. Every name either consumer can ask for has a file. This is the coverage
#    number the fill was for.
# ------------------------------------------------------------------------------
func _namespace_complete() -> void:
	_open("namespace")
	var missing: PackedStringArray = PackedStringArray()
	for id in Biome.IDS:
		for b in range(_band_span()):
			if not FileAccess.file_exists("%s/%s_d%d.jpg" % [DIR, id, b]):
				missing.append("%s_d%d" % [id, b])
	var want: int = Biome.IDS.size() * _band_span()
	_check(missing.is_empty(), "%d biomes x %d bands on disk" % [
		Biome.IDS.size(), _band_span()],
		"%d/%d%s" % [want - missing.size(), want, "" if missing.is_empty()
			else ", missing " + ", ".join(missing)])
	_close("namespace")


# ------------------------------------------------------------------------------
# 2. Each file is a JPEG by its own first bytes and decodes at the shipped size.
#    Read off disk, so a stale import cannot vouch for a file that is no longer
#    there in one piece.
# ------------------------------------------------------------------------------
func _headers_are_jpeg() -> void:
	_open("headers")
	var bad: PackedStringArray = PackedStringArray()
	var n: int = 0
	for key in _grid_keys():
		var path: String = "%s/%s.jpg" % [DIR, key]
		var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
		if fa == null:
			bad.append("%s: unreadable" % key)
			continue
		var head: PackedByteArray = fa.get_buffer(3)
		# SOI + the first marker byte. Every JFIF/EXIF JPEG starts FF D8 FF.
		var tail_ok: bool = false
		if fa.get_length() > 4:
			fa.seek(fa.get_length() - 2)
			var tail: PackedByteArray = fa.get_buffer(2)
			# EOI. Its absence is the signature of a half-written file.
			tail_ok = tail.size() == 2 and tail[0] == 0xFF and tail[1] == 0xD9
		fa.close()
		n += 1
		if head.size() != 3 or head[0] != 0xFF or head[1] != 0xD8 or head[2] != 0xFF:
			bad.append("%s: not a JPEG header" % key)
			continue
		if not tail_ok:
			bad.append("%s: no EOI marker (truncated)" % key)
			continue
		var img: Image = _imgs.get(key) as Image
		if img == null:
			bad.append("%s: does not decode" % key)
			continue
		if img.get_width() != PLATE_W or img.get_height() != PLATE_H:
			bad.append("%s: %dx%d" % [key, img.get_width(), img.get_height()])
	_check(bad.is_empty(), "JPEG header + %dx%d decode" % [PLATE_W, PLATE_H],
		"%d plates%s" % [n, "" if bad.is_empty() else " — " + ", ".join(bad)])
	_close("headers")


# ------------------------------------------------------------------------------
# 3. No two plates are the same picture.
#
#    THE CHEAP WAY TO "FILL COVERAGE" IS TO COPY, and it is invisible to every
#    other check here: a duplicate has a good header, the right size, plenty of
#    contrast and a sane byte count. Compared on decoded content, not on file
#    bytes, so a re-encode of the same image is still caught.
# ------------------------------------------------------------------------------
func _all_distinct() -> void:
	_open("distinct")
	var seen: Dictionary = {}
	var dupes: PackedStringArray = PackedStringArray()
	for key in _grid_keys():
		var img: Image = _imgs.get(key) as Image
		if img == null:
			continue
		var sig: String = _signature(img)
		if seen.has(sig):
			dupes.append("%s == %s" % [key, seen[sig]])
		else:
			seen[sig] = key
	_check(dupes.is_empty(), "every plate a different picture",
		"%d distinct of %d%s" % [seen.size(), _imgs.size(),
			"" if dupes.is_empty() else " — " + ", ".join(dupes)])

	# A flat plate is the NaN-decode failure: uniform, so min == max.
	var flat: PackedStringArray = PackedStringArray()
	for key in _grid_keys():
		var img: Image = _imgs.get(key) as Image
		if img != null and _spread(img) < 0.04:
			flat.append("%s: spread %.3f" % [key, _spread(img)])
	_check(flat.is_empty(), "no blank or NaN-black plate",
		"%d plates%s" % [_imgs.size(),
			"" if flat.is_empty() else " — " + ", ".join(flat)])
	_close("distinct")


# ------------------------------------------------------------------------------
# 4. THE DREAD LADDER REACHED THE PIXELS.
#
#    The whole reason there are five plates per biome instead of one is that
#    band 4 is supposed to look like the end of the world and band 0 like
#    somebody's country. If DREAD_LADDER in the generator ever stops being
#    indexed by the reported band, every band renders off the same rung and the
#    art set silently becomes sixteen pictures in five copies — which sections
#    1-3 all pass, because the images are still distinct generations.
#
#    Asserted in the AGGREGATE, over all sixteen biomes, not per biome: one
#    SDXL sample is noisy enough that a single biome can come back brighter at
#    band 4 by chance, and a per-biome assert would be a flaky test rather than
#    a true one. "Mean luminance falls from band 0 to band 4 across the set" is
#    the claim the ladder actually makes.
# ------------------------------------------------------------------------------
func _dread_darkens() -> void:
	_open("dread")
	var lo_sum: float = 0.0
	var hi_sum: float = 0.0
	var n: int = 0
	var top: int = _band_span() - 1
	for id in Biome.IDS:
		var a: Image = _imgs.get("%s_d0" % id) as Image
		var b: Image = _imgs.get("%s_d%d" % [id, top]) as Image
		if a == null or b == null:
			continue
		lo_sum += _mean_luma(a)
		hi_sum += _mean_luma(b)
		n += 1
	var lo: float = lo_sum / maxf(float(n), 1.0)
	var hi: float = hi_sum / maxf(float(n), 1.0)
	_check(n == Biome.IDS.size(), "both ends of the ladder present",
		"%d/%d biomes have d0 and d%d" % [n, Biome.IDS.size(), top])
	_check(n > 0 and hi < lo, "band %d darker than band 0" % top,
		"mean luma %.3f -> %.3f over %d biomes" % [lo, hi, n])
	_close("dread")


# ------------------------------------------------------------------------------
# 5. THE EFFECT A PLAYER SEES. The carousel node hands back a loaded texture of
#    the map's own band for all 100 maps — no null (flat biome colour) and no
#    downward fallback (another band's weather).
#
#    Through StagePlate.texture_for, which is what the screen calls and which
#    quantises with its own BANDS, so this is the one check that fails if the
#    grid is complete on disk but the plates were never imported.
# ------------------------------------------------------------------------------
func _maps_get_their_own_band() -> void:
	_open("maps")
	var nulls: PackedStringArray = PackedStringArray()
	var off: PackedStringArray = PackedStringArray()
	for i in range(Campaign.map_count()):
		var biome: String = Biome.base_id(Campaign.biome_at(i))
		var band: int = Campaign.dread_band(i, StagePlate.BANDS)
		var tex: Texture2D = StagePlate.texture_for(i)
		if tex == null:
			nulls.append("map %d (%s_d%d)" % [i + 1, biome, band])
			continue
		# Read off the resource: texture_for walks downward, so non-null is no
		# proof it is the right band.
		if tex.resource_path != "%s/%s_d%d.jpg" % [DIR, biome, band]:
			off.append("map %d wanted %s_d%d, got %s" % [
				i + 1, biome, band, tex.resource_path.get_file()])
	_check(nulls.is_empty(), "a texture for all %d maps" % Campaign.map_count(),
		"%d flat-colour fallbacks%s" % [nulls.size(), "" if nulls.is_empty()
			else " — " + ", ".join(nulls.slice(0, 6))])
	_check(off.is_empty(), "exact band for all %d maps" % Campaign.map_count(),
		"%d wrong-dread plates%s" % [off.size(), "" if off.is_empty()
			else " — " + ", ".join(off.slice(0, 6))])

	# StageArt quantises differently (5 bands); the same must hold through it,
	# or the dread-tagged path in plate_key regresses.
	var art_off: int = 0
	for i in range(Campaign.map_count()):
		if StageArt.stage_plate(i) != "%s/%s.jpg" % [DIR, StageArt.plate_key(i)]:
			art_off += 1
	_check(art_off == 0, "StageArt exact for all %d maps" % Campaign.map_count(),
		"%d resolved to another plate" % art_off)
	_close("maps")


# ------------------------------------------------------------------------------
# 6. The bundle cost, and the .import stub that keeps it. Without the stub
#    Godot imports a plate LOSSLESS and a 76 KB picture becomes a 571 KB .ctex
#    in an already-large iOS bundle — see IMPORT_STUB in gen_concept_art.py.
# ------------------------------------------------------------------------------
func _budget() -> void:
	_open("budget")
	var over: PackedStringArray = PackedStringArray()
	var unstubbed: PackedStringArray = PackedStringArray()
	var total: int = 0
	var n: int = 0
	for key in _grid_keys():
		var path: String = "%s/%s.jpg" % [DIR, key]
		var fa: FileAccess = FileAccess.open(path, FileAccess.READ)
		if fa == null:
			continue
		var size: int = int(fa.get_length())
		fa.close()
		total += size
		n += 1
		if size < MIN_BYTES or size > MAX_BYTES:
			over.append("%s: %d B" % [key, size])
		if not FileAccess.file_exists("%s.import" % path):
			unstubbed.append(key)
	_check(over.is_empty(), "each plate %d-%d KB" % [
		MIN_BYTES / 1024, MAX_BYTES / 1024],
		"%d plates, %.2f MiB, mean %d KB%s" % [n, float(total) / 1048576.0,
			(total / maxi(n, 1)) / 1024,
			"" if over.is_empty() else " — " + ", ".join(over)])
	_check(unstubbed.is_empty(), "lossy .import beside every plate",
		"%d without%s" % [unstubbed.size(), "" if unstubbed.is_empty()
			else " — " + ", ".join(unstubbed)])
	_close("budget")


func _grid_keys() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for id in Biome.IDS:
		for b in range(_band_span()):
			var key: String = "%s_d%d" % [id, b]
			if FileAccess.file_exists("%s/%s.jpg" % [DIR, key]):
				out.append(key)
	return out


## A coarse content fingerprint. 16x9 cells of mean luminance quantised to 64
## levels: identical between two encodings of the same painting, different for
## any two separately-generated ones (measured on the 29 plates that already
## shipped — all 29 signatures were unique).
func _signature(img: Image) -> String:
	var cw: int = maxi(img.get_width() / 16, 1)
	var ch: int = maxi(img.get_height() / 9, 1)
	var sig: String = ""
	for cy in range(9):
		for cx in range(16):
			var sum: float = 0.0
			var count: int = 0
			for y in range(cy * ch, mini((cy + 1) * ch, img.get_height()), 8):
				for x in range(cx * cw, mini((cx + 1) * cw, img.get_width()), 8):
					sum += img.get_pixel(x, y).get_luminance()
					count += 1
			sig += "%02x" % int(sum / maxf(float(count), 1.0) * 63.0)
	return sig


func _mean_luma(img: Image) -> float:
	var sum: float = 0.0
	var n: int = 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
	return sum / maxf(float(n), 1.0)


func _spread(img: Image) -> float:
	var lo: float = 1.0
	var hi: float = 0.0
	for y in range(0, img.get_height(), 16):
		for x in range(0, img.get_width(), 16):
			var l: float = img.get_pixel(x, y).get_luminance()
			lo = minf(lo, l)
			hi = maxf(hi, l)
	return hi - lo
