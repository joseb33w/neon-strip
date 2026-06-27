class_name Interiors extends Node3D
## Enterable venue interiors. On enter we save the player's world position, PAUSE chunk streaming,
## build a self-contained interior at a far offset, and teleport the player in. Casino + club are
## TWO floors joined by a ramp-stair AND a working elevator (step in, pick a floor, it carries you).
## The fair is open-air with a rotating, rideable Ferris wheel. Exit restores the city in place.
## Interior NPCs reuse the template InteractionSystem (talk + LLM dialogue); slot/blackjack/elevator/
## ride/exit are interior "specials" handled here.

const OFFSETS := {
	"casino": Vector3(2000, 0, 0),
	"club": Vector3(2400, 0, 0),
	"fair": Vector3(2800, 0, 0),
}
const FLOOR_H := 5.0
const VENUE_NAMES := {"casino": "Lucky Star Casino", "club": "Club Mirage", "fair": "Neon Pier Fair"}

var player: CharacterBody3D
var rpg: RpgState
var interaction: InteractionSystem
var casino: CasinoGames
var main_ref: Node
var chunk_manager: ChunkManager

var inside := false
var venue := ""
var root: Node3D = null
var return_pos := Vector3.ZERO

var specials: Array = []          # [{kind, pos:Vector3, label, data}]
var prompt: Label

# elevator
var elev_platform: Node3D
var elev_panel: CanvasLayer
var _elev_travel := false
var _elev_from := 0.0
var _elev_to := 0.0
var _elev_t := 0.0

# ferris ride
var ferris: Node3D
var ferris_pod: Node3D
var _riding := false
var _ride_t := 0.0


func setup(p: CharacterBody3D, state: RpgState, inter: InteractionSystem, cas: CasinoGames, mainref: Node, cm: ChunkManager, hud: CanvasLayer) -> void:
	player = p
	rpg = state
	interaction = inter
	casino = cas
	main_ref = mainref
	chunk_manager = cm
	prompt = Label.new()
	prompt.add_theme_font_size_override("font_size", 26)
	prompt.add_theme_color_override("font_color", Color(0.5, 1.0, 0.9))
	prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt.position = Vector2(-180, -320)
	prompt.visible = false
	hud.add_child(prompt)
	_build_elev_panel(hud)
	set_process(true)


func busy() -> bool:
	# freeze normal walking while a modal/elevator/ride is active
	return _elev_travel or _riding or (elev_panel and elev_panel.visible) or (casino and casino.is_open())


# ---------------- enter / exit ----------------

func enter(venue_id: String) -> void:
	if inside or not OFFSETS.has(venue_id):
		return
	return_pos = player.global_position
	venue = venue_id
	inside = true
	chunk_manager.paused = true
	specials.clear()
	root = Node3D.new()
	add_child(root)
	var first_visit := rpg.discover(venue_id)
	match venue_id:
		"casino": _build_casino()
		"club": _build_club()
		"fair": _build_fair()
	player.velocity = Vector3.ZERO
	if main_ref.has_method("set_inside"):
		main_ref.set_inside(true)
	AudioManager.play_sfx("door")
	if first_visit:
		AudioManager.play_sfx("success" if AudioManager.has_sfx("success") else "pickup")


func exit() -> void:
	if not inside:
		return
	if root and is_instance_valid(root):
		root.queue_free()
	root = null
	interaction.remove_cell("interior")
	specials.clear()
	prompt.visible = false
	chunk_manager.paused = false
	player.global_position = return_pos
	player.velocity = Vector3.ZERO
	inside = false
	venue = ""
	ferris = null
	ferris_pod = null
	elev_platform = null
	if main_ref.has_method("set_inside"):
		main_ref.set_inside(false)
	AudioManager.play_sfx("door")


# ---------------- USE ----------------

