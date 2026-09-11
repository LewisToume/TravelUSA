extends Node2D

signal game_started
signal state_applied
signal property_prompted(action: Dictionary)
signal action_finished(player_id: int)

@export_range(1, 6, 1) var dice_min_value := 1
@export_range(1, 12, 1) var dice_max_value := 6
@export_range(1024, 65535, 1) var listen_port := 7000

@onready var board: BoardPath = $Board
@onready var player_1: BoardPlayer = $Player1
@onready var player_2: BoardPlayer = $Player2
@onready var follow_camera: Camera2D = $TurnCamera
@onready var game_ui: GameHUD = $GameUI
const PLAYER_SCENE := preload("res://scenes/player.tscn")

var is_host := false
var local_player_id := 0
var game_is_started := false
var players_state: Dictionary = {}
var properties: Array = []
var last_rolls: Dictionary = {1: 0, 2: 0}
var last_event: Dictionary = {}
var last_wheel_result := 0
var player_peer_ids: Dictionary = {1: 1}
var active_player_ids: Array[int] = [1]
var player_nodes: Dictionary = {}

# Host-only state. RPCs run serially on Godot's main thread; per-cell queues keep
# landing decisions atomic while unrelated players remain independent.
var pending_actions: Dictionary = {}
var action_responses: Dictionary = {}
var animation_done: Dictionary = {}
var action_paid_final_toll: Dictionary = {}
var next_action_id := 1
var next_event_id := 1
var notifications: Array = []
var notification_sequence := 1
var dice_animation_duration := 0.75

# This process controls only its assigned player.
var pending_action: Dictionary = {}
var displayed_event_id := 0
var test_mode := false
var test_wheel_result_override := 0
var test_wheel_spin_duration := 0.0
var _random := RandomNumberGenerator.new()
var targeting_card_id := ""
var selected_card_target := -1
var leaderboard_data: Array = []
var server_time_override := -1
var save_path := "user://savegame.json"
var save_temp_path := "user://savegame.tmp"
var save_load_failed := false
var _last_time_check := 0
var _last_autosave_time := 0

func _ready() -> void:
	_random.randomize()
	for player_id in range(1, 7):
		players_state[player_id] = GameRules.build_player_state(player_id)
	player_nodes = {1: player_1, 2: player_2}
	for player_id in range(3, 7):
		var player: BoardPlayer = PLAYER_SCENE.instantiate()
		player.name = "Player%d" % player_id
		player.player_id = player_id
		player.player_color = BoardPath.PLAYER_COLORS[player_id - 1]
		add_child(player)
		player_nodes[player_id] = player
	properties = GameRules.build_cells(board.get_cell_count())
	board.set_property_states(properties)
	player_1.place_at_cell(0, board)
	player_2.place_at_cell(0, board)
	game_ui.host_requested.connect(func() -> void: host_game())
	game_ui.join_requested.connect(func(address: String) -> void: join_game(address))
	game_ui.roll_requested.connect(_on_roll_requested)
	game_ui.property_action_requested.connect(submit_property_action)
	game_ui.wheel_spin_requested.connect(request_wheel_spin)
	game_ui.wheel_confirmation_requested.connect(confirm_wheel_result)
	game_ui.shop_card_requested.connect(request_buy_card)
	game_ui.shop_closed.connect(close_shop)
	game_ui.card_use_requested.connect(request_use_card)
	game_ui.card_selected.connect(_on_card_selected)
	game_ui.target_selection_cancelled.connect(_cancel_card_targeting)
	game_ui.target_selection_confirmed.connect(_confirm_card_targeting)
	game_ui.remote_dice_confirmed.connect(_confirm_remote_dice)
	game_ui.player_target_selected.connect(_select_player_target)
	game_ui.force_buy_requested.connect(_request_force_buy_from_property)
	game_ui.quiz_answer_requested.connect(submit_quiz_answer)
	game_ui.leaderboard_requested.connect(_show_leaderboard)
	board.target_cell_selected.connect(_select_cell_target)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(_delta: float) -> void:
	if game_is_started and local_player_id > 0:
		follow_camera.position = _player_node(local_player_id).position
	if is_host and game_is_started and _server_time() > _last_time_check:
		_last_time_check = _server_time()
		_check_protection_expiry()
		_check_daily_taxes()
		if _server_time() - _last_autosave_time >= 30:
			_save_game()

func host_game(port: int = -1) -> bool:
	var server := ENetMultiplayerPeer.new()
	var target_port := listen_port if port < 0 else port
	var error := server.create_server(target_port, 5)
	if error != OK:
		game_ui.set_lobby_status("Host 启动失败：%s" % error_string(error))
		return false
	multiplayer.multiplayer_peer = server
	is_host = true
	local_player_id = 1
	active_player_ids = [1]
	_load_game()
	_check_player_login(1)
	_check_daily_taxes()
	game_ui.set_lobby_buttons_enabled(false)
	game_ui.set_lobby_status("Host 已创建，等待客户端连接（端口 %d）" % target_port)
	return true

func join_game(address: String = "127.0.0.1", port: int = -1) -> bool:
	var client := ENetMultiplayerPeer.new()
	var target_port := listen_port if port < 0 else port
	var target_address := address if not address.is_empty() else "127.0.0.1"
	var error := client.create_client(target_address, target_port)
	if error != OK:
		game_ui.set_lobby_status("连接失败：%s" % error_string(error))
		return false
	multiplayer.multiplayer_peer = client
	is_host = false
	game_ui.set_lobby_buttons_enabled(false)
	game_ui.set_lobby_status("正在连接 %s:%d…" % [target_address, target_port])
	return true

func start_local_test_game() -> void:
	is_host = true
	local_player_id = 1
	game_is_started = true
	active_player_ids = [1, 2]
	_show_world()
	_apply_snapshot(_make_snapshot())
	game_started.emit()

func generate_roll() -> int:
	return _random.randi_range(dice_min_value, dice_max_value)

func can_upgrade_property(player_level: int, property_level: int) -> bool:
	return GameRules.can_upgrade_property(player_level, property_level)

func can_player_roll(player_id: int) -> bool:
	if not players_state.has(player_id):
		return false
	var state: Dictionary = players_state[player_id]
	return int(state["stamina"]) > 0 and String(state["action_state"]) == GameRules.ACTION_IDLE and String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) != GameRules.BANKRUPTCY_BANKRUPT

func submit_quiz_answer(option_index: int) -> void:
	if pending_action.is_empty() or String(pending_action.get("type", "")) != "quiz": return
	var event_id := int(pending_action["event_id"])
	if is_host: _host_record_response(local_player_id, event_id, "quiz_answer", option_index == int(pending_action.get("correct", 0)), option_index)
	else: _request_quiz_answer_rpc.rpc_id(1, event_id, option_index)

func _show_leaderboard() -> void:
	game_ui.show_leaderboard(leaderboard_data)

func has_local_property_prompt() -> bool:
	return not pending_action.is_empty() and game_ui.property_overlay.visible

func request_test_roll(forced_roll: int) -> void:
	if not test_mode:
		return
	if is_host:
		_host_try_roll(local_player_id, forced_roll)
	else:
		_request_test_roll_rpc.rpc_id(1, forced_roll)

