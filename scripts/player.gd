extends Node2D
class_name BoardPlayer
const PSEUDO_3D_ENABLED := true

signal step_reached(cell_index: int)
signal movement_finished(cell_index: int)

@export_range(100.0, 2000.0, 10.0) var move_speed_pixels_per_second: float = 720.0
@export_range(0.05, 1.0, 0.01) var minimum_step_duration: float = 0.24
@export_range(1, 2, 1) var player_id: int = 1
@export var player_color: Color = Color("ffb347")

var current_cell_index: int = 0
var is_moving: bool = false
var _step_queue: Array[int] = []
var _step_queue_processing: bool = false
var _popup_text := ""
var _popup_color := Color.WHITE
var _popup_alpha := 0.0
var is_bankrupt := false
var _bankruptcy_effect_until := 0


func _ready() -> void:
	queue_redraw()

func _process(_delta: float) -> void:
	if _popup_alpha > 0.0 or Time.get_ticks_msec() < _bankruptcy_effect_until:
		queue_redraw()

func set_bankruptcy_state(bankrupt: bool) -> void:
	if is_bankrupt != bankrupt:
		is_bankrupt = bankrupt
		queue_redraw()

func play_bankruptcy_effect() -> void:
	is_bankrupt = true
	_bankruptcy_effect_until = Time.get_ticks_msec() + 1800
	queue_redraw()


func place_at_cell(cell_index: int, board: BoardPath) -> void:
	current_cell_index = posmod(cell_index, board.get_cell_count())
	position = board.get_cell_position(current_cell_index) + _player_offset()


func move_steps(step_count: int, board: BoardPath) -> void:
	move_steps_direction(step_count, 1, board)

func move_steps_direction(step_count: int, direction: int, board: BoardPath) -> void:
	if is_moving or step_count <= 0:
		return

	is_moving = true
	for _step in range(step_count):
		var next_cell := posmod(current_cell_index + signi(direction), board.get_cell_count())
		await _move_smoothly_to(board.get_cell_position(next_cell) + _player_offset())
		current_cell_index = next_cell
		step_reached.emit(current_cell_index)

	is_moving = false
	movement_finished.emit(current_cell_index)

func move_one_step(target_cell_index: int, board: BoardPath) -> void:
	if is_moving:
		return
	is_moving = true
	var next_cell := posmod(target_cell_index, board.get_cell_count())
	await _move_smoothly_to(board.get_cell_position(next_cell) + _player_offset())
	current_cell_index = next_cell
	is_moving = false
	step_reached.emit(current_cell_index)
	movement_finished.emit(current_cell_index)

func queue_step(target_cell_index: int, board: BoardPath) -> void:
	_step_queue.append(target_cell_index)
	if not _step_queue_processing:
		_process_step_queue(board)

func _process_step_queue(board: BoardPath) -> void:
	_step_queue_processing = true
	while not _step_queue.is_empty():
		var target_cell: int = _step_queue.pop_front()
		await move_one_step(target_cell, board)
	_step_queue_processing = false


func _move_smoothly_to(target_position: Vector2) -> void:
	var distance := position.distance_to(target_position)
	var duration := maxf(minimum_step_duration, distance / move_speed_pixels_per_second)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", target_position, duration)
	await tween.finished

func show_money_popup(amount: int) -> void:
	_popup_text = "%+d" % amount
	_popup_color = Color("75e6a5") if amount >= 0 else Color("ff7c7c")
	_popup_alpha = 1.0
	queue_redraw()
	var tween := create_tween()
	tween.tween_property(self, "_popup_alpha", 0.0, 1.4)
	tween.tween_callback(queue_redraw)


func _draw() -> void:
	var effect_active := Time.get_ticks_msec() < _bankruptcy_effect_until
	var shake := sin(float(Time.get_ticks_msec()) * 0.055) * 11.0 if effect_active else 0.0
	draw_set_transform(Vector2(shake, 0))
	var color := player_color
	if is_bankrupt: color = color.lerp(Color("8f897d"), 0.82)
	draw_set_transform(Vector2(7.0 + shake, 14.0), 0.0, Vector2(1.35, 0.48))
	draw_circle(Vector2.ZERO, 38.0, Color(0.31, 0.20, 0.10, 0.28))
	draw_set_transform(Vector2(shake, 0))
	draw_colored_polygon(PackedVector2Array([Vector2(-29, -2), Vector2(29, -2), Vector2(23, 38), Vector2(-23, 38)]), color.darkened(0.22))
	draw_circle(Vector2(0, 34), 24.0, color.darkened(0.28))
	draw_circle(Vector2(0, -8), 34.0, color)
	draw_circle(Vector2(-10, -18), 10.0, color.lightened(0.35))
	draw_arc(Vector2(0, -8), 34.0, 0.0, TAU, 40, Color("684223"), 4.0, true)
	var label := "P%d" % player_id
	var font := ThemeDB.fallback_font
	var size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22)
	draw_string(font, Vector2(-size.x * 0.5, size.y * 0.32), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)
	if effect_active:
		var bankrupt_text := "破产"
		var bankrupt_size := font.get_string_size(bankrupt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 38)
		draw_string(font, Vector2(-bankrupt_size.x * 0.5, -64), bankrupt_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 38, Color("a63d2f"))
		for offset in [Vector2(-42, 54), Vector2(-12, 68), Vector2(28, 52)]:
			draw_circle(offset, 8.0, Color("d7a62f"))
			draw_line(offset - Vector2(6, 6), offset + Vector2(6, 6), Color("8b5a2b"), 3.0)
	if _popup_alpha > 0.0:
		var popup_size := font.get_string_size(_popup_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 25)
		draw_string(font, Vector2(-popup_size.x * 0.5, -54), _popup_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color(_popup_color, _popup_alpha))
	draw_set_transform(Vector2.ZERO)

func _player_offset() -> Vector2:
	return Vector2.RIGHT.rotated(float(player_id - 1) * TAU / 6.0) * 48.0
