extends CanvasLayer
class_name GameHUD

signal roll_requested

@onready var cell_label: Label = $HUD/InfoPanel/Labels/CellLabel
@onready var roll_label: Label = $HUD/InfoPanel/Labels/RollLabel
@onready var roll_button: Button = $HUD/RollButton


func _ready() -> void:
	roll_button.pressed.connect(_on_roll_button_pressed)


func _on_roll_button_pressed() -> void:
	roll_requested.emit()


func set_current_cell(cell_index: int) -> void:
	cell_label.text = "当前格子：%d" % cell_index


func set_roll_value(value: int) -> void:
	roll_label.text = "骰子点数：%d" % value


func set_roll_enabled(enabled: bool) -> void:
	roll_button.disabled = not enabled
	roll_button.text = "掷骰子" if enabled else "移动中…"

