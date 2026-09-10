extends Node2D

signal turn_started(roll_value: int)
signal turn_finished(cell_index: int)

@export_range(1, 6, 1) var dice_min_value: int = 1
@export_range(1, 12, 1) var dice_max_value: int = 6

@onready var board: BoardPath = $Board
@onready var player: BoardPlayer = $Player
@onready var game_ui: GameHUD = $GameUI

var turn_in_progress: bool = false
var last_roll: int = 0
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	_random.randomize()
	player.place_at_cell(0, board)
	game_ui.set_current_cell(player.current_cell_index)
	game_ui.set_roll_enabled(true)
	game_ui.roll_requested.connect(_on_roll_requested)
	player.step_reached.connect(_on_player_step_reached)


func _on_roll_requested() -> void:
	start_turn()


func generate_roll() -> int:
	return _random.randi_range(dice_min_value, dice_max_value)


func start_turn(forced_roll: int = -1) -> void:
	if turn_in_progress:
		return

	turn_in_progress = true
	last_roll = clampi(forced_roll, dice_min_value, dice_max_value) if forced_roll >= 0 else generate_roll()
	game_ui.set_roll_value(last_roll)
	game_ui.set_roll_enabled(false)
	turn_started.emit(last_roll)

	await player.move_steps(last_roll, board)

	turn_in_progress = false
	game_ui.set_roll_enabled(true)
	turn_finished.emit(player.current_cell_index)


func _on_player_step_reached(cell_index: int) -> void:
	game_ui.set_current_cell(cell_index)

