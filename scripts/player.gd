extends Node2D
class_name BoardPlayer

signal step_reached(cell_index: int)
signal movement_finished(cell_index: int)

@export_range(100.0, 2000.0, 10.0) var move_speed_pixels_per_second: float = 720.0
@export_range(0.05, 1.0, 0.01) var minimum_step_duration: float = 0.24
@export_range(1.0, 20.0, 0.5) var camera_smoothing_speed: float = 10.0

@onready var follow_camera: Camera2D = $Camera2D

var current_cell_index: int = 0
var is_moving: bool = false


func _ready() -> void:
	follow_camera.position_smoothing_enabled = true
	follow_camera.position_smoothing_speed = camera_smoothing_speed
	queue_redraw()


func place_at_cell(cell_index: int, board: BoardPath) -> void:
	current_cell_index = posmod(cell_index, board.get_cell_count())
	position = board.get_cell_position(current_cell_index)
	follow_camera.reset_smoothing()


func move_steps(step_count: int, board: BoardPath) -> void:
	if is_moving or step_count <= 0:
		return

	is_moving = true
	for _step in range(step_count):
		var next_cell := (current_cell_index + 1) % board.get_cell_count()
		await _move_smoothly_to(board.get_cell_position(next_cell))
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
	draw_circle(Vector2(6.0, 10.0), 45.0, Color(0.0, 0.0, 0.0, 0.3))
	draw_circle(Vector2.ZERO, 42.0, Color("ffb347"))
	draw_arc(Vector2.ZERO, 42.0, 0.0, TAU, 48, Color("5b3214"), 6.0, true)
	draw_circle(Vector2(-14.0, -7.0), 5.0, Color("2b241f"))
	draw_circle(Vector2(14.0, -7.0), 5.0, Color("2b241f"))
	draw_arc(Vector2(0.0, 5.0), 17.0, 0.25, PI - 0.25, 24, Color("2b241f"), 4.0, true)

