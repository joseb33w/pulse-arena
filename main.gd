extends Node3D
## Pulse Arena — orchestrator. Builds the neon arena, the first-person local
## player (move / look / shoot with touch + keyboard/mouse), drives the game loop
## (HP, respawn, scoring, win) and bridges everything to the other player over
## Supabase Realtime broadcast (see net.gd / web/bridge.js).
##
## Networking is client-authoritative friends-play. Each peer broadcasts its
## transform ~12x/sec ("st"), a "sh" event per shot for the remote tracer, and a
## "hit" event when its local raycast tags the opponent. Scores stay symmetric
## because every "hit" message is counted once on the shooter (my_score) and once
## on the target (foe_score).

const MOVE_SPEED := 6.2
const GRAVITY := 20.0
const LOOK_SENS := 0.0042
const MOUSE_SENS := 0.0022
const FIRE_COOLDOWN := 0.16
const SHOT_RANGE := 80.0
const WIN_SCORE := 10
const MAX_HP := 3
const RESPAWN_TIME := 2.0
const NET_RATE := 0.08

const CYAN := Color(0.25, 0.95, 1.0)
const MAGENTA := Color(1.0, 0.28, 0.72)

var RemotePlayer := preload("res://remote_player.gd")
var HudScript := preload("res://hud.gd")

var player: CharacterBody3D
var head: Node3D
var camera: Camera3D
var fp_gun: Node3D
var fp_muzzle: Node3D
var fx_root: Node3D
var hud
var hud_layer: CanvasLayer

var started := false
var phase: int = 0  # 0 tap, 1 playing, 2 over
var hp := MAX_HP
var dead := false
var respawn_remaining := 0.0
var my_score := 0
var foe_score := 0

var _yaw := 0.0
var _pitch := 0.0
var _shake := 0.0
var _fire_cd := 0.0
var _gun_rest := Vector3(0.26, -0.22, -0.55)

var _spawns: Array[Vector3] = []
var _peers := {}
var _last_seen := {}
var _net_accum := 0.0
var _room := ""
var _connected := false

var _used_touch := false
var _move_index := -1
var _look_index := -1
var _fire_index := -1
var _move_origin := Vector2.ZERO
var _move_vec := Vector2.ZERO
var _fire_held := false


func _ready() -> void:
	_spawns = [
		Vector3(-9.0, 0.1, -9.0), Vector3(9.0, 0.1, -9.0),
		Vector3(-9.0, 0.1, 9.0), Vector3(9.0, 0.1, 9.0),
		Vector3(0.0, 0.1, -10.0), Vector3(0.0, 0.1, 10.0),
	]
	_build_environment()
	_build_arena()
	_build_player()
	_build_hud()
	fx_root = Node3D.new()
	add_child(fx_root)

	Net.connected.connect(_on_net_connected)
	Net.message.connect(_on_net_message)
	_place_at_spawn(_spawns[randi() % _spawns.size()])
	call_deferred("_net_init")


func _net_init() -> void:
	if not OS.has_feature("web"):
		_room = "LOCAL"
		_sync_hud()
		return
	for i in range(20):
		await get_tree().process_frame
		if str(Net.local_id) != "":
			break
	Net.connect_room()
	var r: Variant = JavaScriptBridge.eval("(new URLSearchParams(location.search)).get('room')||''", true)
	if r != null and str(r) != "":
		_room = str(r)
		_sync_hud()


func _on_net_connected(room: String, _you: String) -> void:
	_room = room
	_sync_hud()


# --------------------------------------------------------------- loop

func _process(delta: float) -> void:
	if _fire_cd > 0.0:
		_fire_cd -= delta
	if _shake > 0.0:
		_shake = max(0.0, _shake - delta * 3.2)
	_apply_shake()
	_sync_hud()

	if not started:
		return

	player.rotation.y = _yaw
	head.rotation.x = _pitch

	if dead:
		respawn_remaining = max(0.0, respawn_remaining - delta)
		if respawn_remaining <= 0.0:
			_respawn()
	else:
		var want_fire := _fire_held or (not _used_touch and Input.is_action_pressed("fire"))
		if want_fire:
			_shoot()

	if started and _connected_or_room():
		_net_accum += delta
		if _net_accum >= NET_RATE:
			_net_accum = 0.0
			_broadcast_state()

	_prune_peers()


