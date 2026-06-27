extends Node3D
## NEON STRIP — open-world neon-desert city (Las Vegas style). Built on the RPG chunk-streaming
## template (mode:"chunk"): ChunkManager streams a 4x4 grid around the player; Weather3D runs the
## day->night cycle; the InteractionSystem + NPC brain handle talking. On top of that this script
## adds: a third-person grounded avatar with gravity (so stairs/elevators work), a drivable car,
## enterable multi-floor venues (Interiors), casino games, a minimap + full map, ambient traffic +
## pedestrians, collectibles (cash/chips/items), neon signage, and Supabase persistence.

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4

const CAM_HEAD := 1.7
const CAM_PITCH_MIN := -1.15
const CAM_PITCH_MAX := -0.12
const LOOK_SENS := 0.006
const GRAVITY := 26.0
const WALK_SPEED := 6.0
const AVATAR_YAW := 0.0          # Kenney chars face +Z (matches player +Z = move dir); no offset

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"
var build_id := ""
var props_pool: Array = []

var world_data := {}
var quests_data := {}
var _world_raw := ""
var _polling := false

var env: Environment
var sun: DirectionalLight3D
var player: CharacterBody3D
var cam: Camera3D
var cam_rig: Node3D
var cam_spring: SpringArm3D
var cam_yaw := 0.0
var cam_pitch := -0.5
var look_idx := -1
var look_last := Vector2.ZERO
var avatar: Node3D
var avatar_bob: Node3D
var _foot_t := 0.0

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem
var weather: Weather3D
var chunk_manager: ChunkManager
var chunk_mode := false
var auto_roam := false
var _roam_t := 0.0

# bespoke systems
var vehicle: Vehicle
var interiors: Interiors
var casino: CasinoGames
var maps: MapSystem
var ambient: AmbientLife
var savesys: SaveSystem
var driving := false
var inside := false

var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO

var hud_layer: CanvasLayer
var info: Label
var info_bg: ColorRect
var action_btn: Button
var use_btn: Button
var map_btn: Button
var hint: Label
var btn_rects: Array = []

# venues + pickups
var venues: Array = []          # [{id,name,pos:Vector3,color}]
var pickups: Array = []         # [{node,pos,kind,amount,id,item,taken}]
var collected := {}
var _loaded_pos = null
var _did_initial_save := false


func _ready() -> void:
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		var bid = JavaScriptBridge.eval("location.pathname.split('/').filter(Boolean)[0] || ''", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)
		var soak = JavaScriptBridge.eval("window.location.search.indexOf('soak=1')>=0", true)
		if typeof(soak) == TYPE_BOOL and soak:
			auto_roam = true

	# responsive full-screen fill (web canvas size isn't final on frame 1)
	var w := get_window()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	w.size_changed.connect(_relayout)

	_build_env()
	_build_player()
	weather = Weather3D.new()
	add_child(weather)
	weather.setup(env, sun, cam_rig)
	_build_hud()
	_register_audio()
	AudioManager.show_tap_overlay()

	rpg = RpgState.new()
	add_child(rpg)
	rpg.changed.connect(_refresh_info)

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.world_url = world_url
	builder.env = env
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)
	quest.objective_changed.connect(_refresh_info)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)

	chunk_manager = ChunkManager.new()
	add_child(chunk_manager)
	chunk_manager.setup(player, builder, self, env, interaction, rpg)
	chunk_manager.area_entered.connect(quest.notify_area)

	# bespoke systems
	casino = CasinoGames.new()
	add_child(casino)
	casino.setup(rpg, hud_layer)

	interiors = Interiors.new()
	add_child(interiors)
	interiors.setup(player, rpg, interaction, casino, self, chunk_manager, hud_layer)

	_spawn_vehicle()
	_spawn_decor_and_venues()
	_spawn_pickups()

	ambient = AmbientLife.new()
	add_child(ambient)
	ambient.setup(player)

	maps = MapSystem.new()
	add_child(maps)
	var vmarks: Array = []
	for v in venues:
		vmarks.append({name = v.name, pos = Vector2(v.pos.x, v.pos.z), color = v.color})
	vmarks.append({name = "Fountain", pos = Vector2(40, 24), color = Color(0.4, 0.8, 1.0)})
	vmarks.append({name = "You start", pos = Vector2(24, 24), color = Color(0.9, 0.9, 0.9)})
	maps.setup(player, Rect2(0, 0, 64, 64), vmarks, hud_layer, Vector2(get_viewport().get_visible_rect().size.x - 206, 14))

	savesys = SaveSystem.new()
	add_child(savesys)
	savesys.setup(self)

	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	_refresh_info()
	_relayout()
	await get_tree().process_frame
	await get_tree().process_frame
	_relayout()
	_boot()


