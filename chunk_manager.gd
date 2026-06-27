class_name ChunkManager extends Node
## CHUNK MANAGER — resident-RING streaming for mode=="chunk" worlds. Maintains a 3x3 ring of
## live cells around the player (Chebyshev radius RING_RADIUS), builds AT MOST ONE queued cell
## per frame (no ring-shift burst -> no main-thread jank), and EVICTS cells outside the ring
## (queue_free root+enemies) — eviction is what BOUNDS memory so the ring fits mobile Safari.
##
## This REPLACES SceneManager for chunk worlds. The one-resident ZONE path (mode!="chunk") is
## untouched — main.gd dispatches on world.mode and routes combat/HUD reads to whichever streamer
## is active. We deliberately expose the SAME public fields SceneManager does
## (enemies / current_id / current_root / transitioning) so those reads stay drop-in.
##
## NAV: props are gone -> the ground is flat, so we use ONE shared flat NavigationRegion3D sized
## to the ring instead of a per-cell runtime bake (the per-cell bake is the main-thread stall the
## prototype must avoid + would corrupt the memory/jank number). enemy.gd also direct-chases when
## the path is degenerate, so a missing/rebuilding region still chases.
##
## HOT-RELOAD (B2): reload(new_world) re-parses the grid in place when the polled world.json
## changes. RESIDENT cells whose record actually CHANGED are rebuilt at the SAME world offset
## (no player move, no fade); non-resident cells just refresh their grid record so the new layout
## is applied the next time they stream in. This is the chunk-mode counterpart of
## SceneManager.reload — which (wrongly for a ring) rebuilds the whole area and teleports the player.

const SKELETON := "/godot-assets/enemies/skeleton_warrior.glb"
const EnemyScript := preload("res://enemy.gd")

const RING_RADIUS := 1                 # Chebyshev radius -> 3x3 footprint
const MAX_RESIDENT_CELLS := 9          # hard cap = (2*RING_RADIUS+1)^2 = 9
const PROP_CAP := 12                    # max INDIVIDUAL props placed per cell (live-node budget is 9*N)
const SCATTER_MAX := 40                 # max instances per MultiMesh scatter entry (1 draw call regardless)
const DEFAULT_GROUND := [0.3, 0.33, 0.38]   # matches area_builder build_area fallback

# --- public surface mirrored from SceneManager (main.gd reads these in chunk mode) ---
var enemies: Array = []                # UNION of every resident cell's live enemies
var current_root: Node3D = null        # non-null sentinel so main._physics_process gate passes
var current_id := "chunk"              # the resident cell's area id (HUD + reach_area target)
var transitioning := false             # chunk mode never fades, so always false after setup

# Emitted when the player crosses into a new cell — main.gd wires it to quest.notify_area
# so reach_area objectives + the world goal progress in chunk mode EXACTLY as in zone mode.
# The id matches the reassembler's idFor(gx,gz) = "c<gx>_<gz>", so quest reach_area targets
# and the qgcheck goal cell line up with what the runtime reports (full winnability parity).
signal area_entered(area_id: String)

# --- wiring (set in setup) ---
var builder: AreaBuilder               # reusable asset/cache/download layer + _box/_col/_mat helpers
var player: Node3D
var world_main: Node                   # passed to enemy.setup as `world` (-> on_enemy_killed)
var env: Environment
var interaction: InteractionSystem     # chunk npc/chest/door registration (per-cell, evict-cleaned)
var rpg: RpgState                      # for enemy/quest hooks parity with the zone path

# --- chunk world data ---
var cell_size := 16.0
var grid := {}                         # cell_key "gx,gz" -> cell record Dictionary
var start_cell := Vector2i.ZERO

# --- resident ring state ---
var resident := {}                     # cell_key "gx,gz" -> { root: Node3D, enemies: Array }
var _build_queue: Array = []           # Array[Vector2i] of in-ring cells awaiting build (FIFO-ish)
var _cur_cell := Vector2i(2147483647, 0)   # forces a ring update on the first frame
var _building := false                 # guards the at-most-one-per-frame async build
var _started := false
var _heading := Vector2i.ZERO          # last non-zero grid-step direction (for pre-warm ordering)
var _reloading := false                # guards a hot-reload rebuild so tick's per-frame build waits
var paused := false                    # interiors freeze the ring (no build/evict) while the player is inside

# --- shared flat nav ---
var _nav_region: NavigationRegion3D = null
var _nav_root: Node3D = null           # parents the shared nav + apron colliders (never evicted)