func _physics_process(delta: float) -> void:
	if not started or dead:
		return
	var input := _move_input()
	var basis := Basis(Vector3.UP, _yaw)
	var wish := basis * Vector3(input.x, 0.0, input.y)
	player.velocity.x = wish.x * MOVE_SPEED
	player.velocity.z = wish.z * MOVE_SPEED
	if player.is_on_floor():
		player.velocity.y = -1.0
	else:
		player.velocity.y -= GRAVITY * delta
	player.move_and_slide()


func _move_input() -> Vector2:
	var v := _move_vec
	v += Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward"),
	)
	if v.length() > 1.0:
		v = v.normalized()
	return v


# --------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_used_touch = true
		_handle_touch(event)
		return
	if event is InputEventScreenDrag:
		_used_touch = true
		_handle_drag(event)
		return
	if _used_touch:
		return  # ignore mouse events synthesized from touch
	if event is InputEventMouseButton and event.pressed:
		_handle_click()
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_add_look(-event.relative.x * MOUSE_SENS, -event.relative.y * MOUSE_SENS)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _handle_click() -> void:
	if phase == 0:
		_start_game(false)
		return
	if phase == 2:
		_restart()
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if phase == 0:
			_start_game(true)
			return
		if phase == 2:
			_restart()
			return
		if hud != null and hud.get_fire_rect().has_point(event.position):
			_fire_index = event.index
			_fire_held = true
		elif event.position.x < _half_x() and _move_index == -1:
			_move_index = event.index
			_move_origin = event.position
			_move_vec = Vector2.ZERO
		elif _look_index == -1:
			_look_index = event.index
	else:
		if event.index == _fire_index:
			_fire_index = -1
			_fire_held = false
		elif event.index == _move_index:
			_move_index = -1
			_move_vec = Vector2.ZERO
		elif event.index == _look_index:
			_look_index = -1


func _handle_drag(event: InputEventScreenDrag) -> void:
	if event.index == _move_index:
		_move_vec = ((event.position - _move_origin) / 78.0).limit_length(1.0)
	elif event.index == _look_index:
		_add_look(-event.relative.x * LOOK_SENS, -event.relative.y * LOOK_SENS)


func _add_look(dyaw: float, dpitch: float) -> void:
	_yaw = wrapf(_yaw + dyaw, -PI, PI)
	_pitch = clamp(_pitch + dpitch, deg_to_rad(-85.0), deg_to_rad(85.0))


func _half_x() -> float:
	return get_viewport().get_visible_rect().size.x * 0.5


# --------------------------------------------------------------- game flow

func _start_game(touch: bool) -> void:
	_used_touch = touch
	started = true
	phase = 1
	hp = MAX_HP
	dead = false
	my_score = 0
	foe_score = 0
	respawn_remaining = 0.0
	_place_at_spawn(_spawns[randi() % _spawns.size()])
	if not touch:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if hud != null:
		hud.touch_ui = touch
	_sync_hud()


func _restart() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("location.reload()", true)
	else:
		get_tree().reload_current_scene()


func _place_at_spawn(p: Vector3) -> void:
	player.global_position = p
	player.velocity = Vector3.ZERO
	var to_center := (Vector3(0, p.y, 0) - p)
	if to_center.length() > 0.01:
		_yaw = atan2(-to_center.x, -to_center.z)
	_pitch = 0.0


func _respawn() -> void:
	hp = MAX_HP
	dead = false
	_place_at_spawn(_spawns[randi() % _spawns.size()])


func _die() -> void:
	dead = true
	respawn_remaining = RESPAWN_TIME
	player.velocity = Vector3.ZERO
	_broadcast_state()


func _take_damage(_from: String) -> void:
	foe_score += 1
	if not dead:
		hp -= 1
		if hud != null:
			hud.flash_damage()
		_add_shake(0.5)
		if hp <= 0:
			_die()
	if foe_score >= WIN_SCORE:
		_game_over(false)
	_sync_hud()


