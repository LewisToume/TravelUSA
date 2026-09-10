extends Node2D

signal game_started
signal state_applied
signal property_prompted(action: Dictionary)
signal turn_finished(player_id: int)

@export_range(1, 6, 1) var dice_min_value: int = 1
@export_range(1, 12, 1) var dice_max_value: int = 6
@export_range(1024, 65535, 1) var listen_port: int = 7000

@onready var board: BoardPath = $Board
@onready var player_1: BoardPlayer = $Player1
@onready var player_2: BoardPlayer = $Player2
@onready var turn_camera: Camera2D = $TurnCamera
@onready var game_ui: GameHUD = $GameUI

var is_host: bool = false
var local_player_id: int = 0
var game_is_started: bool = false
var current_player_id: int = 1
var last_roll: int = 0
var phase: String = "lobby"
var players_state: Dictionary = {}
var properties: Array = []
var pending_action: Dictionary = {}
var last_turn_tolls: Array = []
var last_event: Dictionary = {}
var last_wheel_result: int = 0
var player_peer_ids: Dictionary = {1: 1}
var test_mode: bool = false
var test_wheel_result_override: int = 0
var _local_prompt_active: bool = false
var _random := RandomNumberGenerator.new()

func _ready() -> void:
	_random.randomize()
	players_state = {1: GameRules.build_player_state(), 2: GameRules.build_player_state()}
	properties = GameRules.build_cells(board.get_cell_count())
	board.set_property_states(properties)
	player_1.place_at_cell(0, board)
	player_2.place_at_cell(0, board)
	game_ui.host_requested.connect(func() -> void: host_game())
	game_ui.join_requested.connect(func(address: String) -> void: join_game(address))
	game_ui.roll_requested.connect(_on_roll_requested)
	game_ui.property_action_requested.connect(submit_property_action)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

func _process(_delta: float) -> void:
	if not game_is_started:
		return
	var active := _player_node(current_player_id)
	turn_camera.position = active.position

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
	phase = "lobby"
	game_ui.set_lobby_buttons_enabled(false)
	game_ui.set_lobby_status("Host 已创建，等待 Player 2 连接（端口 %d）" % target_port)
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
	current_player_id = 1
	phase = "waiting"
	_show_world()
	_apply_snapshot(_make_snapshot())
	game_started.emit()

func generate_roll() -> int:
	return _random.randi_range(dice_min_value, dice_max_value)

func can_upgrade_property(player_level: int, property_level: int) -> bool:
	return GameRules.can_upgrade_property(player_level, property_level)

func has_local_property_prompt() -> bool:
	return _local_prompt_active

func request_test_roll(forced_roll: int) -> void:
	if not test_mode:
		return
	if is_host:
		_host_try_roll(local_player_id, forced_roll)
	else:
		_request_test_roll_rpc.rpc_id(1, forced_roll)

func submit_property_action(accepted: bool) -> void:
	if not _local_prompt_active:
		return
	_local_prompt_active = false
	game_ui.hide_property_prompt()
	if is_host:
		_host_resolve_property(local_player_id, accepted)
	else:
		_request_property_action_rpc.rpc_id(1, accepted)

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
	current_player_id = 1
	phase = "waiting"
	_assign_local_player.rpc_id(peer_id, 2)
	_show_world()
	_sync_state.rpc(_make_snapshot())
	game_started.emit()

func _on_peer_disconnected(peer_id: int) -> void:
	if is_host and player_peer_ids.get(2, 0) == peer_id:
		game_is_started = false
		phase = "lobby"
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
func _animate_turn(player_id: int, roll_value: int, start_cell: int) -> void:
	last_roll = roll_value
	phase = "moving"
	_refresh_ui()
	var player := _player_node(player_id)
	player.place_at_cell(start_cell, board)
	_animate_player(player, roll_value)

func _animate_player(player: BoardPlayer, roll_value: int) -> void:
	await player.move_steps(roll_value, board)
	_refresh_ui()

@rpc("authority", "call_remote", "reliable")
func _show_property_prompt_remote(action: Dictionary) -> void:
	pending_action = action.duplicate(true)
	_show_property_prompt_when_ready(action)

@rpc("authority", "call_local", "reliable")
func _show_event_prompt_remote(action: Dictionary) -> void:
	pending_action = action.duplicate(true)
	var can_confirm := local_player_id == current_player_id
	_local_prompt_active = can_confirm
	game_ui.show_event_prompt(action, can_confirm)
	if can_confirm:
		property_prompted.emit(action)