func _boot() -> void:
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	var wq := HTTPRequest.new()
	add_child(wq)
	wq.request(world_url)
	var wr = await wq.request_completed
	wq.queue_free()
	if wr[1] != 200:
		hint.text = "world.json fetch failed (HTTP %s)" % str(wr[1])
		return
	var raw := (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		hint.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw
	_apply_weather(world)

	var qq := HTTPRequest.new()
	add_child(qq)
	qq.request(world_url.replace("world.json", "quests.json"))
	var qr = await qq.request_completed
	qq.queue_free()
	if qr[1] == 200:
		var qdata = JSON.parse_string((qr[3] as PackedByteArray).get_string_from_utf8())
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			var first_quest = quests_data.get("quests", [])
			if first_quest.size() > 0:
				quest.start(first_quest[0].get("id", ""))

	if String(world.get("mode", "")) == "chunk":
		sun.shadow_enabled = true
		sun.shadow_normal_bias = 2.0
		sun.directional_shadow_max_distance = 48.0
		await chunk_manager.start(world)
		chunk_mode = true                      # enable player physics/gravity only AFTER the floor exists
		scene_manager._fade.visible = false    # reveal the built world
	else:
		scene_manager.start(world)


# ---------------- movement ----------------

func _physics_process(delta: float) -> void:
	if player == null or not chunk_mode:
		return
	if inside and interiors and interiors.busy():
		player.velocity = Vector3.ZERO
		return
	if _modal_open():
		player.velocity.x = 0.0
		player.velocity.z = 0.0
		_apply_gravity(delta)
		player.move_and_slide()
		return
	if driving and vehicle:
		_drive(delta)
		return
	_walk(delta)


func _apply_gravity(delta: float) -> void:
	if player.is_on_floor():
		player.velocity.y = -2.0
	else:
		player.velocity.y -= GRAVITY * delta


func _walk(delta: float) -> void:
	var v := _keyboard_vec() + move_vec
	var move_dir := Vector3.ZERO
	if auto_roam and chunk_manager != null:
		_roam_t += delta
		var rect := chunk_manager.grid_world_rect()
		var tt := fmod(_roam_t * 0.05, 2.0)
		var f := tt if tt <= 1.0 else (2.0 - tt)
		var target := Vector3(rect.position.x, 0.0, rect.position.y).lerp(Vector3(rect.end.x, 0.0, rect.end.y), f)
		var to := target - player.global_position
		v = Vector2(to.x, to.z)
		if v.length() > 1.0:
			v = v.normalized()
		move_dir = Vector3(v.x, 0.0, v.y)
	else:
		if v.length() > 1.0:
			v = v.normalized()
		move_dir = Basis(Vector3.UP, cam_yaw) * Vector3(v.x, 0.0, v.y)
	player.velocity.x = move_dir.x * WALK_SPEED
	player.velocity.z = move_dir.z * WALK_SPEED
	_apply_gravity(delta)
	player.move_and_slide()
	if move_dir.length() > 0.1:
		var look := player.global_position - move_dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
		_foot_t += delta
		if _foot_t > 0.34:
			_foot_t = 0.0
			AudioManager.play_sfx("foot", -8.0, randf_range(0.9, 1.1))
		if avatar_bob:
			avatar_bob.position.y = absf(sin(Time.get_ticks_msec() * 0.013)) * 0.07
	elif avatar_bob:
		avatar_bob.position.y = lerpf(avatar_bob.position.y, 0.0, 0.2)


func _drive(delta: float) -> void:
	var v := _keyboard_vec() + move_vec
	vehicle.drive(-v.y, v.x, delta)


func _modal_open() -> bool:
	return (casino and casino.is_open()) or (maps and maps.is_open()) or (interiors and interiors.elev_panel and interiors.elev_panel.visible)


func _process(delta: float) -> void:
	if cam_rig and player:
		var focus := player.global_position
		if driving and vehicle:
			focus = vehicle.global_position
		cam_rig.global_position = focus + Vector3(0.0, CAM_HEAD, 0.0)
		cam_rig.rotation.y = cam_yaw
		cam_spring.rotation.x = cam_pitch
	if chunk_mode and chunk_manager != null:
		chunk_manager.tick(delta)
	if driving and vehicle and absf(vehicle.speed) < 0.1:
		vehicle.coast(delta)
	_update_pickups(delta)
	_update_context()
	_refresh_info()


# ---------------- car ----------------

func _spawn_vehicle() -> void:
	vehicle = Vehicle.new()
	add_child(vehicle)
	var model: Node3D = null
	if ResourceLoader.exists("res://models/car.glb"):
		model = (load("res://models/car.glb") as PackedScene).instantiate() as Node3D
	vehicle.setup(model, "Cruiser")
	vehicle.global_position = Vector3(30, 0.2, 22)
	vehicle.rotation.y = deg_to_rad(90.0)


func _near_car() -> bool:
	return vehicle != null and not inside and player.global_position.distance_to(vehicle.global_position) < 4.0


func _enter_car() -> void:
	if driving or vehicle == null:
		return
	driving = true
	player.collision_layer = 0
	player.collision_mask = 0
	if avatar:
		avatar.visible = false
	AudioManager.play_sfx("door")


func _exit_car() -> void:
	if not driving:
		return
	driving = false
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD
	var side := vehicle.global_transform.basis.x
	player.global_position = vehicle.global_position + side * 2.6 + Vector3(0, 0.2, 0)
	player.velocity = Vector3.ZERO
	if avatar:
		avatar.visible = true
	AudioManager.play_sfx("door")


# ---------------- venues + decor ----------------

func _spawn_decor_and_venues() -> void:
	venues = [
		{id = "casino", name = "Lucky Star Casino", short = "Casino", pos = Vector3(34, 0, 13), color = Color(1.0, 0.82, 0.2)},
		{id = "club", name = "Club Mirage", short = "Club", pos = Vector3(29, 0, 39), color = Color(0.2, 0.9, 1.0)},
		{id = "fair", name = "Neon Pier Fair", short = "Fair", pos = Vector3(40, 0, 45), color = Color(1.0, 0.45, 0.7)},
	]
	var faces := {"casino": 0.0, "club": 90.0, "fair": 0.0}
	for v in venues:
		Neon.sign(self, v.pos + Vector3(3.2, 0, 0), String(v.name), v.color, 8.5, float(faces.get(v.id, 0.0)))
		_entrance_pad(v.pos, v.color)
	# a few extra Strip neon signs for skyline flavor
	Neon.sign(self, Vector3(20, 0, 18), "LOST WAGES", Color(1.0, 0.3, 0.5), 11.0, -90.0)
	Neon.sign(self, Vector3(44, 0, 30), "STARDUST", Color(0.7, 0.4, 1.0), 12.0, 90.0)
	Neon.sign(self, Vector3(20, 0, 50), "DESERT GOLD", Color(1.0, 0.7, 0.2), 10.0, -90.0)


func _entrance_pad(pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 2.0
	cyl.bottom_radius = 2.0
	cyl.height = 0.12
	mi.mesh = cyl
	mi.material_override = Neon.emissive(color, 2.2)
	mi.position = pos + Vector3(0, 0.07, 0)
	add_child(mi)
	Neon.halo(self, pos + Vector3(0, 2.6, 0), Vector2(4.5, 5.0), color)
	var lbl := Label3D.new()
	lbl.text = "ENTER"
	lbl.font_size = 56
	lbl.pixel_size = 0.012
	lbl.modulate = color
	lbl.outline_size = 12
	lbl.outline_modulate = Color(0, 0, 0, 0.85)
	lbl.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	lbl.position = pos + Vector3(0, 3.4, 0)
	add_child(lbl)


func _near_venue() -> String:
	if inside or driving:
		return ""
	for v in venues:
		if player.global_position.distance_to(v.pos) < 4.2:
			return String(v.id)
	return ""


# ---------------- pickups ----------------

func _spawn_pickups() -> void:
	var defs := [
		{id = "c1", kind = "cash", amount = 20, pos = Vector3(32, 0, 28)},
		{id = "c2", kind = "cash", amount = 15, pos = Vector3(36, 0, 20)},
		{id = "c3", kind = "cash", amount = 30, pos = Vector3(28, 0, 34)},
		{id = "c4", kind = "cash", amount = 25, pos = Vector3(44, 0, 36)},
		{id = "c5", kind = "cash", amount = 40, pos = Vector3(12, 0, 30)},
		{id = "k1", kind = "chip", amount = 5, pos = Vector3(34, 0, 16)},
		{id = "k2", kind = "chip", amount = 8, pos = Vector3(38, 0, 26)},
		{id = "k3", kind = "chip", amount = 5, pos = Vector3(30, 0, 44)},
		{id = "k4", kind = "chip", amount = 10, pos = Vector3(40, 0, 50)},
		{id = "i1", kind = "item", item = "drink", pos = Vector3(26, 0, 22)},
		{id = "i2", kind = "item", item = "show_ticket", pos = Vector3(42, 0, 42)},
		{id = "i3", kind = "item", item = "lucky_coin", pos = Vector3(16, 0, 26)},
		{id = "i4", kind = "item", item = "sunglasses", pos = Vector3(20, 0, 40)},
		{id = "i5", kind = "item", item = "souvenir", pos = Vector3(46, 0, 22)},
	]
	for d in defs:
		var node := Node3D.new()
		node.position = d.pos + Vector3(0, 1.0, 0)
		add_child(node)
		var mi := MeshInstance3D.new()
		var col := Color(1.0, 0.85, 0.2)
		if d.kind == "chip":
			col = Color(0.95, 0.2, 0.4)
			var disc := CylinderMesh.new()
			disc.top_radius = 0.45
			disc.bottom_radius = 0.45
			disc.height = 0.12
			mi.mesh = disc
			mi.rotation.x = deg_to_rad(90.0)
		elif d.kind == "item":
			col = Color(0.3, 0.9, 1.0)
			var bx := BoxMesh.new()
			bx.size = Vector3(0.5, 0.5, 0.5)
			mi.mesh = bx
		else:
			var coin := CylinderMesh.new()
			coin.top_radius = 0.42
			coin.bottom_radius = 0.42
			coin.height = 0.1
			mi.mesh = coin
			mi.rotation.z = deg_to_rad(90.0)
		mi.material_override = Neon.emissive(col, 2.4)
		node.add_child(mi)
		Neon.halo(node, Vector3(0, 0, 0), Vector2(1.4, 1.4), col)
		pickups.append({node = node, pos = d.pos, kind = d.kind, amount = int(d.get("amount", 0)), id = d.id, item = String(d.get("item", "")), taken = false})


func _update_pickups(delta: float) -> void:
	var focus := player.global_position
	if driving and vehicle:
		focus = vehicle.global_position
	for p in pickups:
		if p.taken:
			continue
		var node: Node3D = p.node
		node.rotation.y += delta * 2.0
		node.position.y = 1.0 + sin(Time.get_ticks_msec() * 0.004 + p.pos.x) * 0.12
		var d := Vector2(focus.x - p.pos.x, focus.z - p.pos.z).length()
		node.visible = d < 32.0
		if d < 1.5:
			_collect(p)


func _collect(p: Dictionary) -> void:
	p.taken = true
	collected[p.id] = true
	if is_instance_valid(p.node):
		(p.node as Node3D).visible = false
	match p.kind:
		"cash":
			rpg.add_gold(p.amount)
			AudioManager.play_sfx("coin" if AudioManager.has_sfx("coin") else "pickup")
		"chip":
			rpg.add_chips(p.amount)
			AudioManager.play_sfx("chip" if AudioManager.has_sfx("chip") else "pickup")
		"item":
			rpg.add_item(p.item)
			AudioManager.play_sfx("pickup")
	if savesys:
		savesys.save_now()


# ---------------- HUD ----------------

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)
	info_bg = ColorRect.new()
	info_bg.color = Color(0.03, 0.04, 0.08, 0.55)
	info_bg.position = Vector2(8, 8)
	info_bg.size = Vector2(366, 108)
	hud_layer.add_child(info_bg)
	info = Label.new()
	info.position = Vector2(16, 12)
	info.add_theme_font_size_override("font_size", 22)
	info.add_theme_color_override("font_color", Color(0.95, 0.98, 0.85))
	hud_layer.add_child(info)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 24)
	hint.add_theme_color_override("font_color", Color(1.0, 0.95, 0.55))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint.position = Vector2(-180, -250)
	hud_layer.add_child(hint)
	action_btn = _button("Drive", _on_action)
	use_btn = _button("USE", func() -> void: _on_use())
	map_btn = _button("MAP", func() -> void: maps.toggle())


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 28)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


