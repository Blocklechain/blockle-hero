class_name Vfx
extends Node3D
# ------------------------------------------------------------------------------
# What an ability LOOKS like.
#
# TWO INPUTS, MULTIPLIED. The ARCHETYPE comes from the ability — a cleave is a
# sweeping arc, a nova is an expanding ring, a firebolt is a travelling core —
# so the effect always reads as the thing that is about to hit you. The
# SIGNATURE comes from the champion casting it: hue, a second hue, what the
# motes are shaped like, which way the thing spins, how heavy it is. 139
# champions times 12 actions, and no two are the same picture.
#
# The signature is derived from the champion's id by hash, never stored. That
# matters for the same reason the terrain is seeded rather than authored: a
# champion added next year gets a look without anyone drawing one, and the look
# never changes between runs, devices or players.
#
# NOTHING HERE LOADS A FILE. Every mesh is built from primitives or an
# ImmediateMesh, every material is a StandardMaterial3D with emission, and the
# motes are untextured GPUParticles3D. The project generates its art; a VFX
# folder full of PNGs would be the one place that stopped being true, and on a
# phone it is also the cheapest way to do this.
#
# Effects own their own death. Each is a Node3D that advances a normalised life
# in _process and queue_free()s itself at the end, so a caller can fire and
# forget — no pool to drain, nothing to clean up if the region is torn down
# mid-cast.
# ------------------------------------------------------------------------------

## What the motes of a champion's effects are shaped like. Chosen by hash, so
## every champion keeps the same one forever.
enum Motif { EMBER, SHARD, MOTE, RUNE, ASH, PETAL }

const MOTIF_COUNT: int = 6

## Ceiling on effects alive at once. Mid-fight a pack of nine plus the champion
## can all land in the same half-second, and forty GPUParticles3D on a phone is
## a dropped frame the player reads as the game stuttering when it gets busy.
const MAX_LIVE: int = 14

static var _live: int = 0

var _life: float = 0.0
var _age: float = 0.0
var _on_tick: Callable


# ------------------------------------------------------------------------------
# The champion's signature
# ------------------------------------------------------------------------------

## The visual fingerprint of `hero`, stable forever and derived from nothing but
## their id.
##
## School steers the palette so a mage still reads as a mage — spells cool and
## saturated, melee hot and heavy, bows pale and quick — but the hue inside that
## band, the second hue, the motif and the spin are the champion's own.
static func signature(hero: String, cls: int) -> Dictionary:
	var s: int = Rng.seed_of(0x5F17, hero)
	var school: int = HeroClass.school_of(cls)

	# Each school owns an arc of the colour wheel. Within it the champion picks
	# their own hue, so two mages are both unmistakably casting a spell and
	# unmistakably not the same mage.
	var base: float = 0.0
	var span: float = 0.0
	match school:
		HeroClass.School.SPELL:
			base = 0.50
			span = 0.33   # cyan -> violet
		HeroClass.School.RANGED:
			base = 0.18
			span = 0.22   # gold -> green
		_:
			base = 0.93
			span = 0.16   # crimson -> amber, wrapping through red

	var hue: float = fposmod(base + Rng.unit1(s, 1) * span, 1.0)
	# The second hue is a step, not a jump. The first pass spread it up to a
	# third of the wheel away, which put green sparks on an orange slash —
	# two elements in one attack rather than one attack with a hot core. Close
	# enough to read as the same fire, far enough not to be one muddy tone.
	var hue2: float = fposmod(hue + 0.035 + Rng.unit1(s, 2) * 0.055, 1.0)

	return {
		"primary": Color.from_hsv(hue, 0.72, 1.0),
		# Paler and brighter, not just a different angle: the secondary is the
		# core of the effect and cores are hotter than their edges.
		"secondary": Color.from_hsv(hue2, 0.34, 1.0),
		"motif": int(Rng.unit1(s, 3) * float(MOTIF_COUNT)) % MOTIF_COUNT,
		# Which way rings and arcs rotate. Half the roster sweeps the other way,
		# which is more legible in motion than any colour difference.
		"spin": 1.0 if Rng.unit1(s, 4) < 0.5 else -1.0,
		# Heavier champions throw slower, wider, fewer, bigger motes.
		"weight": Rng.range2(s, 5, 0, 0.75, 1.3),
		"motes": int(Rng.range2(s, 6, 0, 14.0, 30.0)),
	}


