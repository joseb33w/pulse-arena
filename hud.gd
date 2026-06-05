extends Control
## Pulse Arena HUD — a single immediate-mode overlay. main.gd pushes state into
## the public vars below and this node draws the crosshair, mobile controls,
## health bar, score, hit-marker, damage flash and the tap-to-start / downed /
## game-over screens. Input is handled in main.gd against get_fire_rect() so the
## touch zones line up exactly with what is drawn here.

enum Phase { TAP_START, PLAYING, GAME_OVER }

const CYAN := Color(0.25, 0.95, 1.0)
const MAGENTA := Color(1.0, 0.28, 0.72)
const WARN := Color(1.0, 0.32, 0.30)
const INK := Color(0.03, 0.05, 0.09)

var phase: int = Phase.TAP_START
var hp: int = 3
var max_hp: int = 3
var my_score: int = 0
var foe_score: int = 0
var win_score: int = 10
var room_code: String = ""
var foe_name: String = ""
var foe_connected: bool = false

var touch_ui: bool = false
var move_active: bool = false
var move_origin: Vector2 = Vector2.ZERO
var move_vec: Vector2 = Vector2.ZERO
var fire_down: bool = false

var hitmarker_t: float = 0.0
var damage_t: float = 0.0

var downed: bool = false
var respawn_remaining: float = 0.0
var won: bool = false

var _t: float = 0.0
var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fit()
	get_viewport().size_changed.connect(_fit)
	set_process(true)


func _fit() -> void:
	position = Vector2.ZERO
	size = get_viewport().get_visible_rect().size


func _process(delta: float) -> void:
	_t += delta
	var vp := get_viewport().get_visible_rect().size
	if size != vp:
		_fit()
	if hitmarker_t > 0.0:
		hitmarker_t = max(0.0, hitmarker_t - delta)
	if damage_t > 0.0:
		damage_t = max(0.0, damage_t - delta)
	queue_redraw()


func flash_hit() -> void:
	hitmarker_t = 0.18


func flash_damage() -> void:
	damage_t = 0.5


func fire_radius() -> float:
	return clamp(min(size.x, size.y) * 0.12, 54.0, 96.0)


func get_fire_rect() -> Rect2:
	var r := fire_radius()
	var c := Vector2(size.x - r - 36.0, size.y - r - 48.0)
	return Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0)


func _fire_center() -> Vector2:
	var rr := get_fire_rect()
	return rr.position + rr.size * 0.5


# ---------------------------------------------------------------- draw

func _draw() -> void:
	match phase:
		Phase.PLAYING:
			_draw_play()
		Phase.TAP_START:
			_draw_play()
			_draw_tap_start()
		Phase.GAME_OVER:
			_draw_play()
			_draw_game_over()


func _draw_play() -> void:
	if damage_t > 0.0:
		var a := damage_t / 0.5
		draw_rect(Rect2(Vector2.ZERO, size), Color(1.0, 0.1, 0.18, 0.42 * a))

	_draw_scorebar()
	_draw_health()
	if phase == Phase.PLAYING and not downed:
		_draw_crosshair()
	if touch_ui:
		_draw_joystick()
		_draw_fire_button()
	if downed:
		_draw_downed()


func _draw_crosshair() -> void:
	var c := size * 0.5
	var col := CYAN if hitmarker_t <= 0.0 else Color(1, 1, 1, 1)
	var gap := 7.0
	var ln := 11.0
	var w := 2.0
	draw_line(c + Vector2(-gap - ln, 0), c + Vector2(-gap, 0), col, w)
	draw_line(c + Vector2(gap, 0), c + Vector2(gap + ln, 0), col, w)
	draw_line(c + Vector2(0, -gap - ln), c + Vector2(0, -gap), col, w)
	draw_line(c + Vector2(0, gap), c + Vector2(0, gap + ln), col, w)
	draw_circle(c, 1.6, col)
	if hitmarker_t > 0.0:
		var a := hitmarker_t / 0.18
		var hm := Color(1.0, 0.9, 0.3, a)
		var d := 14.0
		var g := 5.0
		for s: Vector2 in [Vector2(1, 1), Vector2(1, -1)]:
			draw_line(c + s * g, c + s * d, hm, 3.0)
			draw_line(c - s * g, c - s * d, hm, 3.0)


func _draw_scorebar() -> void:
	var bar_h := 56.0
	draw_rect(Rect2(0, 0, size.x, bar_h), Color(INK.r, INK.g, INK.b, 0.72))
	draw_rect(Rect2(0, bar_h - 2.0, size.x, 2.0), Color(CYAN.r, CYAN.g, CYAN.b, 0.5))

	var you := "YOU %d" % my_score
	var foe := "%d FOE" % foe_score
	var fs := 30
	draw_string(_font, Vector2(20, 38), you, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, CYAN)
	var foew := _font.get_string_size(foe, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(size.x - foew - 20, 38), foe, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, MAGENTA)

	var mid := "FIRST TO %d" % win_score
	var midw := _font.get_string_size(mid, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_string(_font, Vector2(size.x * 0.5 - midw * 0.5, 22), mid, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.7, 0.78, 0.86))

	var status := "ROOM " + room_code
	if foe_connected:
		var nm := foe_name if foe_name != "" else "opponent"
		status += "  -  vs " + nm
	else:
		status += "  -  waiting for opponent"
	var stw := _font.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	var sc := Color(0.55, 0.95, 0.7) if foe_connected else Color(1.0, 0.78, 0.32)
	draw_string(_font, Vector2(size.x * 0.5 - stw * 0.5, 50), status, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, sc)