func try_use() -> void:
	if busy():
		return
	var it = _nearest_special(3.2)
	if it == null:
		interaction.try_use()   # fall through to interior NPC talk
		return
	match it.kind:
		"exit": exit()
		"slots": casino.open_slots()
		"blackjack": casino.open_blackjack()
		"elevator": _open_elev_panel()
		"ride": _start_ride()


func _nearest_special(rng: float):
	var best = null
	var bd := rng
	for it in specials:
		var d: float = player.global_position.distance_to(it.pos)
		if d < bd:
			bd = d
			best = it
	return best


func _process(delta: float) -> void:
	if not inside:
		return
	# proximity prompt for interior specials
	var it = _nearest_special(3.2)
	if it != null and not busy():
		prompt.text = "USE  >  " + String(it.label)
		prompt.visible = true
	else:
		prompt.visible = false
	# rotate the ferris wheel
	if ferris and is_instance_valid(ferris):
		ferris.rotation.z += delta * 0.35
	# elevator travel
	if _elev_travel:
		_elev_t += delta * 0.5
		var y := lerpf(_elev_from, _elev_to, clampf(_elev_t, 0.0, 1.0))
		if elev_platform and is_instance_valid(elev_platform):
			elev_platform.position.y = y
		player.global_position.y = y + 0.05
		player.velocity = Vector3.ZERO
		if _elev_t >= 1.0:
			_elev_travel = false
	# ferris ride: lift the player around an arc then set down
	if _riding:
		_ride_t += delta * 0.32
		var ang := lerpf(-PI * 0.5, PI * 1.5, clampf(_ride_t, 0.0, 1.0))
		var c: Vector3 = OFFSETS[venue] + Vector3(0, 9.0, -8.0)
		player.global_position = c + Vector3(0, sin(ang) * 8.5, cos(ang) * 8.5)
		player.velocity = Vector3.ZERO
		if _ride_t >= 1.0:
			_riding = false
			player.global_position = OFFSETS[venue] + Vector3(3.5, 0.1, 2.0)


# ---------------- build helpers ----------------