func _land_hit(target_id: String) -> void:
	my_score += 1
	if hud != null:
		hud.flash_hit()
	_add_shake(0.18)
	Net.send({"t": "hit", "tg": target_id})
	if my_score >= WIN_SCORE:
		_game_over(true)
	_sync_hud()


func _game_over(win: bool) -> void:
	phase = 2
	started = false
	dead = false
	if OS.has_feature("web"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if hud != null:
		hud.won = win
	_sync_hud()


# --------------------------------------------------------------- shooting

func _shoot() -> void:
	if _fire_cd > 0.0:
		return
	_fire_cd = FIRE_COOLDOWN

	var origin := camera.global_position
	var dir := -camera.global_transform.basis.z.normalized()
	var muzzle := fp_muzzle.global_position

	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * SHOT_RANGE)
	q.collision_mask = 1 | 2
	q.collide_with_areas = true
	q.collide_with_bodies = true
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)

	var end := origin + dir * SHOT_RANGE
	if hit:
		end = hit.position
		var collider: Object = hit.get("collider")
		if collider != null and collider.has_meta("peer_id"):
			var pid := str(collider.get_meta("peer_id"))
			var rp = _peers.get(pid)
			if rp != null and not rp.dead:
				_land_hit(pid)

	spawn_muzzle_flash(muzzle, CYAN)
	spawn_tracer(muzzle, end, CYAN)
	_kick_gun()
	_add_shake(0.08)
	Net.send({"t": "sh", "o": [muzzle.x, muzzle.y, muzzle.z], "d": [dir.x, dir.y, dir.z]})


func _kick_gun() -> void:
	fp_gun.position = _gun_rest + Vector3(0, 0.02, 0.07)
	fp_gun.rotation.x = 0.10
	var t := fp_gun.create_tween()
	t.set_parallel(true)
	t.tween_property(fp_gun, "position", _gun_rest, 0.09).set_trans(Tween.TRANS_SINE)
	t.tween_property(fp_gun, "rotation:x", 0.0, 0.09).set_trans(Tween.TRANS_SINE)


# --------------------------------------------------------------- fx

func spawn_muzzle_flash(pos: Vector3, color: Color) -> void:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.16
	s.height = 0.32
	s.radial_segments = 8
	s.rings = 4
	m.mesh = s
	m.material_override = _unshaded(color)
	fx_root.add_child(m)
	m.global_position = pos
	m.scale = Vector3.ONE * 0.4
	var t := m.create_tween()
	t.tween_property(m, "scale", Vector3.ONE * 1.5, 0.05)
	t.tween_property(m, "scale", Vector3.ZERO, 0.06)
	t.tween_callback(m.queue_free)


func spawn_tracer(a: Vector3, b: Vector3, color: Color) -> void:
	var dist := a.distance_to(b)
	if dist < 0.05:
		return
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, dist)
	m.mesh = box
	var mat := _unshaded(color)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material_override = mat
	fx_root.add_child(m)
	var mid := (a + b) * 0.5
	var up := Vector3.UP
	if abs((b - a).normalized().dot(up)) > 0.99:
		up = Vector3.FORWARD
	m.look_at_from_position(mid, b, up)
	var t := m.create_tween()
	t.tween_property(mat, "albedo_color", Color(color.r, color.g, color.b, 0.0), 0.12)
	t.parallel().tween_property(m, "scale", Vector3(0.2, 0.2, 1.0), 0.12)
	t.tween_callback(m.queue_free)


func _add_shake(amount: float) -> void:
	_shake = min(1.2, max(_shake, amount))


func _apply_shake() -> void:
	if camera == null:
		return
	if _shake <= 0.0:
		camera.position = Vector3.ZERO
		return
	camera.position = Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * _shake * 0.14


# --------------------------------------------------------------- networking

func _connected_or_room() -> bool:
	return _connected or _room != "" or not OS.has_feature("web")


func _broadcast_state() -> void:
	var p := player.global_position
	Net.send({
		"t": "st",
		"p": [p.x, p.y, p.z],
		"y": _yaw,
		"pi": _pitch,
		"h": hp,
		"d": dead,
		"n": Net.local_name,
	})