func _relayout() -> void:
	if hud_layer == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var ins := _safe_insets()
	var top: float = maxf(10.0, ins.get("top", 0.0))
	var bottom: float = maxf(14.0, ins.get("bottom", 0.0))
	var right: float = maxf(10.0, ins.get("right", 0.0))
	var left: float = maxf(10.0, ins.get("left", 0.0))
	if info_bg:
		info_bg.position = Vector2(left, top)
	if info:
		info.position = Vector2(left + 8, top + 4)
	# minimap top-right
	if maps:
		maps.set_mini_pos(Vector2(vp.x - 196 - right, top))
	# bottom-right action cluster
	var bw := 200.0
	var bh := 96.0
	action_btn.size = Vector2(bw, bh)
	action_btn.position = Vector2(vp.x - bw - right, vp.y - bh - bottom)
	use_btn.size = Vector2(bw, bh)
	use_btn.position = Vector2(vp.x - bw - right, vp.y - bh * 2.0 - bottom - 14)
	map_btn.size = Vector2(150, 70)
	map_btn.position = Vector2(left, vp.y - 70 - bottom)
	btn_rects = [
		Rect2(action_btn.position, action_btn.size),
		Rect2(use_btn.position, use_btn.size),
		Rect2(map_btn.position, map_btn.size),
	]


