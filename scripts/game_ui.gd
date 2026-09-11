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
signal quiz_answer_requested(option_index: int)
signal leaderboard_requested
signal repay_tax_requested
signal asset_management_requested
signal asset_action_requested(cell_index: int, action_type: String)

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
var bankruptcy_label: Label
var leaderboard_button: Button
var leaderboard_overlay: PanelContainer
var leaderboard_list: VBoxContainer
var quiz_overlay: PanelContainer
var quiz_progress: Label
var quiz_question: Label
var quiz_score: Label
var quiz_options: VBoxContainer
var _protection_end_time := 0
var _bankruptcy_state := GameRules.BANKRUPTCY_NORMAL
var modal_shade: ColorRect
var active_modal: Control
var warm_theme: Theme
var card_is_shop := false
var shop_coins := 0
var shop_purchases_blocked := false
var modal_close_buttons: Dictionary = {}
var estimated_tax_label: Label
var tax_debt_label: Label
var repay_tax_button: Button
var asset_management_button: Button
var asset_overlay: PanelContainer
var asset_list: VBoxContainer
var selected_player_targets: Array[int] = []

func _ready() -> void:
	_build_card_and_toast_ui()
	_build_modal_system()
	_apply_warm_theme()
	host_button.pressed.connect(func() -> void: host_requested.emit())
	join_button.pressed.connect(func() -> void: join_requested.emit(address_input.text.strip_edges()))
	roll_button.pressed.connect(func() -> void: roll_requested.emit())
	confirm_button.pressed.connect(func() -> void: property_action_requested.emit(true))
	skip_button.pressed.connect(func() -> void: property_action_requested.emit(false))
	force_buy_button.pressed.connect(func() -> void: force_buy_requested.emit())
	wheel_overlay.spin_requested.connect(func() -> void: wheel_spin_requested.emit())
	wheel_overlay.confirmation_requested.connect(func() -> void: wheel_confirmation_requested.emit())
	show_startup()
	set_process(true)

func _process(_delta: float) -> void:
	_update_bankruptcy_text()

func show_startup() -> void:
	_close_all_modals()
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
	estimated_tax_label.text = "预计税款：%d" % GameRules.daily_tax(int(own_state.get("daily_taxable_income", 0)))
	var tax_debt := int(own_state.get("tax_debt", 0))
	tax_debt_label.text = "欠税：%d" % tax_debt
	tax_debt_label.visible = tax_debt > 0
	repay_tax_button.visible = tax_debt > 0
	asset_management_button.visible = tax_debt > 0
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
	_bankruptcy_state = String(own_state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL))
	_protection_end_time = int(own_state.get("protection_end_time", 0))
	if _bankruptcy_state == GameRules.BANKRUPTCY_BANKRUPT: can_roll = false
	roll_button.disabled = not can_roll
	roll_button.text = "今日已破产" if _bankruptcy_state == GameRules.BANKRUPTCY_BANKRUPT else ("掷骰子" if can_roll else ("处理中…" if resolving else "活力不足"))
	var effects: Dictionary = own_state.get("status_effects", {})
	var effect_text: Array[String] = []
	if bool(effects.get("toll_free_next_action", false)): effect_text.append("🛡免租")
	if bool(effects.get("reverse_next_move", false)): effect_text.append("↩反向")
	if int(effects.get("speed_multiplier_next_move", 1)) > 1: effect_text.append("👟×2")
	var status_text := "状态：可行动" if can_roll else ("状态：处理中" if resolving else "状态：活力不足")
	if tax_debt > 0: status_text += "（欠税）"
	action_status_label.text = status_text + ("  " + " ".join(effect_text) if not effect_text.is_empty() else "")
	_update_bankruptcy_text()
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
	_reset_property_overlay()
	var action_type := String(action.get("type", ""))
	var price := int(action.get("price", 0))
	var cell := int(action.get("cell_index", 0))
	var level := int(action.get("property_level", 0))
	var property_type := String(action.get("property_type", GameRules.PROPERTY_HOUSE))
	var type_name := "酒店" if property_type == GameRules.PROPERTY_HOTEL else "住宅"
	match action_type:
		"buy":
			skip_button.visible = true
			property_title.text = "是否购买该房产？"
			property_details.text = "格子 %d（%s）\n购买价格：%d 金币" % [cell, type_name, price]
			confirm_button.text = "购买"
			skip_button.text = "跳过"
		"upgrade":
			skip_button.visible = true
			property_title.text = "是否升级房产？"
			property_details.text = "格子 %d（%s）：L%d → L%d\n升级价格：%d 金币" % [cell, type_name, level, level + 1, price]
			confirm_button.text = "升级"
			skip_button.text = "跳过"
		"capture":
			skip_button.visible = true
			property_title.text = "是否抢占该房产？"
			property_details.text = "房主：Player %d\n%s等级：L%d\n抢占价格：%d 金币" % [int(action.get("owner_id", -1)), type_name, level, price]
			confirm_button.text = "普通抢占"
			skip_button.text = "放弃"
			force_buy_button.visible = action_type == "capture" and property_type == GameRules.PROPERTY_HOUSE and bool(action.get("force_buy_available", false))
	confirm_button.disabled = not bool(action.get("can_afford", true))
	_open_modal(property_overlay)