func submit_property_action(accepted: bool) -> void:
	if pending_action.is_empty():
		return
	var event_id := int(pending_action.get("event_id", 0))
	game_ui.hide_property_prompt()
	if is_host:
		_host_record_response(local_player_id, event_id, "decision", accepted)
	else:
		_request_action_response_rpc.rpc_id(1, event_id, "decision", accepted)

func request_wheel_spin() -> void:
	var event_id := int(pending_action.get("event_id", 0))
	if is_host:
		_host_record_response(local_player_id, event_id, "wheel_spin", true)
	else:
		_request_action_response_rpc.rpc_id(1, event_id, "wheel_spin", true)

func confirm_wheel_result() -> void:
	var event_id := int(pending_action.get("event_id", 0))
	if is_host:
		_host_record_response(local_player_id, event_id, "wheel_confirm", true)
	else:
		_request_action_response_rpc.rpc_id(1, event_id, "wheel_confirm", true)

func request_buy_card(card_id: String) -> void:
	if is_host:
		_host_buy_card(local_player_id, card_id)
	else:
		_request_buy_card_rpc.rpc_id(1, card_id)

func close_shop() -> void:
	var event_id := int(pending_action.get("event_id", 0))
	if is_host:
		_host_record_response(local_player_id, event_id, "shop_close", true)
	else:
		_request_action_response_rpc.rpc_id(1, event_id, "shop_close", true)

func request_use_card(card_id: String, target: int) -> void:
	if is_host:
		if not _host_use_card(local_player_id, card_id, target):
			_send_private_toast(local_player_id, "卡牌使用失败：目标或当前状态不符合条件")
	else:
		_request_use_card_rpc.rpc_id(1, card_id, target)

func _on_card_selected(card_id: String) -> void:
	targeting_card_id = card_id
	selected_card_target = -1
	match card_id:
		GameRules.CARD_REMOTE_DICE:
			game_ui.show_remote_dice_selector()
		GameRules.CARD_BUILD, GameRules.CARD_DEMOLISH:
			var cells: Array[int] = []
			for cell_index in range(properties.size()):
				var property: Dictionary = properties[cell_index]
				var owner_id := int(property.get("owner_id", -1))
				var level := int(property.get("property_level", 0))
				var valid := _is_cell_in_player_view(local_player_id, cell_index)
				if card_id == GameRules.CARD_BUILD:
					valid = valid and owner_id == local_player_id and level >= 1 and level <= 4
				else:
					valid = valid and owner_id not in [-1, local_player_id] and level >= 2 and level <= 5
				if valid: cells.append(cell_index)
			board.set_selectable_cells(cells)
			game_ui.show_map_target_selector("请选择要升级的房产" if card_id == GameRules.CARD_BUILD else "请选择要拆除的房产")
		GameRules.CARD_EQUALIZE:
			var targets: Array[int] = []
			for player_id in active_player_ids:
				if _is_player_in_player_view(local_player_id, player_id): targets.append(player_id)
			game_ui.show_player_selector(players_state, targets)
		GameRules.CARD_FORCE_BUY:
			var cell_index := int(players_state[local_player_id]["cell"])
			var property: Dictionary = properties[cell_index]
			if String(property.get("cell_type", "")) != GameRules.CELL_PROPERTY or int(property.get("owner_id", -1)) in [-1, local_player_id] or int(property.get("property_level", 0)) > GameRules.MAX_CAPTURABLE_PROPERTY_LEVEL:
				game_ui.show_toast("强购卡只能用于脚下敌方 L1～L3 房产")
				_cancel_card_targeting()
			else:
				_show_force_buy_confirmation()
		_:
			game_ui.show_card_confirmation("确认使用%s？" % String(GameRules.CARD_NAMES[card_id]), "效果将在下一次行动生效")

func _select_cell_target(cell_index: int) -> void:
	if targeting_card_id not in [GameRules.CARD_BUILD, GameRules.CARD_DEMOLISH]: return
	selected_card_target = cell_index
	var property: Dictionary = properties[cell_index]
	var level := int(property["property_level"])
	var text := "将 %d 号房产 L%d → L%d？" % [cell_index, level, level + 1]
	if targeting_card_id == GameRules.CARD_DEMOLISH:
		text = "将 Player %d 的 %d 号房产 L%d → L%d？" % [int(property["owner_id"]), cell_index, level, level - 1]
	game_ui.show_card_confirmation("确认目标", text)

func _select_player_target(player_id: int) -> void:
	selected_card_target = player_id
	game_ui.show_card_confirmation("确认使用均富卡", "你：%d 金币\nPlayer %d：%d 金币\n确认后 Host 将按最新金币平分" % [int(players_state[local_player_id]["coins"]), player_id, int(players_state[player_id]["coins"])])

func _confirm_remote_dice(value: int) -> void:
	request_use_card(GameRules.CARD_REMOTE_DICE, value)
	_cancel_card_targeting()

func _confirm_card_targeting() -> void:
	if targeting_card_id.is_empty(): return
	request_use_card(targeting_card_id, selected_card_target)
	_cancel_card_targeting()

func _cancel_card_targeting() -> void:
	targeting_card_id = ""
	selected_card_target = -1
	board.clear_target_selection()
	game_ui.hide_target_selector()

func _show_force_buy_confirmation() -> void:
	var cell_index := int(players_state[local_player_id]["cell"])
	var property: Dictionary = properties[cell_index]
	var level := int(property.get("property_level", 0))
	var price := GameRules.capture_price(level, int(property.get("capture_count", 0)))
	game_ui.show_card_confirmation("确认使用强购卡", "房主：Player %d\n等级：L%d\n价格：%d 金币" % [int(property.get("owner_id", -1)), level, price])

func _request_force_buy_from_property() -> void:
	request_use_card(GameRules.CARD_FORCE_BUY, int(players_state[local_player_id]["cell"]))
	submit_property_action(false)

func _on_roll_requested() -> void:
	if is_host:
		_host_try_roll(local_player_id)
	else:
		_request_roll_rpc.rpc_id(1)

func _on_peer_connected(peer_id: int) -> void:
	if not is_host:
		return
	var assigned_id := _next_available_player_id()
	if assigned_id < 0:
		return
	player_peer_ids[assigned_id] = peer_id
	if assigned_id not in active_player_ids:
		active_player_ids.append(assigned_id)
	_check_player_login(assigned_id)
	game_is_started = true
	_assign_local_player.rpc_id(peer_id, assigned_id)
	_show_world()
	_sync_state.rpc(_make_snapshot())
	game_started.emit()

func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return
	var player_id := _player_id_for_peer(peer_id)
	if player_id > 1:
		player_peer_ids.erase(player_id)
		active_player_ids.erase(player_id)
		_save_game()
		_broadcast_state()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_host:
		_save_game()

func _exit_tree() -> void:
	if is_host:
		_save_game()

func _on_connected_to_server() -> void:
	game_ui.set_lobby_status("已连接，等待 Host 同步游戏…")

func _on_connection_failed() -> void:
	game_ui.set_lobby_buttons_enabled(true)
	game_ui.set_lobby_status("连接失败，请确认 Host 已启动")

func _on_server_disconnected() -> void:
	game_is_started = false
	game_ui.show_startup()
	game_ui.set_lobby_status("与 Host 的连接已断开")

@rpc("authority", "call_remote", "reliable")
func _assign_local_player(assigned_id: int) -> void:
	local_player_id = assigned_id

@rpc("authority", "call_local", "reliable")
func _sync_state(snapshot: Dictionary) -> void:
	_apply_snapshot(snapshot)