func setup(p: Node3D, b: AreaBuilder, main: Node, environment: Environment, inter: InteractionSystem = null, state: RpgState = null) -> void:
	player = p
	builder = b
	world_main = main
	env = environment
	interaction = inter
	rpg = state


# Called by main._boot when world.mode == "chunk" (in place of scene_manager.start()).
func start(world: Dictionary) -> void:
	cell_size = float(world.get("grid", {}).get("cell_size", 16.0))
	if cell_size <= 0.0:
		cell_size = 16.0

	var sc: Array = world.get("start_cell", [0, 0])
	if sc.size() >= 2:
		start_cell = Vector2i(int(sc[0]), int(sc[1]))

	# index every authored cell by its "gx,gz" key
	grid.clear()
	for c in world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		grid[_key(int(cc[0]), int(cc[1]))] = c

	# tint the SHARED env ONCE (per-cell tinting would flicker as the ring shifts);
	# skipped entirely when the Weather3D system owns the sky/ambient.
	if env and not env.has_meta("weather_owned"):
		var a = world.get("ambient", [0.6, 0.6, 0.66])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	# build the persistent nav holder + the shared flat NavigationRegion3D
	_nav_root = Node3D.new()
	world_main.add_child(_nav_root)
	_rebuild_shared_nav()

	# place the persistent player on the start cell centre
	player.global_position = _cell_centre(start_cell.x, start_cell.y)
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3.ZERO

	# non-null sentinel so main._physics_process's `current_root == null` gate passes in chunk mode
	current_root = _nav_root
	current_id = "chunk"
	transitioning = false
	_started = true

	# build the start cell immediately so the player never spawns over a hole, then seed the ring
	_cur_cell = start_cell
	await _build_cell_at(start_cell.x, start_cell.y)
	_update_ring(start_cell)
	# announce the spawn cell so a reach_area objective on the start cell counts immediately
	current_id = _area_id(start_cell)
	area_entered.emit(current_id)


# Driven every frame from main._process (which already reads player.global_position).
func tick(delta: float) -> void:
	if not _started or paused:
		return

	var here := _player_cell()
	if here != _cur_cell:
		var step := here - _cur_cell
		if step != Vector2i.ZERO:
			_heading = Vector2i(signi(step.x), signi(step.y))
		_cur_cell = here
		_update_ring(here)
		# crossing into a new cell counts as entering its area (reach_area + goal progression)
		current_id = _area_id(here)
		area_entered.emit(current_id)

	# build AT MOST ONE queued cell per frame (await keeps it a single in-flight build). Pause the
	# per-frame stream while a hot-reload rebuild is in flight so the two builds never interleave.
	if not _building and not _reloading and not _build_queue.is_empty():
		var next: Vector2i = _build_queue.pop_front()
		if not resident.has(_key(next.x, next.y)) and grid.has(_key(next.x, next.y)):
			_building = true
			await _build_cell_at(next.x, next.y)
			_building = false

	_prune_enemies()


# ---------------- live hot-reload (B2) ----------------

