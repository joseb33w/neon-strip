class_name RpgState extends Node
## RPG DATA SYSTEMS (state + progression + inventory). The single serialized state blob +
## the item catalog. Pure data — no engine risk. The item catalog is inline here; for a
## large game it can become items.json streamed from R2 alongside world.json.

signal changed   ## HUD listens; emitted on any state change

const ITEMS := {
	# Neon Strip collectibles — small trinkets go in the inventory.
	"drink":       {"name": "Neon Cocktail", "type": "trinket"},
	"show_ticket": {"name": "Show Ticket", "type": "trinket"},
	"lucky_coin":  {"name": "Lucky Coin", "type": "trinket"},
	"sunglasses":  {"name": "Shades", "type": "trinket"},
	"souvenir":    {"name": "Strip Souvenir", "type": "trinket"},
}

# --- the state blob ---
var hp := 100.0
var max_hp := 100.0
var level := 1
var xp := 0
var xp_next := 30
var gold := 25            # CASH ($) — starting wallet
var chips := 10           # CASINO CHIPS — gambling currency
var inventory: Array = []
var equipped_weapon := ""
var flags := {}                 # quest/world flags (e.g. dungeon_cleared) — gate seams
var discovered: Array = []      # venue ids the player has entered (for "Discovered N/3")


# ---------------- flags ----------------

func set_flag(f: String) -> void:
	if not flags.get(f, false):
		flags[f] = true
		changed.emit()


func has_flag(f: String) -> bool:
	return flags.get(f, false)


# ---------------- progression ----------------

func grant_xp(n: int) -> void:
	xp += n
	while xp >= xp_next:
		xp -= xp_next
		_level_up()
	changed.emit()


func _level_up() -> void:
	level += 1
	max_hp += 20.0
	hp = max_hp                       # full heal on level up
	xp_next = int(xp_next * 1.4)


func take_damage(d: float) -> bool:
	hp = max(0.0, hp - d)
	changed.emit()
	return hp <= 0.0                  # true = dead


# ---------------- inventory ----------------

func add_item(id: String, qty := 1) -> void:
	for _i in range(qty):
		inventory.append(id)
	changed.emit()


func has_item(id: String) -> bool:
	return id in inventory


func consume_item(id: String) -> bool:
	if id in inventory:
		inventory.erase(id)
		changed.emit()
		return true
	return false


func equip(id: String) -> bool:
	if id in inventory and item_type(id) == "weapon":
		equipped_weapon = id
		changed.emit()
		return true
	return false


func add_gold(n: int) -> void:
	gold += n
	changed.emit()


# ---------------- chips (casino currency) ----------------

func add_chips(n: int) -> void:
	chips += n
	changed.emit()


func spend_chips(n: int) -> bool:
	if chips >= n:
		chips -= n
		changed.emit()
		return true
	return false


# ---------------- discovered venues ----------------

func discover(venue_id: String) -> bool:
	if venue_id == "" or venue_id in discovered:
		return false
	discovered.append(venue_id)
	changed.emit()
	return true


# ---------------- save / load blob ----------------

func to_dict() -> Dictionary:
	return {
		"gold": gold, "chips": chips, "inventory": inventory.duplicate(),
		"discovered": discovered.duplicate(),
	}


func from_dict(d: Dictionary) -> void:
	if d == null:
		return
	gold = int(d.get("gold", gold))
	chips = int(d.get("chips", chips))
	if d.get("inventory") is Array:
		inventory = (d["inventory"] as Array).duplicate()
	if d.get("discovered") is Array:
		discovered = (d["discovered"] as Array).duplicate()
	changed.emit()


func trinket_summary() -> String:
	var counts := {}
	for id in inventory:
		counts[id] = counts.get(id, 0) + 1
	var parts: Array = []
	for id in counts:
		var label := item_name(id)
		if counts[id] > 1:
			label += " x%d" % counts[id]
		parts.append(label)
	return ", ".join(parts) if parts.size() > 0 else "(empty)"


# ---------------- queries ----------------

func weapon_damage() -> float:
	return float(ITEMS.get(equipped_weapon, {}).get("damage", 20))


func item_name(id: String) -> String:
	return ITEMS.get(id, {}).get("name", id)


func item_type(id: String) -> String:
	return ITEMS.get(id, {}).get("type", "")


func inventory_summary() -> String:
	var counts := {}
	for id in inventory:
		counts[id] = counts.get(id, 0) + 1
	var parts: Array = []
	for id in counts:
		var label := item_name(id)
		if id == equipped_weapon:
			label = "[" + label + "]"     # equipped marker
		if counts[id] > 1:
			label += " x%d" % counts[id]
		parts.append(label)
	return ", ".join(parts)