func _draw_health() -> void:
	var pad := 6.0
	var bw := 46.0
	var bh := 16.0
	var ox := 22.0
	var oy := size.y - bh - 28.0
	draw_string(_font, Vector2(ox, oy - 8.0), "HP", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.7, 0.8, 0.9))
	for i in range(max_hp):
		var x := ox + float(i) * (bw + pad)
		var r := Rect2(x, oy, bw, bh)
		draw_rect(r, Color(0.12, 0.16, 0.22, 0.9))
		if i < hp:
			var t := float(hp) / float(max_hp)
			var col := CYAN.lerp(WARN, 1.0 - t)
			draw_rect(r.grow(-2.0), col)
		draw_rect(r.grow(1.0), Color(0.5, 0.8, 1.0, 0.35), false, 1.0)


func _draw_joystick() -> void:
	var base := move_origin if move_active else Vector2(150.0, size.y - 150.0)
	var radius := 86.0
	var ring := Color(0.6, 0.85, 1.0, 0.18 if not move_active else 0.30)
	draw_arc(base, radius, 0.0, TAU, 48, ring, 6.0)
	draw_circle(base, radius, Color(0.3, 0.6, 0.9, 0.06))
	var knob := base + move_vec * radius
	draw_circle(knob, 30.0, Color(CYAN.r, CYAN.g, CYAN.b, 0.30))
	draw_arc(knob, 30.0, 0.0, TAU, 32, CYAN, 3.0)


func _draw_fire_button() -> void:
	var c := _fire_center()
	var r := fire_radius()
	var base := Color(MAGENTA.r, MAGENTA.g, MAGENTA.b, 0.5 if fire_down else 0.22)
	draw_circle(c, r, base)
	draw_arc(c, r, 0.0, TAU, 48, MAGENTA, 4.0)
	if fire_down:
		draw_arc(c, r - 9.0, 0.0, TAU, 48, Color(1, 1, 1, 0.7), 2.0)
	var tw := _font.get_string_size("FIRE", HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
	draw_string(_font, c - Vector2(tw * 0.5, -8.0), "FIRE", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1, 1, 1, 0.92))


func _draw_downed() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.4, 0.0, 0.05, 0.45))
	_center_text("DOWNED", 56, WARN, -36)
	_center_text("respawning in %d" % ceili(respawn_remaining), 24, Color(1, 0.85, 0.85), 22)


func _draw_tap_start() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.06, 0.86))
	var pulse := 0.5 + 0.5 * sin(_t * 3.0)
	_center_text("PULSE ARENA", 64, CYAN.lerp(MAGENTA, 0.5 + 0.5 * sin(_t * 1.3)), -120)
	_center_text("low-poly arena shooter", 22, Color(0.7, 0.8, 0.9), -64)
	_center_text("TAP TO START", 34, Color(1, 1, 1, 0.55 + 0.45 * pulse), 0)
	_center_text("Move: left stick / WASD     Look: drag right / mouse", 17, Color(0.6, 0.7, 0.82), 70)
	_center_text("Fire: FIRE button / click / space", 17, Color(0.6, 0.7, 0.82), 98)
	var rl := "Room " + room_code + " - open this same link in another tab to duel"
	_center_text(rl, 16, Color(0.5, 0.85, 0.7), 140)


func _draw_game_over() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.06, 0.84))
	if won:
		var g := 0.6 + 0.4 * sin(_t * 6.0)
		_center_text("WINNER!", 78, Color(0.4 + 0.6 * g, 1.0, 0.5 + 0.4 * g), -90)
		_center_text("you cleared the arena", 24, Color(0.8, 1.0, 0.85), -20)
		for i in range(10):
			var ang := _t * 2.0 + float(i) * TAU / 10.0
			var rad := 150.0 + 40.0 * sin(_t * 3.0 + float(i))
			var p := size * 0.5 + Vector2(cos(ang), sin(ang)) * rad - Vector2(0, 40)
			var col := CYAN if i % 2 == 0 else MAGENTA
			draw_circle(p, 5.0, Color(col.r, col.g, col.b, 0.9))
	else:
		_center_text("DEFEATED", 70, WARN, -90)
		_center_text("the arena belongs to your foe", 22, Color(0.95, 0.8, 0.82), -20)
	_center_text("YOU %d   -   %d FOE" % [my_score, foe_score], 30, Color(0.85, 0.9, 1.0), 40)
	var pulse := 0.5 + 0.5 * sin(_t * 3.0)
	_center_text("TAP TO PLAY AGAIN", 26, Color(1, 1, 1, 0.5 + 0.5 * pulse), 110)


func _center_text(txt: String, fs: int, col: Color, dy: float) -> void:
	var w := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font, Vector2(size.x * 0.5 - w * 0.5, size.y * 0.5 + dy), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