## What each element looks like. A mage's SCHOOL hue is their own, but their
## ELEMENT is the thing the player has to read off a spell in flight — frost
## has to look cold whoever is casting it, or the status it applies is a
## surprise every time.
##
## The champion's signature still decides the motif, the spin, the weight and
## the second hue, so two Frost mages are both obviously frost and still
## obviously not each other.
const ELEMENT_HUE: Dictionary = {
	MageSpells.Element.FIRE: 0.045,       # orange-red
	MageSpells.Element.FROST: 0.545,      # pale cyan
	MageSpells.Element.STORM: 0.70,       # violet-white
	MageSpells.Element.SHADOW: 0.78,      # deep purple
	MageSpells.Element.ARCANE: 0.62,      # indigo
	MageSpells.Element.VENOM: 0.26,       # sick green
	MageSpells.Element.RADIANCE: 0.13,    # gold
}

## How saturated each element reads. Radiance and storm are nearly white-hot;
## venom and shadow are thick.
const ELEMENT_SAT: Dictionary = {
	MageSpells.Element.FIRE: 0.82,
	MageSpells.Element.FROST: 0.55,
	MageSpells.Element.STORM: 0.38,
	MageSpells.Element.SHADOW: 0.80,
	MageSpells.Element.ARCANE: 0.70,
	MageSpells.Element.VENOM: 0.88,
	MageSpells.Element.RADIANCE: 0.42,
}


## `sig` recoloured for a spell's element, or unchanged for anything that has
## none. The motif, spin and weight survive — only the palette moves.
static func _elemental(sig: Dictionary, element: int) -> Dictionary:
	if element < 0 or not ELEMENT_HUE.has(element):
		return sig
	var out: Dictionary = sig.duplicate()
	var hue: float = float(ELEMENT_HUE[element])
	var sat: float = float(ELEMENT_SAT[element])
	# The champion still nudges the hue, so one Fire mage is not another.
	var own: float = sig["primary"].h
	var nudge: float = (fposmod(own, 0.08) - 0.04) * 0.9
	out["primary"] = Color.from_hsv(fposmod(hue + nudge, 1.0), sat, 1.0)
	out["secondary"] = Color.from_hsv(
		fposmod(hue + nudge + 0.07, 1.0), sat * 0.65, 1.0)
	return out


## The mesh one mote is drawn with. This is the motif, and it is why two
## champions with a similar hue still do not look alike.
static func _mote_mesh(motif: int, scale: float) -> Mesh:
	match motif:
		Motif.SHARD:
			var shard := PrismMesh.new()
			shard.size = Vector3(0.09, 0.26, 0.09) * scale
			return shard
		Motif.MOTE:
			var mote := SphereMesh.new()
			mote.radius = 0.055 * scale
			mote.height = 0.11 * scale
			mote.radial_segments = 6
			mote.rings = 3
			return mote
		Motif.RUNE:
			var rune := BoxMesh.new()
			rune.size = Vector3(0.14, 0.14, 0.02) * scale
			return rune
		Motif.ASH:
			var ash := BoxMesh.new()
			ash.size = Vector3(0.05, 0.05, 0.05) * scale
			return ash
		Motif.PETAL:
			var petal := QuadMesh.new()
			petal.size = Vector2(0.20, 0.09) * scale
			return petal
		_:  # EMBER
			var ember := QuadMesh.new()
			ember.size = Vector2(0.07, 0.19) * scale
			return ember


# ------------------------------------------------------------------------------
# Materials
# ------------------------------------------------------------------------------

## Additive, unshaded, depth-writing off: effects have to glow through the fog
## and over each other rather than be lit like geometry.
static func _glow(c: Color, energy: float = 2.2,
		double_sided: bool = true) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED if double_sided \
		else BaseMaterial3D.CULL_BACK
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	m.disable_receive_shadows = true
	m.no_depth_test = false
	# WITHOUT THIS the per-vertex colours an ImmediateMesh writes are ignored
	# and the arc fills as one flat opaque wedge — the fade from the blade edge
	# out to nothing, which is the entire reason it is built vertex by vertex
	# rather than as a cone primitive, simply does not appear.
	m.vertex_color_use_as_albedo = true
	return m