func _reset_property_overlay() -> void:
	force_buy_button.visible = false
	skip_button.visible = false
	confirm_button.visible = true
	confirm_button.disabled = false

func show_event_prompt(action: Dictionary, can_confirm: bool) -> void:
	_reset_property_overlay()
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
	_open_modal(property_overlay)

func show_toll_prompt(action: Dictionary, local_player_id: int) -> void:
	_reset_property_overlay()
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
	_open_modal(property_overlay)

func show_toll_toast(action: Dictionary, local_player_id: int) -> void:
	var payer_id := int(action["payer_id"])
	var owner_id := int(action["owner_id"])
	var level := int(action["property_level"])
	var amount := int(action["amount"])
	if local_player_id == payer_id:
		show_toast("经过 Player %d 的 L%d 房产，支付 %d 金币" % [owner_id, level, amount])
	else:
		show_toast("Player %d 支付 %d 金币；因欠税由系统收取" % [payer_id, amount] if bool(action.get("system_collected", false)) else "Player %d 经过你的 L%d 房产，获得 %d 金币" % [payer_id, level, amount])

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

func show_shop(inventory: Dictionary, coins: int, purchases_blocked: bool = false) -> void:
	_latest_inventory = inventory.duplicate(true)
	shop_coins = coins
	shop_purchases_blocked = purchases_blocked
	card_is_shop = true
	_populate_card_list(true)
	card_title.text = "卡牌商店"
	card_coins.text = "欠税期间不能购买卡牌" if purchases_blocked else "金币：%d（余额必须高于价格）" % coins
	card_close_button.text = "离开商店"
	_open_modal(card_overlay)

