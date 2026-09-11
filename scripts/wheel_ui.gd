extends Control
class_name WheelUI

signal spin_requested
signal confirmation_requested

@onready var wheel_face: WheelFace = $Shade/Center/Panel/Content/WheelStage/WheelFace
@onready var status_label: Label = $Shade/Center/Panel/Content/StatusLabel
@onready var spin_button: Button = $Shade/Center/Panel/Content/Buttons/SpinButton
@onready var confirm_button: Button = $Shade/Center/Panel/Content/Buttons/ConfirmButton

func _ready() -> void:
	spin_button.pressed.connect(func() -> void: spin_requested.emit())
	confirm_button.pressed.connect(func() -> void: confirmation_requested.emit())
	visible = false

func show_ready(action_player_id: int, can_start: bool) -> void:
	wheel_face.reset_wheel()
	status_label.text = "点击开始，让转盘决定金币变化" if can_start else "观看 Player %d 的转盘" % action_player_id
	spin_button.visible = true
	spin_button.disabled = not can_start
	spin_button.text = "开始转动" if can_start else "仅行动玩家可操作"
	confirm_button.visible = false
	visible = true

func play_spin(result: int, duration: float) -> void:
	visible = true
	spin_button.visible = true
	spin_button.disabled = true
	spin_button.text = "旋转中…"
	confirm_button.visible = false
	status_label.text = "转盘旋转中…"
	wheel_face.spin_to_result(result, duration)

func show_result(result: int, can_confirm: bool, action_player_id: int) -> void:
	status_label.text = "获得 %d 金币" % result if result >= 0 else "损失 %d 金币" % absi(result)
	spin_button.visible = false
	confirm_button.visible = true
	confirm_button.disabled = not can_confirm
	confirm_button.text = "确定" if can_confirm else "由 Player %d 确认" % action_player_id

func hide_wheel() -> void:
	visible = false