# Called by main._poll_world when chunk_mode and the polled world.json raw text changed.
# Unlike SceneManager.reload (which rebuilds the whole area at the spawn and TELEPORTS the player),
# this re-parses the grid IN PLACE and rebuilds ONLY the resident cells whose record actually
# changed, at their SAME world offset — the player never moves and nothing fades. Cells that are
# not currently resident just get their grid record refreshed; the new layout streams in next time
# the ring reaches them.
func reload(new_world: Dictionary) -> void:
	if not _started:
		return

	# re-derive cell_size + start_cell (mirror start()); guard against a degenerate/zero size.
	var new_size := float(new_world.get("grid", {}).get("cell_size", cell_size))
	if new_size <= 0.0:
		new_size = cell_size
	var new_sc: Array = new_world.get("start_cell", [start_cell.x, start_cell.y])
	if new_sc.size() >= 2:
		start_cell = Vector2i(int(new_sc[0]), int(new_sc[1]))

	# re-index the authored cells into a FRESH grid so we can diff against the prior one.
	var new_grid := {}
	for c in new_world.get("cells", []):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cc: Array = c.get("cell", [])
		if cc.size() < 2:
			continue
		new_grid[_key(int(cc[0]), int(cc[1]))] = c

	# re-tint the SHARED env (cheap, no flicker — it's a single environment, not per-cell);
	# skipped when the Weather3D system owns the sky/ambient.
	if env and not env.has_meta("weather_owned"):
		var a = new_world.get("ambient", [env.ambient_light_color.r, env.ambient_light_color.g, env.ambient_light_color.b])
		env.ambient_light_color = Color(a[0], a[1], a[2])
		env.background_color = Color(a[0] * 0.16, a[1] * 0.16, a[2] * 0.20)

	# remember the prior grid so we can diff each resident record before swapping the grid in.
	var old_grid := grid

	# A cell_size change moves every cell's world offset -> the only safe response is a full
	# re-stream. Swap the grid, drop all residents, and let the ring rebuild from the player cell.
	if not is_equal_approx(new_size, cell_size):
		cell_size = new_size
		grid = new_grid
		var all_keys: Array = resident.keys()
		for rk: String in all_keys:
			_evict(rk)
		_build_queue.clear()
		_rebuild_shared_nav()
		_cur_cell = _player_cell()
		_update_ring(_cur_cell)
		return

	# normal case: cell_size unchanged -> world offsets are stable -> rebuild changed residents only.
	grid = new_grid

	# guard the per-frame stream while we rebuild (these builds await on _ensure / GLB cache).
	_reloading = true

	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		var new_rec = new_grid.get(rk)
		var old_rec = old_grid.get(rk)
		if new_rec == null:
			# cell was DELETED from the world -> evict it; the ring will re-queue if it returns later.
			_evict(rk)
			continue
		if _records_equal(old_rec, new_rec):
			continue   # unchanged -> leave the live cell exactly as it is (no player move, no rebuild)
		# CHANGED resident -> rebuild IN PLACE at the SAME (gx,gz) world offset.
		var gx := 0
		var gz := 0
		var parts := rk.split(",")
		if parts.size() >= 2:
			gx = int(parts[0])
			gz = int(parts[1])
		# evict the old root (frees floor/walls/apron + child enemies) but DO NOT touch the player.
		_evict(rk)
		# build_cell uses a deterministic offset from gx/gz, so the cell reappears in the same spot.
		var built: Dictionary = await build_cell(new_rec, gx, gz)
		if built.is_empty():
			continue
		resident[rk] = built
		for e in built.get("enemies", []):
			enemies.append(e)

	# the resident footprint may have shifted (deletions) -> refresh the shared flat nav once.
	_rebuild_shared_nav()
	_reloading = false

	# a cell newly ADDED to the grid within the current ring should stream in NOW (not only on the
	# next cell change); non-resident cells already hold their new record for when they stream in.
	_update_ring(_cur_cell)


# Two cell records are "equal" for reload purposes iff their authored JSON is identical. We compare
# the whole Dictionary (Godot does deep == on Dictionaries/Arrays) so ANY authored field change
# (ground, enemies, props, etc.) triggers an in-place rebuild.
func _records_equal(a, b) -> bool:
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY:
		return a == b
	return (a as Dictionary) == (b as Dictionary)


# ---------------- ring maintenance ----------------

# Recompute the in-ring set around `centre`: queue cells that EXIST in the grid but aren't
# resident, and EVICT resident cells now outside the ring (this is the memory bound).
func _update_ring(centre: Vector2i) -> void:
	var wanted := {}   # cell_key -> Vector2i, the existing cells within the ring
	for gx in range(centre.x - RING_RADIUS, centre.x + RING_RADIUS + 1):
		for gz in range(centre.y - RING_RADIUS, centre.y + RING_RADIUS + 1):
			var k := _key(gx, gz)
			if grid.has(k):
				wanted[k] = Vector2i(gx, gz)

	# EVICT residents now outside the ring (grid-distance > RING_RADIUS)
	var resident_keys: Array = resident.keys()
	for rk: String in resident_keys:
		if not wanted.has(rk):
			_evict(rk)

	# QUEUE in-ring cells that aren't resident yet (and aren't already queued)
	var order: Array = wanted.values()
	order.sort_custom(_ring_priority.bind(centre))
	for cell: Vector2i in order:
		var k := _key(cell.x, cell.y)
		if resident.has(k):
			continue
		if cell in _build_queue:
			continue
		_build_queue.append(cell)


# Pre-warm the cell AHEAD of the heading first, then nearest-first (Chebyshev), so a moving
# player gets the cell they're walking into before the diagonals.
func _ring_priority(a: Vector2i, b: Vector2i, centre: Vector2i) -> bool:
	var ah := _ahead_score(a, centre)
	var bh := _ahead_score(b, centre)
	if ah != bh:
		return ah > bh                 # higher "ahead" score builds first
	return _cheb(a, centre) < _cheb(b, centre)


