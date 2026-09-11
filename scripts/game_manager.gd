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

var is_host := false
var local_player_id := 0
var game_is_started := false
var players_state: Dictionary = {}
var properties: Array = []
var last_rolls: Dictionary = {1: 0, 2: 0}
var last_event: Dictionary = {}
var last_wheel_result := 0
var player_peer_ids: Dictionary = {1: 1}

# Host-only state. RPCs run serially on Godot's main thread; per-cell queues keep
# landing decisions atomic while unrelated players remain independent.
var pending_actions: Dictionary = {}
var property_action_queues: Dictionary = {}
var action_responses: Dictionary = {}
var animation_done: Dictionary = {}
var next_action_id := 1
var next_event_id := 1

# This process controls only its assigned player.
var pending_action: Dictionary = {}
var displayed_event_id := 0
var test_mode := false
var test_wheel_result_override := 0
var test_wheel_spin_duration := 0.0
var _random := RandomNumberGenerator.new()

func _ready() -> void:
	_random.randomize()
	players_state = {1: GameRules.build_player_state(1), 2: GameRules.build_player_state(2)}
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
	var error := server.create_server(target_port, 1)
	if error != OK:
		game_ui.set_lobby_status("Host 启动失败：%s" % error_string(error))
		return false
	multiplayer.multiplayer_peer = server
	is_host = true
	local_player_id = 1
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

func _on_roll_requested() -> void:
	if is_host:
		_host_try_roll(local_player_id)
	else:
		_request_roll_rpc.rpc_id(1)

func _on_peer_connected(peer_id: int) -> void:
	if not is_host or game_is_started:
		return
	player_peer_ids[2] = peer_id
	game_is_started = true
	_assign_local_player.rpc_id(peer_id, 2)
	_show_world()
	_sync_state.rpc(_make_snapshot())
	game_started.emit()

func _on_peer_disconnected(peer_id: int) -> void:
	if is_host and player_peer_ids.get(2, 0) == peer_id:
		game_is_started = false
		game_ui.show_startup()
		game_ui.set_lobby_status("Player 2 已断开，请重新启动本局")

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
func _animate_action(player_id: int, action_id: int, start_cell: int, roll_value: int, target_cell: int) -> void:
	var player := _player_node(player_id)
	player.place_at_cell(start_cell, board)
	player.move_steps(roll_value, board)
	await player.movement_finished
	player.place_at_cell(target_cell, board)
	animation_done[action_id] = true
	_refresh_ui()

@rpc("authority", "call_remote", "reliable")
func _show_property_prompt_remote(action: Dictionary) -> void:
	_show_local_property_prompt(action)

@rpc("authority", "call_local", "reliable")
func _show_toll_prompt_remote(action: Dictionary) -> void:
	displayed_event_id = int(action["event_id"])
	if local_player_id == int(action["payer_id"]):
		pending_action = action.duplicate(true)
	game_ui.show_toll_prompt(action, local_player_id)
	if local_player_id == int(action["payer_id"]):
		property_prompted.emit(action)

@rpc("authority", "call_local", "reliable")
func _show_wheel_ready_remote(action: Dictionary) -> void:
	displayed_event_id = int(action["event_id"])
	if local_player_id == int(action["player_id"]):
		pending_action = action.duplicate(true)
	game_ui.show_wheel_ready(int(action["player_id"]), local_player_id == int(action["player_id"]))

@rpc("authority", "call_local", "reliable")
func _spin_wheel_remote(result: int, duration: float) -> void:
	game_ui.play_wheel_spin(result, duration)

@rpc("authority", "call_local", "reliable")
func _show_wheel_result_remote(action: Dictionary) -> void:
	displayed_event_id = int(action["event_id"])
	if local_player_id == int(action["player_id"]):
		pending_action = action.duplicate(true)
	game_ui.show_wheel_result(int(action["amount"]), local_player_id == int(action["player_id"]), int(action["player_id"]))

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

func _host_try_roll(requesting_player_id: int, forced_roll: int = -1) -> bool:
	if not is_host or not game_is_started or not can_player_roll(requesting_player_id):
		return false
	var roll := generate_roll() if forced_roll < 0 else forced_roll
	if not test_mode:
		roll = clampi(roll, dice_min_value, dice_max_value)
	roll = maxi(1, roll)
	var state: Dictionary = players_state[requesting_player_id]
	var start_cell := int(state["cell"])
	var target_cell := posmod(start_cell + roll, board.get_cell_count())
	var action_id := next_action_id
	next_action_id += 1
	state["stamina"] = int(state["stamina"]) - 1
	state["action_state"] = GameRules.ACTION_RESOLVING
	state["cell"] = target_cell
	players_state[requesting_player_id] = state
	last_rolls[requesting_player_id] = roll
	if String(properties[target_cell]["cell_type"]) == GameRules.CELL_PROPERTY:
		if not property_action_queues.has(target_cell):
			property_action_queues[target_cell] = []
		property_action_queues[target_cell].append(action_id)
	if multiplayer.has_multiplayer_peer():
		_animate_action.rpc(requesting_player_id, action_id, start_cell, roll, target_cell)
	else:
		_animate_action(requesting_player_id, action_id, start_cell, roll, target_cell)
	_broadcast_state()
	_resolve_landing(requesting_player_id, action_id, target_cell)
	return true

func _resolve_landing(player_id: int, action_id: int, cell_index: int) -> void:
	while not bool(animation_done.get(action_id, false)):
		await get_tree().process_frame
	animation_done.erase(action_id)
	var cell_type := String(properties[cell_index]["cell_type"])
	if cell_type == GameRules.CELL_PROPERTY:
		await _wait_for_property_queue(cell_index, action_id)
		await _resolve_property_landing(player_id, cell_index)
		_release_property_queue(cell_index, action_id)
	elif cell_type == GameRules.CELL_REWARD:
		await _resolve_reward(player_id, cell_index)
	elif cell_type == GameRules.CELL_WHEEL:
		await _resolve_wheel(player_id, cell_index)
	_finish_player_action(player_id)