func _on_net_message(data: Dictionary) -> void:
	_connected = true
	var from := str(data.get("from", ""))
	if from == "" or from == str(Net.local_id):
		return
	_last_seen[from] = Time.get_ticks_msec()
	var rp = _ensure_peer(from)
	match str(data.get("t", "")):
		"st":
			var p: Array = data.get("p", [0, 0, 0])
			var pos := Vector3(float(p[0]), float(p[1]), float(p[2]))
			rp.apply_state(pos, float(data.get("y", 0.0)), float(data.get("pi", 0.0)), int(data.get("h", MAX_HP)), bool(data.get("d", false)))
			if hud != null:
				hud.foe_connected = true
				hud.foe_name = str(data.get("n", ""))
		"sh":
			var o: Array = data.get("o", [0, 0, 0])
			var d: Array = data.get("d", [0, 0, 1])
			rp.play_shot(Vector3(float(o[0]), float(o[1]), float(o[2])), Vector3(float(d[0]), float(d[1]), float(d[2])))
		"hit":
			if str(data.get("tg", "")) == str(Net.local_id):
				_take_damage(from)


func _ensure_peer(id: String):
	if _peers.has(id):
		return _peers[id]
	var rp = RemotePlayer.new()
	rp.game = self
	add_child(rp)
	rp.set_peer(id)
	_peers[id] = rp
	return rp


func _prune_peers() -> void:
	var now := Time.get_ticks_msec()
	for id: String in _peers.keys():
		if now - int(_last_seen.get(id, 0)) > 4500:
			var rp = _peers[id]
			if is_instance_valid(rp):
				rp.queue_free()
			_peers.erase(id)
			_last_seen.erase(id)
	if _peers.is_empty() and hud != null:
		hud.foe_connected = false


# --------------------------------------------------------------- hud sync

func _sync_hud() -> void:
	if hud == null:
		return
	hud.phase = phase
	hud.hp = hp
	hud.max_hp = MAX_HP
	hud.my_score = my_score
	hud.foe_score = foe_score
	hud.win_score = WIN_SCORE
	hud.room_code = _room
	hud.touch_ui = _used_touch
	hud.move_active = _move_index != -1
	hud.move_origin = _move_origin
	hud.move_vec = _move_vec
	hud.fire_down = _fire_held
	hud.downed = dead
	hud.respawn_remaining = respawn_remaining


# --------------------------------------------------------------- build

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.02, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.32, 0.38, 0.52)
	env.ambient_light_energy = 0.85
	env.fog_enabled = true
	env.fog_light_color = Color(0.04, 0.06, 0.12)
	env.fog_density = 0.012
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -38.0, 0.0)
	sun.light_color = Color(0.85, 0.9, 1.0)
	sun.light_energy = 1.05
	sun.shadow_enabled = false
	add_child(sun)


