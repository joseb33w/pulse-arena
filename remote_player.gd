extends Node3D
## Networked opponent avatar. main.gd spawns one of these per remote peer and
## feeds it state from Supabase Realtime broadcast. It interpolates toward the
## last received transform, tilts its head/gun to show aim, exposes a hittable
## Area3D (collision layer 2) for the shooter's raycast, flashes on damage and
## hides while its owner is downed.

const FOE := Color(1.0, 0.28, 0.72)

var peer_id: String = ""
var game: Node = null

var hp: int = 3
var dead: bool = false

var _target_pos: Vector3 = Vector3.ZERO
var _target_yaw: float = 0.0
var _target_pitch: float = 0.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _flash: float = 0.0
var _last_hp: int = 3

var _yaw_node: Node3D
var _pitch_node: Node3D
var _area: Area3D
var _mats: Array[StandardMaterial3D] = []


func _ready() -> void:
	_yaw_node = Node3D.new()
	add_child(_yaw_node)

	var body := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.42
	cap.height = 1.5
	body.mesh = cap
	body.position = Vector3(0, 0.85, 0)
	body.material_override = _mat(FOE, 0.5)
	_yaw_node.add_child(body)

	var core := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.5, 0.42, 0.5)
	core.mesh = cm
	core.position = Vector3(0, 1.05, 0)
	core.material_override = _mat(FOE.darkened(0.15), 0.9)
	_yaw_node.add_child(core)

	_pitch_node = Node3D.new()
	_pitch_node.position = Vector3(0, 1.5, 0)
	_yaw_node.add_child(_pitch_node)

	var head := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.46, 0.34, 0.46)
	head.mesh = hm
	head.material_override = _mat(FOE.lightened(0.1), 0.6)
	_pitch_node.add_child(head)

	for sx: float in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3(0.1, 0.07, 0.04)
		eye.mesh = em
		eye.position = Vector3(0.12 * sx, 0.02, -0.24)
		eye.material_override = _glow(Color(1.0, 0.95, 0.4))
		_pitch_node.add_child(eye)

	var gun := MeshInstance3D.new()
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(0.16, 0.16, 0.7)
	gun.mesh = gmesh
	gun.position = Vector3(0.22, -0.12, -0.45)
	gun.material_override = _mat(Color(0.7, 0.75, 0.85), 0.2)
	_pitch_node.add_child(gun)

	var tip := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.1, 0.1, 0.16)
	tip.mesh = tm
	tip.position = Vector3(0, 0, -0.42)
	tip.material_override = _glow(FOE)
	gun.add_child(tip)

	_area = Area3D.new()
	_area.collision_layer = 2
	_area.collision_mask = 0
	_area.monitorable = true
	_area.monitoring = false
	_area.set_meta("peer_id", peer_id)
	var cs := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.5
	shape.height = 1.7
	cs.shape = shape
	cs.position = Vector3(0, 0.9, 0)
	_area.add_child(cs)
	add_child(_area)

	_target_pos = position


func set_peer(id: String) -> void:
	peer_id = id
	if _area != null:
		_area.set_meta("peer_id", id)


func _process(delta: float) -> void:
	position = position.lerp(_target_pos, clamp(delta * 14.0, 0.0, 1.0))
	_yaw = lerp_angle(_yaw, _target_yaw, clamp(delta * 16.0, 0.0, 1.0))
	_pitch = lerp_angle(_pitch, _target_pitch, clamp(delta * 16.0, 0.0, 1.0))
	_yaw_node.rotation.y = _yaw
	_pitch_node.rotation.x = _pitch
	if _flash > 0.0:
		_flash = max(0.0, _flash - delta)
		var k := _flash / 0.22
		var c := FOE.lerp(Color(1, 1, 1), k)
		for m in _mats:
			m.emission_energy_multiplier = lerp(0.7, 3.0, k)
			m.albedo_color = c if k > 0.5 else m.albedo_color


func apply_state(pos: Vector3, yaw: float, pitch: float, new_hp: int, is_dead: bool) -> void:
	_target_pos = pos
	_target_yaw = yaw
	_target_pitch = pitch
	hp = new_hp
	if new_hp < _last_hp:
		_flash = 0.22
	_last_hp = new_hp
	_set_dead(is_dead)


func _set_dead(is_dead: bool) -> void:
	if is_dead == dead:
		return
	dead = is_dead
	_yaw_node.visible = not is_dead
	_area.monitorable = not is_dead
	_area.collision_layer = 0 if is_dead else 2


func play_shot(origin: Vector3, dir: Vector3) -> void:
	if game == null:
		return
	game.spawn_muzzle_flash(origin, FOE)
	var end := origin + dir.normalized() * 60.0
	game.spawn_tracer(origin, end, FOE)


func _mat(c: Color, emit: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = emit
	m.roughness = 0.5
	_mats.append(m)
	return m


func _glow(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 4.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m
