extends SceneTree

var _game
var _role := ""
var _port := 17000
var _result_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_parse_arguments()
	_game = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_game)
	await process_frame
	await process_frame
	_game.test_mode = true
	for player in [_game.player_1, _game.player_2]:
		player.move_speed_pixels_per_second = 100000.0
		player.minimum_step_duration = 0.05
	if _role == "host":
		await _run_host()
	else:
		await _run_client()

func _run_host() -> void:
	if not _game.host_game(_port) or not await _wait_until(func() -> bool: return _game.game_is_started):
		_finish(false, "host_or_connection_failed")
		return
	_game.request_test_roll(2)
	var stamina_after_first := int(_game.players_state[1]["stamina"])
	_game.request_test_roll(2)
	if int(_game.players_state[1]["stamina"]) != stamina_after_first:
		_finish(false, "duplicate_roll_not_rejected")
		return
	if not await _wait_until(func() -> bool: return _both_players_resolving(), 5.0):
		_finish(false, "players_did_not_act_concurrently")
		return
	if not await _wait_local_prompt("buy"):
		_finish(false, "p1_first_buy_prompt_missing")
		return
	_game.submit_property_action(true)
	if not await _wait_until(func() -> bool: return int(_game.properties[2]["owner_id"]) == 1):
		_finish(false, "p1_purchase_not_committed")
		return
	if not await _wait_until(func() -> bool: return _game.game_ui.property_overlay.visible and "向你支付了 25 金币" in _game.game_ui.property_details.text, 6.0):
		_finish(false, "owner_toll_popup_missing")
		return
	if not await _wait_until(_final_state_ready, 8.0):
		_finish(false, "host_final_state_timeout")
		return
	_finish(_validate_final_state(), "host_async_state")

func _run_client() -> void:
	if not _game.join_game("127.0.0.1", _port):
		_finish(false, "client_create_failed")
		return
	if not await _wait_until(func() -> bool: return _game.game_is_started and _game.local_player_id == 2):
		_finish(false, "assignment_missing")
		return
	if not await _wait_until(func() -> bool: return String(_game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING):
		_finish(false, "p1_action_not_synced")
		return
	_game.request_test_roll(2)
	if not await _wait_until(func() -> bool: return _both_players_resolving() and int(_game.players_state[2]["stamina"]) == 19):
		_finish(false, "p2_could_not_roll_during_p1_action")
		return
	if not await _wait_local_prompt("toll", 7.0):
		_finish(false, "p2_saw_stale_empty_property")
		return
	if "你支付了 25 金币" not in _game.game_ui.property_details.text:
		_finish(false, "payer_toll_message_incorrect")
		return
	_game.submit_property_action(true)
	if not await _wait_local_prompt("capture"):
		_finish(false, "capture_prompt_missing_after_toll")
		return
	_game.submit_property_action(false)
	if not await _wait_until(_final_state_ready, 8.0):
		_finish(false, "client_final_state_timeout")
		return
	_finish(_validate_final_state(), "client_async_state")

func _both_players_resolving() -> bool:
	return String(_game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING and String(_game.players_state[2]["action_state"]) == GameRules.ACTION_RESOLVING

func _final_state_ready() -> bool:
	return int(_game.properties[2]["owner_id"]) == 1 and String(_game.players_state[1]["action_state"]) == GameRules.ACTION_IDLE and String(_game.players_state[2]["action_state"]) == GameRules.ACTION_IDLE

func _validate_final_state() -> bool:
	return int(_game.players_state[1]["cell"]) == 2 \
		and int(_game.players_state[2]["cell"]) == 2 \
		and int(_game.players_state[1]["stamina"]) == 19 \
		and int(_game.players_state[2]["stamina"]) == 19 \
		and int(_game.players_state[1]["coins"]) == 975 \
		and int(_game.players_state[2]["coins"]) == 975 \
		and int(_game.properties[2]["owner_id"]) == 1 \
		and int(_game.properties[2]["property_level"]) == 1

func _wait_local_prompt(action_type: String, timeout_seconds := 5.0) -> bool:
	return await _wait_until(func() -> bool: return _game.has_local_property_prompt() and String(_game.pending_action.get("type", "")) == action_type, timeout_seconds)

func _wait_until(predicate: Callable, timeout_seconds := 5.0) -> bool:
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