func _build_arena() -> void:
	var grid := _grid_texture(Color(0.05, 0.07, 0.11), Color(0.15, 0.85, 1.0), 256, 6)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(26.0, 26.0)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_texture = grid
	fmat.uv1_scale = Vector3(13, 13, 1)
	fmat.emission_enabled = true
	fmat.emission_texture = grid
	fmat.emission = Color(1, 1, 1)
	fmat.emission_energy_multiplier = 0.7
	fmat.roughness = 0.7
	floor_mi.material_override = fmat
	add_child(floor_mi)
	_static_box(Vector3(0, -0.5, 0), Vector3(40, 1.0, 40), null, false)

	var half := 13.0
	var wh := 3.0
	var walls := [
		[Vector3(0, wh * 0.5, -half), Vector3(26, wh, 0.6)],
		[Vector3(0, wh * 0.5, half), Vector3(26, wh, 0.6)],
		[Vector3(-half, wh * 0.5, 0), Vector3(0.6, wh, 26)],
		[Vector3(half, wh * 0.5, 0), Vector3(0.6, wh, 26)],
	]
	for w: Array in walls:
		var pos: Vector3 = w[0]
		var sz: Vector3 = w[1]
		_static_box(pos, sz, _wall_mat(), true)
		var trim := MeshInstance3D.new()
		var tb := BoxMesh.new()
		tb.size = Vector3(sz.x, 0.12, sz.z) + Vector3(0.05, 0, 0.05)
		trim.mesh = tb
		trim.material_override = _unshaded(CYAN)
		trim.position = pos + Vector3(0, wh * 0.5, 0)
		add_child(trim)

	var covers := [
		[Vector3(-4.5, 0.9, -3.0), Vector3(1.8, 1.8, 1.8), MAGENTA],
		[Vector3(4.5, 0.7, 3.0), Vector3(2.4, 1.4, 1.6), CYAN],
		[Vector3(0.0, 1.1, 4.5), Vector3(1.4, 2.2, 1.4), MAGENTA],
		[Vector3(-3.5, 0.6, 5.5), Vector3(1.6, 1.2, 1.6), CYAN],
		[Vector3(3.5, 0.9, -5.5), Vector3(1.6, 1.8, 1.6), MAGENTA],
		[Vector3(0.0, 0.5, -2.0), Vector3(3.0, 1.0, 1.2), CYAN],
	]
	for c: Array in covers:
		var pos: Vector3 = c[0]
		var sz: Vector3 = c[1]
		var col: Color = c[2]
		_static_box(pos, sz, _cover_mat(col), true)
		var edge := MeshInstance3D.new()
		var eb := BoxMesh.new()
		eb.size = sz + Vector3(0.06, 0.06, 0.06)
		edge.mesh = eb
		var em := _unshaded(col)
		em.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		em.albedo_color = Color(col.r, col.g, col.b, 0.16)
		edge.material_override = em
		edge.position = pos
		add_child(edge)


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = 4
	player.collision_mask = 1
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.5
	cs.shape = cap
	cs.position = Vector3(0, 0.85, 0)
	player.add_child(cs)
	add_child(player)

	head = Node3D.new()
	head.position = Vector3(0, 1.5, 0)
	player.add_child(head)
	camera = Camera3D.new()
	camera.fov = 78.0
	camera.current = true
	head.add_child(camera)

	fp_gun = Node3D.new()
	fp_gun.position = _gun_rest
	camera.add_child(fp_gun)

	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.14, 0.14, 0.42)
	body.mesh = bm
	body.material_override = _solid(Color(0.16, 0.18, 0.24))
	fp_gun.add_child(body)

	var barrel := MeshInstance3D.new()
	var brm := BoxMesh.new()
	brm.size = Vector3(0.08, 0.08, 0.34)
	barrel.mesh = brm
	barrel.position = Vector3(0, 0.0, -0.34)
	barrel.material_override = _solid(Color(0.1, 0.11, 0.15))
	fp_gun.add_child(barrel)

	var core := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.1, 0.05, 0.2)
	core.mesh = cm
	core.position = Vector3(0, 0.09, -0.05)
	core.material_override = _unshaded(CYAN)
	fp_gun.add_child(core)

	fp_muzzle = Node3D.new()
	fp_muzzle.position = Vector3(0, 0, -0.54)
	fp_gun.add_child(fp_muzzle)


func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.name = "HUD"
	add_child(hud_layer)
	hud = HudScript.new()
	hud_layer.add_child(hud)


# --------------------------------------------------------------- materials / helpers

func _static_box(pos: Vector3, size: Vector3, mat, visible: bool) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	sb.position = pos
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	sb.add_child(cs)
	if visible and mat != null:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.material_override = mat
		sb.add_child(mi)
	add_child(sb)


func _grid_texture(bg: Color, line: Color, dim: int, thickness: int) -> ImageTexture:
	var img := Image.create(dim, dim, false, Image.FORMAT_RGBA8)
	img.fill(bg)
	for x in range(dim):
		for y in range(dim):
			if x < thickness or y < thickness or x >= dim - thickness or y >= dim - thickness:
				img.set_pixel(x, y, line)
	return ImageTexture.create_from_image(img)


func _wall_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.07, 0.09, 0.14)
	m.emission_enabled = true
	m.emission = Color(0.1, 0.4, 0.6)
	m.emission_energy_multiplier = 0.18
	m.roughness = 0.8
	return m


func _cover_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.08, 0.1, 0.15)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.25
	m.roughness = 0.6
	return m


func _solid(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.5
	return m


func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 3.0
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m