# ------------------------------------------------------------------------------
# Lifetime
# ------------------------------------------------------------------------------

func _init(life: float = 0.6) -> void:
	_life = maxf(life, 0.05)


func _process(delta: float) -> void:
	_age += delta
	var t: float = clampf(_age / _life, 0.0, 1.0)
	if not _on_tick.is_null():
		_on_tick.call(self, t)
	if _age >= _life:
		queue_free()


func _exit_tree() -> void:
	_live = maxi(_live - 1, 0)


# ------------------------------------------------------------------------------
# The one entry point
# ------------------------------------------------------------------------------

## Play `ability` cast by `hero` at `origin`, facing `facing` radians, aimed at
## `target` (ground coordinates). Returns the effect, or null if it was skipped.
##
## SKIPPING IS NORMAL, not a failure: past MAX_LIVE the newest effect is
## dropped. A fight that is already a wall of light loses nothing by one more
## arc it would have drawn on top of nine others, and the frame rate is worth
## more than that arc.
static func play(parent: Node, ability: Ability, hero: String, cls: int,
		origin: Vector2, facing: float, target: Vector2,
		ground_y: float = 0.0) -> Vfx:
	if parent == null or ability == null or not parent.is_inside_tree():
		return null
	if _live >= MAX_LIVE:
		return null

	var sig: Dictionary = signature(hero, cls)
	var fx: Vfx = _build(ability, sig, origin, facing, target)
	if fx == null:
		return null

	# ONTO THE GROUND THE FIGHT IS ON. Every archetype builds itself around an
	# absolute Y — 0.06 for a ground ring, 1.15 for a bolt leaving the hand —
	# because it only knows the caster's position as a Vector2 of x and z.
	# The champion stands at terrain.height_at(), which is metres above sea
	# level nearly everywhere, so the entire effects system was rendering
	# UNDERNEATH the world. It fired, it animated, it freed itself on time,
	# and no player ever saw any of it.
	fx.position.y += ground_y

	_live += 1
	parent.add_child(fx)
	return fx


## Archetype by ability id first, then by shape.
##
## The id branch is what makes the nine named abilities distinct from each
## other; the shape fallback is what makes a tenth ability added later still
## look like something rather than nothing. A missing effect must never be an
## invisible attack.
static func _build(ability: Ability, sig: Dictionary, origin: Vector2,
		facing: float, target: Vector2) -> Vfx:
	match ability.id:
		"cleave":
			return _arc_sweep(sig, origin, facing, ability.range_m,
				ability.arc_degrees, 0.42)
		"shield_slam":
			return _shockwave(sig, origin, ability.range_m, true)
		"rally":
			return _pillar(sig, origin)
		"volley":
			return _fan(sig, origin, facing, ability.range_m,
				ability.arc_degrees)
		"pin":
			return _tracer(sig, origin, target)
		"evade":
			return _ghost(sig, origin, facing)
		"firebolt":
			return _bolt(sig, origin, target)
		"frost_nova":
			return _nova(sig, origin, ability.range_m)
		"ward":
			return _dome(sig, origin)

	# MAGE SPELLS ARE ROLLED, NOT NAMED. Every mage's three spells have ids
	# like "g044_s1", so the id branch above can never match them — and before
	# this they all fell through to the generic shape fallback, which drew a
	# Venom chain and a Frost nova as the same ring. The form is the archetype
	# and the element is the palette, which is 7 x 7 distinct spells on top of
	# the champion's own signature.
	if ability.form >= 0:
		return _spell(ability, sig, origin, facing, target)

	# The basic attacks and anything added later.
	match ability.shape:
		Ability.Shape.ARC:
			return _arc_sweep(sig, origin, facing, ability.range_m,
				ability.arc_degrees, 0.26)
		Ability.Shape.CIRCLE:
			return _nova(sig, origin, ability.range_m)
		Ability.Shape.SELF:
			return _dome(_elemental(sig, ability.element), origin)
		_:
			# A single-target hit at range is a tracer; in your face it is a
			# short spark, which _tracer degrades to on its own.
			return _tracer(sig, origin, target)