func _safe_insets() -> Dictionary:
	if not OS.has_feature("web"):
		return {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}
	var js := """(() => { const d=document.createElement('div'); d.style.cssText=
		'position:fixed;top:env(safe-area-inset-top);bottom:env(safe-area-inset-bottom);left:env(safe-area-inset-left);right:env(safe-area-inset-right)';
		document.body.appendChild(d); const r=getComputedStyle(d);
		const o={top:parseFloat(r.top)||0,bottom:parseFloat(r.bottom)||0,left:parseFloat(r.left)||0,right:parseFloat(r.right)||0};
		d.remove(); return JSON.stringify(o); })()"""
	var raw: String = str(JavaScriptBridge.eval(js, true))
	var d = JSON.parse_string(raw) if raw != "" else {}
	return d if d is Dictionary else {}


func _update_context() -> void:
	if action_btn == null:
		return
	if driving:
		action_btn.text = "Exit Car"
		action_btn.visible = true
	elif inside:
		action_btn.visible = false
	else:
		var ven := _near_venue()
		if _near_car():
			action_btn.text = "Drive"
			action_btn.visible = true
		elif ven != "":
			var nm := ven
			for v in venues:
				if v.id == ven:
					nm = String(v.short)
			action_btn.text = "Enter " + nm
			action_btn.visible = true
		else:
			action_btn.visible = false