func _ahead_score(cell: Vector2i, centre: Vector2i) -> int:
	if _heading == Vector2i.ZERO:
		return 0
	var d := cell - centre
	return d.x * _heading.x + d.y * _heading.y


# queue_free the cell's root (which parents its enemies) and drop the dict entry.
func _evict(k: String) -> void:
	var rec = resident.get(k)
	if rec == null:
		resident.erase(k)
		return
	var root = rec.get("root")
	if root != null and is_instance_valid(root):
		(root as Node).queue_free()   # frees floor/walls/apron + child enemies
	resident.erase(k)
	# drop this cell's enemies from the union list (root.queue_free already kills the nodes)
	var cell_enemies: Array = rec.get("enemies", [])
	for e in cell_enemies:
		enemies.erase(e)
	if interaction != null:
		interaction.remove_cell(k)   # drop this cell's npc/chest/door entries -> no ghost interactables


# ---------------- cell build (world-space, open-edge walls, apron, shared nav) ----------------

func _build_cell_at(gx: int, gz: int) -> void:
	var k := _key(gx, gz)
	if resident.has(k) or not grid.has(k):
		return
	var rec: Dictionary = grid[k]
	var built: Dictionary = await build_cell(rec, gx, gz)
	if built.is_empty():
		return
	resident[k] = built
	for e in built.get("enemies", []):
		enemies.append(e)
	# the ring grew -> the shared flat nav should cover the new footprint
	_rebuild_shared_nav()

	# hard-cap safety net: should never trip (eviction keeps us <= 9), but if it does, evict the
	# farthest resident from the current cell so the cap is a true ceiling for the memory number.
	while resident.size() > MAX_RESIDENT_CELLS:
		_evict_farthest()