func _mat(c: Color, rough := 0.85, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _slab(center: Vector3, size: Vector3, color: Color, solid := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color)
	mi.position = center
	root.add_child(mi)
	if solid:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.position = center
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		cs.shape = bs
		body.add_child(cs)
		root.add_child(body)
	return mi


func _ramp(base: Vector3, top: Vector3, width: float, color: Color) -> void:
	# a tilted box bridging base(y0) -> top(y1) the player can walk up/down
	var mid := (base + top) * 0.5
	var run := Vector2(top.x - base.x, top.z - base.z).length()
	var rise := top.y - base.y
	var length := sqrt(run * run + rise * rise) + 0.6
	var angle := atan2(rise, run)
	var dir := Vector3(top.x - base.x, 0, top.z - base.z).normalized()
	var yaw := atan2(dir.x, dir.z)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(width, 0.4, length)
	mi.mesh = bm
	mi.material_override = _mat(color)
	mi.position = mid
	mi.rotation = Vector3(angle, yaw, 0)
	root.add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = mid
	body.rotation = Vector3(angle, yaw, 0)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(width, 0.4, length)
	cs.shape = bs
	body.add_child(cs)
	root.add_child(body)


func _light(pos: Vector3, color: Color, energy := 3.0, rng := 14.0) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = rng
	root.add_child(l)


func _add_npc(pos: Vector3, id: String, nm: String, persona: String, lines: Array, ped: String, sound := "chatter") -> void:
	var model: Node = null
	var path := "res://models/%s.glb" % ped
	if ResourceLoader.exists(path):
		model = (load(path) as PackedScene).instantiate()
		if model is Node3D:
			Neon.tint_solid(model, Color.from_hsv(randf(), 0.5, 0.9))
	interaction.set_area_parent(root)
	interaction.add_npc(pos, id, nm, persona, lines, model, root, "interior", sound)


func _special(kind: String, pos: Vector3, label: String) -> void:
	specials.append({kind = kind, pos = pos, label = label})


func _box_prop(center: Vector3, size: Vector3, color: Color, emissive := false, energy := 3.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = Neon.emissive(color, energy) if emissive else _mat(color, 0.6, 0.2)
	mi.position = center
	root.add_child(mi)
	return mi


# ---------------- CASINO (2 floors) ----------------

func _build_casino() -> void:
	var O: Vector3 = OFFSETS["casino"]
	var carpet := Color(0.18, 0.05, 0.10)
	_slab(O + Vector3(0, -0.5, 0), Vector3(28, 1, 28), carpet)
	_outer_walls(O, 28, 28, Color(0.10, 0.04, 0.12))
	# floor 1 is a back balcony (z -13..-3); front stays a double-height atrium
	_slab(O + Vector3(0, FLOOR_H, -8), Vector3(28, 0.6, 10), Color(0.14, 0.06, 0.16))
	_outer_rail(O + Vector3(0, FLOOR_H + 0.5, -3), 16, Color(0.9, 0.2, 0.5))
	# stairs from the front atrium up onto the balcony (left side)
	_ramp(O + Vector3(-11, 0, 6.0), O + Vector3(-11, FLOOR_H + 0.3, -4.0), 3.0, Color(0.3, 0.1, 0.2))
	# elevator in the open atrium, just in front of the balcony edge (right side)
	_build_elevator(O + Vector3(11, 0, -1.5))
	# lighting + neon
	_light(O + Vector3(0, 4.2, 4), Color(1.0, 0.7, 0.4), 4.0, 22.0)
	_light(O + Vector3(0, FLOOR_H + 3.5, -7), Color(0.7, 0.5, 1.0), 3.0, 18.0)
	Neon.sign(root, O + Vector3(0, 0, 13.2), "JACKPOT", Color(1.0, 0.85, 0.2), 4.5, 180.0)
	Neon.strip(root, O + Vector3(0, 9.4, -13.6), Vector3(24, 0.3, 0.2), Color(1.0, 0.2, 0.5))
	# SLOT MACHINES (floor 0)
	for i in 4:
		var sp: Vector3 = O + Vector3(-9 + i * 3.0, 0, 8.0)
		_slot_cabinet(sp)
		if i == 1:
			_special("slots", sp + Vector3(0, 0, -1.2), "Play Slots (2 chips)")
	# a second bank used as the interactable anchor too
	_special("slots", O + Vector3(7, 0, 8.0), "Play Slots (2 chips)")
	_slot_cabinet(O + Vector3(7, 0, 8.0))
	# BLACKJACK table (floor 0)
	_blackjack_table(O + Vector3(6, 0, -1))
	_special("blackjack", O + Vector3(6, 0, 1.4), "Play Blackjack (5 chips)")
	# bar
	_box_prop(O + Vector3(-11, 0.6, -10), Vector3(5, 1.2, 2), Color(0.25, 0.12, 0.06))
	# NPCs
	_add_npc(O + Vector3(6, 0, -2.6), "dealer", "Dealer Dot", "A sharp, friendly blackjack dealer at the Lucky Star Casino in a neon desert city. One short playful sentence.", ["Dealer Dot: Welcome to the table, high roller.", "Dealer Dot: Five chips a hand. Dealer stands on 17."], "ped_a", "chatter")
	_add_npc(O + Vector3(-7, 0, 6), "gambler", "Lucky Lou", "A superstitious old gambler clutching a lucky coin in a Vegas-style casino. One short sentence.", ["Lucky Lou: The 7s are hot tonight, kid!", "Lucky Lou: Pull that lever, fortune favors the bold."], "ped_b", "chatter")
	_add_npc(O + Vector3(9, FLOOR_H + 0.05, -9), "highroller", "Vivian", "A glamorous high-roller in the upstairs lounge of a neon casino. One short elegant sentence.", ["Vivian: The view's better up here, darling.", "Vivian: Take the elevator down when you're ready to win."], "ped_c", "chatter")
	# EXIT
	_exit_marker(O + Vector3(0, 0, 11.5))
	# localized casino music + jingle bed
	_venue_loop(O + Vector3(0, 1.5, 4), "casino", -9.0, 40.0)


func _slot_cabinet(base: Vector3) -> void:
	_box_prop(base + Vector3(0, 0.9, 0), Vector3(1.1, 1.8, 0.9), Color(0.12, 0.10, 0.16))
	_box_prop(base + Vector3(0, 1.4, 0.46), Vector3(0.85, 0.7, 0.08), Color(1.0, 0.85, 0.2), true, 2.2)
	Neon.strip(root, base + Vector3(0, 2.0, 0.4), Vector3(1.2, 0.12, 0.12), Color(1.0, 0.2, 0.5))


func _blackjack_table(base: Vector3) -> void:
	var top := _box_prop(base + Vector3(0, 1.0, 0), Vector3(3.4, 0.2, 2.0), Color(0.05, 0.35, 0.18))
	top.material_override = _mat(Color(0.05, 0.4, 0.2), 0.5)
	_box_prop(base + Vector3(0, 0.5, 0), Vector3(3.0, 1.0, 1.6), Color(0.2, 0.08, 0.04))
	Neon.strip(root, base + Vector3(0, 1.15, 0), Vector3(3.5, 0.06, 2.1), Color(1.0, 0.85, 0.3))


# ---------------- CLUB (2 floors, dance floor) ----------------

func _build_club() -> void:
	var O: Vector3 = OFFSETS["club"]
	_slab(O + Vector3(0, -0.5, 0), Vector3(26, 1, 26), Color(0.06, 0.04, 0.12))
	_outer_walls(O, 26, 26, Color(0.07, 0.03, 0.16))
	_slab(O + Vector3(0, FLOOR_H, -8), Vector3(26, 0.6, 10), Color(0.10, 0.05, 0.18))    # VIP balcony (back)
	_outer_rail(O + Vector3(0, FLOOR_H + 0.5, -3), 16, Color(0.2, 0.9, 1.0))
	_ramp(O + Vector3(11, 0, 6.0), O + Vector3(11, FLOOR_H + 0.3, -4.0), 3.0, Color(0.12, 0.06, 0.2))
	_build_elevator(O + Vector3(-10, 0, -1.5))
	# LIT DANCE FLOOR: a grid of emissive tiles
	var cols := 6
	for ix in cols:
		for iz in cols:
			var c := Color.from_hsv(fmod((ix + iz) * 0.13, 1.0), 0.8, 1.0)
			var tile := _box_prop(O + Vector3(-5 + ix * 2.0, 0.06, -2 + iz * 2.0), Vector3(1.9, 0.12, 1.9), c, true, 1.8)
			tile.set_meta("dance", true)
	_light(O + Vector3(0, 6, 0), Color(0.4, 0.3, 1.0), 4.0, 26.0)
	_light(O + Vector3(-7, 5, -6), Color(1.0, 0.2, 0.6), 3.0, 16.0)
	_light(O + Vector3(7, 5, 6), Color(0.2, 1.0, 0.7), 3.0, 16.0)
	Neon.sign(root, O + Vector3(0, 0, 12.2), "MIRAGE", Color(0.2, 0.9, 1.0), 4.0, 180.0)
	Neon.strip(root, O + Vector3(0, 9.0, -12.6), Vector3(22, 0.3, 0.2), Color(0.9, 0.2, 0.9))
	# DJ booth
	_box_prop(O + Vector3(0, 0.8, -10), Vector3(4, 1.6, 1.5), Color(0.1, 0.05, 0.2))
	_box_prop(O + Vector3(0, 1.7, -9.4), Vector3(3, 0.2, 0.8), Color(0.2, 0.9, 1.0), true, 2.5)
	# bar
	_box_prop(O + Vector3(10, 0.6, 9), Vector3(5, 1.2, 2), Color(0.15, 0.07, 0.25))
	_add_npc(O + Vector3(0, 0.1, -8), "dj", "DJ Pulse", "An energetic club DJ at Club Mirage in a neon desert city. One short hype sentence.", ["DJ Pulse: Welcome to Mirage! Feel that bass!", "DJ Pulse: Floor's open all night, baby!"], "ped_d", "chatter")
	_add_npc(O + Vector3(-4, 0.1, 3), "dancer", "Mara", "A cheerful regular dancing at a neon club. One short sentence.", ["Mara: Best floor on the Strip!", "Mara: Come dance, the lights are wild tonight."], "ped_a", "chatter")
	_add_npc(O + Vector3(10, 0.1, 7), "bartender", "Rico", "A smooth club bartender mixing neon cocktails. One short sentence.", ["Rico: Neon cocktail? On the house, friend.", "Rico: VIP lounge is upstairs."], "ped_b", "chatter")
	_add_npc(O + Vector3(-6, FLOOR_H + 0.05, -8), "vip", "Silk", "A cool VIP lounging on the club's upstairs balcony overlooking the dance floor. One short sentence.", ["Silk: Best seat in the house up here.", "Silk: Take the elevator down when the floor calls you."], "ped_c", "chatter")
	_box_prop(O + Vector3(-6, FLOOR_H + 0.6, -10), Vector3(4, 1.0, 1.5), Color(0.15, 0.08, 0.25))
	_exit_marker(O + Vector3(0, 0, 11.0))
	_venue_loop(O + Vector3(0, 1.5, 0), "club", -7.0, 44.0)


# ---------------- FAIR (open-air, Ferris wheel ride) ----------------

func _build_fair() -> void:
	var O: Vector3 = OFFSETS["fair"]
	_slab(O + Vector3(0, -0.5, 0), Vector3(30, 1, 30), Color(0.55, 0.45, 0.28))   # sandy lot
	# low perimeter fence (visual)
	for s in [-1, 1]:
		_box_prop(O + Vector3(s * 14.5, 1.0, 0), Vector3(0.4, 2.0, 30), Color(0.3, 0.2, 0.4))
		_box_prop(O + Vector3(0, 1.0, s * 14.5), Vector3(30, 2.0, 0.4), Color(0.3, 0.2, 0.4))
	# Meshy Ferris wheel if available, else a built one — both rotate
	_build_ferris(O + Vector3(0, 0, -8))
	# a couple of stalls
	for i in 3:
		var sx: float = -8.0 + i * 8.0
		_box_prop(O + Vector3(sx, 1.3, 9), Vector3(3, 2.6, 3), Color.from_hsv(i * 0.3, 0.6, 0.8))
		Neon.strip(root, O + Vector3(sx, 2.7, 10.5), Vector3(3.2, 0.14, 0.14), Color.from_hsv(i * 0.3 + 0.5, 0.9, 1.0))
	Neon.sign(root, O + Vector3(0, 0, 13.5), "FUN PIER", Color(1.0, 0.45, 0.7), 5.0, 180.0)
	_light(O + Vector3(0, 8, -8), Color(0.9, 0.7, 1.0), 3.0, 30.0)
	_add_npc(O + Vector3(-5, 0.1, 4), "carny", "Gus", "A cheerful carnival barker at a neon fairground. One short sentence.", ["Gus: Step right up! Ride the big wheel!", "Gus: Best view in Neon Springs, free of charge."], "ped_c", "chatter")
	_add_npc(O + Vector3(6, 0.1, 5), "kid", "Pip", "An excited fairgoer holding a show ticket. One short sentence.", ["Pip: I rode it three times already!", "Pip: Go on, press USE by the wheel!"], "ped_d", "chatter")
	_special("ride", O + Vector3(3.5, 0, 0), "Ride the Ferris Wheel")
	_exit_marker(O + Vector3(0, 0, 12.5))
	_venue_loop(O + Vector3(0, 1.5, 9), "crowd", -10.0, 40.0)


func _build_ferris(base: Vector3) -> void:
	# A-frame supports + axle
	_box_prop(base + Vector3(-3.5, 5, 0), Vector3(0.5, 11, 0.5), Color(0.2, 0.2, 0.28)).rotation.z = 0.3
	_box_prop(base + Vector3(3.5, 5, 0), Vector3(0.5, 11, 0.5), Color(0.2, 0.2, 0.28)).rotation.z = -0.3
	ferris = Node3D.new()
	ferris.position = base + Vector3(0, 9.0, 0)
	root.add_child(ferris)
	# built wheel (rim + spokes + pods) — visible even if Meshy file is absent
	var rim_r := 8.0
	for i in 12:
		var a := TAU * i / 12.0
		var sp := _box_prop(Vector3.ZERO, Vector3(0.16, rim_r * 2.0, 0.16), Color(0.8, 0.85, 0.95))
		sp.get_parent().remove_child(sp)
		ferris.add_child(sp)
		sp.position = Vector3.ZERO
		sp.rotation.z = a
		# pod at the rim
		var pod := _box_prop(Vector3.ZERO, Vector3(1.2, 1.0, 1.0), Color.from_hsv(i / 12.0, 0.7, 1.0), true, 1.6)
		pod.get_parent().remove_child(pod)
		ferris.add_child(pod)
		pod.position = Vector3(cos(a) * rim_r, sin(a) * rim_r, 0)
		if i == 0:
			ferris_pod = pod
	# neon rim ring (a torus-ish ring of small emissive boxes)
	for i in 24:
		var a := TAU * i / 24.0
		var seg := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.25, 2.2, 0.25)
		seg.mesh = bm
		seg.material_override = Neon.emissive(Color(0.2, 0.95, 1.0), 3.0)
		seg.position = Vector3(cos(a) * rim_r, sin(a) * rim_r, 0)
		seg.rotation.z = a
		ferris.add_child(seg)


func _start_ride() -> void:
	if _riding:
		return
	_riding = true
	_ride_t = 0.0
	AudioManager.play_sfx("success" if AudioManager.has_sfx("success") else "pickup")


# ---------------- elevator ----------------

func _build_elevator(base: Vector3) -> void:
	# shaft walls (3 sides) + a platform that travels
	_box_prop(base + Vector3(-1.6, FLOOR_H * 0.5, 0), Vector3(0.3, FLOOR_H + 1.0, 3.2), Color(0.12, 0.12, 0.18))
	_box_prop(base + Vector3(1.6, FLOOR_H * 0.5, 0), Vector3(0.3, FLOOR_H + 1.0, 3.2), Color(0.12, 0.12, 0.18))
	_box_prop(base + Vector3(0, FLOOR_H * 0.5, -1.6), Vector3(3.2, FLOOR_H + 1.0, 0.3), Color(0.12, 0.12, 0.18))
	# call indicator (neon)
	_box_prop(base + Vector3(1.5, 1.4, 1.5), Vector3(0.4, 0.8, 0.2), Color(0.2, 1.0, 0.6), true, 2.5)
	# the platform (solid, the player stands on it)
	elev_platform = _slab(base + Vector3(0, 0.1, 0), Vector3(3.0, 0.2, 3.0), Color(0.25, 0.25, 0.32))
	elev_platform.set_meta("base", base)
	_special("elevator", base + Vector3(0, 0, 0), "Call Elevator")


func _build_elev_panel(hud: CanvasLayer) -> void:
	elev_panel = CanvasLayer.new()
	elev_panel.layer = 65
	elev_panel.visible = false
	hud.add_child(elev_panel)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.custom_minimum_size = Vector2(360, 320)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.12, 0.97)
	sb.border_color = Color(0.3, 1.0, 0.7)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(12)
	sb.set_content_margin_all(20)
	pc.add_theme_stylebox_override("panel", sb)
	elev_panel.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	pc.add_child(vb)
	var t := Label.new()
	t.text = "Elevator — pick a floor"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 28)
	t.add_theme_color_override("font_color", Color(0.4, 1.0, 0.8))
	vb.add_child(t)
	var b1 := Button.new()
	b1.text = "Ground Floor"
	b1.custom_minimum_size = Vector2(0, 70)
	b1.add_theme_font_size_override("font_size", 28)
	b1.pressed.connect(func() -> void: _ride_elev(0))
	vb.add_child(b1)
	var b2 := Button.new()
	b2.text = "Upper Floor"
	b2.custom_minimum_size = Vector2(0, 70)
	b2.add_theme_font_size_override("font_size", 28)
	b2.pressed.connect(func() -> void: _ride_elev(1))
	vb.add_child(b2)
	var bc := Button.new()
	bc.text = "Cancel"
	bc.custom_minimum_size = Vector2(0, 56)
	bc.add_theme_font_size_override("font_size", 24)
	bc.pressed.connect(func() -> void: elev_panel.visible = false)
	vb.add_child(bc)


