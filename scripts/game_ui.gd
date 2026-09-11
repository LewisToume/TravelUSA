extends CanvasLayer
class_name GameHUD

signal host_requested
signal join_requested(address: String)
signal roll_requested
signal property_action_requested(accepted: bool)
signal wheel_spin_requested
signal wheel_confirmation_requested
signal shop_card_requested(card_id: String)
signal shop_closed
signal card_use_requested(card_id: String, target: int)
signal card_selected(card_id: String)
signal target_selection_cancelled
signal target_selection_confirmed
signal remote_dice_confirmed(value: int)
signal player_target_selected(player_id: int)
signal force_buy_requested

@onready var startup_overlay: Control = $StartupOverlay
@onready var lobby_status_label: Label = $StartupOverlay/Center/Panel/Content/LobbyStatus
@onready var address_input: LineEdit = $StartupOverlay/Center/Panel/Content/AddressInput
@onready var host_button: Button = $StartupOverlay/Center/Panel/Content/Buttons/HostButton
@onready var join_button: Button = $StartupOverlay/Center/Panel/Content/Buttons/JoinButton
@onready var hud: Control = $HUD
@onready var player_label: Label = $HUD/InfoPanel/Labels/PlayerLabel
@onready var coins_label: Label = $HUD/InfoPanel/Labels/CoinsLabel
@onready var stamina_label: Label = $HUD/InfoPanel/Labels/StaminaLabel
@onready var all_players_label: Label = $HUD/InfoPanel/Labels/AllPlayersLabel
@onready var cell_label: Label = $HUD/InfoPanel/Labels/CellLabel
@onready var roll_label: Label = $HUD/InfoPanel/Labels/RollLabel
@onready var action_status_label: Label = $HUD/InfoPanel/Labels/ActionStatusLabel
@onready var roll_button: Button = $HUD/RollButton
@onready var property_overlay: Control = $PropertyOverlay
@onready var property_title: Label = $PropertyOverlay/Center/Panel/Content/Title
@onready var property_details: Label = $PropertyOverlay/Center/Panel/Content/Details
@onready var confirm_button: Button = $PropertyOverlay/Center/Panel/Content/Actions/ConfirmButton
@onready var skip_button: Button = $PropertyOverlay/Center/Panel/Content/Actions/SkipButton
@onready var wheel_overlay: WheelUI = $WheelOverlay
var card_button: Button
var card_overlay: PanelContainer
var card_title: Label
var card_coins: Label
var card_list: Container
var card_close_button: Button
var toast_container: VBoxContainer
var dice_label: Label
var mailbox_button: Button
var mailbox_overlay: PanelContainer
var mailbox_list: VBoxContainer
var unread_count := 0
var _known_notification_ids: Dictionary = {}
var _latest_inventory: Dictionary = {}
var selection_overlay: PanelContainer
var selection_title: Label
var selection_details: Label
var selection_choices: HBoxContainer
var selection_confirm_button: Button
var selection_cancel_button: Button
var selected_remote_roll := 0
var force_buy_button: Button

func _ready() -> void:
	_build_card_and_toast_ui()
	host_button.pressed.connect(func() -> void: host_requested.emit())
	join_button.pressed.connect(func() -> void: join_requested.emit(address_input.text.strip_edges()))
	roll_button.pressed.connect(func() -> void: roll_requested.emit())
	confirm_button.pressed.connect(func() -> void: property_action_requested.emit(true))
	skip_button.pressed.connect(func() -> void: property_action_requested.emit(false))
	force_buy_button.pressed.connect(func() -> void: force_buy_requested.emit())
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