# Build a cell at WORLD offset (gx*cell_size, 0, gz*cell_size) — NOT origin-centered like
# build_area. Floor tile colored by cell.ground; walls ONLY on TRUE world-border edges (no
# neighbor cell in the grid), OPEN on edges shared with an adjacent existing cell; a thin apron
# collider over shared edges so the player can't fall through a not-yet-built neighbor.
# Returns { root: Node3D, enemies: Array } (compatible with the resident dict / SceneManager shape).
func build_cell(rec: Dictionary, gx: int, gz: int) -> Dictionary:
	var half := cell_size * 0.5
	var ox := float(gx) * cell_size
	var oz := float(gz) * cell_size
	var centre := Vector3(ox + half, 0.0, oz + half)

	var enemy_n := int(rec.get("enemies", 0))

	# Build the floor + walls/apron IMMEDIATELY (no downloads needed) so the cell is solid ground
	# the instant it becomes resident — scenery streams in AFTER. Without this, the player (now under
	# gravity) falls through a cell during its ~1-2s asset download and never recovers.
	var root := Node3D.new()
	world_main.add_child(root)

	# floor tile: centered on the cell's world centre, full cell footprint, slab below y=0.
	# cast_shadow=false -> the big flat floor never casts into the shadowmap (no self-acne) but
	# STILL RECEIVES shadows from props (real contact shadows).
	var ground := builder._col(rec.get("ground", DEFAULT_GROUND))
	builder._box(root, centre + Vector3(0.0, -0.5, 0.0), Vector3(cell_size, 1.0, cell_size), ground, false)

	# walls ONLY on edges with NO neighbor in the grid; OPEN + APRON on shared edges.
	var wall := Color(ground.r * 0.7, ground.g * 0.7, ground.b * 0.78)
	var wall_h := 4.0
	var wall_t := 1.0
	var apron := half * 0.25   # thin apron reaching into the (maybe unbuilt) neighbor

	# -z edge
	if grid.has(_key(gx, gz - 1)):
		_collider_box(root, centre + Vector3(0.0, -0.5, -half - apron * 0.5),
			Vector3(cell_size, 1.0, apron))
	else:
		builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, -half),
			Vector3(cell_size, wall_h, wall_t), wall)
	# +z edge
	if grid.has(_key(gx, gz + 1)):
		_collider_box(root, centre + Vector3(0.0, -0.5, half + apron * 0.5),
			Vector3(cell_size, 1.0, apron))
	else:
		builder._box(root, centre + Vector3(0.0, wall_h * 0.5 - 0.5, half),
			Vector3(cell_size, wall_h, wall_t), wall)
	# -x edge
	if grid.has(_key(gx - 1, gz)):
		_collider_box(root, centre + Vector3(-half - apron * 0.5, -0.5, 0.0),
			Vector3(apron, 1.0, cell_size))
	else:
		builder._box(root, centre + Vector3(-half, wall_h * 0.5 - 0.5, 0.0),
			Vector3(wall_t, wall_h, cell_size), wall)
	# +x edge
	if grid.has(_key(gx + 1, gz)):
		_collider_box(root, centre + Vector3(half + apron * 0.5, -0.5, 0.0),
			Vector3(apron, 1.0, cell_size))
	else:
		builder._box(root, centre + Vector3(half, wall_h * 0.5 - 0.5, 0.0),
			Vector3(wall_t, wall_h, cell_size), wall)

	# ---- gather EVERY asset url (enemy + scenery) for ONE parallel download (cache-shared) ----
	var scatter_list = rec.get("scatter", [])
	var prop_list = rec.get("props", [])
	var landmark = rec.get("landmark", null)
	var urls: Array = []
	if enemy_n > 0:
		var eu := _enemy_model_url(rec)
		if eu != "" and not urls.has(eu):
			urls.append(eu)
	if scatter_list is Array:
		for s in scatter_list:
			var su := _asset_url(s)
			if su != "" and not urls.has(su):
				urls.append(su)
	if prop_list is Array:
		for p in prop_list:
			var pu := _asset_url(p)
			if pu != "" and not urls.has(pu):
				urls.append(pu)
	if landmark != null:
		var lu := _asset_url(landmark)
		if lu != "" and not urls.has(lu):
			urls.append(lu)
	if typeof(rec.get("npc", null)) == TYPE_DICTIONARY:
		var nu := _npc_model_url(rec.get("npc"))
		if nu != "" and not urls.has(nu):
			urls.append(nu)
	await builder._ensure(urls)

	# ---- per-cell SCENERY: landmark (1) -> individual props (capped) -> scatter (MultiMesh) ----
	# All parented to `root`, so eviction (root.queue_free) reclaims them. Grounded so nothing floats.
	if landmark != null:
		_place_one(root, landmark, centre, half)
	if prop_list is Array:
		var placed := 0
		for p in prop_list:
			if placed >= PROP_CAP:
				break
			if _place_one(root, p, centre, half):
				placed += 1
	if scatter_list is Array:
		for s in scatter_list:
			_place_scatter(root, s, centre, half)

	# ---- interactables: npc / chest / doors, parented to THIS cell (root) + tagged with the cell
	# key so _evict -> interaction.remove_cell drops the registry entries (no ghost interactables) ----
	var ckey := _key(gx, gz)
	if interaction != null:
		var npc = rec.get("npc", null)
		if typeof(npc) == TYPE_DICTIONARY:
			var np := _xz(npc.get("pos", [0, 0]))
			var npos := centre + Vector3(clampf(np.x, -half + 1.0, half - 1.0), 0.0, clampf(np.y, -half + 1.0, half - 1.0))
			var nmu := _npc_model_url(npc)
			var nmodel: Node = null
			if builder.cache.has(nmu):
				nmodel = (builder.cache[nmu] as Node).duplicate()
			interaction.add_npc(npos, String(npc.get("id", "")), String(npc.get("name", "Stranger")),
				String(npc.get("persona", "")), npc.get("lines", []), nmodel, root, ckey, String(npc.get("sound", "")))
		var chest = rec.get("chest", null)
		if typeof(chest) == TYPE_DICTIONARY:
			var cp := _xz(chest.get("pos", [0, 0]))
			var cpos := centre + Vector3(clampf(cp.x, -half + 1.0, half - 1.0), 0.0, clampf(cp.y, -half + 1.0, half - 1.0))
			interaction.add_chest(cpos, chest.get("contents", []), int(chest.get("gold", 0)), root, ckey)
		var door_list = rec.get("doors", [])
		if door_list is Array:
			for d in door_list:
				if typeof(d) != TYPE_DICTIONARY:
					continue
				var dp := _xz(d.get("pos", [0, 0]))
				var dpos := centre + Vector3(clampf(dp.x, -half + 1.0, half - 1.0), 0.0, clampf(dp.y, -half + 1.0, half - 1.0))
				interaction.add_door(dpos, float(d.get("facing", 0.0)), String(d.get("lock", "")),
					String(d.get("label", "Door")), root, ckey)

	# spawn this cell's enemies at the world offset (ring around the cell centre)
	var cell_enemies: Array = []
	var emu := _enemy_model_url(rec)
	if enemy_n > 0 and builder.cache.has(emu):
		for i in range(enemy_n):
			var e := CharacterBody3D.new()
			e.set_script(EnemyScript)
			root.add_child(e)
			var ang := TAU * float(i) / float(enemy_n)
			e.global_position = centre + Vector3(cos(ang) * (half * 0.45), 0.0, sin(ang) * (half * 0.45))
			var model: Node = (builder.cache[emu] as Node).duplicate()
			e.setup(player, model, world_main, i, enemy_n, String(rec.get("enemy_type", "skeleton")))
			cell_enemies.append(e)

	return {root = root, enemies = cell_enemies}


