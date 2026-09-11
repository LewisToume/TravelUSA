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
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(_delta: float) -> void:
	if game_is_started and local_player_id > 0:
		follow_camera.position = _player_node(local_player_id).position

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
	return int(state["stamina"]) > 0 and String(state["action_state"]) == GameRules.ACTION_IDLE

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
		_host_use_card(local_player_id, card_id, target)
	else:
		_request_use_card_rpc.rpc_id(1, card_id, target)

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
		_broadcast_state()

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
		_host_use_card(_player_id_for_peer(multiplayer.get_remote_sender_id()), card_id, target)

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
	var move_distance := roll + (3 if bool(state.get("speed_next_move", false)) else 0)
	state["reverse_next_move"] = false
	state["speed_next_move"] = false
	state["status_effects"]["reverse_next_move"] = false
	state["status_effects"]["speed_bonus_next_move"] = 0
	var start_cell := int(state["cell"])
	var target_cell := posmod(start_cell + direction * move_distance, board.get_cell_count())
	var action_id := next_action_id
	next_action_id += 1
	state["stamina"] = int(state["stamina"]) - 1
	state["action_state"] = GameRules.ACTION_RESOLVING
	state["cell"] = target_cell
	players_state[requesting_player_id] = state
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
	_finish_player_action(player_id)

func _resolve_property_landing(player_id: int, cell_index: int, final_toll_paid: bool) -> void:
	var property: Dictionary = properties[cell_index]
	if not final_toll_paid and int(property["owner_id"]) not in [-1, player_id]:
		_settle_step_toll(player_id, cell_index)
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
	var property: Dictionary = properties[cell_index]
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY:
		return false
	var owner_id := int(property["owner_id"])
	var amount := GameRules.toll_fee(int(property["property_level"]))
	if owner_id == -1 or owner_id == player_id or amount <= 0:
		return false
	var payer: Dictionary = players_state[player_id]
	if bool(payer.get("next_toll_free", false)):
		payer["next_toll_free"] = false
		payer["status_effects"]["toll_free_charges"] = 0
		players_state[player_id] = payer
		_notify("toll_free", player_id, owner_id, cell_index, amount, "Player %d 使用免租卡，免除 %d 金币过路费" % [player_id, amount])
		_broadcast_state()
		return true
	var owner: Dictionary = players_state[owner_id]
	payer["coins"] = int(payer["coins"]) - amount
	owner["coins"] = int(owner["coins"]) + amount
	players_state[player_id] = payer
	players_state[owner_id] = owner
	_show_money_popup(player_id, -amount)
	_show_money_popup(owner_id, amount)
	var action := {"type": "toll", "payer_id": player_id, "owner_id": owner_id, "cell_index": cell_index, "property_level": int(property["property_level"]), "amount": amount}
	_notify("toll", player_id, owner_id, cell_index, amount, "Player %d 经过 Player %d 的 L%d 房产，支付 %d 金币" % [player_id, owner_id, int(property["property_level"]), amount])
	_broadcast_state()
	if multiplayer.has_multiplayer_peer():
		_show_toll_toast_remote.rpc(action)
	else:
		_show_toll_toast_remote(action)
	return true

