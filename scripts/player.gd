extends Node2D
class_name BoardPlayer

signal step_reached(cell_index: int)
signal movement_finished(cell_index: int)

@export_range(100.0, 2000.0, 10.0) var move_speed_pixels_per_second: float = 720.0
@export_range(0.05, 1.0, 0.01) var minimum_step_duration: float = 0.24
@export_range(1, 2, 1) var player_id: int = 1
@export var player_color: Color = Color("ffb347")

var current_cell_index: int = 0
var is_moving: bool = false


func _ready() -> void:
	queue_redraw()


func place_at_cell(cell_index: int, board: BoardPath) -> void:
	current_cell_index = posmod(cell_index, board.get_cell_count())
	position = board.get_cell_position(current_cell_index) + _player_offset()


func move_steps(step_count: int, board: BoardPath) -> void:
	if is_moving or step_count <= 0:
		return

	is_moving = true
	for _step in range(step_count):
		var next_cell := (current_cell_index + 1) % board.get_cell_count()
		await _move_smoothly_to(board.get_cell_position(next_cell) + _player_offset())
		current_cell_index = next_cell
		step_reached.emit(current_cell_index)

	is_moving = false
	movement_finished.emit(current_cell_index)


func _move_smoothly_to(target_position: Vector2) -> void:
	var distance := position.distance_to(target_position)
	var duration := maxf(minimum_step_duration, distance / move_speed_pixels_per_second)
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(self, "position", target_position, duration)
	await tween.finished


func _draw() -> void:
	draw_circle(Vector2(5.0, 8.0), 37.0, Color(0.0, 0.0, 0.0, 0.3))
	draw_circle(Vector2.ZERO, 35.0, player_color)
	draw_arc(Vector2.ZERO, 35.0, 0.0, TAU, 40, Color("17242b"), 5.0, true)
	var label := "P%d" % player_id
	var font := ThemeDB.fallback_font
	var size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22)
	draw_string(font, Vector2(-size.x * 0.5, size.y * 0.32), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)

func _player_offset() -> Vector2:
	return Vector2(-42.0, 0.0) if player_id == 1 else Vector2(42.0, 0.0)