@rpc("authority", "call_local", "reliable")
func _animate_action(player_id: int, action_id: int, start_cell: int, move_distance: int, direction: int, target_cell: int) -> void:
	var player := _player_node(player_id)
	player.place_at_cell(start_cell, board)
	player.move_steps_direction(move_distance, direction, board)
	for _step in range(move_distance):
		var reached_cell: int = await player.step_reached
		if is_host and _settle_step_toll(player_id, reached_cell) and reached_cell == target_cell:
			action_paid_final_toll[action_id] = true
	await player.movement_finished
	player.place_at_cell(target_cell, board)
	animation_done[action_id] = true
	_refresh_ui()

@rpc("authority", "call_remote", "reliable")
func _show_property_prompt_remote(action: Dictionary) -> void:
	_show_local_property_prompt(action)

@rpc("authority", "call_remote", "reliable")
func _show_quiz_question_remote(action: Dictionary) -> void:
	pending_action = action.duplicate(true)
	displayed_event_id = int(action["event_id"])
	game_ui.show_quiz_question(action)

@rpc("authority", "call_local", "reliable")
func _show_toll_toast_remote(action: Dictionary) -> void:
	if local_player_id == int(action["payer_id"]) or local_player_id == int(action["owner_id"]):
		game_ui.show_toll_toast(action, local_player_id)

@rpc("authority", "call_remote", "reliable")
func _show_wheel_ready_remote(action: Dictionary) -> void:
	displayed_event_id = int(action["event_id"])
	if local_player_id == int(action["player_id"]):
		pending_action = action.duplicate(true)
	game_ui.show_wheel_ready(int(action["player_id"]), local_player_id == int(action["player_id"]))

@rpc("authority", "call_remote", "reliable")
func _spin_wheel_remote(result: int, duration: float) -> void:
	game_ui.play_wheel_spin(result, duration)

@rpc("authority", "call_remote", "reliable")
func _show_wheel_result_remote(action: Dictionary) -> void:
	displayed_event_id = int(action["event_id"])
	if local_player_id == int(action["player_id"]):
		pending_action = action.duplicate(true)
	game_ui.show_wheel_result(int(action["amount"]), local_player_id == int(action["player_id"]), int(action["player_id"]))

@rpc("authority", "call_remote", "reliable")
func _show_shop_remote(action: Dictionary, inventory: Dictionary, coins: int) -> void:
	pending_action = action.duplicate(true)
	displayed_event_id = int(action["event_id"])
	game_ui.show_shop(inventory, coins)

@rpc("authority", "call_local", "reliable")
func _show_toast_remote(message: String) -> void:
	game_ui.show_toast(message)

@rpc("authority", "call_remote", "reliable")
func _show_dice_roll_remote(roll: int) -> void:
	game_ui.play_dice_roll(roll, dice_animation_duration)

@rpc("authority", "call_remote", "reliable")
func _play_card_effect_remote(card_id: String) -> void:
	game_ui.play_card_effect(card_id)

@rpc("authority", "call_local", "reliable")
func _play_property_effect_remote(cell_index: int, effect_type: String) -> void:
	board.play_building_effect(cell_index, effect_type)

@rpc("authority", "call_local", "reliable")
func _show_money_popup_remote(player_id: int, amount: int) -> void:
	_player_node(player_id).show_money_popup(amount)

@rpc("authority", "call_remote", "reliable")
func _play_bankruptcy_effect_remote(player_id: int) -> void:
	if local_player_id == player_id: _player_node(player_id).play_bankruptcy_effect()

@rpc("authority", "call_local", "reliable")
func _hide_prompt_remote(event_id: int) -> void:
	if int(pending_action.get("event_id", -1)) == event_id:
		pending_action = {}
	if displayed_event_id == event_id:
		displayed_event_id = 0
		game_ui.hide_all_prompts()

@rpc("any_peer", "call_remote", "reliable")
func _request_roll_rpc() -> void:
	if is_host:
		_host_try_roll(_player_id_for_peer(multiplayer.get_remote_sender_id()))

@rpc("any_peer", "call_remote", "reliable")
func _request_test_roll_rpc(forced_roll: int) -> void:
	if is_host and test_mode:
		_host_try_roll(_player_id_for_peer(multiplayer.get_remote_sender_id()), forced_roll)

@rpc("any_peer", "call_remote", "reliable")
func _request_action_response_rpc(event_id: int, response_type: String, accepted: bool) -> void:
	if is_host:
		_host_record_response(_player_id_for_peer(multiplayer.get_remote_sender_id()), event_id, response_type, accepted)

@rpc("any_peer", "call_remote", "reliable")
func _request_buy_card_rpc(card_id: String) -> void:
	if is_host:
		_host_buy_card(_player_id_for_peer(multiplayer.get_remote_sender_id()), card_id)

@rpc("any_peer", "call_remote", "reliable")
func _request_use_card_rpc(card_id: String, target: int) -> void:
	if is_host:
		var player_id := _player_id_for_peer(multiplayer.get_remote_sender_id())
		if not _host_use_card(player_id, card_id, target):
			_send_private_toast(player_id, "卡牌使用失败：目标或当前状态不符合条件")

@rpc("any_peer", "call_remote", "reliable")
func _request_quiz_answer_rpc(event_id: int, option_index: int) -> void:
	if is_host:
		var player_id := _player_id_for_peer(multiplayer.get_remote_sender_id())
		_host_record_response(player_id, event_id, "quiz_answer", false, option_index)

func _host_try_roll(requesting_player_id: int, forced_roll: int = -1) -> bool:
	if not is_host or not game_is_started or not can_player_roll(requesting_player_id):
		return false
	var roll := generate_roll() if forced_roll < 0 else forced_roll
	var state: Dictionary = players_state[requesting_player_id]
	if int(state.get("forced_next_roll", 0)) > 0:
		roll = int(state["forced_next_roll"])
		state["forced_next_roll"] = 0
		state["status_effects"]["forced_next_roll"] = 0
	if not test_mode:
		roll = clampi(roll, dice_min_value, dice_max_value)
	roll = maxi(1, roll)
	var direction := -1 if bool(state.get("reverse_next_move", false)) else 1
	var move_distance := roll * (2 if bool(state.get("speed_next_move", false)) else 1)
	state["last_move_distance"] = move_distance
	state["last_move_was_speed"] = move_distance != roll
	var protected_action := String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_PROTECTED and _server_time() < int(state.get("protection_end_time", 0))
	state["toll_free_this_action"] = false if protected_action else bool(state.get("toll_free_next_action", false))
	if not protected_action: state["toll_free_next_action"] = false
	state["reverse_next_move"] = false
	state["speed_next_move"] = false
	state["status_effects"]["reverse_next_move"] = false
	state["status_effects"]["speed_multiplier_next_move"] = 1
	state["status_effects"]["toll_free_next_action"] = bool(state.get("toll_free_next_action", false))
	var start_cell := int(state["cell"])
	var target_cell := posmod(start_cell + direction * move_distance, board.get_cell_count())
	var action_id := next_action_id
	next_action_id += 1
	state["stamina"] = int(state["stamina"]) - 1
	state["action_state"] = GameRules.ACTION_RESOLVING
	state["cell"] = target_cell
	players_state[requesting_player_id] = state
	if bool(state["toll_free_this_action"]):
		_send_card_effect(requesting_player_id, GameRules.CARD_TOLL_FREE)
	last_rolls[requesting_player_id] = roll
	_broadcast_state()
	_send_dice_roll(requesting_player_id, roll)
	_begin_move_after_dice(requesting_player_id, action_id, start_cell, move_distance, direction, target_cell)
	return true

