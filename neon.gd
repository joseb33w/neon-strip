class_name Neon extends Object
## Neon / emissive helpers. GLOW is unreliable in Compatibility, so we FAKE bloom with a
## bright emissive surface + an additive (blend_add) halo quad behind it (art.md). Emission is
## always on, so signs read subtly by day and POP against the dark night sky.

static func emissive(color: Color, energy := 3.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m


# Recolor a whole model to ONE solid LIT color (replaces missing/textureless materials with a
# clean StandardMaterial3D), so library characters that ship without their texture atlas still
# read as deliberately-styled people instead of flat white.
static func tint_solid(root: Node3D, color: Color) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.85
		for s in range(maxi(1, mi.mesh.get_surface_count())):
			mi.set_surface_override_material(s, m)


static func unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# An additive halo quad — fake bloom behind a glowing element. NEVER blend_mul.
static func halo(parent: Node3D, pos: Vector3, size: Vector2, color: Color) -> void:
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size
	q.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(color.r, color.g, color.b, 0.5)
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	q.material_override = m
	q.position = pos
	parent.add_child(q)


# A glowing horizontal/vertical neon strip (thin emissive box).
static func strip(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = emissive(color, 3.5)
	mi.position = pos
	parent.add_child(mi)
	return mi


# A free-standing neon sign on a pole: a dark panel framed in glowing tubes with bright
# billboarded text on top. `world_pos` is the base on the ground (y=0). Returns the root.
static func sign(parent: Node3D, world_pos: Vector3, text: String, color: Color, height := 9.0, facing := 0.0) -> Node3D:
	var root := Node3D.new()
	root.position = world_pos
	root.rotation.y = deg_to_rad(facing)
	parent.add_child(root)
	# pole
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.1
	pm.bottom_radius = 0.13
	pm.height = height
	pole.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.10, 0.10, 0.13)
	pmat.metallic = 0.6
	pmat.roughness = 0.4
	pole.material_override = pmat
	pole.position.y = height * 0.5
	root.add_child(pole)
	# panel
	var panel := MeshInstance3D.new()
	var bm := BoxMesh.new()
	var pw := maxf(3.2, text.length() * 0.62)
	bm.size = Vector3(pw, 2.4, 0.3)
	panel.mesh = bm
	var panmat := StandardMaterial3D.new()
	panmat.albedo_color = Color(0.04, 0.03, 0.07)
	panel.material_override = panmat
	panel.position.y = height + 1.0
	root.add_child(panel)
	# glowing frame strips
	var hy := height + 1.0
	strip(root, Vector3(0, hy + 1.25, 0.2), Vector3(pw + 0.3, 0.16, 0.16), color)
	strip(root, Vector3(0, hy - 1.25, 0.2), Vector3(pw + 0.3, 0.16, 0.16), color)
	strip(root, Vector3(-pw * 0.5 - 0.15, hy, 0.2), Vector3(0.16, 2.5, 0.16), color)
	strip(root, Vector3(pw * 0.5 + 0.15, hy, 0.2), Vector3(0.16, 2.5, 0.16), color)
	halo(root, Vector3(0, hy, 0.35), Vector2(pw + 2.0, 4.5), color)
	# text
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = 110
	lbl.pixel_size = 0.012
	lbl.modulate = color
	lbl.outline_size = 16
	lbl.outline_modulate = Color(0, 0, 0, 0.9)
	lbl.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	lbl.position = Vector3(0, hy, 0.3)
	root.add_child(lbl)
	return root