## A rolled mage spell: form picks the shape it arrives in, element the colour.
static func _spell(ability: Ability, sig: Dictionary, origin: Vector2,
		facing: float, target: Vector2) -> Vfx:
	var e: Dictionary = _elemental(sig, ability.element)
	match ability.form:
		MageSpells.Form.BOLT:
			return _bolt(e, origin, target)
		MageSpells.Form.ORB:
			# Slower and fatter than a bolt, and it lingers where it lands.
			var orb: Vfx = _bolt(e, origin, target)
			orb._life = 0.75
			return orb
		MageSpells.Form.LANCE:
			# A narrow spear of it: the arc is 25 degrees, so a thin sweep
			# reads as a line punched through a rank rather than a swing.
			return _arc_sweep(e, origin, facing, ability.range_m,
				maxf(ability.arc_degrees, 12.0), 0.34)
		MageSpells.Form.CONE:
			return _arc_sweep(e, origin, facing, ability.range_m,
				ability.arc_degrees, 0.5)
		MageSpells.Form.NOVA:
			return _nova(e, origin, ability.range_m)
		MageSpells.Form.STORM:
			# Weather, not a blast: a column over the ground it covers.
			return _pillar(e, target if target != Vector2.INF else origin)
		MageSpells.Form.CHAIN:
			return _fan(e, origin, facing, ability.range_m,
				maxf(ability.arc_degrees, 30.0))
	return _nova(e, origin, maxf(ability.range_m, 3.0))


# ------------------------------------------------------------------------------
# Archetypes
# ------------------------------------------------------------------------------

## A blade sweeping through a cone: a ribbon that grows along the arc, brightens
## at its leading edge and fades from the tail.
static func _arc_sweep(sig: Dictionary, at: Vector2, facing: float,
		reach: float, degrees: float, life: float) -> Vfx:
	var fx := Vfx.new(life)
	fx.position = Vector3(at.x, 0.9, at.y)

	var mi := MeshInstance3D.new()
	var mesh := ImmediateMesh.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = _glow(sig["primary"], 2.6)
	mi.material_override = mat
	fx.add_child(mi)

	var spin: float = sig["spin"]
	var half: float = deg_to_rad(degrees) * 0.5
	var inner: float = reach * 0.30
	fx._on_tick = func(_n: Vfx, t: float) -> void:
		# The sweep is the arc being DRAWN, not an arc appearing: at t=0 it is a
		# sliver at the leading edge, at t=1 the whole cone has been cut.
		mesh.clear_surfaces()
		var steps: int = 14
		var from: float = -half * spin
		var to: float = lerpf(-half, half, t) * spin
		mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
		for i in range(steps + 1):
			var a: float = facing + lerpf(from, to, float(i) / float(steps))
			var d := Vector3(sin(a), 0.0, cos(a))
			mesh.surface_set_color(Color(1, 1, 1, 1.0 - t))
			mesh.surface_add_vertex(d * inner)
			mesh.surface_set_color(Color(1, 1, 1, 0.0))
			mesh.surface_add_vertex(d * reach)
		mesh.surface_end()
		mat.albedo_color = Color(sig["primary"], 1.0 - t)
		mat.emission_energy_multiplier = lerpf(3.4, 0.2, t)

	fx.add_child(_motes(sig, 0.8, reach * 0.5, 1.1))
	return fx


## An impact: a flat ring racing outward across the ground, with a dust kick at
## the centre if it landed hard.
static func _shockwave(sig: Dictionary, at: Vector2, radius: float,
		heavy: bool) -> Vfx:
	var fx := Vfx.new(0.5)
	fx.position = Vector3(at.x, 0.06, at.y)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.80
	torus.outer_radius = 1.0
	torus.rings = 20
	torus.ring_segments = 6
	ring.mesh = torus
	# NO ROTATION. A TorusMesh already lies flat in the XZ plane, so the
	# "flatten it" rotation this used to carry stood the ring UP — a shockwave
	# drawn as a vertical hoop arching over the caster's head.
	var mat: StandardMaterial3D = _glow(sig["primary"], 3.0)
	ring.material_override = mat
	fx.add_child(ring)

	var grow: float = radius * (1.25 if heavy else 1.0)
	fx._on_tick = func(_n: Vfx, t: float) -> void:
		var e: float = 1.0 - pow(1.0 - t, 3.0)   # fast out, settling
		ring.scale = Vector3(grow * e, 1.0 + 3.0 * t, grow * e)
		mat.albedo_color = Color(sig["primary"], 1.0 - e)
		mat.emission_energy_multiplier = lerpf(3.6, 0.0, e)

	if heavy:
		fx.add_child(_motes(sig, 1.2, 1.6, 1.4, Vector3(0, 2.4, 0)))
	return fx


