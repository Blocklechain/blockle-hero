class_name ChampionName
extends RefCounted
# ------------------------------------------------------------------------------
# What a champion is CALLED on screen.
#
# The roster is a list of model ids (assets/heroes/roster.json): fourteen are
# authored words — "aldous", "lysandra", "thornwood" — and the other 125 are
# the exporter's filenames, "g001" through "g196". A shipping champion select
# cannot show "G001", so the generic ids get a real name here.
#
# It is DERIVED FROM THE ID, exactly as rarity and class already are
# (Champion.rarity_of, HeroClass.for_hero), which is what keeps it stable: the
# same hero has the same name on every device, after every reinstall, with no
# table to ship, migrate, or keep in step with the manifest. The name is never
# persisted — only the id is — so changing these tables renames champions
# without touching anyone's save.
#
# Collisions are resolved against the catalogue in manifest order, so the list
# the player scrolls never shows the same name twice.
# ------------------------------------------------------------------------------

const SEED: int = 0x4E414D45                    # "NAME"

const HEAD: PackedStringArray = [
	"Bal", "Bran", "Cael", "Dar", "Dro", "El", "Fen", "Gar", "Hal", "Ith",
	"Jor", "Kael", "Kor", "Lir", "Mar", "Mor", "Nar", "Oth", "Rav", "Ser",
	"Syl", "Tor", "Vand", "Ver", "Wul", "Yr", "Zeph", "Ash",
]
const MID: PackedStringArray = [
	"", "", "a", "e", "i", "o", "en", "ar", "ir", "or", "and", "eth",
]
const TAIL: PackedStringArray = [
	"dros", "rik", "wyn", "mir", "thas", "dan", "ric", "vek", "lun", "gar",
	"nis", "ras", "tion", "val", "zel", "quen", "dir", "mund",
]

## Only used when two generated names would otherwise match.
const EPITHET: PackedStringArray = [
	"the Elder", "the Younger", "the Grim", "the Bright", "the Silent",
	"the Bold", "the Lost", "the Last",
]

## id -> display name, built once per run for the whole catalogue.
static var _cache: Dictionary = {}
static var _cache_for: int = 0


## True for an id that is already a word a player can read.
static func is_authored(id: String) -> bool:
	for i in range(id.length()):
		if not (id[i] >= "a" and id[i] <= "z"):
			return false
	return id.length() >= 3


static func _invent(id: String, variant: int) -> String:
	var h: int = Rng.seed_of(SEED, id)
	var head: String = HEAD[int(Rng.hash2(h, variant, 11) % HEAD.size())]
	var mid: String = MID[int(Rng.hash2(h, variant, 13) % MID.size())]
	var tail: String = TAIL[int(Rng.hash2(h, variant, 17) % TAIL.size())]
	return head + mid + tail


## The player-facing name for one champion id.
static func of(id: String) -> String:
	if id == "":
		return ""
	if is_authored(id):
		return id.capitalize()
	var roster: PackedStringArray = HeroRig.animated_heroes()
	if _cache_for != roster.size() or _cache.is_empty():
		_build(roster)
	if _cache.has(id):
		return String(_cache[id])
	# An id outside the catalogue — a save from before the roster was gated.
	# It still gets a name; uniqueness against the catalogue is not promised.
	return _invent(id, 0)


static func _build(roster: PackedStringArray) -> void:
	_cache = {}
	_cache_for = roster.size()
	var taken: Dictionary = {}
	for id in roster:
		if is_authored(id):
			taken[id.capitalize()] = true
	for id in roster:
		if is_authored(id):
			_cache[id] = id.capitalize()
			continue
		var name: String = ""
		# Re-roll with a different variant before resorting to an epithet, so
		# most champions keep a clean single-word name.
		for variant in range(6):
			name = _invent(id, variant)
			if not taken.has(name):
				break
		if taken.has(name):
			for e in EPITHET:
				var alt: String = "%s %s" % [name, e]
				if not taken.has(alt):
					name = alt
					break
		taken[name] = true
		_cache[id] = name


## "Lysandra — Rare Mage, level 7". One line that answers every question the
## champion list is asked, used wherever a champion is referred to in prose.
static func describe(roster: Roster, id: String) -> String:
	var p: HeroProgress = roster.progress(id)
	if p == null:
		return "%s — %s, locked" % [of(id), Champion.rarity_name(id)]
	return "%s — %s %s, level %d" % [of(id), Champion.rarity_name(id),
		p.class_name_str(), p.level]
