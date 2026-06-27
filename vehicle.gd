class_name Vehicle extends CharacterBody3D
## Drivable arcade car. Flat-ground (no gravity); throttle accelerates, steer turns (scaled by
## speed), friction coasts to a stop. Collides with world (buildings). main.gd toggles driving and
## feeds drive(throttle, steer); the orbit camera retargets to the car while the player is aboard.
## Engine loop pitches up with speed; a fake "headlight" emissive pops the car at night.

const MAX_SPEED := 24.0
const REVERSE_SPEED := 9.0
const ACCEL := 20.0
const BRAKE := 30.0
const FRICTION := 12.0
const TURN := 2.0
const MODEL_YAW := 180.0   # rotate the car model so its NOSE points the body's +Z drive axis

var speed := 0.0
var model: Node3D
var _engine: AudioStreamPlayer3D
var label: String = "Sedan"


func setup(car_model: Node3D, _label := "Sedan") -> void:
	label = _label
	collision_layer = 1            # world layer — ambient/peds avoid; player mask includes 1
	collision_mask = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 1.3, 4.4)
	cs.shape = box
	cs.position.y = 0.7
	add_child(cs)
	if car_model:
		model = car_model
		add_child(model)
		model.rotation.y = deg_to_rad(MODEL_YAW)
		_seat(model)
	# attach an engine loop (idles quietly; pitch rises with speed in drive())
	if ResourceLoader.exists("res://audio/engine.wav"):
		_engine = AudioManager.attach_loop(self, load("res://audio/engine.wav"), -14.0, 30.0, 8.0)
		if _engine:
			_engine.position.y = 0.5


func _seat(n: Node3D) -> void:
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


# throttle in [-1,1] (forward/back), steer in [-1,1] (left/right). Called from main while driving.
func drive(throttle: float, steer: float, delta: float) -> void:
	if throttle > 0.05:
		speed += ACCEL * throttle * delta
	elif throttle < -0.05:
		speed += -BRAKE * (-throttle) * delta if speed > 0.0 else -ACCEL * (-throttle) * delta
	else:
		speed = move_toward(speed, 0.0, FRICTION * delta)
	speed = clampf(speed, -REVERSE_SPEED, MAX_SPEED)
	if absf(speed) > 0.4:
		var spd_factor := clampf(absf(speed) / 8.0, 0.35, 1.0)
		rotation.y -= steer * TURN * delta * signf(speed) * spd_factor
	var fwd := global_transform.basis.z   # body +Z is the drive axis (model nose aligned to it)
	velocity = fwd * speed
	velocity.y = 0.0
	move_and_slide()
	# if we slammed a wall, bleed speed so we don't grind
	if get_slide_collision_count() > 0 and absf(speed) > 6.0:
		speed *= 0.6
	if _engine:
		_engine.pitch_scale = 0.7 + clampf(absf(speed) / MAX_SPEED, 0.0, 1.0) * 1.3
		_engine.volume_db = lerpf(-16.0, -6.0, clampf(absf(speed) / MAX_SPEED, 0.0, 1.0))


func coast(delta: float) -> void:
	# parked: ease to stop + idle the engine quiet
	speed = move_toward(speed, 0.0, FRICTION * delta)
	if _engine:
		_engine.pitch_scale = 0.7
		_engine.volume_db = -22.0
