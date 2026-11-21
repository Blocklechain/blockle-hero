extends SceneTree
# Photographs every ability, mid-flight, against a dark ground — so the effects
# can be LOOKED at. A headless test can prove an effect has meshes in it and
# still not notice it is a grey smear.
#
#   godot --path . --script tools/vfxshot.gd        (needs a display)
#
# Writes tools/out/vfx/<hero>_<ability>.png.

const OUT: String = "res://tools/out/vfx"
## Where in the effect's life to capture. Early enough that nothing has faded,
## late enough that travelling effects have travelled.
const AT: float = 0.45


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var root := Node3D.new()
	get_root().add_child(root)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.03, 0.035, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.2, 0.22, 0.3)
	e.glow_enabled = true
	e.glow_intensity = 0.9
	e.glow_bloom = 0.25
	env.environment = e
	root.add_child(env)

	var cam := Camera3D.new()
	# Three-quarter view DOWN THE LINE OF FIRE, not into it. Effects are cast
	# from the origin toward +Z, so a camera on +Z watches them come straight
	# at the lens and most of the frame is the first half-metre.
	cam.position = Vector3(11.0, 7.0, -4.5)
	cam.current = true
	root.add_child(cam)
	# After parenting: look_at needs the node in a tree.
	cam.look_at(Vector3(0.0, 1.0, 3.5), Vector3.UP)

	# A floor, so ground effects have something to sit on.
	var floor_mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	floor_mi.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.07, 0.08, 0.1)
	floor_mi.material_override = fm
	root.add_child(floor_mi)

	var roster: PackedStringArray = HeroRig.animated_heroes()
	# Three champions of the same class as well as one of each: the point of
	# the system is that two fighters do NOT look alike, and that only shows
	# when two fighters are photographed.
	var picks: Array = []
	for cls in [HeroClass.Kind.FIGHTER, HeroClass.Kind.RANGER,
			HeroClass.Kind.MAGE]:
		var found: int = 0
		for h in roster:
			if HeroClass.for_hero(h) == cls:
				picks.append([h, cls])
				found += 1
				if found >= 2:
					break

	for pick in picks:
		var who: String = pick[0]
		var cls: int = pick[1]
		var kit: Array[Ability] = [Ability.basic_attack(cls)]
		kit.append_array(Ability.for_hero(who, cls))
		for ab in kit:
			var fx: Vfx = Vfx.play(root, ab, who, cls,
				Vector2.ZERO, 0.0, Vector2(0.0, 7.0))
			if fx == null:
				print("  SKIPPED %s/%s (cap)" % [who, ab.id])
				continue
			# Drive the effect by hand to a fixed point in its life, so the
			# capture is the same frame every run rather than whatever the
			# scheduler happened to deliver.
			fx._process(fx._life * AT)
			await process_frame
			await process_frame
			var img: Image = get_root().get_texture().get_image()
			img.save_png(ProjectSettings.globalize_path(
				"%s/%s_%s.png" % [OUT, who, ab.id]))
			print("  %s / %-12s  motif=%d" % [who, ab.id,
				int(Vfx.signature(who, cls)["motif"])])
			fx.queue_free()
			await process_frame

	quit(0)
