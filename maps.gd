class_name MapSystem extends Node
## Corner MINIMAP (always on) + toggleable FULLSCREEN map. Both draw the city footprint, venue /
## landmark markers, and the player's position + heading. Resolution-independent: the minimap pins
## to the top-right (safe-area aware via main), the full map fills a centered rect.

var player: Node3D
var world_rect := Rect2(0, 0, 64, 64)
var venues: Array = []          # [{name:String, pos:Vector2(world xz), color:Color}]

var mini: Control
var full_layer: CanvasLayer
var full: Control
var _font: Font


func setup(p: Node3D, wrect: Rect2, venue_list: Array, hud_parent: Node, mini_pos: Vector2) -> void:
	player = p
	world_rect = wrect
	venues = venue_list
	_font = ThemeDB.fallback_font
	mini = Control.new()
	mini.custom_minimum_size = Vector2(190, 190)
	mini.size = Vector2(190, 190)
	mini.position = mini_pos
	mini.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mini.draw.connect(func() -> void: _draw_map(mini, Rect2(Vector2.ZERO, mini.size), false))
	hud_parent.add_child(mini)

	full_layer = CanvasLayer.new()
	full_layer.layer = 70
	full_layer.visible = false
	hud_parent.add_child(full_layer)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.05, 0.92)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	full_layer.add_child(dim)
	full = Control.new()
	full.set_anchors_preset(Control.PRESET_FULL_RECT)
	full.draw.connect(_draw_full)
	full_layer.add_child(full)
	var close := Button.new()
	close.text = "Close Map"
	close.add_theme_font_size_override("font_size", 28)
	close.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	close.position = Vector2(-110, -90)
	close.custom_minimum_size = Vector2(220, 64)
	close.pressed.connect(toggle)
	full_layer.add_child(close)
	set_process(true)


func set_mini_pos(p: Vector2) -> void:
	if mini:
		mini.position = p


func toggle() -> void:
	full_layer.visible = not full_layer.visible


func is_open() -> bool:
	return full_layer != null and full_layer.visible


func _process(_d: float) -> void:
	if mini and mini.visible:
		mini.queue_redraw()
	if full_layer and full_layer.visible:
		full.queue_redraw()


func _world_to_map(w: Vector2, rect: Rect2) -> Vector2:
	var u := (w.x - world_rect.position.x) / world_rect.size.x
	var v := (w.y - world_rect.position.y) / world_rect.size.y
	return rect.position + Vector2(u * rect.size.x, v * rect.size.y)


func _draw_full() -> void:
	var vp := full.get_viewport_rect().size
	var side := minf(vp.x, vp.y) * 0.74
	var r := Rect2((vp - Vector2(side, side)) * 0.5, Vector2(side, side))
	_draw_map(full, r, true)
	full.draw_string(_font, Vector2(r.position.x, r.position.y - 18), "NEON SPRINGS — city map",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.5, 1.0, 0.95))


func _draw_map(ci: CanvasItem, rect: Rect2, big: bool) -> void:
	# backdrop
	ci.draw_rect(rect, Color(0.05, 0.06, 0.10, 0.85 if big else 0.6))
	ci.draw_rect(rect, Color(0.4, 0.9, 0.85, 0.9), false, 2.0)
	# cell grid (4x4)
	var cols := 4
	for i in range(1, cols):
		var x := rect.position.x + rect.size.x * float(i) / cols
		ci.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.position.y + rect.size.y), Color(0.3, 0.4, 0.5, 0.4), 1.0)
		var y := rect.position.y + rect.size.y * float(i) / cols
		ci.draw_line(Vector2(rect.position.x, y), Vector2(rect.position.x + rect.size.x, y), Color(0.3, 0.4, 0.5, 0.4), 1.0)
	# "Strip" highlight band (central columns)
	var band := Rect2(rect.position.x + rect.size.x * 0.25, rect.position.y, rect.size.x * 0.5, rect.size.y)
	ci.draw_rect(band, Color(0.95, 0.4, 0.7, 0.10))
	# venue / landmark markers
	var dot := 7.0 if not big else 13.0
	for v in venues:
		var mp := _world_to_map(v.pos, rect)
		ci.draw_circle(mp, dot, v.color)
		ci.draw_circle(mp, dot, Color(1, 1, 1, 0.8), false, 1.5)
		if big:
			ci.draw_string(_font, mp + Vector2(dot + 4, 6), String(v.name), HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.92, 0.95, 1.0))
	# player triangle (position + heading)
	if player:
		var pp := _world_to_map(Vector2(player.global_position.x, player.global_position.z), rect)
		var fwd := player.global_transform.basis.z   # +Z = facing/heading
		var ang := atan2(fwd.z, fwd.x)
		var s := 9.0 if not big else 15.0
		var p1 := pp + Vector2(cos(ang), sin(ang)) * s
		var p2 := pp + Vector2(cos(ang + 2.5), sin(ang + 2.5)) * s * 0.7
		var p3 := pp + Vector2(cos(ang - 2.5), sin(ang - 2.5)) * s * 0.7
		ci.draw_colored_polygon(PackedVector2Array([p1, p2, p3]), Color(1.0, 0.95, 0.3))
		ci.draw_circle(pp, 2.5, Color(0.1, 0.1, 0.1))
