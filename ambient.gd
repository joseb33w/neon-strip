class_name AmbientLife extends Node3D
## "Just enough to feel alive": a few cars cruising the boulevard + highway and pedestrians
## strolling the Strip sidewalks. Pure visual movers (no hard physics) — looped along lanes,
## facing travel direction, with a walk-bob on peds. Culled past ~34u so they never hover over
## an un-streamed edge cell and cost nothing when off-screen.

const CULL_DIST := 34.0
const CAR_COLORS := [Color(0.9, 0.2, 0.25), Color(0.2, 0.5, 0.95), Color(0.95, 0.8, 0.2), Color(0.85, 0.85, 0.9), Color(0.2, 0.8, 0.55)]

var player: Node3D
var agents: Array = []     # [{node, model, a:Vector3, b:Vector3, t:float, speed:float, ped:bool, bob:Node3D}]


func setup(p: Node3D) -> void:
	player = p
	var car_scene: PackedScene = load("res://models/car.glb") if ResourceLoader.exists("res://models/car.glb") else null
	# lanes: [from, to] world points (y=0). Cars loop a->b->a.
	var car_lanes := [
		[Vector3(29, 0, -2), Vector3(29, 0, 66)],    # boulevard southbound
		[Vector3(35, 0, 66), Vector3(35, 0, -2)],    # boulevard northbound
		[Vector3(56, 0, -2), Vector3(56, 0, 66)],    # highway
		[Vector3(56, 0, 66), Vector3(52, 0, -2)],    # highway opposite
	]
	var ci := 0
	for lane in car_lanes:
		_spawn_car(car_scene, lane[0], lane[1], CAR_COLORS[ci % CAR_COLORS.size()], 7.0 + ci)
		ci += 1
	# pedestrians on the sidewalks
	var ped_paths := [
		[Vector3(22, 0, 10), Vector3(22, 0, 40)],
		[Vector3(42, 0, 40), Vector3(42, 0, 12)],
		[Vector3(20, 0, 30), Vector3(20, 0, 52)],
		[Vector3(44, 0, 52), Vector3(44, 0, 26)],
		[Vector3(26, 0, 46), Vector3(38, 0, 46)],
	]
	var pi := 0
	for pp in ped_paths:
		var path := "res://models/ped_%s.glb" % ["a", "b", "c", "d"][pi % 4]
		_spawn_ped(path, pp[0], pp[1], 1.4 + (pi % 3) * 0.3)
		pi += 1
	set_process(true)


func _spawn_car(scene: PackedScene, a: Vector3, b: Vector3, col: Color, speed: float) -> void:
	var node := Node3D.new()
	add_child(node)
	var model: Node3D
	if scene:
		model = scene.instantiate() as Node3D
		_recolor(model, col)
	else:
		model = _box_car(col)
	node.add_child(model)
	_ground(model)
	agents.append({node = node, model = model, a = a, b = b, t = randf(), speed = speed, ped = false, bob = null})


func _spawn_ped(path: String, a: Vector3, b: Vector3, speed: float) -> void:
	var node := Node3D.new()
	add_child(node)
	var bob := Node3D.new()
	node.add_child(bob)
	var model: Node3D
	if ResourceLoader.exists(path):
		model = (load(path) as PackedScene).instantiate() as Node3D
		Neon.tint_solid(model, Color.from_hsv(randf(), 0.55, 0.85))
	else:
		model = _capsule_person()
	bob.add_child(model)
	_ground(model)
	agents.append({node = node, model = model, a = a, b = b, t = randf(), speed = speed, ped = true, bob = bob})


func _process(delta: float) -> void:
	if player == null:
		return
	var pp := player.global_position
	for ag in agents:
		var seg: Vector3 = ag.b - ag.a
		var seg_len: float = maxf(seg.length(), 0.001)
		ag.t += (ag.speed / seg_len) * delta
		if ag.t >= 1.0:
			# wrap: swap direction so they patrol back (keeps them on the lane forever)
			var tmp = ag.a; ag.a = ag.b; ag.b = tmp
			ag.t = 0.0
			seg = ag.b - ag.a
		var pos: Vector3 = (ag.a as Vector3).lerp(ag.b, clampf(ag.t, 0.0, 1.0))
		var node: Node3D = ag.node
		node.global_position = pos
		# face travel direction (+Z model forward)
		var dir: Vector3 = ag.b - ag.a
		dir.y = 0.0
		if dir.length() > 0.01:
			var yaw := atan2(dir.x, dir.z)
			node.rotation.y = yaw
		# distance cull
		var d := pos.distance_to(pp)
		node.visible = d < CULL_DIST
		if ag.ped and ag.bob and node.visible:
			(ag.bob as Node3D).position.y = absf(sin(Time.get_ticks_msec() * 0.008 + ag.t * 10.0)) * 0.08


func _ground(n: Node3D) -> void:
	var ab := _aabb(n)
	n.position.y -= ab.position.y


func _aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var wa: AABB = mi.transform * mi.get_aabb()
		if first:
			merged = wa; first = false
		else:
			merged = merged.merge(wa)
	return merged


func _recolor(root: Node3D, tint: Color) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in range(maxi(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(s)
			var m := (base.duplicate() if base else StandardMaterial3D.new()) as StandardMaterial3D
			if m == null:
				continue
			m.albedo_color = tint
			mi.set_surface_override_material(s, m)


func _box_car(col: Color) -> Node3D:
	var n := Node3D.new()
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.0, 1.0, 4.0)
	body.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.3
	body.material_override = m
	body.position.y = 0.6
	n.add_child(body)
	var cab := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(1.7, 0.7, 2.0)
	cab.mesh = cm
	cab.material_override = m
	cab.position = Vector3(0, 1.3, -0.2)
	n.add_child(cab)
	return n


func _capsule_person() -> Node3D:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.32
	cm.height = 1.6
	mi.mesh = cm
	mi.position.y = 0.8
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(randf() * 0.5 + 0.3, randf() * 0.5 + 0.3, randf() * 0.5 + 0.3)
	mi.material_override = m
	n.add_child(mi)
	return n