func _on_action() -> void:
	if driving:
		_exit_car()
	elif inside:
		pass
	else:
		var ven := _near_venue()
		if _near_car():
			_enter_car()
		elif ven != "":
			interiors.enter(ven)
			savesys.save_now()


func _on_use() -> void:
	if inside:
		interiors.try_use()
	else:
		interaction.try_use()


func _refresh_info() -> void:
	if info == null or rpg == null:
		return
	var tod := ""
	if weather:
		tod = weather._active_wx
	var place := "The Strip"
	if inside and interiors:
		place = Interiors.VENUE_NAMES.get(interiors.venue, "Venue")
	elif driving:
		place = "Driving"
	var sync := savesys.status if savesys else ""
	info.text = "$%d   Chips %d   Discovered %d/3\n%s   |   %s\nInv: %s" % [
		rpg.gold, rpg.chips, rpg.discovered.size(), place, "save: " + sync, rpg.trinket_summary()]


# ---------------- save / load ----------------

func save_blob() -> Dictionary:
	var b := rpg.to_dict()
	var pos := player.global_position
	b["pos"] = [pos.x, pos.y, pos.z]
	b["collected"] = collected.keys()
	return b


func apply_loaded(raw: String) -> void:
	if raw == "" or raw == "null":
		_did_initial_save = true
		return
	var d = JSON.parse_string(raw)
	if not (d is Dictionary):
		return
	rpg.from_dict(d)
	if d.get("collected") is Array:
		for cid in d["collected"]:
			collected[cid] = true
			for p in pickups:
				if p.id == String(cid):
					p.taken = true
					if is_instance_valid(p.node):
						(p.node as Node3D).visible = false
	if d.get("pos") is Array and (d["pos"] as Array).size() >= 3 and not driving and not inside:
		var pa: Array = d["pos"]
		player.global_position = Vector3(float(pa[0]), float(pa[1]) + 0.2, float(pa[2]))
	_refresh_info()