func _show_inventory() -> void:
	card_is_shop = false
	_populate_card_list(false)
	card_title.text = "我的卡牌"
	card_coins.text = "选择卡牌后按对应方式选取目标"
	card_close_button.text = "关闭"
	_open_modal(card_overlay)

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
			button.disabled = shop_purchases_blocked or shop_coins <= GameRules.card_price(card_id)
			button.pressed.connect(func() -> void: shop_card_requested.emit(card_id))
		else:
			button.pressed.connect(func() -> void:
				_close_modal(card_overlay)
				card_selected.emit(card_id)
			)
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
	bankruptcy_label = Label.new(); bankruptcy_label.position = Vector2(32, 492); bankruptcy_label.size = Vector2(360, 44); bankruptcy_label.add_theme_font_size_override("font_size", 22); hud.add_child(bankruptcy_label)
	leaderboard_button = Button.new(); leaderboard_button.text = "排行榜"; leaderboard_button.position = Vector2(32, 548); leaderboard_button.size = Vector2(180, 58); leaderboard_button.pressed.connect(func() -> void: leaderboard_requested.emit()); hud.add_child(leaderboard_button)
	estimated_tax_label = Label.new(); estimated_tax_label.add_theme_font_size_override("font_size", 22); $HUD/InfoPanel/Labels.add_child(estimated_tax_label)
	tax_debt_label = Label.new(); tax_debt_label.position = Vector2(32, 618); tax_debt_label.size = Vector2(360, 40); tax_debt_label.add_theme_font_size_override("font_size", 25); tax_debt_label.add_theme_color_override("font_color", Color("a84022")); hud.add_child(tax_debt_label)
	repay_tax_button = Button.new(); repay_tax_button.text = "立即还税"; repay_tax_button.position = Vector2(32, 666); repay_tax_button.size = Vector2(180, 58); repay_tax_button.pressed.connect(func() -> void: repay_tax_requested.emit()); hud.add_child(repay_tax_button)
	asset_management_button = Button.new(); asset_management_button.text = "处理资产"; asset_management_button.position = Vector2(224, 666); asset_management_button.size = Vector2(180, 58); asset_management_button.pressed.connect(func() -> void: asset_management_requested.emit()); hud.add_child(asset_management_button)
	_build_asset_ui()
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
	var mailbox_content := VBoxContainer.new(); mailbox_overlay.add_child(mailbox_content)
	var mailbox_title := Label.new(); mailbox_title.text = "消息邮箱"; mailbox_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; mailbox_title.add_theme_font_size_override("font_size", 32); mailbox_content.add_child(mailbox_title)
	var mailbox_scroll := ScrollContainer.new(); mailbox_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL; mailbox_content.add_child(mailbox_scroll)
	mailbox_list = VBoxContainer.new(); mailbox_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL; mailbox_scroll.add_child(mailbox_list)
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
		_close_card_window())
	card_overlay.visible = false
	add_child(card_overlay)
	force_buy_button = Button.new()
	force_buy_button.text = "使用强购卡"
	force_buy_button.custom_minimum_size = Vector2(190, 58)
	$PropertyOverlay/Center/Panel/Content/Actions.add_child(force_buy_button)
	force_buy_button.visible = false
	_build_selection_ui()
	_build_leaderboard_ui()
	_build_quiz_ui()
	_add_close_button(property_overlay.get_node("Center/Panel"), "property", Callable(), false)
	_add_close_button(wheel_overlay.get_node("Shade/Center/Panel"), "wheel", Callable(), false)
	_add_close_button(card_overlay, "card", _close_card_window, true)
	_add_close_button(mailbox_overlay, "mailbox", func() -> void: _close_modal(mailbox_overlay), true)
	_add_close_button(leaderboard_overlay, "leaderboard", func() -> void: _close_modal(leaderboard_overlay), true)
	_add_close_button(selection_overlay, "selection", func() -> void: target_selection_cancelled.emit(), true)
	_add_close_button(quiz_overlay, "quiz", Callable(), false)
	_add_close_button(asset_overlay, "asset", func() -> void: _close_modal(asset_overlay), true)

func _update_bankruptcy_text() -> void:
	if bankruptcy_label == null: return
	if _bankruptcy_state == GameRules.BANKRUPTCY_BANKRUPT:
		bankruptcy_label.text = "破产状态：今日已破产"
	elif _bankruptcy_state == GameRules.BANKRUPTCY_PROTECTED:
		var remaining := maxi(0, _protection_end_time - int(Time.get_unix_time_from_system()))
		bankruptcy_label.text = "破产保护 %02d:%02d:%02d" % [remaining / 3600, (remaining % 3600) / 60, remaining % 60]
	elif _bankruptcy_state == GameRules.BANKRUPTCY_TAX_DEBT:
		bankruptcy_label.text = "欠税状态：请还税或处理资产"
	else:
		bankruptcy_label.text = "破产状态：正常"

func _build_asset_ui() -> void:
	asset_overlay = PanelContainer.new()
	asset_overlay.set_anchors_preset(Control.PRESET_CENTER)
	asset_overlay.offset_left = -520; asset_overlay.offset_top = -390; asset_overlay.offset_right = 520; asset_overlay.offset_bottom = 390
	var content := VBoxContainer.new(); asset_overlay.add_child(content)
	var title := Label.new(); title.text = "欠税资产处理"; title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; title.add_theme_font_size_override("font_size", 34); content.add_child(title)
	var hint := Label.new(); hint.text = "回收资金优先偿还欠税，剩余部分进入现金"; hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; hint.add_theme_font_size_override("font_size", 22); content.add_child(hint)
	var scroll := ScrollContainer.new(); scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL; content.add_child(scroll)
	asset_list = VBoxContainer.new(); asset_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL; scroll.add_child(asset_list)
	asset_overlay.visible = false
	add_child(asset_overlay)

