extends CanvasLayer
class_name GameHUD

signal host_requested
signal join_requested(address: String)
signal roll_requested
signal property_action_requested(accepted: bool)
signal wheel_spin_requested
signal wheel_confirmation_requested

@onready var startup_overlay: Control = $StartupOverlay
@onready var lobby_status_label: Label = $StartupOverlay/Center/Panel/Content/LobbyStatus
@onready var address_input: LineEdit = $StartupOverlay/Center/Panel/Content/AddressInput
@onready var host_button: Button = $StartupOverlay/Center/Panel/Content/Buttons/HostButton
@onready var join_button: Button = $StartupOverlay/Center/Panel/Content/Buttons/JoinButton
@onready var hud: Control = $HUD
@onready var current_player_label: Label = $HUD/InfoPanel/Labels/CurrentPlayerLabel
@onready var coins_label: Label = $HUD/InfoPanel/Labels/CoinsLabel
@onready var all_coins_label: Label = $HUD/InfoPanel/Labels/AllCoinsLabel
@onready var cell_label: Label = $HUD/InfoPanel/Labels/CellLabel
@onready var roll_label: Label = $HUD/InfoPanel/Labels/RollLabel
@onready var turn_status_label: Label = $HUD/InfoPanel/Labels/TurnStatusLabel
@onready var roll_button: Button = $HUD/RollButton
@onready var property_overlay: Control = $PropertyOverlay
@onready var property_title: Label = $PropertyOverlay/Center/Panel/Content/Title
@onready var property_details: Label = $PropertyOverlay/Center/Panel/Content/Details
@onready var confirm_button: Button = $PropertyOverlay/Center/Panel/Content/Actions/ConfirmButton
@onready var skip_button: Button = $PropertyOverlay/Center/Panel/Content/Actions/SkipButton
@onready var wheel_overlay: WheelUI = $WheelOverlay

func _ready() -> void:
	host_button.pressed.connect(func() -> void: host_requested.emit())
	join_button.pressed.connect(func() -> void: join_requested.emit(address_input.text.strip_edges()))
	roll_button.pressed.connect(func() -> void: roll_requested.emit())
	confirm_button.pressed.connect(func() -> void: property_action_requested.emit(true))
	skip_button.pressed.connect(func() -> void: property_action_requested.emit(false))
	wheel_overlay.spin_requested.connect(func() -> void: wheel_spin_requested.emit())
	wheel_overlay.confirmation_requested.connect(func() -> void: wheel_confirmation_requested.emit())
	show_startup()

func show_startup() -> void:
	startup_overlay.visible = true
	hud.visible = false
	property_overlay.visible = false
	wheel_overlay.hide_wheel()
	set_lobby_status("请选择 Host 或 Join")

func show_game() -> void:
	startup_overlay.visible = false
	hud.visible = true

func set_lobby_status(message: String) -> void:
	lobby_status_label.text = message

func set_lobby_buttons_enabled(enabled: bool) -> void:
	host_button.disabled = not enabled
	join_button.disabled = not enabled

func update_game_state(local_player_id: int, current_player_id: int, players: Dictionary, cell_index: int, roll_value: int, phase: String) -> void:
	current_player_label.text = "当前玩家：Player %d" % current_player_id
	var own_state: Dictionary = players.get(local_player_id, {})
	coins_label.text = "自己的金币：%d" % int(own_state.get("coins", 0))
	var p1: Dictionary = players.get(1, {})
	var p2: Dictionary = players.get(2, {})
	all_coins_label.text = "P1 %d  |  P2 %d" % [int(p1.get("coins", 0)), int(p2.get("coins", 0))]
	cell_label.text = "当前格子：%d" % cell_index
	roll_label.text = "骰子点数：%s" % (str(roll_value) if roll_value > 0 else "—")
	var is_my_turn := local_player_id == current_player_id
	var can_roll := is_my_turn and phase == "waiting"
	roll_button.disabled = not can_roll
	roll_button.text = "掷骰子" if can_roll else ("移动中…" if phase == "moving" else "等待")
	turn_status_label.text = ("轮到你操作" if phase == "waiting" else "正在处理当前回合") if is_my_turn else "等待 Player %d" % current_player_id

func show_property_prompt(action: Dictionary) -> void:
	skip_button.visible = true
	var action_type := String(action.get("type", ""))
	var price := int(action.get("price", 0))
	var cell := int(action.get("cell_index", 0))
	var level := int(action.get("property_level", 0))
	match action_type:
		"buy":
			property_title.text = "是否购买该房产？"
			property_details.text = "格子 %d\n购买价格：%d 金币" % [cell, price]
			confirm_button.text = "购买"
			skip_button.text = "跳过"
		"upgrade":
			property_title.text = "是否升级房产？"
			property_details.text = "格子 %d：L%d → L%d\n升级价格：%d 金币" % [cell, level, level + 1, price]
			confirm_button.text = "升级"
			skip_button.text = "跳过"
		"capture":
			property_title.text = "是否抢占该房产？"
			property_details.text = "房主：Player %d\n房产等级：L%d\n抢占价格：%d 金币" % [int(action.get("owner_id", -1)), level, price]
			confirm_button.text = "抢占"
			skip_button.text = "放弃"
	confirm_button.disabled = not bool(action.get("can_afford", true))
	property_overlay.visible = true

func show_event_prompt(action: Dictionary, can_confirm: bool) -> void:
	var action_type := String(action.get("type", ""))
	var amount := int(action.get("amount", 0))
	if action_type == "reward":
		property_title.text = "奖励格"
		property_details.text = "获得 %d 金币" % amount
	else:
		property_title.text = "大转盘"
		property_details.text = "获得 %d 金币" % amount if amount >= 0 else "损失 %d 金币" % absi(amount)
	confirm_button.text = "确定" if can_confirm else "等待 Player %d 确认" % int(action.get("player_id", 0))
	confirm_button.disabled = not can_confirm
	skip_button.visible = false
	property_overlay.visible = true

func show_toll_prompt(action: Dictionary, local_player_id: int) -> void:
	var payer_id := int(action["payer_id"])
	var owner_id := int(action["owner_id"])
	var amount := int(action["amount"])
	var level := int(action["property_level"])
	property_title.text = "过路费"
	if local_player_id == payer_id:
		property_details.text = "经过 Player %d 的 L%d 房产\n你支付了 %d 金币" % [owner_id, level, amount]
		confirm_button.text = "确定"
		confirm_button.disabled = false
	else:
		property_details.text = "Player %d 经过你的 L%d 房产\nPlayer %d 向你支付了 %d 金币" % [payer_id, level, payer_id, amount]
		confirm_button.text = "等待 Player %d 确认" % payer_id
		confirm_button.disabled = true
	skip_button.visible = false
	property_overlay.visible = true

func show_wheel_ready(current_player_id: int, can_start: bool) -> void:
	wheel_overlay.show_ready(current_player_id, can_start)

func play_wheel_spin(result: int, duration: float) -> void:
	wheel_overlay.play_spin(result, duration)

func show_wheel_result(result: int, can_confirm: bool, current_player_id: int) -> void:
	wheel_overlay.show_result(result, can_confirm, current_player_id)

func hide_property_prompt() -> void:
	property_overlay.visible = false

func hide_all_prompts() -> void:
	property_overlay.visible = false
	wheel_overlay.hide_wheel()