# A collision-ONLY box (no visible mesh) — for the edge aprons, so they stop fall-through into a
# not-yet-built neighbor WITHOUT z-fighting the neighbor's coplanar floor mesh.
func _collider_box(parent: Node, pos: Vector3, sz: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = sz
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)


# ---------------- per-cell scenery (Phase 1) ----------------

# Resolve a scenery ref to an absolute asset URL. Accepts {kind:"<palette>"} (library palette)
# OR {url|model|asset:"<path>"} where <path> is a full https url, a leading-slash R2 path
# (e.g. /<BUILD_ID>/models/keep.glb for a Meshy asset, or /godot-assets/...), or a bare
# "group/file.glb" relative to the library.
func _asset_url(ref) -> String:
	if typeof(ref) != TYPE_DICTIONARY:
		return ""
	var u := String(ref.get("url", ref.get("model", ref.get("asset", ""))))
	if u != "":
		return _resolve(u)
	return builder._palette_url(ref)   # {kind} -> origin + PALETTE[kind] (or "")


func _resolve(u: String) -> String:
	if u.begins_with("http"):
		return u
	if u.begins_with("/"):
		return builder.origin + u
	return builder.origin + "/godot-assets/" + u


# NPC model URL. A cell's npc may set {model|url|asset:"<path>"} to render as a CUSTOM character —
# a Meshy-generated person at /<BUILD_ID>/models/<name>.glb, a /godot-assets/... library char, a
# full https url, or a bare "group/file.glb". With no such field it falls back to the default
# library NPC model (KayKit Knight). interaction.add_npc idle-animates self-animated models (Meshy
# chars ship their own AnimationPlayer), so a generated person renders + idles, not T-posed.
func _npc_model_url(npc) -> String:
	if typeof(npc) == TYPE_DICTIONARY:
		var u := String(npc.get("model", npc.get("url", npc.get("asset", ""))))
		if u != "":
			return _resolve(u)
	return builder.origin + AreaBuilder.NPC_MODEL


# Enemy model URL. A cell may set {enemy_model|enemy_url:"<path>"} so its enemies render as a CUSTOM
# creature (e.g. a Meshy villain) instead of the default skeleton; same path forms as above. enemy.gd
# auto-plays an embedded AnimationPlayer (self-animated Meshy chars) or retargets KayKit rigs via
# AnimRig, so either model type animates. With no field it falls back to the default skeleton.
func _enemy_model_url(rec) -> String:
	if typeof(rec) == TYPE_DICTIONARY:
		var u := String(rec.get("enemy_model", rec.get("enemy_url", "")))
		if u != "":
			return _resolve(u)
	return builder.origin + SKELETON


# read a cell-LOCAL [x,z] (or [x,y,z]) offset from a ref's pos field
func _xz(p) -> Vector2:
	if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 2:
		var zi := 2 if (p as Array).size() > 2 else 1
		return Vector2(float(p[0]), float(p[zi]))
	return Vector2.ZERO


