extends SceneTree

var game
var role := ""
var port := 17000
var result_path := ""

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	_parse_arguments()
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(game)
	await process_frame; await process_frame
	game.save_path = result_path + ".save"
	game.save_temp_path = result_path + ".tmp"
	game.test_mode = true; game.test_wheel_result_override = 200; game.test_wheel_spin_duration = 0.35
	for player_id in game.player_nodes:
		game.player_nodes[player_id].move_speed_pixels_per_second = 100000.0
		game.player_nodes[player_id].minimum_step_duration = 0.04
	if role == "host": await _host_flow()
	else: await _client_flow()

func _host_flow() -> void:
	if not game.host_game(port) or not await _wait(func(): return game.active_player_ids.size() == 4, 8.0): await _finish(false, "three_clients_not_connected"); return
	var import_csv := "word,meaning\n"
	for entry in QuestionBank.DEFAULT_ENTRIES: import_csv += "%s,%s\n" % [entry["word"], entry["meaning"]]
	game._prepare_wordbook_import("network-room.csv", import_csv, "csv"); game._confirm_wordbook_import()
	var p4: Dictionary = game.players_state[4]
	p4["encounter_type"] = GameRules.ENCOUNTER_PROPERTY_GUEST; p4["encounter_remaining_steps"] = GameRules.ENCOUNTER_DURATION_STEPS; p4["encounter_start_date"] = game._server_date(); game.players_state[4] = p4
	var debug_inventory: Dictionary = game.players_state[3]["inventory"].duplicate(true); debug_inventory[GameRules.CARD_BUILD] = 2
	if not game._host_apply_debug_modifier(3, 3333, 17, debug_inventory): await _finish(false, "host_debug_modifier_failed"); return
	game._broadcast_state()
	game.request_test_roll(9)
	if not await _wait_action(1, "wheel"): await _finish(false, "p1_wheel_missing"); return
	if not await _wait(func(): return String(game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING and int(game.players_state[2]["stamina"]) == 19 and int(game.players_state[3]["stamina"]) == 16 and int(game.players_state[4]["stamina"]) == 19, 5.0): await _finish(false, "clients_blocked_by_p1_wheel"); return
	game.request_wheel_spin()
	if not await _wait(func(): return int(game.players_state[2]["cell"]) == 9 and int(game.players_state[3]["cell"]) == 2 and int(game.players_state[4]["cell"]) == 3, 6.0): await _finish(false, "client_moves_not_synced"); return
	if not await _wait(func(): return game.last_wheel_result == 200 and int(game.players_state[1]["coins"]) == 1200, 5.0): await _finish(false, "wheel_result_not_authoritative"); return
	game.confirm_wheel_result()
	if not await _wait(func(): return _all_idle(), 6.0): await _finish(false, "actions_not_independent"); return
	await _finish(_valid_shared_state(), "host_with_three_clients_async")

func _client_flow() -> void:
	if not game.join_game("127.0.0.1", port): await _finish(false, "client_create_failed"); return
	if not await _wait(func(): return game.local_player_id in [2, 3, 4] and game.game_is_started, 8.0): await _finish(false, "assignment_missing"); return
	if not await _wait(func(): return String(game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING, 6.0): await _finish(false, "p1_wheel_state_missing"); return
	if game.game_ui.wheel_overlay.visible: await _finish(false, "foreign_wheel_ui_visible"); return
	var local_before := int(game.players_state[game.local_player_id]["coins"])
	if game._host_apply_debug_modifier(game.local_player_id, 999999, 20, {}): await _finish(false, "client_used_debug_modifier"); return
	if int(game.players_state[game.local_player_id]["coins"]) != local_before: await _finish(false, "client_changed_debug_state"); return
	game.request_test_roll(9 if game.local_player_id == 2 else game.local_player_id - 1)
	if not await _wait(func(): return String(game.players_state[game.local_player_id]["action_state"]) == GameRules.ACTION_RESOLVING): await _finish(false, "client_roll_blocked"); return
	await create_timer(0.65).timeout
	if game.local_player_id == 2:
		if not await _wait(func(): return String(game.pending_action.get("type", "")) == "wheel" and game.game_ui.wheel_overlay.visible, 5.0): await _finish(false, "second_wheel_not_independent"); return
		game.request_wheel_spin()
		if not await _wait(func(): return int(game.players_state[2]["coins"]) == 1200, 5.0): await _finish(false, "second_wheel_result_missing"); return
		game.confirm_wheel_result()
	else:
		if game.game_ui.wheel_overlay.visible: await _finish(false, "foreign_wheel_blocked_client"); return
		if not await _wait_local_action("buy"): await _finish(false, "client_buy_prompt_missing"); return
		game.submit_property_action(false)
	if not await _wait(func(): return _all_idle(), 8.0): await _finish(false, "final_snapshot_missing"); return
	await _finish(_valid_shared_state(), "three_clients_async")

func _all_resolving() -> bool:
	for player_id in [1, 2, 3, 4]:
		if String(game.players_state[player_id]["action_state"]) != GameRules.ACTION_RESOLVING: return false
	return true

func _all_idle() -> bool:
	for player_id in [1, 2, 3, 4]:
		if String(game.players_state[player_id]["action_state"]) != GameRules.ACTION_IDLE: return false
	return true

func _valid_shared_state() -> bool:
	var encounters_synced := String(game.properties[5].get("encounter_type", "")) == GameRules.ENCOUNTER_PROPERTY_GUEST and String(game.properties[13].get("encounter_type", "")) == GameRules.ENCOUNTER_LUCKY_STAR and String(game.properties[21].get("encounter_type", "")) == GameRules.ENCOUNTER_WEALTH_GOD and String(game.properties[31].get("encounter_type", "")) == GameRules.ENCOUNTER_BROOM_STAR and String(game.properties[41].get("encounter_type", "")) == GameRules.ENCOUNTER_DEBT_COLLECTOR
	return encounters_synced and game.active_player_ids.size() == 4 and game.known_player_ids.size() == 4 and int(game.players_state[1]["cell"]) == 9 and int(game.players_state[2]["cell"]) == 9 and int(game.players_state[3]["cell"]) == 2 and int(game.players_state[4]["cell"]) == 3 and int(game.players_state[1]["stamina"]) == 19 and int(game.players_state[2]["stamina"]) == 19 and int(game.players_state[3]["stamina"]) == 16 and int(game.players_state[4]["stamina"]) == 19 and int(game.players_state[1]["coins"]) == 1200 and int(game.players_state[2]["coins"]) == 1200 and int(game.players_state[3]["coins"]) == 3333 and int(game.players_state[3]["inventory"][GameRules.CARD_BUILD]) == 2 and game.players_state[1].has("tax_debt") and game.players_state[1].has("last_stamina_recovery_time") and String(game.properties[8].get("property_type", "")) == GameRules.PROPERTY_HOTEL and game.room_wordbook_name == "network-room.csv" and game.room_wordbook.size() == QuestionBank.DEFAULT_ENTRIES.size() and String(game.players_state[4].get("encounter_type", "")) == GameRules.ENCOUNTER_PROPERTY_GUEST and int(game.players_state[4].get("encounter_remaining_steps", -1)) == 12

func _wait_action(player_id: int, kind: String, seconds := 5.0) -> bool:
	return await _wait(func(): return game.pending_actions.has(player_id) and String(game.pending_actions[player_id].get("type", "")) == kind, seconds)

func _wait_local_action(kind: String, seconds := 5.0) -> bool:
	return await _wait(func(): return game.has_local_property_prompt() and String(game.pending_action.get("type", "")) == kind, seconds)

func _wait(callable: Callable, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not callable.call() and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	return callable.call()

func _finish(success: bool, detail: String) -> void:
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	if file: file.store_line(JSON.stringify({"role": role, "success": success, "detail": detail, "state": game._make_snapshot()}))
	print("NETWORK RESULT | ", role, " | ", "PASS" if success else "FAIL", " | ", detail)
	game.is_host = false
	for path in [result_path + ".save", result_path + ".tmp", result_path + ".save.bak"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await create_timer(0.2).timeout; quit(0 if success else 1)

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="): role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="): port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--result="): result_path = argument.trim_prefix("--result=")