## A column of light from the ground up: the shout, the rally, the heal.
static func _pillar(sig: Dictionary, at: Vector2) -> Vfx:
	var fx := Vfx.new(0.85)
	fx.position = Vector3(at.x, 0.0, at.y)

	var col := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.95
	cyl.bottom_radius = 1.25
	cyl.height = 1.0
	cyl.radial_segments = 14
	cyl.rings = 1
	col.mesh = cyl
	var mat: StandardMaterial3D = _glow(sig["secondary"], 2.4)
	col.material_override = mat
	fx.add_child(col)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.0
	torus.rings = 18
	torus.ring_segments = 5
	ring.mesh = torus
	var rmat: StandardMaterial3D = _glow(sig["primary"], 3.0)
	ring.material_override = rmat
	fx.add_child(ring)

	fx._on_tick = func(_n: Vfx, t: float) -> void:
		var h: float = lerpf(0.4, 3.6, sqrt(t))
		col.scale = Vector3(1.0 - 0.45 * t, h, 1.0 - 0.45 * t)
		col.position.y = h * 0.5
		mat.albedo_color = Color(sig["secondary"], (1.0 - t) * 0.75)
		ring.scale = Vector3(1.0 + 1.4 * t, 1.0, 1.0 + 1.4 * t)
		ring.position.y = 0.05
		rmat.albedo_color = Color(sig["primary"], 1.0 - t)

	# Rising, not scattering — the one effect whose motes go up.
	fx.add_child(_motes(sig, 1.0, 0.9, 1.0, Vector3(0, 3.0, 0)))
	return fx


## Many shots at once, spread across the cone.
static func _fan(sig: Dictionary, at: Vector2, facing: float, reach: float,
		degrees: float) -> Vfx:
	var fx := Vfx.new(0.55)
	fx.position = Vector3(at.x, 1.1, at.y)

	var shots: Array[MeshInstance3D] = []
	var angles: PackedFloat32Array = PackedFloat32Array()
	var half: float = deg_to_rad(degrees) * 0.5
	var n: int = 7
	var mat: StandardMaterial3D = _glow(sig["primary"], 3.2, false)
	for i in range(n):
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.05, 0.05, 1.5)
		mi.mesh = box
		mi.material_override = mat
		fx.add_child(mi)
		shots.append(mi)
		angles.append(facing + lerpf(-half, half, float(i) / float(n - 1)))

	fx._on_tick = func(_n: Vfx, t: float) -> void:
		var e: float = 1.0 - pow(1.0 - t, 2.0)
		for i in range(shots.size()):
			var a: float = angles[i]
			# Staggered: a volley loosed as one solid wall reads as a single
			# wide object rather than seven arrows.
			var lead: float = clampf(e * 1.25 - float(i % 3) * 0.12, 0.0, 1.0)
			var d := Vector3(sin(a), 0.0, cos(a))
			shots[i].position = d * (reach * lead)
			shots[i].rotation.y = a
			shots[i].scale.z = 1.0 + 1.6 * lead
		mat.albedo_color = Color(sig["primary"], 1.0 - t * t)

	return fx