func set_inside(v: bool) -> void:
	inside = v
	if maps and maps.mini:
		maps.mini.visible = not v


# ---------------- hot reload + input ----------------

func _poll_world() -> void:
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var w = JSON.parse_string(raw)
	if not (w is Dictionary):
		return
	if chunk_mode and not w.has("cells"):
		return
	_world_raw = raw
	world_data = w
	_apply_weather(w)
	if chunk_mode:
		chunk_manager.reload(world_data)


func _unhandled_input(event: InputEvent) -> void:
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			if e.position.x < half and move_idx == -1:
				move_idx = e.index
				move_origin = e.position
				move_vec = Vector2.ZERO
			elif e.position.x >= half and look_idx == -1 and not _over_button(e.position):
				look_idx = e.index
				look_last = e.position
		else:
			if e.index == move_idx:
				move_idx = -1
				move_vec = Vector2.ZERO
			elif e.index == look_idx:
				look_idx = -1
	elif event is InputEventScreenDrag:
		var e := event as InputEventScreenDrag
		if e.index == move_idx:
			move_vec = ((e.position - move_origin) / 80.0).limit_length(1.0)
		elif e.index == look_idx:
			_apply_look(e.position - look_last)
			look_last = e.position
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and move_idx == -1 and look_idx == -1:
		_apply_look(event.relative)


func _over_button(pos: Vector2) -> bool:
	for r: Rect2 in btn_rects:
		if r.has_point(pos):
			return true
	return false


func _apply_look(d: Vector2) -> void:
	cam_yaw -= d.x * LOOK_SENS
	cam_pitch = clampf(cam_pitch - d.y * LOOK_SENS, CAM_PITCH_MIN, CAM_PITCH_MAX)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	return v


# ---------------- manifest + env + player ----------------

func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not (data is Dictionary):
		return
	for p in data.get("props", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("category", "")) != "nature":
			continue
		var fn := String(p.get("file", "")).get_file().to_lower()
		if "terrain" in fn or "path" in fn or "cliff" in fn or "beach" in fn or "railway" in fn or "road" in fn or "fence" in fn:
			continue
		var u := _norm(String(p.get("file", "")))
		if u != "" and "/godot-assets/props/" in u:
			props_pool.append(u)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


func _apply_weather(world: Dictionary) -> void:
	if weather == null:
		return
	var sky = world.get("sky", null)
	if sky is Dictionary:
		weather.apply(sky)


func _register_audio() -> void:
	for n in ["slot", "win", "lose", "coin", "chip", "foot"]:
		for ext in ["wav", "ogg"]:
			var p := "res://audio/%s.%s" % [n, ext]
			if ResourceLoader.exists(p):
				AudioManager.register_sfx(n, load(p))
				break


func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.66)
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	we.environment = env
	add_child(we)
	get_viewport().msaa_3d = Viewport.MSAA_2X
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -45.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD
	player.floor_max_angle = deg_to_rad(48.0)
	player.floor_snap_length = 0.6
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.38
	cap.height = 1.6
	cs.shape = cap
	cs.position.y = 0.85
	player.add_child(cs)
	avatar_bob = Node3D.new()
	player.add_child(avatar_bob)
	if ResourceLoader.exists("res://models/player.glb"):
		avatar = (load("res://models/player.glb") as PackedScene).instantiate() as Node3D
		avatar_bob.add_child(avatar)
		avatar.rotation.y = deg_to_rad(AVATAR_YAW)
		avatar.position.y -= _subtree_aabb(avatar).position.y
		Neon.tint_solid(avatar, Color(0.92, 0.28, 0.55))
	else:
		avatar = MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.38
		cm.height = 1.6
		(avatar as MeshInstance3D).mesh = cm
		(avatar as MeshInstance3D).material_override = _mat(Color(0.3, 0.6, 0.95))
		avatar.position.y = 0.8
		avatar_bob.add_child(avatar)
	cam_rig = Node3D.new()
	add_child(cam_rig)
	cam_spring = SpringArm3D.new()
	cam_spring.spring_length = 9.0
	cam_spring.collision_mask = L_WORLD
	cam_spring.margin = 0.4
	cam_spring.rotation.x = cam_pitch
	cam_rig.add_child(cam_spring)
	cam = Camera3D.new()
	cam.fov = 64.0
	cam.far = 600.0
	cam_spring.add_child(cam)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m


func _subtree_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged
