extends SceneTree

var failures: Array[String] = []
var game
const SAVE := "user://economy-test-save.json"
const TEMP := "user://economy-test-save.tmp"

func _initialize() -> void: call_deferred("_run")
func check(value: bool, message: String) -> void:
	if value: print("PASS | ", message)
	else: failures.append(message); push_error("FAIL | " + message)

func _run() -> void:
	_cleanup()
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(game)
	await process_frame; await process_frame
	game.test_mode = true; game.test_wheel_result_override = 200; game.test_wheel_spin_duration = 0.01; game.is_host = true; game.local_player_id = 1; game.game_is_started = false; game.active_player_ids.assign([1, 2, 3, 4])
	game.save_path = SAVE; game.save_temp_path = TEMP
	check(GameRules.MAP_CELL_TYPES.count(GameRules.CELL_QUIZ) == 9, "地图包含 9 个均匀分布的 QUIZ 格")
	check(QuestionBank.QUESTIONS.size() >= 5 and int(QuestionBank.QUESTIONS[0]["correct"]) == 0, "QuestionBank 独立且 A 为正确答案")

	_set_property(1, 2, 3)
	var p1: Dictionary = game.players_state[1]; p1["coins"] = 40; game.players_state[1] = p1
	check(game._settle_step_toll(1, 1), "余额不足时仍由 Host 结算过路费")
	check(int(game.players_state[1]["coins"]) == 0 and String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "100 过路费只实付 40 且进入破产")
	check(int(game.players_state[2]["coins"]) == 1040 and int(game.players_state[2]["daily_taxable_income"]) == 40, "房主只收到实际付款且计入应税收入")
	check(not game.can_player_roll(1) and not game._host_use_card(1, GameRules.CARD_SPEED, 0), "当天破产不能掷骰或使用卡牌")

	var bankrupt_day := Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 10, "hour": 15, "minute": 0, "second": 0})
	p1 = game.players_state[1]; p1["bankrupt_date"] = "2026-09-10"; game.players_state[1] = p1
	game.server_time_override = bankrupt_day + 86400
	game._check_player_login(1)
	check(int(game.players_state[1]["coins"]) == 1000 and String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_PROTECTED, "次日登录获得 1000 救济并进入保护")
	check(int(game.players_state[1]["protection_end_time"]) == game.server_time_override + 18000 and int(game.players_state[1]["daily_taxable_income"]) == 0, "保护持续 5 小时且救济不计税")
	p1 = game.players_state[1]; p1["toll_free_next_action"] = true; p1["toll_free_this_action"] = true; game.players_state[1] = p1
	var protected_coins := int(game.players_state[1]["coins"])
	game._settle_step_toll(1, 1)
	check(int(game.players_state[1]["coins"]) == protected_coins and bool(game.players_state[1]["toll_free_next_action"]), "保护期免除全部过路费且不消耗免租卡")
	game.game_is_started = true; game.dice_animation_duration = 0.01; game.player_nodes[1].move_speed_pixels_per_second = 100000.0; game.player_nodes[1].minimum_step_duration = 0.01
	p1 = game.players_state[1]; p1["cell"] = 0; p1["action_state"] = GameRules.ACTION_IDLE; game.players_state[1] = p1; game.player_nodes[1].place_at_cell(0, game.board)
	game._host_try_roll(1, 1)
	await _wait(func(): return game.pending_actions.has(1) and String(game.pending_actions[1].get("type", "")) == "capture")
	game._host_record_response(1, int(game.pending_actions[1]["event_id"]), "decision", false)
	await _wait(func(): return String(game.players_state[1]["action_state"]) == GameRules.ACTION_IDLE)
	game.game_is_started = false
	check(bool(game.players_state[1]["toll_free_next_action"]), "保护期完成整次掷骰行动仍保留下一次免租卡")
	game.server_time_override = int(game.players_state[1]["protection_end_time"])
	game._check_protection_expiry()
	check(String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_NORMAL, "5 小时后自动恢复 NORMAL")

	await _run_quiz(3, 0)
	check(int(game.players_state[3]["coins"]) == 1200 and int(game.players_state[3]["daily_taxable_income"]) == 200, "五题全选 A 共奖励 200 且全部计税")
	await _run_quiz(4, 1)
	check(int(game.players_state[4]["coins"]) == 1000 and int(game.players_state[4]["daily_taxable_income"]) == 0, "B/C/D 错误不奖励金币")
	var reward_income := int(game.players_state[3]["daily_taxable_income"])
	game._resolve_reward(3, 5)
	await _wait(func(): return game.pending_actions.has(3) and String(game.pending_actions[3].get("type", "")) == "reward")
	game._host_record_response(3, int(game.pending_actions[3]["event_id"]), "decision", true)
	await _wait(func(): return not game.pending_actions.has(3))
	check(int(game.players_state[3]["daily_taxable_income"]) == reward_income + 100, "奖励格收入进入 taxable income")
	var wheel_income := int(game.players_state[4]["daily_taxable_income"])
	game._resolve_wheel(4, 9)
	await _wait(func(): return game.pending_actions.has(4) and String(game.pending_actions[4].get("type", "")) == "wheel")
	var wheel_event := int(game.pending_actions[4]["event_id"])
	game._host_record_response(4, wheel_event, "wheel_spin", true)
	await _wait(func(): return int(game.players_state[4]["daily_taxable_income"]) == wheel_income + 200)
	game._host_record_response(4, wheel_event, "wheel_confirm", true)
	await _wait(func(): return not game.pending_actions.has(4))
	check(int(game.players_state[4]["daily_taxable_income"]) == wheel_income + 200, "转盘正收益进入 taxable income")

	var p2: Dictionary = game.players_state[2]; p2["coins"] = 300; game.players_state[2] = p2
	var p3: Dictionary = game.players_state[3]; p3["coins"] = 1300; game.players_state[3] = p3
	var taxable_before := int(p2["daily_taxable_income"]) + int(p3["daily_taxable_income"])
	game._card_equalize(2, 3)
	check(int(game.players_state[2]["daily_taxable_income"]) + int(game.players_state[3]["daily_taxable_income"]) == taxable_before, "均富卡资产转移不计税")
	_set_property(3, 2, 2)
	var owner_tax_before := int(game.players_state[2]["daily_taxable_income"])
	game._apply_property_action(3, {"type": "capture", "cell_index": 3, "price": 100})
	check(int(game.players_state[2]["daily_taxable_income"]) == owner_tax_before, "产权补偿不计税")

	_set_property(7, 2, 5); _set_property(8, 3, 1)
	var ranking: Array = game._calculate_leaderboard()
	check(int(ranking[0]["total_wealth"]) >= int(ranking[1]["total_wealth"]), "财富榜按总财富降序")
	var p2_rank: Dictionary = _rank_entry(ranking, 2)
	check(int(p2_rank["property_value"]) >= 800, "财富榜按 L1～L5 建造价值统计房产")

	var tax_time := Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 12, "hour": 13, "minute": 21, "second": 0})
	game.server_time_override = tax_time
	p2 = game.players_state[2]; p2["coins"] = 10; p2["daily_taxable_income"] = 101; p2["last_tax_date"] = "2026-09-11"; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; game.players_state[2] = p2
	check(game._check_player_tax(2) and int(game.players_state[2]["coins"]) == 0 and String(game.players_state[2]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "13:20 后按 floor(收入×10%) 扣税并可触发破产")
	check(not game._check_player_tax(2), "同一天税收绝不重复结算")

	var saved_cell := 14
	p3 = game.players_state[3]; p3["cell"] = saved_cell; p3["stamina"] = 7; p3["inventory"][GameRules.CARD_BUILD] = 4; p3["coins"] = 1000; p3["daily_taxable_income"] = 100; p3["last_tax_date"] = "2026-09-11"; game.players_state[3] = p3
	var p4: Dictionary = game.players_state[4]; p4["bankruptcy_state"] = GameRules.BANKRUPTCY_PROTECTED; p4["protection_end_time"] = tax_time + 3600; game.players_state[4] = p4
	_set_property(14, 3, 4)
	check(game._save_game(), "Host 使用临时文件原子保存")
	var restored = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(restored); await process_frame
	restored.is_host = true; restored.save_path = SAVE; restored.save_temp_path = TEMP; restored.server_time_override = game.server_time_override
	check(restored._load_game(), "Host 可加载 save_version=1 存档")
	check(int(restored.players_state[3]["cell"]) == saved_cell and int(restored.players_state[3]["stamina"]) == 7 and int(restored.players_state[3]["inventory"][GameRules.CARD_BUILD]) == 4 and int(restored.properties[14]["property_level"]) == 4, "coins/stamina/cell/cards/房产及永久状态完整恢复")
	check(String(restored.players_state[2]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "Host 重启后破产状态保持")
	check(int(restored.players_state[4]["protection_end_time"]) - restored.server_time_override == 3600, "Host 重启后保护剩余时间正确")
	restored._check_player_login(3)
	check(int(restored.players_state[3]["coins"]) == 990 and String(restored.players_state[3]["last_tax_date"]) == "2026-09-12", "13:20 离线后登录会补结算当日税收")

	var corrupt = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(corrupt); await process_frame
	corrupt.is_host = true; corrupt.save_path = "user://corrupt-save.json"; corrupt.save_temp_path = "user://corrupt-save.tmp"
	var bad := FileAccess.open(corrupt.save_path, FileAccess.WRITE); bad.store_string("{broken"); bad.close()
	check(not corrupt._load_game() and corrupt.save_load_failed and not corrupt._save_game(), "损坏存档不崩溃且不会被自动覆盖")

	game.is_host = false; restored.is_host = false; corrupt.is_host = false
	_cleanup()
	if failures.is_empty(): print("ECONOMY RESULT | PASS | 破产、保护、答题、税收、排行和持久化通过"); quit(0)
	else: print("ECONOMY RESULT | FAIL | ", failures); quit(1)

func _run_quiz(player_id: int, answer: int) -> void:
	var state: Dictionary = game.players_state[player_id]; state["action_state"] = GameRules.ACTION_RESOLVING; game.players_state[player_id] = state
	game._resolve_quiz(player_id, 4)
	for question_number in range(1, 6):
		await _wait(func(): return game.pending_actions.has(player_id) and int(game.pending_actions[player_id].get("question_number", 0)) == question_number)
		var event_id := int(game.pending_actions[player_id]["event_id"])
		game._host_record_response(player_id, event_id, "quiz_answer", false, answer)
	await _wait(func(): return not game.pending_actions.has(player_id))

func _set_property(index: int, owner: int, level: int) -> void:
	var value: Dictionary = game.properties[index]; value["owner_id"] = owner; value["property_level"] = level; game.properties[index] = value

func _rank_entry(entries: Array, player_id: int) -> Dictionary:
	for entry in entries:
		if int(entry["player_id"]) == player_id: return entry
	return {}

func _wait(callable: Callable, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not callable.call() and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	return callable.call()

func _cleanup() -> void:
	for path in [SAVE, TEMP, SAVE + ".bak", "user://corrupt-save.json", "user://corrupt-save.tmp"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