func _begin_move_after_dice(player_id: int, action_id: int, start_cell: int, move_distance: int, direction: int, target_cell: int) -> void:
	await get_tree().create_timer(dice_animation_duration).timeout
	if multiplayer.has_multiplayer_peer():
		_animate_action.rpc(player_id, action_id, start_cell, move_distance, direction, target_cell)
	else:
		_animate_action(player_id, action_id, start_cell, move_distance, direction, target_cell)
	_resolve_landing(player_id, action_id, target_cell)

func _resolve_landing(player_id: int, action_id: int, cell_index: int) -> void:
	while not bool(animation_done.get(action_id, false)):
		await get_tree().process_frame
	animation_done.erase(action_id)
	if _is_bankrupt(player_id):
		_finish_player_action(player_id)
		return
	var cell_type := String(properties[cell_index]["cell_type"])
	if cell_type == GameRules.CELL_PROPERTY:
		await _resolve_property_landing(player_id, cell_index, bool(action_paid_final_toll.get(action_id, false)))
		action_paid_final_toll.erase(action_id)
	elif cell_type == GameRules.CELL_REWARD:
		await _resolve_reward(player_id, cell_index)
	elif cell_type == GameRules.CELL_WHEEL:
		await _resolve_wheel(player_id, cell_index)
	elif cell_type == GameRules.CELL_SHOP:
		await _resolve_shop(player_id, cell_index)
	elif cell_type == GameRules.CELL_QUIZ:
		await _resolve_quiz(player_id, cell_index)
	_finish_player_action(player_id)

func _resolve_property_landing(player_id: int, cell_index: int, final_toll_paid: bool) -> void:
	if _is_bankrupt(player_id): return
	var property: Dictionary = properties[cell_index]
	if not final_toll_paid and int(property["owner_id"]) not in [-1, player_id]:
		_settle_step_toll(player_id, cell_index)
	if _is_bankrupt(player_id): return
	var action := _build_property_action(player_id, cell_index)
	if action.is_empty():
		return
	var accepted: bool = await _request_player_decision(player_id, action)
	if accepted:
		var current_action := _build_property_action(player_id, cell_index)
		if String(current_action.get("type", "")) == String(action.get("type", "")) and bool(current_action.get("can_afford", false)):
			_apply_property_action(player_id, current_action)
			_notify("property", player_id, -1, cell_index, int(current_action.get("price", 0)), "Player %d %s了 %d 号房产" % [player_id, "买下" if String(current_action["type"]) == "buy" else "操作", cell_index])
		elif String(action.get("type", "")) == "buy" and int(properties[cell_index]["owner_id"]) != -1:
			_send_private_toast(player_id, "手速太慢，这块地已经被 Player %d 买走了！" % int(properties[cell_index]["owner_id"]))
		_broadcast_state()

