class_name CasinoGames extends Node
## Playable casino games that bet real chips against RpgState: a 3-reel SLOT machine you pull,
## and a simple BLACKJACK table vs a dealer. Both are modal CanvasLayer panels centered on screen
## (anchors -> resolution-independent). Win/lose adjusts rpg.chips with a real delta + plays SFX.

const SYMS := ["7", "BAR", "BELL", "CHERRY", "DIAMOND", "STAR"]
const SLOT_BET := 2
const BJ_BET := 5

var rpg: RpgState
var layer: CanvasLayer
var _slot_panel: PanelContainer
var _bj_panel: PanelContainer

# slot state
var _reels := ["7", "7", "7"]
var _reel_labels: Array = []
var _slot_result: Label
var _slot_btn: Button
var _spin_t := 0.0

# blackjack state
var _bj_deck: Array = []
var _player: Array = []
var _dealer: Array = []
var _bj_dealer_label: RichTextLabel
var _bj_player_label: RichTextLabel
var _bj_result: Label
var _bj_hit: Button
var _bj_stand: Button
var _bj_deal: Button
var _in_round := false


func setup(state: RpgState, hud_parent: Node) -> void:
	rpg = state
	layer = CanvasLayer.new()
	layer.layer = 60
	hud_parent.add_child(layer)
	_build_slot()
	_build_blackjack()
	set_process(true)


func is_open() -> bool:
	return (_slot_panel and _slot_panel.visible) or (_bj_panel and _bj_panel.visible)


# ------------- shared panel chrome -------------

func _panel(title: String) -> VBoxContainer:
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.custom_minimum_size = Vector2(560, 520)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.05, 0.13, 0.97)
	sb.border_color = Color(0.95, 0.25, 0.65)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(14)
	sb.set_content_margin_all(22)
	pc.add_theme_stylebox_override("panel", sb)
	pc.visible = false
	layer.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	pc.add_child(vb)
	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 36)
	t.add_theme_color_override("font_color", Color(0.4, 1.0, 0.95))
	vb.add_child(t)
	pc.set_meta("panel", pc)
	return vb


func _big_button(text: String, cb: Callable, col := Color(0.95, 0.3, 0.55)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 74)
	b.add_theme_font_size_override("font_size", 30)
	b.pressed.connect(cb)
	return b


# ------------- SLOT MACHINE -------------

func _build_slot() -> void:
	var vb := _panel("SLOTS  -  bet %d chips" % SLOT_BET)
	_slot_panel = vb.get_parent() as PanelContainer
	var reels := HBoxContainer.new()
	reels.alignment = BoxContainer.ALIGNMENT_CENTER
	reels.add_theme_constant_override("separation", 18)
	vb.add_child(reels)
	for i in 3:
		var rp := PanelContainer.new()
		rp.custom_minimum_size = Vector2(150, 170)
		var rs := StyleBoxFlat.new()
		rs.bg_color = Color(0.02, 0.02, 0.04)
		rs.border_color = Color(1.0, 0.85, 0.2)
		rs.set_border_width_all(3)
		rs.set_corner_radius_all(10)
		rp.add_theme_stylebox_override("panel", rs)
		reels.add_child(rp)
		var l := Label.new()
		l.text = "7"
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 40)
		l.add_theme_color_override("font_color", Color(1.0, 0.95, 0.6))
		rp.add_child(l)
		_reel_labels.append(l)
	_slot_result = Label.new()
	_slot_result.text = "Pull the lever!"
	_slot_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_result.add_theme_font_size_override("font_size", 26)
	_slot_result.add_theme_color_override("font_color", Color(0.95, 0.95, 0.8))
	vb.add_child(_slot_result)
	_slot_btn = _big_button("PULL", _pull, Color(0.95, 0.2, 0.4))
	vb.add_child(_slot_btn)
	vb.add_child(_big_button("Leave Table", func() -> void: _slot_panel.visible = false, Color(0.3, 0.3, 0.4)))