# Place ONE individual prop/landmark: instance from cache, position cell-local, scale, GROUND
# (drop so its base rests on the floor at y=0; never lift embedded meshes), then a box or trimesh
# collider. collider:"mesh" -> ConcavePolygonShape3D so the player walks INTO it (arches/rooms/gates).
func _place_one(root: Node, ref, centre: Vector3, half: float) -> bool:
	if typeof(ref) != TYPE_DICTIONARY:
		return false
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return false
	var src = builder.cache[url]
	if src == null:
		return false
	var n := (src as Node).duplicate() as Node3D
	if n == null:
		return false
	root.add_child(n)
	var xz := _xz(ref.get("pos", [0, 0]))
	n.position = centre + Vector3(clampf(xz.x, -half + 0.5, half - 0.5), 0.0, clampf(xz.y, -half + 0.5, half - 0.5))
	if ref.has("rot"):
		n.rotation.y = deg_to_rad(float(ref.get("rot", 0.0)))
	var sc := float(ref.get("scale", 1.0))
	if sc > 0.0 and sc != 1.0:
		n.scale = Vector3(sc, sc, sc)
	# SCALE SANITY: a hallucinated `scale` (the 160-280x coastal-stroll failure) or
	# oversized source art must never make a prop span the whole cell. Cap the
	# horizontal FOOTPRINT to the cell; height is left alone so tall-but-thin
	# buildings/towers still work.
	var foot_ab := builder._world_aabb(n)
	var foot := maxf(foot_ab.size.x, foot_ab.size.z)
	if foot > half * 2.0 and foot > 0.001:
		n.scale *= (half * 2.0) / foot
	# GROUND: floor top is y=0; drop the model so its lowest point rests there (origins vary per .glb)
	var ab := builder._world_aabb(n)
	n.position.y -= maxf(0.0, ab.position.y)
	if String(ref.get("collider", "box")) == "mesh":
		_add_mesh_collision(n)
	else:
		builder._add_prop_collision(n, root)
	# POSITIONAL place sound (a fountain hums, a machine whirs, a road has traffic) —
	# anchored to THIS prop so it fades with distance, NOT a global bed. world.json:
	# {"url":…, "sound":"fountain"} → res://audio/fountain.ogg (curl the loop into res://audio/).
	var snd := String(ref.get("sound", ""))
	if snd != "":
		var spath := "res://audio/%s.ogg" % snd
		if not ResourceLoader.exists(spath):
			spath = "res://audio/%s.wav" % snd
		if ResourceLoader.exists(spath):
			AudioManager.attach_loop(n, load(spath), -9.0, 20.0, 6.0)
	return true


# Scatter N copies of one decorative mesh as a SINGLE MultiMeshInstance3D (= one draw call).
# Decorative only (no per-instance collider). Grounded by the source mesh's base offset.
func _place_scatter(root: Node, ref, centre: Vector3, half: float) -> void:
	if typeof(ref) != TYPE_DICTIONARY:
		return
	var url := _asset_url(ref)
	if url == "" or not builder.cache.has(url):
		return
	var src = builder.cache[url]
	if src == null:
		return
	var cnt := clampi(int(ref.get("count", 8)), 1, SCATTER_MAX)
	var mesh := _extract_mesh(src as Node)
	if mesh != null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = cnt
		var drop := maxf(0.0, mesh.get_aabb().position.y)   # source-mesh base offset
		# SCALE SANITY: scatter is small ambient clutter — cap an oversized source
		# mesh so a single instance can't fill the cell (footprint <= ~5u).
		var msz := mesh.get_aabb().size
		var mdim := maxf(msz.x, msz.z)
		var base := 1.0 if (mdim <= 5.0 or mdim < 0.001) else 5.0 / mdim
		for i in range(cnt):
			var sj := randf_range(0.8, 1.2) * base
			var b := Basis().rotated(Vector3.UP, randf() * TAU).scaled(Vector3(sj, sj, sj))
			var spot := Vector2(randf_range(-half + 1.0, half - 1.0), randf_range(-half + 1.0, half - 1.0))
			mm.set_instance_transform(i, Transform3D(b, Vector3(spot.x, -drop * sj, spot.y)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.position = centre
		root.add_child(mmi)
		return
	# fallback (multi-mesh asset): a few duplicated nodes instead of a MultiMesh
	for i in range(mini(cnt, 6)):
		var d := (src as Node).duplicate() as Node3D
		if d == null:
			continue
		root.add_child(d)
		d.position = centre + Vector3(randf_range(-half + 1.0, half - 1.0), 0.0, randf_range(-half + 1.0, half - 1.0))
		d.rotation.y = randf() * TAU
		var ab := builder._world_aabb(d)
		d.position.y -= maxf(0.0, ab.position.y)


# first usable Mesh in a loaded GLB scene (handles both runtime MeshInstance3D and headless
# ImporterMeshInstance3D) — for MultiMesh scatter
func _extract_mesh(scene: Node) -> Mesh:
	var stack: Array = [scene]
	while not stack.is_empty():
		var nn = stack.pop_back()
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			return (nn as MeshInstance3D).mesh
		if nn is ImporterMeshInstance3D and (nn as ImporterMeshInstance3D).mesh != null:
			return (nn as ImporterMeshInstance3D).mesh.get_mesh()
		for c in nn.get_children():
			stack.append(c)
	return null


# Trimesh (concave) static collider over every mesh in a prop -> walkable interiors/gates/arches.
func _add_mesh_collision(node: Node) -> void:
	var stack: Array = [node]
	while not stack.is_empty():
		var nn = stack.pop_back()
		for c in nn.get_children():
			stack.append(c)
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			(nn as MeshInstance3D).create_trimesh_collision()


# ---------------- shared flat nav ----------------

# Rebuild ONE flat NavigationRegion3D spanning the current resident footprint (+1 cell margin).
# Flat plane -> trivial mesh, NO per-cell collider parse/bake (the main-thread stall). enemy.gd
# direct-chases when no path is available, so this is best-effort encircle quality, not required.
func _rebuild_shared_nav() -> void:
	if _nav_root == null:
		return
	if _nav_region != null and is_instance_valid(_nav_region):
		_nav_region.queue_free()
		_nav_region = null

	# bounding box of resident cells (fall back to the start cell so there's always a region)
	var min_gx: int = start_cell.x
	var max_gx: int = start_cell.x
	var min_gz: int = start_cell.y
	var max_gz: int = start_cell.y
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var cgx := int(parts[0])
		var cgz := int(parts[1])
		min_gx = mini(min_gx, cgx)
		max_gx = maxi(max_gx, cgx)
		min_gz = mini(min_gz, cgz)
		max_gz = maxi(max_gz, cgz)

	var pad := 1.0
	var x0 := float(min_gx) * cell_size - pad
	var x1 := float(max_gx + 1) * cell_size + pad
	var z0 := float(min_gz) * cell_size - pad
	var z1 := float(max_gz + 1) * cell_size + pad

	var nav := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.7
	# author a single flat quad at y=0 by hand -> NO geometry parse, NO bake stall
	var verts := PackedVector3Array([
		Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0),
		Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1),
	])
	nm.set_vertices(verts)
	nm.add_polygon(PackedInt32Array([0, 1, 2, 3]))
	nav.navigation_mesh = nm
	_nav_root.add_child(nav)
	_nav_region = nav