func _open_elev_panel() -> void:
	if elev_platform == null:
		return
	elev_panel.visible = true


func _ride_elev(floor_i: int) -> void:
	elev_panel.visible = false
	if elev_platform == null:
		return
	var target_y := 0.15 if floor_i == 0 else FLOOR_H + 0.45
	_elev_from = player.global_position.y
	_elev_to = target_y
	_elev_t = 0.0
	_elev_travel = true
	AudioManager.play_sfx("ui_confirm" if AudioManager.has_sfx("ui_confirm") else "ui")


# ---------------- shared room helpers ----------------

func _outer_walls(O: Vector3, w: float, d: float, color: Color) -> void:
	var h := 9.0
	_wall(O + Vector3(0, h * 0.5, -d * 0.5), Vector3(w, h, 0.6), color)
	_wall(O + Vector3(0, h * 0.5, d * 0.5), Vector3(w, h, 0.6), color)
	_wall(O + Vector3(-w * 0.5, h * 0.5, 0), Vector3(0.6, h, d), color)
	_wall(O + Vector3(w * 0.5, h * 0.5, 0), Vector3(0.6, h, d), color)
	# ceiling
	_wall(O + Vector3(0, h, 0), Vector3(w, 0.5, d), Color(color.r * 0.6, color.g * 0.6, color.b * 0.7))