func _settle_step_toll(player_id: int, cell_index: int) -> bool:
	if _is_bankrupt(player_id): return false
	var property: Dictionary = properties[cell_index]
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY:
		return false
	var owner_id := int(property["owner_id"])
	var amount := GameRules.toll_fee(int(property["property_level"]))
	if owner_id == -1 or owner_id == player_id or amount <= 0:
		return false
	var payer: Dictionary = players_state[player_id]
	if String(payer.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_PROTECTED and _server_time() < int(payer.get("protection_end_time", 0)):
		_notify("bankruptcy_protection", player_id, owner_id, cell_index, amount, "Player %d 处于破产保护，免除 %d 金币过路费" % [player_id, amount])
		_send_private_toast(player_id, "破产保护：免除 %d 金币过路费" % amount)
		_broadcast_state()
		return true
	if bool(payer.get("toll_free_this_action", false)):
		players_state[player_id] = payer
		_notify("toll_free", player_id, owner_id, cell_index, amount, "Player %d 使用免租卡，免除 %d 金币过路费" % [player_id, amount])
		_send_private_toast(player_id, "免租 -%d" % amount)
		_broadcast_state()
		return true
	var actual_payment := _apply_passive_payment(player_id, amount, "toll")
	var owner: Dictionary = players_state[owner_id]
	owner["coins"] = int(owner["coins"]) + actual_payment
	owner["daily_taxable_income"] = int(owner.get("daily_taxable_income", 0)) + actual_payment
	players_state[owner_id] = owner
	_show_money_popup(player_id, -actual_payment)
	_show_money_popup(owner_id, actual_payment)
	var action := {"type": "toll", "payer_id": player_id, "owner_id": owner_id, "cell_index": cell_index, "property_level": int(property["property_level"]), "amount": actual_payment}
	_notify("toll", player_id, owner_id, cell_index, actual_payment, "Player %d 经过 Player %d 的 L%d 房产，实际支付 %d 金币" % [player_id, owner_id, int(property["property_level"]), actual_payment])
	_broadcast_state()
	_save_game()
	if multiplayer.has_multiplayer_peer():
		_show_toll_toast_remote.rpc(action)
	else:
		_show_toll_toast_remote(action)
	return true

func _resolve_reward(player_id: int, cell_index: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + GameRules.REWARD_COINS
	state["daily_taxable_income"] = int(state.get("daily_taxable_income", 0)) + GameRules.REWARD_COINS
	players_state[player_id] = state
	var action := {"type": "reward", "amount": GameRules.REWARD_COINS, "cell_index": cell_index, "player_id": player_id}
	last_event = action.duplicate(true)
	_notify("reward", player_id, -1, cell_index, GameRules.REWARD_COINS, "Player %d 获得奖励 %d 金币" % [player_id, GameRules.REWARD_COINS])
	await _request_player_decision(player_id, action)
	_save_game()

func _resolve_wheel(player_id: int, cell_index: int) -> void:
	var result := _choose_wheel_result()
	last_wheel_result = result
	var action := {"type": "wheel", "amount": result, "cell_index": cell_index, "player_id": player_id}
	_assign_event_id(action)
	pending_actions[player_id] = action
	_broadcast_state()
	_send_wheel_ready(player_id, action)
	await _await_response(player_id, int(action["event_id"]), "wheel_spin")
	var duration := test_wheel_spin_duration if test_mode and test_wheel_spin_duration > 0.0 else GameRules.WHEEL_SPIN_DURATION
	_send_wheel_spin(player_id, result, duration)
	await get_tree().create_timer(duration).timeout
	var state: Dictionary = players_state[player_id]
	if result >= 0:
		state["coins"] = int(state["coins"]) + result
		state["daily_taxable_income"] = int(state.get("daily_taxable_income", 0)) + result
	else:
		_apply_passive_payment(player_id, absi(result), "wheel")
		state = players_state[player_id]
	players_state[player_id] = state
	last_event = action.duplicate(true)
	_broadcast_state()
	_send_wheel_result(player_id, action)
	_notify("wheel", player_id, -1, cell_index, result, "Player %d 转盘%s %d 金币" % [player_id, "获得" if result >= 0 else "损失", absi(result)])
	_broadcast_state()
	await _await_response(player_id, int(action["event_id"]), "wheel_confirm")
	_close_event(player_id, int(action["event_id"]))
	_save_game()

func _resolve_quiz(player_id: int, cell_index: int) -> void:
	if _is_bankrupt(player_id): return
	var action := {"type": "quiz", "player_id": player_id, "cell_index": cell_index, "event_id": next_event_id, "correct_count": 0, "earned": 0}
	next_event_id += 1
	pending_actions[player_id] = action
	for question_index in range(GameRules.QUIZ_QUESTION_COUNT):
		if _is_bankrupt(player_id): break
		var question := QuestionBank.get_question(question_index + player_id)
		action.merge({"question_number": question_index + 1, "question": question["question"], "options": question["options"], "correct": int(question["correct"])}, true)
		pending_actions[player_id] = action.duplicate(true)
		_send_quiz_question(player_id, action)
		var selected := await _await_quiz_answer(player_id, int(action["event_id"]))
		if selected == int(question["correct"]):
			var state: Dictionary = players_state[player_id]
			state["coins"] = int(state["coins"]) + GameRules.QUIZ_REWARD_PER_CORRECT
			state["daily_taxable_income"] = int(state.get("daily_taxable_income", 0)) + GameRules.QUIZ_REWARD_PER_CORRECT
			players_state[player_id] = state
			action["correct_count"] = int(action["correct_count"]) + 1
			action["earned"] = int(action["earned"]) + GameRules.QUIZ_REWARD_PER_CORRECT
		_broadcast_state()
	_notify("quiz", player_id, -1, cell_index, int(action["earned"]), "Player %d 完成五连答题，获得 %d 金币" % [player_id, int(action["earned"])])
	_close_event(player_id, int(action["event_id"]))
	_save_game()

func _send_quiz_question(player_id: int, action: Dictionary) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1: _show_quiz_question_remote(action)
	else: _show_quiz_question_remote.rpc_id(peer_id, action)

func _await_quiz_answer(player_id: int, event_id: int) -> int:
	while true:
		var response: Dictionary = action_responses.get(event_id, {})
		if int(response.get("player_id", -1)) == player_id and String(response.get("type", "")) == "quiz_answer":
			action_responses.erase(event_id)
			return int(response.get("option_index", -1))
		await get_tree().process_frame
	return -1

func _send_wheel_ready(player_id: int, action: Dictionary) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_show_wheel_ready_remote(action)
	else:
		_show_wheel_ready_remote.rpc_id(peer_id, action)

func _send_wheel_spin(player_id: int, result: int, duration: float) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_spin_wheel_remote(result, duration)
	else:
		_spin_wheel_remote.rpc_id(peer_id, result, duration)

func _send_wheel_result(player_id: int, action: Dictionary) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_show_wheel_result_remote(action)
	else:
		_show_wheel_result_remote.rpc_id(peer_id, action)

func _send_dice_roll(player_id: int, roll: int) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_show_dice_roll_remote(roll)
	else:
		_show_dice_roll_remote.rpc_id(peer_id, roll)

func _send_card_effect(player_id: int, card_id: String) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_play_card_effect_remote(card_id)
	else:
		_play_card_effect_remote.rpc_id(peer_id, card_id)

func _resolve_shop(player_id: int, cell_index: int) -> void:
	var action := {"type": "shop", "cell_index": cell_index, "player_id": player_id}
	_assign_event_id(action)
	pending_actions[player_id] = action
	_send_shop(player_id, action)
	await _await_response(player_id, int(action["event_id"]), "shop_close")
	_close_event(player_id, int(action["event_id"]))

func _send_shop(player_id: int, action: Dictionary) -> void:
	var state: Dictionary = players_state[player_id]
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		pending_action = action.duplicate(true)
		displayed_event_id = int(action["event_id"])
		game_ui.show_shop(state["inventory"], int(state["coins"]))
	else:
		_show_shop_remote.rpc_id(peer_id, action, state["inventory"], int(state["coins"]))

func _host_buy_card(player_id: int, card_id: String) -> bool:
	if not is_host or _is_bankrupt(player_id) or not pending_actions.has(player_id) or String(pending_actions[player_id].get("type", "")) != "shop" or card_id not in GameRules.CARD_IDS:
		return false
	var price := GameRules.card_price(card_id)
	var state: Dictionary = players_state[player_id]
	if int(state["coins"]) <= price:
		_send_private_toast(player_id, "金币不足")
		_send_shop(player_id, pending_actions[player_id])
		return false
	var inventory: Dictionary = state["inventory"]
	state["coins"] = int(state["coins"]) - price
	inventory[card_id] = int(inventory.get(card_id, 0)) + 1
	state["inventory"] = inventory
	players_state[player_id] = state
	if int(state["coins"]) == 0: _declare_bankruptcy(player_id, "shop")
	_notify("shop", player_id, -1, int(pending_actions[player_id].get("cell_index", -1)), -price, "Player %d 在商店购买了%s" % [player_id, String(GameRules.CARD_NAMES[card_id])])
	_broadcast_state()
	_send_shop(player_id, pending_actions[player_id])
	_save_game()
	return true

func _host_use_card(player_id: int, card_id: String, target: int) -> bool:
	var resolving_force_buy := card_id == GameRules.CARD_FORCE_BUY and pending_actions.has(player_id) and String(pending_actions[player_id].get("type", "")) == "capture"
	if not is_host or _is_bankrupt(player_id) or (not can_player_roll(player_id) and not resolving_force_buy) or card_id not in GameRules.CARD_IDS:
		return false
	var state: Dictionary = players_state[player_id]
	var inventory: Dictionary = state["inventory"]
	if int(inventory.get(card_id, 0)) <= 0:
		return false
	var valid := false
	match card_id:
		GameRules.CARD_REMOTE_DICE:
			valid = target >= 1 and target <= 6
			if valid: state["forced_next_roll"] = target; state["status_effects"]["forced_next_roll"] = target
		GameRules.CARD_TOLL_FREE:
			valid = true
			state["toll_free_next_action"] = true
			state["status_effects"]["toll_free_next_action"] = true
		GameRules.CARD_REVERSE:
			valid = true
			state["reverse_next_move"] = true
			state["status_effects"]["reverse_next_move"] = true
		GameRules.CARD_SPEED:
			valid = true
			state["speed_next_move"] = true
			state["status_effects"]["speed_multiplier_next_move"] = 2
		GameRules.CARD_BUILD:
			valid = _is_cell_in_player_view(player_id, target) and _card_build(player_id, target)
		GameRules.CARD_DEMOLISH:
			valid = _is_cell_in_player_view(player_id, target) and _card_demolish(player_id, target)
		GameRules.CARD_FORCE_BUY:
			valid = _card_force_buy(player_id)
			if valid: state = players_state[player_id]
		GameRules.CARD_EQUALIZE:
			valid = _is_player_in_player_view(player_id, target) and _card_equalize(player_id, target)
			if valid: state = players_state[player_id]
	if not valid:
		return false
	inventory = state["inventory"]
	inventory[card_id] = int(inventory[card_id]) - 1
	state["inventory"] = inventory
	players_state[player_id] = state
	_send_card_effect(player_id, card_id)
	_notify("card", player_id, target, int(state.get("cell", -1)), 0, _card_notification(player_id, card_id, target))
	_broadcast_state()
	if card_id == GameRules.CARD_REMOTE_DICE:
		_host_try_roll(player_id, target)
	_save_game()
	return true

func _card_notification(player_id: int, card_id: String, target: int) -> String:
	match card_id:
		GameRules.CARD_REMOTE_DICE: return "Player %d 使用遥控骰子，选择了 %d 点" % [player_id, target]
		GameRules.CARD_BUILD:
			var level := int(properties[target]["property_level"])
			return "Player %d 使用建房卡，将 %d 号房产 L%d → L%d" % [player_id, target, level - 1, level]
		GameRules.CARD_DEMOLISH:
			var level := int(properties[target]["property_level"])
			return "Player %d 使用拆房卡，将 Player %d 的 %d 号房产 L%d → L%d" % [player_id, int(properties[target]["owner_id"]), target, level + 1, level]
		GameRules.CARD_FORCE_BUY: return "Player %d 使用强购卡取得了 %d 号房产" % [player_id, int(players_state[player_id]["cell"])]
		GameRules.CARD_EQUALIZE: return "Player %d 使用均富卡与 Player %d 平分金币" % [player_id, target]
		_: return "Player %d 使用了%s" % [player_id, String(GameRules.CARD_NAMES[card_id])]

func _card_build(player_id: int, cell_index: int) -> bool:
	if cell_index < 0 or cell_index >= properties.size(): return false
	var property: Dictionary = properties[cell_index]
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY or int(property["owner_id"]) != player_id or int(property["property_level"]) >= GameRules.MAX_PROPERTY_LEVEL: return false
	property["property_level"] = int(property["property_level"]) + 1
	properties[cell_index] = property
	_broadcast_property_effect(cell_index, "upgrade")
	return true

func _card_demolish(player_id: int, cell_index: int) -> bool:
	if cell_index < 0 or cell_index >= properties.size(): return false
	var property: Dictionary = properties[cell_index]
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY or int(property["owner_id"]) in [-1, player_id] or int(property["property_level"]) <= 1: return false
	property["property_level"] = int(property["property_level"]) - 1
	properties[cell_index] = property
	_broadcast_property_effect(cell_index, "demolish")
	return true

func _card_force_buy(player_id: int) -> bool:
	var cell_index := int(players_state[player_id]["cell"])
	var property: Dictionary = properties[cell_index]
	var owner_id := int(property["owner_id"])
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY or owner_id in [-1, player_id] or int(property["property_level"]) > GameRules.MAX_CAPTURABLE_PROPERTY_LEVEL: return false
	var price := GameRules.capture_price(int(property["property_level"]), int(property["capture_count"]))
	if int(players_state[player_id]["coins"]) < price: return false
	_apply_property_action(player_id, {"type": "capture", "cell_index": cell_index, "price": price})
	return true

func _card_equalize(player_id: int, target_player_id: int) -> bool:
	if target_player_id == player_id or target_player_id not in active_player_ids: return false
	var player: Dictionary = players_state[player_id]
	var target: Dictionary = players_state[target_player_id]
	var total := int(player["coins"]) + int(target["coins"])
	player["coins"] = floori(float(total) * 0.5)
	target["coins"] = total - int(player["coins"])
	players_state[player_id] = player
	players_state[target_player_id] = target
	return true

func _is_cell_in_player_view(player_id: int, cell_index: int) -> bool:
	if cell_index < 0 or cell_index >= board.get_cell_count():
		return false
	var half_view := get_viewport().get_visible_rect().size * 0.5
	var delta := board.get_cell_position(cell_index) - _player_node(player_id).position
	return absf(delta.x) <= half_view.x + board.cell_size * 0.5 and absf(delta.y) <= half_view.y + board.cell_size * 0.5

func _is_player_in_player_view(player_id: int, target_player_id: int) -> bool:
	if target_player_id not in active_player_ids or target_player_id == player_id:
		return false
	var half_view := get_viewport().get_visible_rect().size * 0.5
	var delta := _player_node(target_player_id).position - _player_node(player_id).position
	return absf(delta.x) <= half_view.x and absf(delta.y) <= half_view.y

func _broadcast_toast(message: String, excluded_player_id: int = -1) -> void:
	for player_id in active_player_ids:
		if player_id == excluded_player_id: continue
		var peer_id := int(player_peer_ids.get(player_id, 1))
		if peer_id == 1:
			_show_toast_remote(message)
		else:
			_show_toast_remote.rpc_id(peer_id, message)

func _send_private_toast(player_id: int, message: String) -> void:
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_show_toast_remote(message)
	else:
		_show_toast_remote.rpc_id(peer_id, message)

func _notify(event_type: String, source_player_id: int, target_player_id: int, cell_id: int, amount: int, message: String) -> void:
	notifications.push_front({"event_id": next_event_id, "sequence_id": notification_sequence, "event_type": event_type, "source_player_id": source_player_id, "target_player_id": target_player_id, "cell_id": cell_id, "amount": amount, "message": message, "time": Time.get_time_string_from_system()})
	next_event_id += 1
	notification_sequence += 1
	if notifications.size() > 100:
		notifications.pop_back()
	_broadcast_toast(message)

func _request_player_decision(player_id: int, action: Dictionary) -> bool:
	_assign_event_id(action)
	pending_actions[player_id] = action
	_broadcast_state()
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1:
		_show_local_property_prompt(action)
	else:
		_show_property_prompt_remote.rpc_id(peer_id, action)
	var accepted: bool = await _await_response(player_id, int(action["event_id"]), "decision")
	_close_event(player_id, int(action["event_id"]))
	return accepted

func _assign_event_id(action: Dictionary) -> void:
	action["event_id"] = next_event_id
	next_event_id += 1

func _show_local_property_prompt(action: Dictionary) -> void:
	pending_action = action.duplicate(true)
	displayed_event_id = int(action["event_id"])
	if String(action["type"]) == "reward":
		game_ui.show_event_prompt(action, true)
	else:
		game_ui.show_property_prompt(action)
	property_prompted.emit(action)

func _await_response(player_id: int, event_id: int, response_type: String) -> bool:
	while true:
		var response: Dictionary = action_responses.get(event_id, {})
		if int(response.get("player_id", -1)) == player_id and String(response.get("type", "")) == response_type:
			action_responses.erase(event_id)
			return bool(response.get("accepted", false))
		await get_tree().process_frame
	return false

func _host_record_response(player_id: int, event_id: int, response_type: String, accepted: bool, option_index: int = -1) -> void:
	if not is_host or not pending_actions.has(player_id):
		return
	var expected: Dictionary = pending_actions[player_id]
	if int(expected.get("event_id", -1)) != event_id:
		return
	action_responses[event_id] = {"player_id": player_id, "type": response_type, "accepted": accepted, "option_index": option_index}

func _close_event(player_id: int, event_id: int) -> void:
	if pending_actions.has(player_id) and int(pending_actions[player_id].get("event_id", -1)) == event_id:
		pending_actions.erase(player_id)
	if multiplayer.has_multiplayer_peer():
		_hide_prompt_remote.rpc(event_id)
	else:
		_hide_prompt_remote(event_id)

func _build_property_action(player_id: int, cell_index: int) -> Dictionary:
	var property: Dictionary = properties[cell_index]
	var owner_id := int(property["owner_id"])
	var level := int(property["property_level"])
	var player: Dictionary = players_state[player_id]
	var action: Dictionary = {"cell_index": cell_index, "owner_id": owner_id, "property_level": level, "player_id": player_id}
	if owner_id == -1:
		action.merge({"type": "buy", "price": GameRules.purchase_price()})
	elif owner_id == player_id and GameRules.can_upgrade_property(int(player["player_level"]), level):
		action.merge({"type": "upgrade", "price": GameRules.upgrade_price(level)})
	elif owner_id != player_id and level >= 1 and level <= GameRules.MAX_CAPTURABLE_PROPERTY_LEVEL:
		action.merge({"type": "capture", "price": GameRules.capture_price(level, int(property["capture_count"]))})
		action["force_buy_available"] = int(player["inventory"].get(GameRules.CARD_FORCE_BUY, 0)) > 0
	else:
		return {}
	action["can_afford"] = int(player["coins"]) >= int(action["price"])
	return action

func _apply_property_action(player_id: int, action: Dictionary) -> void:
	var cell_index := int(action["cell_index"])
	var price := int(action["price"])
	var player: Dictionary = players_state[player_id]
	var property: Dictionary = properties[cell_index]
	player["coins"] = int(player["coins"]) - price
	match String(action["type"]):
		"buy":
			property["owner_id"] = player_id
			property["property_level"] = 1
		"upgrade":
			property["property_level"] = int(property["property_level"]) + 1
		"capture":
			var old_owner := int(property["owner_id"])
			var old_owner_state: Dictionary = players_state[old_owner]
			old_owner_state["coins"] = int(old_owner_state["coins"]) + GameRules.capture_owner_payout(price)
			players_state[old_owner] = old_owner_state
			property["owner_id"] = player_id
			property["capture_count"] = int(property["capture_count"]) + 1
	players_state[player_id] = player
	properties[cell_index] = property
	if int(player["coins"]) == 0: _declare_bankruptcy(player_id, "property")
	var effect_type := "upgrade" if String(action["type"]) == "upgrade" else ("ownership" if String(action["type"]) in ["buy", "capture"] else "upgrade")
	_broadcast_property_effect(cell_index, effect_type)
	_save_game()

func _broadcast_property_effect(cell_index: int, effect_type: String) -> void:
	if multiplayer.has_multiplayer_peer():
		_play_property_effect_remote.rpc(cell_index, effect_type)
	else:
		_play_property_effect_remote(cell_index, effect_type)

func _show_money_popup(player_id: int, amount: int) -> void:
	if multiplayer.has_multiplayer_peer():
		_show_money_popup_remote.rpc(player_id, amount)
	else:
		_show_money_popup_remote(player_id, amount)

func _finish_player_action(player_id: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["toll_free_this_action"] = false
	state["action_state"] = GameRules.ACTION_IDLE
	players_state[player_id] = state
	_broadcast_state()
	action_finished.emit(player_id)

func _is_bankrupt(player_id: int) -> bool:
	return String(players_state[player_id].get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_BANKRUPT

func _apply_passive_payment(player_id: int, requested: int, reason: String) -> int:
	var state: Dictionary = players_state[player_id]
	var actual := mini(maxi(0, int(state.get("coins", 0))), maxi(0, requested))
	state["coins"] = maxi(0, int(state.get("coins", 0)) - actual)
	players_state[player_id] = state
	if int(state["coins"]) == 0 and requested > 0:
		_declare_bankruptcy(player_id, reason)
	return actual

func _declare_bankruptcy(player_id: int, _reason: String = "") -> void:
	var state: Dictionary = players_state[player_id]
	if String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_BANKRUPT: return
	state["coins"] = 0
	state["bankruptcy_state"] = GameRules.BANKRUPTCY_BANKRUPT
	state["bankrupt_date"] = _server_date()
	state["protection_end_time"] = 0
	state["action_state"] = GameRules.ACTION_IDLE
	state["toll_free_this_action"] = false
	players_state[player_id] = state
	var peer_id := int(player_peer_ids.get(player_id, 1))
	if peer_id == 1: _play_bankruptcy_effect_remote(player_id)
	else: _play_bankruptcy_effect_remote.rpc_id(peer_id, player_id)
	_notify("bankrupt", player_id, -1, int(state["cell"]), 0, "Player %d 已破产" % player_id)
	_save_game()

func _check_player_login(player_id: int) -> void:
	var state: Dictionary = players_state[player_id]
	if String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_BANKRUPT and not String(state.get("bankrupt_date", "")).is_empty() and _server_date() > String(state["bankrupt_date"]):
		state["coins"] = GameRules.BANKRUPTCY_RELIEF_COINS
		state["bankruptcy_state"] = GameRules.BANKRUPTCY_PROTECTED
		state["protection_end_time"] = _server_time() + GameRules.BANKRUPTCY_PROTECTION_SECONDS
		players_state[player_id] = state
		_notify("bankruptcy_relief", player_id, -1, int(state["cell"]), GameRules.BANKRUPTCY_RELIEF_COINS, "Player %d 获得 1000 金币破产救济，并进入 5 小时保护期" % player_id)
		_save_game()
	elif String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_PROTECTED and _server_time() >= int(state.get("protection_end_time", 0)):
		_end_protection(player_id)
	_check_player_tax(player_id)

func _check_protection_expiry() -> void:
	for player_id in active_player_ids:
		var state: Dictionary = players_state[player_id]
		if String(state.get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_PROTECTED and _server_time() >= int(state.get("protection_end_time", 0)):
			_end_protection(player_id)

func _end_protection(player_id: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL
	state["protection_end_time"] = 0
	players_state[player_id] = state
	_notify("protection_ended", player_id, -1, int(state["cell"]), 0, "Player %d 的破产保护已结束" % player_id)
	_broadcast_state()
	_save_game()

func _check_daily_taxes() -> void:
	for player_id in active_player_ids:
		_check_player_tax(player_id)

func _check_player_tax(player_id: int) -> bool:
	var now := _server_datetime()
	if int(now.hour) < GameRules.DAILY_TAX_HOUR or (int(now.hour) == GameRules.DAILY_TAX_HOUR and int(now.minute) < GameRules.DAILY_TAX_MINUTE): return false
	var state: Dictionary = players_state[player_id]
	if String(state.get("last_tax_date", "")) == _server_date(): return false
	var income := maxi(0, int(state.get("daily_taxable_income", 0)))
	var requested_tax := floori(float(income) * GameRules.DAILY_TAX_RATE)
	var actual_tax := _apply_passive_payment(player_id, requested_tax, "daily_tax")
	state = players_state[player_id]
	state["daily_taxable_income"] = 0
	state["last_tax_date"] = _server_date()
	players_state[player_id] = state
	_notify("daily_tax", player_id, -1, int(state["cell"]), -actual_tax, "每日税收结算：Player %d 今日收入 %d，缴税 %d" % [player_id, income, actual_tax])
	_send_private_toast(player_id, "【每日税收】\n今日可税收入：%d\n税率：10%%\n缴税：%d" % [income, actual_tax])
	_broadcast_state()
	_save_game()
	return true

func _server_time() -> int:
	return server_time_override if server_time_override >= 0 else int(Time.get_unix_time_from_system())

func _server_date() -> String:
	var value := _server_datetime()
	return "%04d-%02d-%02d" % [int(value.year), int(value.month), int(value.day)]

func _server_datetime() -> Dictionary:
	return Time.get_datetime_dict_from_unix_time(server_time_override) if server_time_override >= 0 else Time.get_datetime_dict_from_system()

func _calculate_leaderboard() -> Array:
	var result: Array = []
	for player_id in active_player_ids:
		var property_value := 0
		for property in properties:
			if int(property.get("owner_id", -1)) == player_id: property_value += GameRules.property_value(int(property.get("property_level", 0)))
		var coins := int(players_state[player_id].get("coins", 0))
		result.append({"player_id": player_id, "coins": coins, "property_value": property_value, "total_wealth": coins + property_value})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["total_wealth"]) == int(b["total_wealth"]): return int(a["coins"]) > int(b["coins"])
		return int(a["total_wealth"]) > int(b["total_wealth"]))
	for index in range(result.size()): result[index]["rank"] = index + 1
	return result

func _save_game() -> bool:
	if not is_host or save_load_failed: return false
	var saved_players := players_state.duplicate(true)
	for player_id in saved_players:
		var saved_state: Dictionary = saved_players[player_id]
		saved_state["action_state"] = GameRules.ACTION_IDLE
		saved_state["toll_free_this_action"] = false
		saved_players[player_id] = saved_state
	var payload := {"save_version": GameRules.SAVE_VERSION, "players_state": saved_players, "properties": properties, "notifications": notifications, "notification_sequence": notification_sequence, "next_event_id": next_event_id}
	var file := FileAccess.open(save_temp_path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(payload))
	file.flush()
	file.close()
	var absolute_save := ProjectSettings.globalize_path(save_path)
	var absolute_temp := ProjectSettings.globalize_path(save_temp_path)
	var absolute_backup := absolute_save + ".bak"
	if FileAccess.file_exists(absolute_backup): DirAccess.remove_absolute(absolute_backup)
	if FileAccess.file_exists(absolute_save) and DirAccess.rename_absolute(absolute_save, absolute_backup) != OK: return false
	if DirAccess.rename_absolute(absolute_temp, absolute_save) != OK:
		if FileAccess.file_exists(absolute_backup): DirAccess.rename_absolute(absolute_backup, absolute_save)
		return false
	if FileAccess.file_exists(absolute_backup): DirAccess.remove_absolute(absolute_backup)
	_last_autosave_time = _server_time()
	return true

func _load_game() -> bool:
	if not FileAccess.file_exists(save_path): return false
	var file := FileAccess.open(save_path, FileAccess.READ)
	if file == null: save_load_failed = true; return false
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		save_load_failed = true
		return false
	var parsed = parser.data
	if not parsed is Dictionary or int(parsed.get("save_version", -1)) != GameRules.SAVE_VERSION:
		save_load_failed = true
		return false
	var loaded := _migrate_and_apply_save(parsed)
	if not loaded: save_load_failed = true
	return loaded

func _migrate_and_apply_save(data: Dictionary) -> bool:
	if int(data.get("save_version", -1)) != GameRules.SAVE_VERSION: return false
	if not data.get("players_state", null) is Dictionary or not data.get("properties", null) is Array or not data.get("notifications", null) is Array: return false
	var loaded_players: Dictionary = data["players_state"]
	for player_id in range(1, 7):
		var raw_loaded = loaded_players.get(str(player_id), loaded_players.get(player_id, {}))
		if not raw_loaded is Dictionary: return false
		var loaded: Dictionary = raw_loaded
		var state := GameRules.build_player_state(player_id)
		for key in loaded: state[key] = loaded[key]
		var inventory: Dictionary = GameRules.build_initial_inventory(); inventory.merge(state.get("inventory", {}), true); state["inventory"] = inventory
		var effects: Dictionary = GameRules.build_player_state(player_id)["status_effects"]; effects.merge(state.get("status_effects", {}), true); state["status_effects"] = effects
		state["action_state"] = GameRules.ACTION_IDLE
		state["toll_free_this_action"] = false
		players_state[player_id] = state
	var loaded_properties: Array = data.get("properties", [])
	if loaded_properties.size() != properties.size(): return false
	for property in loaded_properties:
		if not property is Dictionary or not property.has("cell_index") or not property.has("owner_id") or not property.has("property_level") or not property.has("capture_count"): return false
	properties = loaded_properties.duplicate(true)
	notifications = data.get("notifications", []).duplicate(true)
	notification_sequence = int(data.get("notification_sequence", 1))
	next_event_id = int(data.get("next_event_id", 1))
	board.set_property_states(properties)
	for player_id in player_nodes:
		_player_node(player_id).place_at_cell(int(players_state[player_id]["cell"]), board)
	return true

func _choose_wheel_result() -> int:
	if test_mode and GameRules.is_wheel_result_valid(test_wheel_result_override):
		return test_wheel_result_override
	return int(GameRules.WHEEL_RESULTS[_random.randi_range(0, GameRules.WHEEL_RESULTS.size() - 1)])

func _broadcast_state() -> void:
	var snapshot := _make_snapshot()
	if multiplayer.has_multiplayer_peer():
		_sync_state.rpc(snapshot)
	else:
		_apply_snapshot(snapshot)

func _make_snapshot() -> Dictionary:
	leaderboard_data = _calculate_leaderboard()
	return {"players": players_state.duplicate(true), "active_player_ids": active_player_ids.duplicate(), "properties": properties.duplicate(true), "last_rolls": last_rolls.duplicate(true), "last_event": last_event.duplicate(true), "last_wheel_result": last_wheel_result, "notifications": notifications.duplicate(true), "leaderboard": leaderboard_data.duplicate(true), "server_time": _server_time()}

func _apply_snapshot(snapshot: Dictionary) -> void:
	players_state = snapshot["players"].duplicate(true)
	active_player_ids.assign(snapshot.get("active_player_ids", [1, 2]))
	properties = snapshot["properties"].duplicate(true)
	last_rolls = snapshot.get("last_rolls", {1: 0, 2: 0}).duplicate(true)
	last_event = snapshot.get("last_event", {}).duplicate(true)
	last_wheel_result = int(snapshot.get("last_wheel_result", 0))
	notifications = snapshot.get("notifications", []).duplicate(true)
	leaderboard_data = snapshot.get("leaderboard", []).duplicate(true)
	game_is_started = true
	_show_world()
	board.set_property_states(properties)
	for player_id in player_nodes:
		var player := _player_node(player_id)
		player.visible = player_id in active_player_ids
		player.set_bankruptcy_state(String(players_state[player_id].get("bankruptcy_state", GameRules.BANKRUPTCY_NORMAL)) == GameRules.BANKRUPTCY_BANKRUPT)
		if not player.is_moving and String(players_state[player_id].get("action_state", GameRules.ACTION_IDLE)) == GameRules.ACTION_IDLE:
			player.place_at_cell(int(players_state[player_id]["cell"]), board)
	_refresh_ui()
	state_applied.emit()

func _show_world() -> void:
	board.visible = true
	for player_id in player_nodes:
		player_nodes[player_id].visible = player_id in active_player_ids
	game_ui.show_game()

func _refresh_ui() -> void:
	if local_player_id > 0:
		game_ui.update_game_state(local_player_id, players_state, active_player_ids, last_rolls, notifications)

func _player_node(player_id: int) -> BoardPlayer:
	return player_nodes[player_id]

func _next_available_player_id() -> int:
	for player_id in range(2, 7):
		if not player_peer_ids.has(player_id):
			return player_id
	return -1

func _player_id_for_peer(peer_id: int) -> int:
	for player_id in player_peer_ids:
		if int(player_peer_ids[player_id]) == peer_id:
			return int(player_id)
	return -1