## A single shot, there and gone: a line from caster to target that brightens,
## lands, and sparks.
static func _tracer(sig: Dictionary, from: Vector2, to: Vector2) -> Vfx:
	var fx := Vfx.new(0.3)
	fx.position = Vector3(from.x, 1.1, from.y)

	var span := Vector3(to.x - from.x, 0.0, to.y - from.y)
	# Degenerate aim (no target, or standing inside them) still has to produce
	# something: a short stab along nothing is better than an invisible hit.
	if span.length() < 0.4:
		span = Vector3(0, 0, 1) * 1.2

	var line := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.07, 0.07, span.length())
	line.mesh = box
	var mat: StandardMaterial3D = _glow(sig["primary"], 3.8, false)
	line.material_override = mat
	# An explicit basis rather than look_at(). look_at() wants a node that is
	# already in the tree AND a point in GLOBAL space; given a local offset it
	# errors and leaves the tracer lying along +Z whatever it was aimed at.
	# Building the basis has neither dependency, so this is correct at any
	# point in the node's life.
	line.transform = Transform3D(
		Basis.looking_at(span, Vector3.UP), span * 0.5)
	fx.add_child(line)

	var spark := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.16
	sph.height = 0.32
	sph.radial_segments = 8
	sph.rings = 4
	spark.mesh = sph
	spark.position = span
	var smat: StandardMaterial3D = _glow(sig["secondary"], 4.0)
	spark.material_override = smat
	fx.add_child(spark)

	fx._on_tick = func(_n: Vfx, t: float) -> void:
		mat.albedo_color = Color(sig["primary"], 1.0 - t)
		var pop: float = sin(clampf(t, 0.0, 1.0) * PI)
		spark.scale = Vector3.ONE * (0.5 + 1.8 * pop)
		smat.albedo_color = Color(sig["secondary"], pop)

	return fx


## The champion was here a moment ago: a receding afterimage for a dash.
static func _ghost(sig: Dictionary, at: Vector2, facing: float) -> Vfx:
	var fx := Vfx.new(0.45)
	fx.position = Vector3(at.x, 0.95, at.y)

	var shells: Array[MeshInstance3D] = []
	var mat: StandardMaterial3D = _glow(sig["secondary"], 1.8)
	for i in range(4):
		var mi := MeshInstance3D.new()
		var caps := CapsuleMesh.new()
		caps.radius = 0.32
		caps.height = 1.7
		caps.radial_segments = 8
		caps.rings = 2
		mi.mesh = caps
		mi.material_override = mat
		mi.position = Vector3(sin(facing), 0.0, cos(facing)) * (-0.45 * float(i))
		fx.add_child(mi)
		shells.append(mi)

	fx._on_tick = func(_n: Vfx, t: float) -> void:
		mat.albedo_color = Color(sig["secondary"], (1.0 - t) * 0.42)
		for i in range(shells.size()):
			shells[i].scale = Vector3.ONE * (1.0 - 0.14 * float(i) - 0.2 * t)

	return fx


## A travelling core that arrives and bursts.
static func _bolt(sig: Dictionary, from: Vector2, to: Vector2) -> Vfx:
	var fx := Vfx.new(0.5)
	fx.position = Vector3(from.x, 1.15, from.y)

	var span := Vector3(to.x - from.x, 0.0, to.y - from.y)
	if span.length() < 0.4:
		span = Vector3(0, 0, 1) * 1.5

	var core := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.22
	sph.height = 0.44
	sph.radial_segments = 10
	sph.rings = 5
	core.mesh = sph
	var mat: StandardMaterial3D = _glow(sig["primary"], 3.6)
	core.material_override = mat
	fx.add_child(core)

	var halo := MeshInstance3D.new()
	halo.mesh = sph
	var hmat: StandardMaterial3D = _glow(sig["secondary"], 2.0)
	halo.material_override = hmat
	core.add_child(halo)

	var spin: float = sig["spin"]
	fx._on_tick = func(_n: Vfx, t: float) -> void:
		# Travel for the first two thirds, bloom for the last.
		var fly: float = clampf(t / 0.66, 0.0, 1.0)
		core.position = span * fly
		core.rotation.y = t * TAU * 2.0 * spin
		if t < 0.66:
			core.scale = Vector3.ONE
			halo.scale = Vector3.ONE * (1.7 + 0.3 * sin(t * 40.0))
			hmat.albedo_color = Color(sig["secondary"], 0.5)
		else:
			var b: float = (t - 0.66) / 0.34
			core.scale = Vector3.ONE * (1.0 + 4.5 * b)
			halo.scale = Vector3.ONE * (1.7 + 2.0 * b)
			mat.albedo_color = Color(sig["primary"], 1.0 - b)
			hmat.albedo_color = Color(sig["secondary"], (1.0 - b) * 0.5)

	return fx