func update_game_state(local_player_id: int, players: Dictionary, _active_player_ids: Array, last_rolls: Dictionary, notifications: Array = []) -> void:
	player_label.text = "Player %d" % local_player_id
	var own_state: Dictionary = players.get(local_player_id, {})
	coins_label.text = "自己的金币：%d" % int(own_state.get("coins", 0))
	stamina_label.text = "自己的活力：%d" % int(own_state.get("stamina", 0))
	all_players_label.visible = false
	_latest_inventory = own_state.get("inventory", {}).duplicate(true)
	cell_label.text = "当前位置：%d" % int(own_state.get("cell", 0))
	var roll_value := int(last_rolls.get(local_player_id, 0))
	roll_label.text = "骰子点数：%s" % (str(roll_value) if roll_value > 0 else "—")
	if bool(own_state.get("last_move_was_speed", false)):
		roll_label.text += "  加速 ×2  移动：%d" % int(own_state.get("last_move_distance", roll_value))
	var resolving := String(own_state.get("action_state", GameRules.ACTION_IDLE)) == GameRules.ACTION_RESOLVING
	var has_stamina := int(own_state.get("stamina", 0)) > 0
	var can_roll := has_stamina and not resolving
	roll_button.disabled = not can_roll
	roll_button.text = "掷骰子" if can_roll else ("处理中…" if resolving else "活力不足")
	var effects: Dictionary = own_state.get("status_effects", {})
	var effect_text: Array[String] = []
	if bool(effects.get("toll_free_next_action", false)): effect_text.append("🛡免租")
	if bool(effects.get("reverse_next_move", false)): effect_text.append("↩反向")
	if int(effects.get("speed_multiplier_next_move", 1)) > 1: effect_text.append("👟×2")
	action_status_label.text = ("状态：可行动" if can_roll else ("状态：处理中" if resolving else "状态：活力不足")) + ("  " + " ".join(effect_text) if not effect_text.is_empty() else "")
	_update_mailbox(notifications)

func play_dice_roll(final_roll: int, duration: float) -> void:
	dice_label.visible = true
	dice_label.modulate.a = 1.0
	var cycles := 10
	for index in range(cycles):
		dice_label.text = "🎲 %d" % ((index % 6) + 1)
		await get_tree().create_timer(duration / float(cycles + 1)).timeout
	dice_label.text = "🎲 %d" % final_roll
	var tween := dice_label.create_tween()
	tween.tween_interval(0.45)
	tween.tween_property(dice_label, "modulate:a", 0.0, 0.25)
	tween.tween_callback(func() -> void: dice_label.visible = false)

func play_card_effect(card_id: String) -> void:
	var glyphs := {GameRules.CARD_REMOTE_DICE: "🎲", GameRules.CARD_TOLL_FREE: "🛡", GameRules.CARD_SPEED: "🪶👟", GameRules.CARD_REVERSE: "↩", GameRules.CARD_BUILD: "🏠", GameRules.CARD_DEMOLISH: "💥", GameRules.CARD_FORCE_BUY: "⚑", GameRules.CARD_EQUALIZE: "⚖"}
	if not glyphs.has(card_id):
		return
	dice_label.text = String(glyphs[card_id])
	dice_label.visible = true
	dice_label.modulate = Color.WHITE
	dice_label.scale = Vector2(0.8, 0.8)
	var start_position := dice_label.position
	var tween := dice_label.create_tween()
	tween.tween_property(dice_label, "scale", Vector2(2.25, 2.25), 0.18)
	if card_id == GameRules.CARD_SPEED:
		tween.tween_property(dice_label, "position:x", dice_label.position.x + 220.0, 0.28)
	tween.tween_property(dice_label, "scale", Vector2(1.65, 1.65), 0.22)
	tween.tween_property(dice_label, "modulate:a", 0.0, 0.4)
	tween.tween_callback(func() -> void:
		dice_label.visible = false
		dice_label.position = start_position)

func show_property_prompt(action: Dictionary) -> void:
	skip_button.visible = true
	force_buy_button.visible = false
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
			confirm_button.text = "普通抢占"
			skip_button.text = "放弃"
			force_buy_button.visible = bool(action.get("force_buy_available", false))
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
	confirm_button.text = "确定" if can_confirm else "由 Player %d 确认" % int(action.get("player_id", 0))
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
		confirm_button.text = "由 Player %d 确认" % payer_id
		confirm_button.disabled = true
	skip_button.visible = false
	property_overlay.visible = true