func show_asset_management(owned_properties: Array) -> void:
	for child in asset_list.get_children(): child.queue_free()
	if owned_properties.is_empty():
		var empty := Label.new(); empty.text = "没有可处理的房产"; empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; asset_list.add_child(empty)
	for property in owned_properties:
		var cell_index := int(property.get("cell_index", -1))
		var level := int(property.get("property_level", 0))
		var property_type := String(property.get("property_type", GameRules.PROPERTY_HOUSE))
		var value := GameRules.property_value(level, property_type)
		var row := HBoxContainer.new()
		var label := Label.new(); label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; label.text = "%d 号  %s  L%d  价值 %d\n降级回收 %d / 整块出售 %d" % [cell_index, "酒店" if property_type == GameRules.PROPERTY_HOTEL else "住宅", level, value, GameRules.asset_recovery(value) if level > 1 else 0, GameRules.asset_recovery(value)]; row.add_child(label)
		var downgrade := Button.new(); downgrade.text = "降级"; downgrade.disabled = level <= 1; downgrade.pressed.connect(func() -> void: asset_action_requested.emit(cell_index, "downgrade")); row.add_child(downgrade)
		var sell := Button.new(); sell.text = "卖给系统"; sell.pressed.connect(func() -> void: asset_action_requested.emit(cell_index, "sell")); row.add_child(sell)
		asset_list.add_child(row)
	_open_modal(asset_overlay)

func _build_leaderboard_ui() -> void:
	leaderboard_overlay = PanelContainer.new(); leaderboard_overlay.set_anchors_preset(Control.PRESET_CENTER_RIGHT); leaderboard_overlay.offset_left = -520; leaderboard_overlay.offset_top = -360; leaderboard_overlay.offset_right = -30; leaderboard_overlay.offset_bottom = 360
	var content := VBoxContainer.new(); leaderboard_overlay.add_child(content)
	var title := Label.new(); title.text = "财富排行榜"; title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; title.add_theme_font_size_override("font_size", 34); content.add_child(title)
	leaderboard_list = VBoxContainer.new(); content.add_child(leaderboard_list)
	var close := Button.new(); close.text = "关闭"; close.pressed.connect(func() -> void: _close_modal(leaderboard_overlay)); content.add_child(close)
	leaderboard_overlay.visible = false; add_child(leaderboard_overlay)

func show_leaderboard(entries: Array) -> void:
	for child in leaderboard_list.get_children(): child.queue_free()
	for entry in entries:
		var label := Label.new(); label.text = "%d. Player %d\n   总财富：%d  现金：%d  房产：%d" % [int(entry["rank"]), int(entry["player_id"]), int(entry["total_wealth"]), int(entry["coins"]), int(entry["property_value"])]; label.add_theme_font_size_override("font_size", 22); leaderboard_list.add_child(label)
	_open_modal(leaderboard_overlay)

func _build_quiz_ui() -> void:
	quiz_overlay = PanelContainer.new(); quiz_overlay.set_anchors_preset(Control.PRESET_CENTER); quiz_overlay.offset_left = -420; quiz_overlay.offset_top = -330; quiz_overlay.offset_right = 420; quiz_overlay.offset_bottom = 330
	var content := VBoxContainer.new(); quiz_overlay.add_child(content)
	quiz_progress = Label.new(); quiz_progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; quiz_progress.add_theme_font_size_override("font_size", 30); content.add_child(quiz_progress)
	quiz_score = Label.new(); quiz_score.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; content.add_child(quiz_score)
	quiz_question = Label.new(); quiz_question.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; quiz_question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; quiz_question.add_theme_font_size_override("font_size", 26); content.add_child(quiz_question)
	quiz_options = VBoxContainer.new(); content.add_child(quiz_options)
	quiz_overlay.visible = false; add_child(quiz_overlay)

func show_quiz_question(action: Dictionary) -> void:
	quiz_progress.text = "第 %d / %d 题" % [int(action["question_number"]), GameRules.QUIZ_QUESTION_COUNT]
	quiz_score.text = "当前答对：%d    当前获得：%d 金币" % [int(action.get("correct_count", 0)), int(action.get("earned", 0))]
	quiz_question.text = String(action["question"])
	for child in quiz_options.get_children(): child.queue_free()
	var options: Array = action["options"]
	for index in range(options.size()):
		var button := Button.new(); button.text = "[%s] %s" % [String.chr(65 + index), String(options[index])]; button.custom_minimum_size = Vector2(0, 64); button.add_theme_font_size_override("font_size", 23)
		button.pressed.connect(func() -> void:
			for sibling in quiz_options.get_children():
				if sibling is Button: sibling.disabled = true
			quiz_answer_requested.emit(index))
		quiz_options.add_child(button)
	_open_modal(quiz_overlay)

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
	_begin_target_selection()

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
	_open_modal(selection_overlay)

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
	selected_player_targets.clear()
	selection_title.text = "请选择两名均富对象"
	selection_details.text = "选择除自己外的两名视野内玩家（0 / 2）"
	for player_id in target_ids:
		var button := Button.new(); button.name = "PlayerTarget%d" % player_id; button.text = "Player %d\n%d 金币" % [player_id, int(players[player_id]["coins"])]; button.custom_minimum_size = Vector2(150, 72); button.toggle_mode = true
		button.pressed.connect(func() -> void: player_target_selected.emit(player_id))
		selection_choices.add_child(button)
	selection_confirm_button.visible = false
	_begin_target_selection()

func set_selected_player_targets(target_ids: Array[int]) -> void:
	selected_player_targets = target_ids.duplicate()
	selection_details.text = "已选择：%s（%d / 2）" % [", ".join(target_ids.map(func(value: int) -> String: return "Player %d" % value)), target_ids.size()]
	for child in selection_choices.get_children():
		if child is Button and child.name.begins_with("PlayerTarget"):
			child.button_pressed = int(child.name.trim_prefix("PlayerTarget")) in target_ids

func show_card_confirmation(title: String, details: String) -> void:
	_clear_selection_choices()
	selection_title.text = title
	selection_details.text = details
	selection_confirm_button.visible = true
	selection_confirm_button.disabled = false
	_open_modal(selection_overlay)

func hide_target_selector() -> void:
	_close_modal(selection_overlay)
	_clear_selection_choices()

func _clear_selection_choices() -> void:
	for child in selection_choices.get_children(): child.queue_free()
	for connection in selection_confirm_button.pressed.get_connections():
		selection_confirm_button.pressed.disconnect(connection.callable)
	selection_confirm_button.pressed.connect(func() -> void: target_selection_confirmed.emit())
	selected_player_targets.clear()

func _begin_target_selection() -> void:
	_close_all_modals()
	selection_overlay.visible = true
	selection_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	active_modal = null
	modal_shade.visible = false

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
		var prefixes := {"daily_tax": "【税收】", "bankrupt": "【破产】", "bankruptcy_relief": "【破产】", "protection_ended": "【破产】", "quiz": "【答题】", "property": "【房产】", "toll": "【房产】", "card": "【卡牌】"}
		label.text = "%s %s  %s" % [String(prefixes.get(String(event.get("event_type", "")), "【通知】")), String(event.get("time", "")), String(event.get("message", ""))]
		mailbox_list.add_child(label)

func _toggle_mailbox() -> void:
	if active_modal == mailbox_overlay:
		_close_modal(mailbox_overlay)
	else:
		_open_modal(mailbox_overlay)
		unread_count = 0
		mailbox_button.text = "✉ 0"

func show_wheel_ready(action_player_id: int, can_start: bool) -> void:
	_begin_modal(wheel_overlay)
	wheel_overlay.show_ready(action_player_id, can_start)

func play_wheel_spin(result: int, duration: float) -> void:
	wheel_overlay.play_spin(result, duration)

func show_wheel_result(result: int, can_confirm: bool, action_player_id: int) -> void:
	_begin_modal(wheel_overlay)
	wheel_overlay.show_result(result, can_confirm, action_player_id)

func hide_property_prompt() -> void:
	_close_modal(property_overlay)

func hide_all_prompts() -> void:
	_close_all_modals()

func _build_modal_system() -> void:
	modal_shade = ColorRect.new()
	modal_shade.name = "ModalInputBlocker"
	modal_shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	modal_shade.color = Color(0.25, 0.16, 0.08, 0.46)
	modal_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_shade.visible = false
	add_child(modal_shade)
	move_child(modal_shade, property_overlay.get_index())