@rpc("any_peer", "call_remote", "reliable")
func _request_roll_rpc() -> void:
	if is_host:
		_host_try_roll(_player_id_for_peer(multiplayer.get_remote_sender_id()))

@rpc("any_peer", "call_remote", "reliable")
func _request_test_roll_rpc(forced_roll: int) -> void:
	if is_host and test_mode:
		_host_try_roll(_player_id_for_peer(multiplayer.get_remote_sender_id()), forced_roll)

@rpc("any_peer", "call_remote", "reliable")
func _request_property_action_rpc(accepted: bool) -> void:
	if is_host:
		_host_resolve_property(_player_id_for_peer(multiplayer.get_remote_sender_id()), accepted)

func _host_try_roll(requesting_player_id: int, forced_roll: int = -1) -> void:
	if not is_host or not game_is_started or phase != "waiting" or requesting_player_id != current_player_id:
		return
	var roll := generate_roll() if forced_roll < 0 else forced_roll
	if not test_mode:
		roll = clampi(roll, dice_min_value, dice_max_value)
	_host_execute_turn(current_player_id, maxi(1, roll))

func _host_execute_turn(player_id: int, roll_value: int) -> void:
	phase = "moving"
	last_roll = roll_value
	last_turn_tolls = []
	last_event = {}
	last_wheel_result = 0
	var start_cell := int(players_state[player_id]["cell"])
	if multiplayer.has_multiplayer_peer():
		_animate_turn.rpc(player_id, roll_value, start_cell)
	else:
		_animate_turn(player_id, roll_value, start_cell)
	var player := _player_node(player_id)
	for _step in range(roll_value):
		var reached_cell: int = await player.step_reached
		var state: Dictionary = players_state[player_id]
		state["cell"] = reached_cell
		players_state[player_id] = state
		if _settle_toll(player_id, reached_cell):
			_broadcast_state()
	_handle_final_cell(player_id)

func _handle_final_cell(player_id: int) -> void:
	var cell := int(players_state[player_id]["cell"])
	var cell_type := String(properties[cell]["cell_type"])
	match cell_type:
		GameRules.CELL_PROPERTY:
			pending_action = _build_property_action(player_id)
			if pending_action.is_empty():
				_end_turn()
				return
			_begin_property_decision(player_id)
		GameRules.CELL_REWARD:
			_start_reward_event(player_id)
		GameRules.CELL_WHEEL:
			_start_wheel_event(player_id)
		_:
			_end_turn()

func _begin_property_decision(player_id: int) -> void:
	phase = "decision"
	_broadcast_state()
	var target_peer := int(player_peer_ids.get(player_id, 1))
	if target_peer == 1:
		_show_property_prompt_when_ready(pending_action)
	else:
		_show_property_prompt_remote.rpc_id(target_peer, pending_action)

func _start_reward_event(player_id: int) -> void:
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + GameRules.REWARD_COINS
	players_state[player_id] = state
	pending_action = {"type": "reward", "amount": GameRules.REWARD_COINS, "cell_index": int(state["cell"]), "player_id": player_id}
	last_event = pending_action.duplicate(true)
	phase = "event"
	_broadcast_state()
	_broadcast_event_prompt()

func _start_wheel_event(player_id: int) -> void:
	last_wheel_result = _choose_wheel_result()
	var state: Dictionary = players_state[player_id]
	state["coins"] = int(state["coins"]) + last_wheel_result
	players_state[player_id] = state
	pending_action = {"type": "wheel", "amount": last_wheel_result, "cell_index": int(state["cell"]), "player_id": player_id}
	last_event = pending_action.duplicate(true)
	phase = "event"
	_broadcast_state()
	_broadcast_event_prompt()

func _choose_wheel_result() -> int:
	if test_mode and GameRules.is_wheel_result_valid(test_wheel_result_override):
		return test_wheel_result_override
	return int(GameRules.WHEEL_RESULTS[_random.randi_range(0, GameRules.WHEEL_RESULTS.size() - 1)])

func _broadcast_event_prompt() -> void:
	if multiplayer.has_multiplayer_peer():
		_show_event_prompt_remote.rpc(pending_action)
	else:
		_show_event_prompt_remote(pending_action)