func show_toll_toast(action: Dictionary, local_player_id: int) -> void:
	var payer_id := int(action["payer_id"])
	var owner_id := int(action["owner_id"])
	var level := int(action["property_level"])
	var amount := int(action["amount"])
	if local_player_id == payer_id:
		show_toast("经过 Player %d 的 L%d 房产，支付 %d 金币" % [owner_id, level, amount])
	else:
		show_toast("Player %d 经过你的 L%d 房产，获得 %d 金币" % [payer_id, level, amount])

func show_toast(message: String) -> void:
	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color.WHITE)
	toast_container.add_child(label)
	var tween := label.create_tween()
	tween.tween_interval(1.5)
	tween.tween_property(label, "modulate:a", 0.0, 0.35)
	tween.tween_callback(label.queue_free)

func show_shop(inventory: Dictionary, coins: int) -> void:
	_latest_inventory = inventory.duplicate(true)
	_populate_card_list(true)
	card_title.text = "卡牌商店"
	card_coins.text = "金币：%d" % coins
	card_close_button.text = "离开商店"
	card_overlay.visible = true

func _show_inventory() -> void:
	_populate_card_list(false)
	card_title.text = "我的卡牌"
	card_coins.text = "选择卡牌后按对应方式选取目标"
	card_close_button.text = "关闭"
	card_overlay.visible = true

func _populate_card_list(shop_mode: bool) -> void:
	for child in card_list.get_children(): child.queue_free()
	for card_id in GameRules.CARD_IDS:
		var button := Button.new()
		var count := int(_latest_inventory.get(card_id, 0))
		button.custom_minimum_size = Vector2(145, 115)
		button.text = "%s\n%s" % [_card_icon(card_id), ("%d 金币" % GameRules.card_price(card_id)) if shop_mode else ("×%d" % count)]
		button.tooltip_text = String(GameRules.CARD_NAMES[card_id])
		button.add_theme_font_size_override("font_size", 30)
		button.disabled = not shop_mode and count <= 0
		if shop_mode:
			button.pressed.connect(func() -> void: shop_card_requested.emit(card_id))
		else:
			button.pressed.connect(func() -> void:
				card_selected.emit(card_id)
				card_overlay.visible = false)
		card_list.add_child(button)

func _card_icon(card_id: String) -> String:
	return {GameRules.CARD_REMOTE_DICE: "🎲", GameRules.CARD_BUILD: "🏠", GameRules.CARD_DEMOLISH: "💥", GameRules.CARD_FORCE_BUY: "⚑", GameRules.CARD_TOLL_FREE: "🛡", GameRules.CARD_REVERSE: "↩", GameRules.CARD_SPEED: "👟", GameRules.CARD_EQUALIZE: "⚖"}.get(card_id, "✦")