func open_slots() -> void:
	if _bj_panel:
		_bj_panel.visible = false
	_slot_panel.visible = true
	_slot_result.text = "Pull the lever!   (you have %d chips)" % rpg.chips


func _pull() -> void:
	if _spin_t > 0.0:
		return
	if rpg.chips < SLOT_BET:
		_slot_result.text = "Not enough chips! Find more around the Strip."
		AudioManager.play_sfx("ui_error" if AudioManager.has_sfx("ui_error") else "ui")
		return
	rpg.spend_chips(SLOT_BET)
	AudioManager.play_sfx("slot" if AudioManager.has_sfx("slot") else "ui")
	_spin_t = 1.1
	_slot_btn.disabled = true
	_slot_result.text = "Spinning..."


func _finish_spin() -> void:
	for i in 3:
		_reels[i] = SYMS[randi() % SYMS.size()]
		(_reel_labels[i] as Label).text = _reels[i]
	_slot_btn.disabled = false
	var payout := 0
	if _reels[0] == _reels[1] and _reels[1] == _reels[2]:
		match _reels[0]:
			"7": payout = SLOT_BET * 50
			"DIAMOND": payout = SLOT_BET * 25
			"STAR": payout = SLOT_BET * 15
			_: payout = SLOT_BET * 10
	elif _reels[0] == _reels[1] or _reels[1] == _reels[2] or _reels[0] == _reels[2]:
		payout = SLOT_BET * 2
	if payout > 0:
		rpg.add_chips(payout)
		_slot_result.text = "WIN!  +%d chips   (total %d)" % [payout, rpg.chips]
		AudioManager.play_sfx("win" if AudioManager.has_sfx("win") else "success")
	else:
		_slot_result.text = "No luck. Pull again!   (%d chips)" % rpg.chips
		AudioManager.play_sfx("lose" if AudioManager.has_sfx("lose") else "ui_back")


# ------------- BLACKJACK -------------

func _build_blackjack() -> void:
	var vb := _panel("BLACKJACK  -  bet %d chips" % BJ_BET)
	_bj_panel = vb.get_parent() as PanelContainer
	_bj_dealer_label = RichTextLabel.new()
	_bj_dealer_label.bbcode_enabled = true
	_bj_dealer_label.fit_content = true
	_bj_dealer_label.custom_minimum_size = Vector2(0, 70)
	_bj_dealer_label.add_theme_font_size_override("normal_font_size", 26)
	vb.add_child(_bj_dealer_label)
	_bj_player_label = RichTextLabel.new()
	_bj_player_label.bbcode_enabled = true
	_bj_player_label.fit_content = true
	_bj_player_label.custom_minimum_size = Vector2(0, 70)
	_bj_player_label.add_theme_font_size_override("normal_font_size", 26)
	vb.add_child(_bj_player_label)
	_bj_result = Label.new()
	_bj_result.text = "Deal to play."
	_bj_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bj_result.add_theme_font_size_override("font_size", 26)
	_bj_result.add_theme_color_override("font_color", Color(0.95, 0.95, 0.8))
	vb.add_child(_bj_result)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(row)
	_bj_hit = _big_button("HIT", _bj_hit_fn, Color(0.2, 0.7, 0.95))
	_bj_hit.custom_minimum_size = Vector2(150, 74)
	_bj_stand = _big_button("STAND", _bj_stand_fn, Color(0.95, 0.6, 0.2))
	_bj_stand.custom_minimum_size = Vector2(150, 74)
	row.add_child(_bj_hit)
	row.add_child(_bj_stand)
	_bj_deal = _big_button("DEAL", _bj_deal_fn, Color(0.2, 0.85, 0.45))
	vb.add_child(_bj_deal)
	vb.add_child(_big_button("Leave Table", func() -> void: _bj_panel.visible = false, Color(0.3, 0.3, 0.4)))
	_bj_set_buttons(false)