func _settle_toll(player_id: int, cell_index: int) -> bool:
	var cell: Dictionary = properties[cell_index]
	if String(cell["cell_type"]) != GameRules.CELL_PROPERTY:
		return false
	var owner_id := int(cell["owner_id"])
	if owner_id == -1 or owner_id == player_id:
		return false
	var amount := GameRules.toll_fee(int(cell["property_level"]))
	if amount <= 0:
		return false
	var payer: Dictionary = players_state[player_id]
	var owner: Dictionary = players_state[owner_id]
	payer["coins"] = int(payer["coins"]) - amount
	owner["coins"] = int(owner["coins"]) + amount
	players_state[player_id] = payer
	players_state[owner_id] = owner
	last_turn_tolls.append({"cell_index": cell_index, "payer_id": player_id, "owner_id": owner_id, "amount": amount})
	return true

func _build_property_action(player_id: int) -> Dictionary:
	var cell := int(players_state[player_id]["cell"])
	if String(properties[cell]["cell_type"]) != GameRules.CELL_PROPERTY:
		return {}
	var property: Dictionary = properties[cell]
	var owner_id := int(property["owner_id"])
	var level := int(property["property_level"])
	var player: Dictionary = players_state[player_id]
	var action: Dictionary = {"cell_index": cell, "owner_id": owner_id, "property_level": level}
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

func _show_property_prompt_when_ready(action: Dictionary) -> void:
	var local_player := _player_node(local_player_id)
	while local_player.is_moving:
		await get_tree().process_frame
	_local_prompt_active = true
	game_ui.show_property_prompt(action)
	property_prompted.emit(action)

func _host_resolve_property(requesting_player_id: int, accepted: bool) -> void:
	if not is_host or phase not in ["decision", "event"] or pending_action.is_empty() or requesting_player_id != current_player_id:
		return
	if phase == "decision" and accepted and bool(pending_action.get("can_afford", false)):
		_apply_property_action(requesting_player_id, pending_action)
	_end_turn()

func _apply_property_action(player_id: int, action: Dictionary) -> void:
	var cell := int(action["cell_index"])
	var price := int(action["price"])
	var player: Dictionary = players_state[player_id]
	var property: Dictionary = properties[cell]
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
	properties[cell] = property

func _end_turn() -> void:
	var finished_player := current_player_id
	pending_action = {}
	current_player_id = 2 if current_player_id == 1 else 1
	phase = "waiting"
	_broadcast_state()
	turn_finished.emit(finished_player)

func _broadcast_state() -> void:
	var snapshot := _make_snapshot()
	if multiplayer.has_multiplayer_peer():
		_sync_state.rpc(snapshot)
	else:
		_apply_snapshot(snapshot)

func _make_snapshot() -> Dictionary:
	return {
		"players": players_state.duplicate(true),
		"properties": properties.duplicate(true),
		"current_player_id": current_player_id,
		"last_roll": last_roll,
		"phase": phase,
		"last_turn_tolls": last_turn_tolls.duplicate(true),
		"last_event": last_event.duplicate(true),
		"last_wheel_result": last_wheel_result,
	}

func _apply_snapshot(snapshot: Dictionary) -> void:
	players_state = snapshot["players"].duplicate(true)
	properties = snapshot["properties"].duplicate(true)
	current_player_id = int(snapshot["current_player_id"])
	last_roll = int(snapshot["last_roll"])
	phase = String(snapshot["phase"])
	last_turn_tolls = snapshot.get("last_turn_tolls", []).duplicate(true)
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
	if phase == "waiting" or phase == "moving":
		_local_prompt_active = false
		game_ui.hide_property_prompt()
	turn_camera.position = _player_node(current_player_id).position
	turn_camera.reset_smoothing()
	state_applied.emit()

func _show_world() -> void:
	board.visible = true
	player_1.visible = true
	player_2.visible = true
	game_ui.show_game()

func _refresh_ui() -> void:
	if local_player_id == 0:
		return
	var display_cell := _player_node(local_player_id).current_cell_index
	game_ui.update_game_state(local_player_id, current_player_id, players_state, display_cell, last_roll, phase)

func _player_node(player_id: int) -> BoardPlayer:
	return player_1 if player_id == 1 else player_2

func _player_id_for_peer(peer_id: int) -> int:
	for player_id in player_peer_ids:
		if int(player_peer_ids[player_id]) == peer_id:
			return int(player_id)
	return -1