func _build_card_and_toast_ui() -> void:
	card_button = Button.new()
	card_button.text = "卡牌"
	card_button.position = Vector2(32, 420)
	card_button.size = Vector2(180, 64)
	card_button.add_theme_font_size_override("font_size", 28)
	card_button.pressed.connect(_show_inventory)
	hud.add_child(card_button)
	toast_container = VBoxContainer.new()
	toast_container.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_container.offset_left = -350; toast_container.offset_top = 40; toast_container.offset_right = 350; toast_container.offset_bottom = 220
	add_child(toast_container)
	dice_label = Label.new()
	dice_label.set_anchors_preset(Control.PRESET_CENTER)
	dice_label.offset_left = -130; dice_label.offset_top = -100; dice_label.offset_right = 130; dice_label.offset_bottom = 100
	dice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dice_label.add_theme_font_size_override("font_size", 72)
	dice_label.visible = false
	add_child(dice_label)
	mailbox_button = Button.new()
	mailbox_button.text = "✉ 0"
	mailbox_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	mailbox_button.offset_left = -190; mailbox_button.offset_top = 32; mailbox_button.offset_right = -32; mailbox_button.offset_bottom = 92
	mailbox_button.add_theme_font_size_override("font_size", 26)
	mailbox_button.pressed.connect(_toggle_mailbox)
	hud.add_child(mailbox_button)
	mailbox_overlay = PanelContainer.new()
	mailbox_overlay.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	mailbox_overlay.offset_left = -620; mailbox_overlay.offset_top = -310; mailbox_overlay.offset_right = -28; mailbox_overlay.offset_bottom = 310
	mailbox_list = VBoxContainer.new(); mailbox_overlay.add_child(mailbox_list)
	mailbox_overlay.visible = false; add_child(mailbox_overlay)
	card_overlay = PanelContainer.new()
	card_overlay.set_anchors_preset(Control.PRESET_CENTER)
	card_overlay.offset_left = -350; card_overlay.offset_top = -320; card_overlay.offset_right = 350; card_overlay.offset_bottom = 320
	var content := VBoxContainer.new()
	card_overlay.add_child(content)
	card_title = Label.new(); card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; card_title.add_theme_font_size_override("font_size", 36); content.add_child(card_title)
	card_coins = Label.new(); card_coins.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; card_coins.add_theme_font_size_override("font_size", 22); content.add_child(card_coins)
	card_list = GridContainer.new(); card_list.columns = 4; content.add_child(card_list)
	card_close_button = Button.new(); content.add_child(card_close_button)
	card_close_button.pressed.connect(func() -> void:
		var was_shop := card_title.text == "卡牌商店"
		card_overlay.visible = false
		if was_shop: shop_closed.emit())
	card_overlay.visible = false
	add_child(card_overlay)
	force_buy_button = Button.new()
	force_buy_button.text = "使用强购卡"
	force_buy_button.custom_minimum_size = Vector2(190, 58)
	$PropertyOverlay/Center/Panel/Content/Actions.add_child(force_buy_button)
	force_buy_button.visible = false
	_build_selection_ui()

func _build_selection_ui() -> void:
	selection_overlay = PanelContainer.new()
	selection_overlay.set_anchors_preset(Control.PRESET_CENTER_TOP)
	selection_overlay.offset_left = -410; selection_overlay.offset_top = 80; selection_overlay.offset_right = 410; selection_overlay.offset_bottom = 310
	var content := VBoxContainer.new(); selection_overlay.add_child(content)
	selection_title = Label.new(); selection_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; selection_title.add_theme_font_size_override("font_size", 32); content.add_child(selection_title)
	selection_details = Label.new(); selection_details.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; selection_details.add_theme_font_size_override("font_size", 23); content.add_child(selection_details)
	selection_choices = HBoxContainer.new(); selection_choices.alignment = BoxContainer.ALIGNMENT_CENTER; content.add_child(selection_choices)
	var actions := HBoxContainer.new(); actions.alignment = BoxContainer.ALIGNMENT_CENTER; content.add_child(actions)
	selection_confirm_button = Button.new(); selection_confirm_button.text = "确认使用"; selection_confirm_button.disabled = true; actions.add_child(selection_confirm_button)
	selection_cancel_button = Button.new(); selection_cancel_button.text = "取消"; actions.add_child(selection_cancel_button)
	selection_confirm_button.pressed.connect(func() -> void: target_selection_confirmed.emit())
	selection_cancel_button.pressed.connect(func() -> void: target_selection_cancelled.emit())
	selection_overlay.visible = false; add_child(selection_overlay)

func show_map_target_selector(title: String) -> void:
	_clear_selection_choices()
	selection_title.text = title
	selection_details.text = "点击地图中高亮并呼吸的房产"
	selection_confirm_button.visible = false
	selection_overlay.visible = true