## Everything around the caster, at once: the ring that defines a nova.
static func _nova(sig: Dictionary, at: Vector2, radius: float) -> Vfx:
	var fx := Vfx.new(0.65)
	fx.position = Vector3(at.x, 0.08, at.y)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.86
	torus.outer_radius = 1.0
	torus.rings = 24
	torus.ring_segments = 6
	ring.mesh = torus
	var mat: StandardMaterial3D = _glow(sig["primary"], 3.2)
	ring.material_override = mat
	fx.add_child(ring)

	# A second ring a beat behind the first. One ring is a shockwave; two is a
	# nova, and it costs one more draw call to say so.
	var inner := MeshInstance3D.new()
	inner.mesh = torus
	var imat: StandardMaterial3D = _glow(sig["secondary"], 2.6)
	inner.material_override = imat
	fx.add_child(inner)

	var spin: float = sig["spin"]
	fx._on_tick = func(_n: Vfx, t: float) -> void:
		var e: float = 1.0 - pow(1.0 - t, 2.4)
		ring.scale = Vector3(radius * e, 1.0 + 2.0 * t, radius * e)
		ring.rotation.y = t * spin * 1.2
		mat.albedo_color = Color(sig["primary"], 1.0 - e)
		var e2: float = 1.0 - pow(1.0 - clampf(t * 1.45 - 0.25, 0.0, 1.0), 2.4)
		inner.scale = Vector3(radius * e2 * 0.8, 1.0, radius * e2 * 0.8)
		inner.rotation.y = -t * spin * 1.6
		imat.albedo_color = Color(sig["secondary"], (1.0 - e2) * 0.8)

	fx.add_child(_motes(sig, 1.4, radius * 0.55, 1.2))
	return fx


## A shell around the caster: wards, buffs, anything that protects.
static func _dome(sig: Dictionary, at: Vector2) -> Vfx:
	var fx := Vfx.new(0.8)
	fx.position = Vector3(at.x, 1.0, at.y)

	var shell := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 1.25
	sph.height = 2.5
	sph.radial_segments = 16
	sph.rings = 8
	shell.mesh = sph
	var mat: StandardMaterial3D = _glow(sig["primary"], 1.6)
	shell.material_override = mat
	fx.add_child(shell)

	var spin: float = sig["spin"]
	fx._on_tick = func(_n: Vfx, t: float) -> void:
		# Snaps out, breathes, fades. A shield that fades linearly reads as a
		# bubble deflating rather than a ward being raised.
		var pop: float = clampf(t / 0.22, 0.0, 1.0)
		var s: float = lerpf(0.25, 1.0, pop) * (1.0 + 0.05 * sin(t * 18.0))
		shell.scale = Vector3.ONE * s
		shell.rotation.y = t * spin * 2.0
		mat.albedo_color = Color(sig["primary"], (1.0 - t * t) * 0.42)
		mat.emission_energy_multiplier = lerpf(2.4, 0.4, t)

	fx.add_child(_motes(sig, 0.9, 1.25, 0.9, Vector3(0, 0.8, 0)))
	return fx


# ------------------------------------------------------------------------------
# Motes
# ------------------------------------------------------------------------------

## The champion's motif, thrown outward. This is the layer that carries the
## signature most visibly — the ring colour tells you which school, the motes
## tell you which champion.
static func _motes(sig: Dictionary, amount: float, spread: float,
		speed: float, gravity: Vector3 = Vector3(0, -3.0, 0)) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	var weight: float = sig["weight"]
	p.amount = maxi(int(float(sig["motes"]) * amount / weight), 6)
	p.lifetime = 0.55 * weight
	p.one_shot = true
	p.explosiveness = 0.92
	p.draw_pass_1 = _mote_mesh(int(sig["motif"]), weight)

	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	m.emission_sphere_radius = maxf(spread * 0.35, 0.2)
	m.direction = Vector3(0, 0.35, 0)
	m.spread = 72.0
	m.initial_velocity_min = 2.0 * speed / weight
	m.initial_velocity_max = 5.5 * speed / weight
	m.gravity = gravity
	m.scale_min = 0.6
	m.scale_max = 1.5
	m.angular_velocity_min = -220.0
	m.angular_velocity_max = 220.0
	m.color = sig["secondary"]
	p.process_material = m
	p.material_override = _glow(sig["secondary"], 2.4)
	p.emitting = true
	return p