func _wait_for_property_queue(cell_index: int, action_id: int) -> void:
	while property_action_queues.has(cell_index) and int(property_action_queues[cell_index][0]) != action_id:
		await get_tree().process_frame

func _release_property_queue(cell_index: int, action_id: int) -> void:
	if not property_action_queues.has(cell_index):
		return
	var queue: Array = property_action_queues[cell_index]
	if not queue.is_empty() and int(queue[0]) == action_id:
		queue.pop_front()
	if queue.is_empty():
		property_action_queues.erase(cell_index)
	else:
		property_action_queues[cell_index] = queue

func _resolve_property_landing(player_id: int, cell_index: int) -> void:
	var property: Dictionary = properties[cell_index]
	var owner_id := int(property["owner_id"])
	if owner_id != -1 and owner_id != player_id:
		await _resolve_toll(player_id, cell_index)
	var action := _build_property_action(player_id, cell_index)
	if action.is_empty():
		return
	var accepted: bool = await _request_player_decision(player_id, action)
	if accepted and bool(action.get("can_afford", false)):
		_apply_property_action(player_id, action)
		_broadcast_state()

func _resolve_toll(player_id: int, cell_index: int) -> void:
	var property: Dictionary = properties[cell_index]
	var owner_id := int(property["owner_id"])
	var amount := GameRules.toll_fee(int(property["property_level"]))
	if owner_id == -1 or owner_id == player_id or amount <= 0:
		return
	var payer: Dictionary = players_state[player_id]
	var owner: Dictionary = players_state[owner_id]
	payer["coins"] = int(payer["coins"]) - amount
	owner["coins"] = int(owner["coins"]) + amount
	players_state[player_id] = payer
	players_state[owner_id] = owner
	var action := {"type": "toll", "payer_id": player_id, "owner_id": owner_id, "cell_index": cell_index, "property_level": int(property["property_level"]), "amount": amount}
	_assign_event_id(action)
	pending_actions[player_id] = action
	_broadcast_state()
	if multiplayer.has_multiplayer_peer():
		_show_toll_prompt_remote.rpc(action)
	else:
		_show_toll_prompt_remote(action)
	await _await_response(player_id, int(action["event_id"]), "decision")
	_close_event(player_id, int(action["event_id"]))

func _resolve_reward(player_id: int, cell_index: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + GameRules.REWARD_COINS
	players_state[player_id] = state
	var action := {"type": "reward", "amount": GameRules.REWARD_COINS, "cell_index": cell_index, "player_id": player_id}
	last_event = action.duplicate(true)
	await _request_player_decision(player_id, action)

func _resolve_wheel(player_id: int, cell_index: int) -> void:
	var result := _choose_wheel_result()
	last_wheel_result = result
	var action := {"type": "wheel", "amount": result, "cell_index": cell_index, "player_id": player_id}
	_assign_event_id(action)
	pending_actions[player_id] = action
	_broadcast_state()
	if multiplayer.has_multiplayer_peer():
		_show_wheel_ready_remote.rpc(action)
	else:
		_show_wheel_ready_remote(action)
	await _await_response(player_id, int(action["event_id"]), "wheel_spin")
	var duration := test_wheel_spin_duration if test_mode and test_wheel_spin_duration > 0.0 else GameRules.WHEEL_SPIN_DURATION
	if multiplayer.has_multiplayer_peer():
		_spin_wheel_remote.rpc(result, duration)
	else:
		_spin_wheel_remote(result, duration)
	await get_tree().create_timer(duration).timeout
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + result
	players_state[player_id] = state
	last_event = action.duplicate(true)
	_broadcast_state()
	if multiplayer.has_multiplayer_peer():
		_show_wheel_result_remote.rpc(action)
	else:
		_show_wheel_result_remote(action)
	await _await_response(player_id, int(action["event_id"]), "wheel_confirm")
	_close_event(player_id, int(action["event_id"]))

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
	return {"players": players_state.duplicate(true), "properties": properties.duplicate(true), "last_rolls": last_rolls.duplicate(true), "last_event": last_event.duplicate(true), "last_wheel_result": last_wheel_result}

func _apply_snapshot(snapshot: Dictionary) -> void:
	players_state = snapshot["players"].duplicate(true)
	properties = snapshot["properties"].duplicate(true)
	last_rolls = snapshot.get("last_rolls", {1: 0, 2: 0}).duplicate(true)
	last_event = snapshot.get("last_event", {}).duplicate(true)
	last_wheel_result = int(snapshot.get("last_wheel_result", 0))
	game_is_started = true
	_show_world()
	board.set_property_states(properties)
	for player_id in [1, 2]:
		var player := _player_node(player_id)
		if not player.is_moving:
			player.place_at_cell(int(players_state[player_id]["cell"]), board)
	_refresh_ui()
	state_applied.emit()

func _show_world() -> void:
	board.visible = true
	player_1.visible = true
	player_2.visible = true
	game_ui.show_game()

func _refresh_ui() -> void:
	if local_player_id > 0:
		game_ui.update_game_state(local_player_id, players_state, last_rolls)

func _player_node(player_id: int) -> BoardPlayer:
	return player_1 if player_id == 1 else player_2

func _player_id_for_peer(peer_id: int) -> int:
	for player_id in player_peer_ids:
		if int(player_peer_ids[player_id]) == peer_id:
			return int(player_id)
	return -1
