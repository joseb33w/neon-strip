class_name SaveSystem extends Node
## Supabase persistence (web). Orchestrates the bridge.js auth -> load -> periodic save loop and
## delegates the actual blob shape to main (save_blob / apply_loaded). On native/non-web it no-ops
## gracefully (the game still runs); cloud save just isn't available outside the browser.

const SAVE_PERIOD := 6.0

var main_ref: Node
var enabled := false
var auth_ready := false
var loaded := false
var _save_t := 0.0
var status := "offline"


func setup(mainref: Node) -> void:
	main_ref = mainref
	if not OS.has_feature("web"):
		status = "native (no cloud)"
		return
	var has_fn = JavaScriptBridge.eval("typeof window.gogiInit === 'function' ? 1 : 0", true)
	if int(has_fn) == 1:
		enabled = true
		status = "connecting"
		JavaScriptBridge.eval("window.gogiInit();", true)
	else:
		status = "bridge missing"
	set_process(true)


func _process(delta: float) -> void:
	if not enabled:
		return
	if not auth_ready:
		var r = JavaScriptBridge.eval("(window.__gogi && window.__gogi.ready) ? 1 : 0", true)
		if int(r) == 1:
			auth_ready = true
			status = "loading"
			JavaScriptBridge.eval("window.gogiLoad();", true)
		return
	if not loaded:
		var l = JavaScriptBridge.eval("(window.__gogi && window.__gogi.loaded) ? 1 : 0", true)
		if int(l) == 1:
			loaded = true
			status = "synced"
			var raw := str(JavaScriptBridge.eval("window.__gogi.data", true))
			if main_ref.has_method("apply_loaded"):
				main_ref.apply_loaded(raw)
		return
	_save_t += delta
	if _save_t >= SAVE_PERIOD:
		_save_t = 0.0
		save_now()


func save_now() -> void:
	if not enabled or not auth_ready or main_ref == null or not main_ref.has_method("save_blob"):
		return
	var blob: Dictionary = main_ref.save_blob()
	var j := JSON.stringify(blob)
	# pass as a JS string literal (double-encode) so quotes/braces survive the eval
	JavaScriptBridge.eval("window.gogiSave(%s);" % JSON.stringify(j), true)