func _begin_modal(target: Control) -> void:
	if target != property_overlay: force_buy_button.visible = false
	if active_modal != null and active_modal != target:
		_hide_modal_visual(active_modal)
	active_modal = target
	modal_shade.visible = true
	target.visible = true

func _open_modal(target: Control) -> void:
	_begin_modal(target)

func _close_modal(target: Control) -> void:
	_hide_modal_visual(target)
	if active_modal == target:
		active_modal = null
		modal_shade.visible = false

func _hide_modal_visual(target: Control) -> void:
	if target == wheel_overlay: wheel_overlay.hide_wheel()
	else: target.visible = false

func _close_all_modals() -> void:
	for target in [property_overlay, wheel_overlay, card_overlay, mailbox_overlay, leaderboard_overlay, selection_overlay, quiz_overlay, asset_overlay]:
		if target != null: _hide_modal_visual(target)
	active_modal = null
	force_buy_button.visible = false
	if modal_shade != null: modal_shade.visible = false

func _close_card_window() -> void:
	_close_modal(card_overlay)
	if card_is_shop: shop_closed.emit()
	card_is_shop = false

func _add_close_button(panel: Control, key: String, handler: Callable, enabled: bool) -> void:
	var content := panel.get_child(0) as VBoxContainer
	var header := HBoxContainer.new()
	var spacer := Control.new(); spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL; header.add_child(spacer)
	var close := Button.new()
	close.name = "CloseX"
	close.text = "×"
	close.custom_minimum_size = Vector2(58, 58)
	close.add_theme_font_size_override("font_size", 38)
	close.disabled = not enabled
	if enabled: close.pressed.connect(handler)
	header.add_child(close)
	content.add_child(header)
	content.move_child(header, 0)
	modal_close_buttons[key] = close

func _apply_warm_theme() -> void:
	warm_theme = Theme.new()
	var panel := StyleBoxFlat.new(); panel.bg_color = Color("f7e7bd"); panel.border_color = Color("8b5a2b"); panel.set_border_width_all(5); panel.set_corner_radius_all(18); panel.set_content_margin_all(24)
	var normal := StyleBoxFlat.new(); normal.bg_color = Color("e7bd72"); normal.border_color = Color("8b5a2b"); normal.set_border_width_all(3); normal.set_corner_radius_all(12)
	var hover := normal.duplicate(); hover.bg_color = Color("f4cf83")
	var pressed := normal.duplicate(); pressed.bg_color = Color("d29a4a")
	var disabled := normal.duplicate(); disabled.bg_color = Color("cdbf9f"); disabled.border_color = Color("9b8a6d")
	var input_style := StyleBoxFlat.new(); input_style.bg_color = Color("fff8e5"); input_style.border_color = Color("9a6a37"); input_style.set_border_width_all(3); input_style.set_corner_radius_all(8)
	warm_theme.set_stylebox("panel", "PanelContainer", panel)
	warm_theme.set_stylebox("normal", "Button", normal); warm_theme.set_stylebox("hover", "Button", hover); warm_theme.set_stylebox("pressed", "Button", pressed); warm_theme.set_stylebox("disabled", "Button", disabled)
	warm_theme.set_stylebox("normal", "LineEdit", input_style); warm_theme.set_stylebox("focus", "LineEdit", input_style)
	warm_theme.set_color("font_color", "Label", Color("4b2d18")); warm_theme.set_color("font_color", "Button", Color("4b2d18")); warm_theme.set_color("font_disabled_color", "Button", Color("75634c"))
	warm_theme.set_color("font_color", "LineEdit", Color("4b2d18"))
	for root_control in [startup_overlay, hud, property_overlay, wheel_overlay, card_overlay, mailbox_overlay, leaderboard_overlay, selection_overlay, quiz_overlay, asset_overlay]:
		root_control.theme = warm_theme
		_remove_cold_overrides(root_control)
	$StartupOverlay/Backdrop.color = Color("f2d99d")
	$PropertyOverlay/Shade.color = Color(0.25, 0.16, 0.08, 0.46)
	wheel_overlay.get_node("Shade").color = Color(0.25, 0.16, 0.08, 0.46)

func _remove_cold_overrides(node: Node) -> void:
	if node is PanelContainer: node.remove_theme_stylebox_override("panel")
	if node is Label: node.remove_theme_color_override("font_color")
	for child in node.get_children(): _remove_cold_overrides(child)
