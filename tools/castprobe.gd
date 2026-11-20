extends Node3D
# Probe: instantiate the real Play scene and interrogate the live
# HeroController about what use_ability() actually plays.

var _play: Node3D

func _ready() -> void:
	var hero: String = ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		hero = args[0]
	_play = load("res://scenes/Play.tscn").instantiate()
	_play.hero = hero
	add_child(_play)
	var waited: float = 0.0
	while _play._hero == null and waited < 90.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var h: HeroController = _play._hero
	print("hero=", h.rig.hero_name, " rigged=", h.rig.is_rigged)
	print("controller.abilities.size()=", h.abilities.size())
	for a in h.abilities:
		print("   slot=", a.slot, " id=", a.id, " anim_state=", a.anim_state())
	print("rig._clip_for=", h.rig._clip_for)
	for slot in range(0, 4):
		var ab: Ability = h.ability_in_slot(slot)
		print("ability_in_slot(%d) = %s" % [slot, ab.id if ab != null else "<null>"])
		h._busy_until = 0.0
		h.pending_cast = null
		h._cooldowns.clear()
		h.rig.set_state(HeroRig.State.IDLE, true)
		await get_tree().process_frame
		var ok: bool = h.use_ability(slot)
		var st: int = h.rig.state()
		print("   use_ability(%d)=%s  rig.state=%d  clip='%s' len=%.2f" % [
			slot, ok, st, h.rig._anim.current_animation,
			h.rig._anim.current_animation_length])
	get_tree().quit()
