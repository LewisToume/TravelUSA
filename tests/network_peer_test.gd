extends SceneTree

var _game
var _role := ""
var _port := 17000
var _result_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_arguments()
	var packed := load("res://scenes/main.tscn") as PackedScene
	_game = packed.instantiate()
	root.add_child(_game)
	await process_frame
	await process_frame
	_game.test_mode = true
	for player in [_game.player_1, _game.player_2]:
		player.move_speed_pixels_per_second = 100000.0
		player.minimum_step_duration = 0.001
	if _role == "host":
		await _run_host()
	else:
		await _run_client()

func _run_host() -> void:
	if not _game.host_game(_port):
		_finish(false, "host_create_failed")
		return
	if not await _wait_until(func() -> bool: return _game.game_is_started):
		_finish(false, "client_not_connected")
		return
	_game.request_test_roll(2)
	if not await _wait_prompt():
		_finish(false, "p1_buy_prompt_missing")
		return
	_game.submit_property_action(true)
	if not await _wait_until(func() -> bool: return _game.current_player_id == 1 and int(_game.properties[1]["owner_id"]) == 2):
		_finish(false, "p2_buy_not_synced")
		return
	_game.request_test_roll(30)
	if not await _wait_prompt(6.0):
		_finish(false, "p1_upgrade_prompt_missing")
		return
	_game.submit_property_action(true)
	if not await _wait_until(_final_state_ready, 8.0):
		_finish(false, "p2_capture_not_synced")
		return
	_finish(_validate_final_state(), "host_final_state")

func _run_client() -> void:
	if not _game.join_game("127.0.0.1", _port):
		_finish(false, "client_create_failed")
		return
	if not await _wait_until(func() -> bool: return _game.game_is_started and _game.local_player_id == 2):
		_finish(false, "assignment_missing")
		return
	if not await _wait_until(func() -> bool: return _game.current_player_id == 2 and int(_game.properties[2]["owner_id"]) == 1):
		_finish(false, "p1_buy_not_synced")
		return
	_game.request_test_roll(1)
	if not await _wait_prompt():
		_finish(false, "p2_buy_prompt_missing")
		return
	_game.submit_property_action(true)
	if not await _wait_until(func() -> bool: return _game.current_player_id == 2 and int(_game.properties[2]["property_level"]) == 2, 8.0):
		_finish(false, "p1_upgrade_not_synced")
		return
	_game.request_test_roll(1)
	if not await _wait_prompt():
		_finish(false, "p2_capture_prompt_missing")
		return
	_game.submit_property_action(true)
	if not await _wait_until(_final_state_ready):
		_finish(false, "final_snapshot_missing")
		return
	_finish(_validate_final_state(), "client_final_state")

func _final_state_ready() -> bool:
	return _game.current_player_id == 1 and int(_game.properties[2]["owner_id"]) == 2 and int(_game.properties[2]["capture_count"]) == 1

func _validate_final_state() -> bool:
	var property: Dictionary = _game.properties[2]
	return int(_game.players_state[1]["cell"]) == 2 \
		and int(_game.players_state[2]["cell"]) == 2 \
		and int(_game.players_state[1]["coins"]) == 8600 \
		and int(_game.players_state[2]["coins"]) == 7000 \
		and int(property["owner_id"]) == 2 \
		and int(property["property_level"]) == 3 \
		and int(property["capture_count"]) == 1

func _wait_prompt(timeout_seconds: float = 4.0) -> bool:
	return await _wait_until(func() -> bool: return _game.has_local_property_prompt(), timeout_seconds)

func _wait_until(predicate: Callable, timeout_seconds: float = 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return predicate.call()

func _finish(success: bool, detail: String) -> void:
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file:
		file.store_line(JSON.stringify({"role": _role, "success": success, "detail": detail, "state": _game._make_snapshot()}))
	print("NETWORK RESULT | ", _role, " | ", "PASS" if success else "FAIL", " | ", detail)
	await create_timer(0.2).timeout
	quit(0 if success else 1)

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			_role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			_port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--result="):
			_result_path = argument.trim_prefix("--result=")