func _wall(center: Vector3, size: Vector3, color: Color) -> void:
	_slab(center, size, color)


func _outer_rail(center: Vector3, w: float, color: Color) -> void:
	# a low glowing railing along the front edge of the upper floor (z = 0)
	Neon.strip(root, center + Vector3(0, 0.6, 0), Vector3(w - 2, 0.12, 0.12), color)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = center + Vector3(0, 0.6, 0)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(w - 2, 1.2, 0.3)
	cs.shape = bs
	body.add_child(cs)
	root.add_child(body)


func _exit_marker(pos: Vector3) -> void:
	# a glowing EXIT arch + a special; USE leaves the venue
	_box_prop(pos + Vector3(0, 1.5, 0), Vector3(3.2, 0.3, 0.3), Color(0.2, 1.0, 0.4), true, 2.5)
	var lbl := Label3D.new()
	lbl.text = "EXIT"
	lbl.font_size = 80
	lbl.pixel_size = 0.012
	lbl.modulate = Color(0.3, 1.0, 0.4)
	lbl.outline_size = 14
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	lbl.position = pos + Vector3(0, 2.4, 0)
	root.add_child(lbl)
	_special("exit", pos, "Leave (back to the Strip)")


func _venue_loop(pos: Vector3, loop_name: String, vol: float, dist: float) -> void:
	var path := "res://audio/%s.wav" % loop_name
	if not ResourceLoader.exists(path):
		path = "res://audio/%s.ogg" % loop_name
	if ResourceLoader.exists(path):
		var anchor := Node3D.new()
		anchor.position = pos
		root.add_child(anchor)
		AudioManager.attach_loop(anchor, load(path), vol, dist, 10.0)