func show_remote_dice_selector() -> void:
	_clear_selection_choices()
	selected_remote_roll = 0
	selection_title.text = "请选择骰子点数"
	selection_details.text = "请选择 1～6，再确认使用遥控骰子"
	for value in range(1, 7):
		var button := Button.new(); button.text = str(value); button.toggle_mode = true; button.custom_minimum_size = Vector2(82, 64)
		button.add_theme_font_size_override("font_size", 30)
		button.pressed.connect(func() -> void: _select_remote_roll(value, button))
		selection_choices.add_child(button)
	selection_confirm_button.visible = true
	selection_confirm_button.disabled = true
	selection_overlay.visible = true

func _select_remote_roll(value: int, selected_button: Button) -> void:
	selected_remote_roll = value
	for child in selection_choices.get_children():
		if child is Button: child.button_pressed = child == selected_button
	selection_details.text = "已选择：%d 点" % value
	selection_confirm_button.disabled = false
	for connection in selection_confirm_button.pressed.get_connections():
		selection_confirm_button.pressed.disconnect(connection.callable)
	selection_confirm_button.pressed.connect(func() -> void: remote_dice_confirmed.emit(selected_remote_roll), CONNECT_ONE_SHOT)

func show_player_selector(players: Dictionary, target_ids: Array[int]) -> void:
	_clear_selection_choices()
	selection_title.text = "请选择均富对象"
	selection_details.text = "只可选择当前视野内的其他玩家"
	for player_id in target_ids:
		var button := Button.new(); button.text = "Player %d\n%d 金币" % [player_id, int(players[player_id]["coins"])]; button.custom_minimum_size = Vector2(150, 72)
		button.pressed.connect(func() -> void: player_target_selected.emit(player_id))
		selection_choices.add_child(button)
	selection_confirm_button.visible = false
	selection_overlay.visible = true

func show_card_confirmation(title: String, details: String) -> void:
	_clear_selection_choices()
	selection_title.text = title
	selection_details.text = details
	selection_confirm_button.visible = true
	selection_confirm_button.disabled = false
	selection_overlay.visible = true

func hide_target_selector() -> void:
	selection_overlay.visible = false
	_clear_selection_choices()

func _clear_selection_choices() -> void:
	for child in selection_choices.get_children(): child.queue_free()
	for connection in selection_confirm_button.pressed.get_connections():
		selection_confirm_button.pressed.disconnect(connection.callable)
	selection_confirm_button.pressed.connect(func() -> void: target_selection_confirmed.emit())

func _update_mailbox(notifications: Array) -> void:
	for event in notifications:
		var event_id := int(event.get("event_id", 0))
		if not _known_notification_ids.has(event_id):
			_known_notification_ids[event_id] = true
			unread_count += 1
	mailbox_button.text = "✉ %d" % unread_count
	for child in mailbox_list.get_children(): child.queue_free()
	for event in notifications:
		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = "%s  %s" % [String(event.get("time", "")), String(event.get("message", ""))]
		mailbox_list.add_child(label)

func _toggle_mailbox() -> void:
	mailbox_overlay.visible = not mailbox_overlay.visible
	if mailbox_overlay.visible:
		unread_count = 0
		mailbox_button.text = "✉ 0"

func show_wheel_ready(action_player_id: int, can_start: bool) -> void:
	wheel_overlay.show_ready(action_player_id, can_start)

func play_wheel_spin(result: int, duration: float) -> void:
	wheel_overlay.play_spin(result, duration)

func show_wheel_result(result: int, can_confirm: bool, action_player_id: int) -> void:
	wheel_overlay.show_result(result, can_confirm, action_player_id)

func hide_property_prompt() -> void:
	property_overlay.visible = false

func hide_all_prompts() -> void:
	property_overlay.visible = false
	wheel_overlay.hide_wheel()
	card_overlay.visible = false
	hide_target_selector()