func open_blackjack() -> void:
	if _slot_panel:
		_slot_panel.visible = false
	_bj_panel.visible = true
	_in_round = false
	_bj_set_buttons(false)
	_bj_result.text = "Deal to play.   (you have %d chips)" % rpg.chips
	_bj_dealer_label.text = "[b]Dealer[/b]"
	_bj_player_label.text = "[b]You[/b]"


func _bj_set_buttons(in_round: bool) -> void:
	_bj_hit.disabled = not in_round
	_bj_stand.disabled = not in_round
	_bj_deal.disabled = in_round


func _fresh_deck() -> void:
	_bj_deck = []
	for _s in 4:
		for r in ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]:
			_bj_deck.append(r)
	_bj_deck.shuffle()


func _draw_card() -> String:
	if _bj_deck.is_empty():
		_fresh_deck()
	return _bj_deck.pop_back()


func _hand_value(hand: Array) -> int:
	var total := 0
	var aces := 0
	for c in hand:
		if c == "A":
			total += 11; aces += 1
		elif c in ["K", "Q", "J"]:
			total += 10
		else:
			total += int(c)
	while total > 21 and aces > 0:
		total -= 10; aces -= 1
	return total


func _bj_deal_fn() -> void:
	if rpg.chips < BJ_BET:
		_bj_result.text = "Not enough chips! Find more around the Strip."
		AudioManager.play_sfx("ui_error" if AudioManager.has_sfx("ui_error") else "ui")
		return
	rpg.spend_chips(BJ_BET)
	AudioManager.play_sfx("ui_confirm" if AudioManager.has_sfx("ui_confirm") else "ui")
	_fresh_deck()
	_player = [_draw_card(), _draw_card()]
	_dealer = [_draw_card(), _draw_card()]
	_in_round = true
	_bj_set_buttons(true)
	_bj_render(true)
	if _hand_value(_player) == 21:
		_bj_stand_fn()


func _bj_hit_fn() -> void:
	if not _in_round:
		return
	_player.append(_draw_card())
	AudioManager.play_sfx("ui_click" if AudioManager.has_sfx("ui_click") else "ui")
	_bj_render(true)
	if _hand_value(_player) > 21:
		_end_round("BUST! You lose %d chips." % BJ_BET, false)


func _bj_stand_fn() -> void:
	if not _in_round:
		return
	while _hand_value(_dealer) < 17:
		_dealer.append(_draw_card())
	var pv := _hand_value(_player)
	var dv := _hand_value(_dealer)
	if pv == 21 and _player.size() == 2:
		_end_round("BLACKJACK! +%d chips." % int(BJ_BET * 1.5 + BJ_BET), true, int(BJ_BET * 2.5))
	elif dv > 21 or pv > dv:
		_end_round("You win! +%d chips." % BJ_BET, true, BJ_BET * 2)
	elif pv == dv:
		_end_round("Push. Bet returned.", true, BJ_BET)
	else:
		_end_round("Dealer wins. -%d chips." % BJ_BET, false)


func _end_round(msg: String, won: bool, payout := 0) -> void:
	_in_round = false
	_bj_set_buttons(false)
	if payout > 0:
		rpg.add_chips(payout)
	_bj_render(false)
	_bj_result.text = "%s   (total %d)" % [msg, rpg.chips]
	AudioManager.play_sfx(("win" if AudioManager.has_sfx("win") else "success") if won else ("lose" if AudioManager.has_sfx("lose") else "ui_back"))


func _bj_render(hide_hole: bool) -> void:
	if hide_hole:
		_bj_dealer_label.text = "[b]Dealer[/b]:  %s  [??]" % _dealer[0]
	else:
		_bj_dealer_label.text = "[b]Dealer[/b]:  %s   = %d" % [" ".join(_dealer), _hand_value(_dealer)]
	_bj_player_label.text = "[b]You[/b]:  %s   = %d" % [" ".join(_player), _hand_value(_player)]


func _process(delta: float) -> void:
	if _spin_t > 0.0:
		_spin_t -= delta
		for i in 3:
			(_reel_labels[i] as Label).text = SYMS[randi() % SYMS.size()]
		if _spin_t <= 0.0:
			_finish_spin()