func _resolve_reward(player_id: int, cell_index: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + GameRules.REWARD_COINS
	players_state[player_id] = state
	var action := {"type": "reward", "amount": GameRules.REWARD_COINS, "cell_index": cell_index, "player_id": player_id}
	last_event = action.duplicate(true)
	_notify("reward", player_id, -1, cell_index, GameRules.REWARD_COINS, "Player %d 获得奖励 %d 金币" % [player_id, GameRules.REWARD_COINS])
	await _request_player_decision(player_id, action)

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
	state["coins"] = int(state["coins"]) + result
	players_state[player_id] = state
	last_event = action.duplicate(true)
	_broadcast_state()
	_send_wheel_result(player_id, action)
	_notify("wheel", player_id, -1, cell_index, result, "Player %d 转盘%s %d 金币" % [player_id, "获得" if result >= 0 else "损失", absi(result)])
	_broadcast_state()
	await _await_response(player_id, int(action["event_id"]), "wheel_confirm")
	_close_event(player_id, int(action["event_id"]))

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
	if not is_host or not pending_actions.has(player_id) or String(pending_actions[player_id].get("type", "")) != "shop" or card_id not in GameRules.CARD_IDS:
		return false
	var price := GameRules.card_price(card_id)
	var state: Dictionary = players_state[player_id]
	if int(state["coins"]) < price:
		return false
	var inventory: Dictionary = state["inventory"]
	state["coins"] = int(state["coins"]) - price
	inventory[card_id] = int(inventory.get(card_id, 0)) + 1
	state["inventory"] = inventory
	players_state[player_id] = state
	_notify("shop", player_id, -1, int(pending_actions[player_id].get("cell_index", -1)), -price, "Player %d 在商店购买了%s" % [player_id, String(GameRules.CARD_NAMES[card_id])])
	_broadcast_state()
	_send_shop(player_id, pending_actions[player_id])
	return true

func _host_use_card(player_id: int, card_id: String, target: int) -> bool:
	if not is_host or not can_player_roll(player_id) or card_id not in GameRules.CARD_IDS:
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
			state["next_toll_free"] = true
			state["status_effects"]["toll_free_charges"] = 1
		GameRules.CARD_REVERSE:
			valid = true
			state["reverse_next_move"] = true
			state["status_effects"]["reverse_next_move"] = true
		GameRules.CARD_SPEED:
			valid = true
			state["speed_next_move"] = true
			state["status_effects"]["speed_bonus_next_move"] = 3
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
	_notify("card", player_id, target, int(state.get("cell", -1)), 0, "Player %d 使用了%s" % [player_id, String(GameRules.CARD_NAMES[card_id])])
	_broadcast_state()
	if card_id == GameRules.CARD_REMOTE_DICE:
		_host_try_roll(player_id, target)
	return true

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
	if String(property["cell_type"]) != GameRules.CELL_PROPERTY or owner_id in [-1, player_id]: return false
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
	return board.get_cell_position(cell_index).distance_to(_player_node(player_id).position) <= maxf(half_view.x, half_view.y) + board.cell_size

func _is_player_in_player_view(player_id: int, target_player_id: int) -> bool:
	if target_player_id not in active_player_ids or target_player_id == player_id:
		return false
	var half_view := get_viewport().get_visible_rect().size * 0.5
	return _player_node(player_id).position.distance_to(_player_node(target_player_id).position) <= maxf(half_view.x, half_view.y) + board.cell_size

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

func _host_record_response(player_id: int, event_id: int, response_type: String, accepted: bool) -> void:
	if not is_host or not pending_actions.has(player_id):
		return
	var expected: Dictionary = pending_actions[player_id]
	if int(expected.get("event_id", -1)) != event_id:
		return
	action_responses[event_id] = {"player_id": player_id, "type": response_type, "accepted": accepted}

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
			if GameRules.can_upgrade_property(int(player["player_level"]), int(property["property_level"])):
				property["property_level"] = int(property["property_level"]) + 1
	players_state[player_id] = player
	properties[cell_index] = property
	var effect_type := "upgrade" if String(action["type"]) == "upgrade" else ("ownership" if String(action["type"]) in ["buy", "capture"] else "upgrade")
	_broadcast_property_effect(cell_index, effect_type)

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
	state["action_state"] = GameRules.ACTION_IDLE
	players_state[player_id] = state
	_broadcast_state()
	action_finished.emit(player_id)

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
	return {"players": players_state.duplicate(true), "active_player_ids": active_player_ids.duplicate(), "properties": properties.duplicate(true), "last_rolls": last_rolls.duplicate(true), "last_event": last_event.duplicate(true), "last_wheel_result": last_wheel_result, "notifications": notifications.duplicate(true)}

func _apply_snapshot(snapshot: Dictionary) -> void:
	players_state = snapshot["players"].duplicate(true)
	active_player_ids.assign(snapshot.get("active_player_ids", [1, 2]))
	properties = snapshot["properties"].duplicate(true)
	last_rolls = snapshot.get("last_rolls", {1: 0, 2: 0}).duplicate(true)
	last_event = snapshot.get("last_event", {}).duplicate(true)
	last_wheel_result = int(snapshot.get("last_wheel_result", 0))
	notifications = snapshot.get("notifications", []).duplicate(true)
	game_is_started = true
	_show_world()
	board.set_property_states(properties)
	for player_id in player_nodes:
		var player := _player_node(player_id)
		player.visible = player_id in active_player_ids
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