# ---------------- enemy union upkeep ----------------

func _prune_enemies() -> void:
	# drop freed/dead-and-collected enemies so the union list (read by main._attack/_refresh_stats)
	# doesn't accumulate stale refs as cells evict / enemies die.
	var live: Array = []
	for e in enemies:
		if is_instance_valid(e):
			live.append(e)
	enemies = live


# ---------------- helpers ----------------

func _key(gx: int, gz: int) -> String:
	return str(gx) + "," + str(gz)


# Area id for a cell — MUST match the reassembler's idFor(gx,gz) ("c<gx>_<gz>") so quest
# reach_area targets and the qgcheck goal cell agree with what area_entered reports.
func _area_id(c: Vector2i) -> String:
	return "c" + str(c.x) + "_" + str(c.y)


func _player_cell() -> Vector2i:
	var p := player.global_position
	return Vector2i(floori(p.x / cell_size), floori(p.z / cell_size))


func _cell_centre(gx: int, gz: int) -> Vector3:
	return Vector3(float(gx) * cell_size + cell_size * 0.5, 0.0, float(gz) * cell_size + cell_size * 0.5)


func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


func _evict_farthest() -> void:
	var worst_key := ""
	var worst_d := -1
	for k: String in resident.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var d := _cheb(Vector2i(int(parts[0]), int(parts[1])), _cur_cell)
		if d > worst_d:
			worst_d = d
			worst_key = k
	if worst_key != "":
		_evict(worst_key)


# world-space xz bounds of all authored cells — used by main.gd's auto-roam to sweep the grid.
func grid_world_rect() -> Rect2:
	var min_gx := 2147483647
	var max_gx := -2147483648
	var min_gz := 2147483647
	var max_gz := -2147483648
	for k: String in grid.keys():
		var parts := k.split(",")
		if parts.size() < 2:
			continue
		var gx := int(parts[0])
		var gz := int(parts[1])
		min_gx = mini(min_gx, gx)
		max_gx = maxi(max_gx, gx)
		min_gz = mini(min_gz, gz)
		max_gz = maxi(max_gz, gz)
	if min_gx > max_gx:
		return Rect2(cell_size * 0.5, cell_size * 0.5, cell_size, cell_size)
	var x0 := float(min_gx) * cell_size + cell_size * 0.5
	var z0 := float(min_gz) * cell_size + cell_size * 0.5
	var w := float(max_gx - min_gx) * cell_size
	var h := float(max_gz - min_gz) * cell_size
	return Rect2(x0, z0, w, h)
