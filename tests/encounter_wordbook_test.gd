extends SceneTree

var failures: Array[String] = []
var game
const SAVE := "user://encounter-wordbook-test.json"
const TEMP := "user://encounter-wordbook-test.tmp"

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if value: print("PASS | ", message)
	else: failures.append(message); push_error("FAIL | " + message)

func _run() -> void:
	_cleanup()
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(game)
	await process_frame; await process_frame
	game.test_mode = true; game.is_host = true; game.local_player_id = 1; game.game_is_started = false
	game.active_player_ids.assign([1, 2, 3, 4]); game.save_path = SAVE; game.save_temp_path = TEMP
	_test_parsers_and_room_book()
	_test_question_generation()
	await _test_quiz_run()
	_test_encounters()
	await _test_persistence_and_snapshot()
	game.is_host = false
	_cleanup()
	if failures.is_empty(): print("ENCOUNTER/WORDBOOK RESULT | PASS"); quit(0)
	else: print("ENCOUNTER/WORDBOOK RESULT | FAIL | ", failures); quit(1)

func _test_parsers_and_room_book() -> void:
	var csv := "单词,释义\napple,苹果\nbook,书\ninvalid,\n"
	var csv_result := QuestionBank.parse_csv(csv)
	check(int(csv_result["success_count"]) == 2 and int(csv_result["failed_count"]) == 1, "CSV 自动识别中英文表头并统计失败行")
	var txt := "apple 苹果\nbook - 书\ncamera：相机\ndream,梦想\nearth=地球\nfamily\t家庭\ninvalid line\n"
	var txt_result := QuestionBank.parse_txt(txt)
	check(int(txt_result["success_count"]) == 6 and int(txt_result["failed_count"]) == 1, "TXT 支持空格、横线、冒号、逗号、等号和 Tab")
	game._prepare_wordbook_import("small.txt", "apple 苹果\nbook 书", "txt")
	check(game._confirm_wordbook_import() and game.room_wordbook.size() == 2, "词条不足十个时仍可确认，答题时按规则允许重复")
	var import_csv := "word,meaning\n"
	for entry in QuestionBank.DEFAULT_ENTRIES: import_csv += "%s,%s\n" % [entry["word"], entry["meaning"]]
	var old_id: String = game.room_wordbook_id
	var preview: Dictionary = game._prepare_wordbook_import("test-room.csv", import_csv, "csv")
	check(preview["success_count"] == QuestionBank.DEFAULT_ENTRIES.size() and game.room_wordbook_id == old_id, "导入先预览，确认前不替换房间词书")
	check(game._confirm_wordbook_import() and game.room_wordbook_name == "test-room.csv", "Host 确认后统一切换房间词书")
	game.is_host = false
	check(game._prepare_wordbook_import("client.txt", "apple 苹果", "txt").is_empty() and game.room_wordbook_name == "test-room.csv", "Client 不能切换房间词书")
	game.is_host = true

func _test_question_generation() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 20260912
	var positions: Dictionary = {}
	for index in range(18):
		var kind: String = [QuestionBank.TYPE_EN_TO_ZH, QuestionBank.TYPE_ZH_TO_EN, QuestionBank.TYPE_SPELLING][index % 3]
		var question := QuestionBank.build_question(game.room_wordbook[index % game.room_wordbook.size()], game.room_wordbook, kind, rng)
		positions[int(question["correct"])] = true
		check(question["options"].size() == 4 and int(question["correct"]) in range(4), "题目生成四个选项且答案有效")
	check(positions.size() > 1, "正确答案位置会随机分布到 A/B/C/D")
	var spelling := QuestionBank.build_question(game.room_wordbook[0], game.room_wordbook, QuestionBank.TYPE_SPELLING, rng)
	var underscore_count := String(spelling["question"]).count("_")
	check(underscore_count >= 1 and underscore_count <= 3, "拼写题随机隐藏 1～3 个字母")

func _test_quiz_run() -> void:
	var player_id := 3
	var state: Dictionary = game.players_state[player_id]; state["action_state"] = GameRules.ACTION_RESOLVING; state["recent_question_words"] = []; game.players_state[player_id] = state
	var start_coins := int(state["coins"]); var start_taxable := int(state["daily_taxable_income"])
	var words: Dictionary = {}; var type_counts := {QuestionBank.TYPE_EN_TO_ZH: 0, QuestionBank.TYPE_ZH_TO_EN: 0, QuestionBank.TYPE_SPELLING: 0}
	game._resolve_quiz(player_id, 4)
	for number in range(1, GameRules.QUIZ_QUESTION_COUNT + 1):
		await _wait(func(): return game.pending_actions.has(player_id) and int(game.pending_actions[player_id].get("question_number", 0)) == number)
		var pending: Dictionary = game.pending_actions[player_id]
		words[String(pending["word"])] = true
		type_counts[String(pending["question_type"])] += 1
		game._host_record_response(player_id, int(pending["event_id"]), "quiz_answer", false, int(pending["correct"]))
	await _wait(func(): return not game.pending_actions.has(player_id))
	check(words.size() == 10 and type_counts[QuestionBank.TYPE_EN_TO_ZH] == 4 and type_counts[QuestionBank.TYPE_ZH_TO_EN] == 4 and type_counts[QuestionBank.TYPE_SPELLING] == 2, "十连题单次不重复且题型比例为 4/4/2")
	check(int(game.players_state[player_id]["coins"]) == start_coins + 200 and int(game.players_state[player_id]["daily_taxable_income"]) == start_taxable + 200, "每题 20 金币，十题全对共 200 并计税")
	var next_entries: Array = game._select_quiz_entries(player_id, 10)
	var next_words: Dictionary = {}
	for entry in next_entries: next_words[String(entry["word"])] = true
	var overlap := 0
	for word in words: if next_words.has(word): overlap += 1
	check(overlap == 0, "近期约 100 个单词优先不重复")
	check((game.players_state[4]["recent_question_words"] as Array).is_empty(), "不同玩家保存独立题目历史")

func _test_encounters() -> void:
	var state: Dictionary
	# 地产客：住宅抢占半价，最多两次，酒店无效。
	_set_encounter(1, GameRules.ENCOUNTER_PROPERTY_GUEST)
	_set_property(1, 2, 1, GameRules.PROPERTY_HOUSE); _set_property(2, 2, 2, GameRules.PROPERTY_HOUSE); _set_property(3, 2, 1, GameRules.PROPERTY_HOUSE)
	state = game.players_state[1]; state["coins"] = 5000; game.players_state[1] = state
	check(game._capture_price_for_player(1, game.properties[1]) == roundi(GameRules.capture_price(1, 0) * 0.5), "地产客使普通住宅抢占价格减半")
	game._apply_property_action(1, {"type": "capture", "cell_index": 1, "price": game._capture_price_for_player(1, game.properties[1])})
	game._apply_property_action(1, {"type": "capture", "cell_index": 2, "price": game._capture_price_for_player(1, game.properties[2])})
	check(int(game.players_state[1]["encounter_trigger_count"]) == 2 and game._capture_price_for_player(1, game.properties[3]) == GameRules.capture_price(1, 0), "地产客最多触发两次")
	_set_property(8, 2, 1, GameRules.PROPERTY_HOTEL)
	check(game._capture_price_for_player(1, game.properties[8]) == GameRules.capture_price(1, 0, GameRules.PROPERTY_HOTEL), "地产客对 HOTEL 无效")

	# 幸运星：立即两张卡，路过自己的住宅免费升级两次，并与建房卡互斥。
	_clear_encounter(1); state = game.players_state[1]; state["inventory"] = _empty_inventory(); game.players_state[1] = state
	game.test_encounter_override = GameRules.ENCOUNTER_LUCKY_STAR; game._resolve_encounter(1, 5)
	check(_inventory_total(game.players_state[1]["inventory"]) == 2, "幸运星立即随机获得两张卡")
	_set_property(4, 1, 1, GameRules.PROPERTY_HOUSE); _set_property(6, 1, 1, GameRules.PROPERTY_HOUSE); _set_property(7, 1, 1, GameRules.PROPERTY_HOUSE)
	game._process_encounter_step(1, 4, false); game._process_encounter_step(1, 6, false); game._process_encounter_step(1, 7, false)
	check(int(game.properties[4]["property_level"]) == 2 and int(game.properties[6]["property_level"]) == 2 and int(game.properties[7]["property_level"]) == 1, "幸运星免费升级自己的 HOUSE 且最多两次")
	state = game.players_state[1]; state["inventory"][GameRules.CARD_BUILD] = 1; game.players_state[1] = state
	check(not game._host_use_card(1, GameRules.CARD_BUILD, 4) and int(game.players_state[1]["inventory"][GameRules.CARD_BUILD]) == 1, "幸运星期间建房卡不可使用且不扣库存")

	# 财神：立即应税收入并免租，免租卡保持独立。
	_clear_encounter(1); state = game.players_state[1]; state["coins"] = 1000; state["daily_taxable_income"] = 0; state["inventory"][GameRules.CARD_TOLL_FREE] = 1; game.players_state[1] = state
	game.test_encounter_override = GameRules.ENCOUNTER_WEALTH_GOD; game._resolve_encounter(1, 12)
	var wealth_gain := int(game.players_state[1]["coins"]) - 1000
	check(wealth_gain >= 100 and wealth_gain <= 999 and int(game.players_state[1]["daily_taxable_income"]) == wealth_gain, "财神立即获得 100～999 金币且计税")
	_set_property(10, 2, 3, GameRules.PROPERTY_HOUSE); var before_toll := int(game.players_state[1]["coins"])
	check(game._settle_step_toll(1, 10) and int(game.players_state[1]["coins"]) == before_toll, "财神持续期间免除所有过路费")
	check(not game._host_use_card(1, GameRules.CARD_TOLL_FREE, 0) and int(game.players_state[1]["inventory"][GameRules.CARD_TOLL_FREE]) == 1, "财神期间免租卡不可使用且不扣库存")

	# 扫把星：总卡数向上取半，并禁止所有房产投资。
	_clear_encounter(1); state = game.players_state[1]; state["inventory"] = _empty_inventory(); state["inventory"][GameRules.CARD_SPEED] = 9; game.players_state[1] = state
	game.test_encounter_override = GameRules.ENCOUNTER_BROOM_STAR; game._resolve_encounter(1, 19)
	check(_inventory_total(game.players_state[1]["inventory"]) == 5, "扫把星将九张卡减半并向上取整为五张")
	_set_property(11, -1, 0, GameRules.PROPERTY_HOUSE)
	check(game._build_property_action(1, 11).is_empty(), "扫把星期间不能买房、升级、抢占或强购")

	# 讨债人：即时损失，自己支付的租金和抢占费翻倍。
	_clear_encounter(1); state = game.players_state[1]; state["coins"] = 3000; state["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; state["toll_free_this_action"] = false; game.players_state[1] = state
	game.test_encounter_override = GameRules.ENCOUNTER_DEBT_COLLECTOR; game._resolve_encounter(1, 26)
	var debt_loss := 3000 - int(game.players_state[1]["coins"])
	check(debt_loss >= 100 and debt_loss <= 999, "讨债人立即损失 100～999 金币且不低于零")
	_set_property(14, 2, 1, GameRules.PROPERTY_HOUSE)
	check(game._capture_price_for_player(1, game.properties[14]) == GameRules.capture_price(1, 0) * 2, "讨债人使自己的抢占费用翻倍")
	var toll_before := int(game.players_state[1]["coins"]); game._settle_step_toll(1, 14)
	check(toll_before - int(game.players_state[1]["coins"]) == GameRules.toll_fee(1) * 2, "讨债人使自己支付的过路费翻倍")

	# 生命周期：同一时间仅一个，15 格或跨日结束。
	var current: String = game._encounter_type(1); game.test_encounter_override = GameRules.ENCOUNTER_WEALTH_GOD; game._resolve_encounter(1, 5)
	check(game._encounter_type(1) == current, "当前奇遇未结束时不会叠加第二个")
	state = game.players_state[1]; state["encounter_remaining_steps"] = 1; game.players_state[1] = state
	game._process_encounter_step(1, 0, false)
	check(game._encounter_type(1) == GameRules.ENCOUNTER_NONE, "奇遇累计移动 15 格后结束")
	_set_encounter(1, GameRules.ENCOUNTER_WEALTH_GOD); state = game.players_state[1]; state["encounter_start_date"] = "2026-09-11"; game.players_state[1] = state
	game.server_time_override = Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 12, "hour": 0, "minute": 1, "second": 0})
	check(game._expire_encounter_if_needed(1) and game._encounter_type(1) == GameRules.ENCOUNTER_NONE, "奇遇跨过当天 24:00 后结束")

func _test_persistence_and_snapshot() -> void:
	_set_encounter(3, GameRules.ENCOUNTER_LUCKY_STAR)
	var state: Dictionary = game.players_state[3]; state["recent_question_words"] = ["apple", "book"]; state["encounter_remaining_steps"] = 9; state["encounter_trigger_count"] = 1; game.players_state[3] = state
	check(game._save_game(), "Host 保存词书、题目历史与奇遇状态")
	var restored = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(restored); await process_frame
	restored.is_host = true; restored.save_path = SAVE; restored.save_temp_path = TEMP; restored.server_time_override = game.server_time_override
	check(restored._load_game(), "Host 重启可读取版本化存档")
	check(restored.room_wordbook_id == game.room_wordbook_id and restored.room_wordbook.size() == game.room_wordbook.size(), "房间统一词书完整恢复")
	check((restored.players_state[3]["recent_question_words"] as Array).size() == 2 and String(restored.players_state[3]["encounter_type"]) == GameRules.ENCOUNTER_LUCKY_STAR and int(restored.players_state[3]["encounter_remaining_steps"]) == 9, "玩家近期词历史及奇遇状态完整恢复")
	var client = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(client); await process_frame
	client.is_host = false; client._apply_snapshot(game._make_snapshot())
	check(client.room_wordbook_id == game.room_wordbook_id and String(client.players_state[3]["encounter_type"]) == GameRules.ENCOUNTER_LUCKY_STAR, "统一词书和奇遇状态通过 Host snapshot 同步")
	restored.is_host = false; client.is_host = false

func _set_encounter(player_id: int, encounter_type: String) -> void:
	var state: Dictionary = game.players_state[player_id]
	state["encounter_type"] = encounter_type; state["encounter_remaining_steps"] = GameRules.ENCOUNTER_DURATION_STEPS; state["encounter_trigger_count"] = 0; state["encounter_start_date"] = game._server_date(); state["action_state"] = GameRules.ACTION_IDLE
	players_update(player_id, state)

func _clear_encounter(player_id: int) -> void:
	var state: Dictionary = game.players_state[player_id]
	state["encounter_type"] = GameRules.ENCOUNTER_NONE; state["encounter_remaining_steps"] = 0; state["encounter_trigger_count"] = 0; state["encounter_start_date"] = ""; state["action_state"] = GameRules.ACTION_IDLE
	players_update(player_id, state)

func players_update(player_id: int, state: Dictionary) -> void: game.players_state[player_id] = state

func _set_property(index: int, owner: int, level: int, property_type: String) -> void:
	var value: Dictionary = game.properties[index]; value["owner_id"] = owner; value["property_level"] = level; value["capture_count"] = 0; value["cell_type"] = GameRules.CELL_PROPERTY; value["property_type"] = property_type; game.properties[index] = value

func _empty_inventory() -> Dictionary:
	var inventory := {}
	for card_id in GameRules.CARD_IDS: inventory[card_id] = 0
	return inventory

func _inventory_total(inventory: Dictionary) -> int:
	var total := 0
	for card_id in GameRules.CARD_IDS: total += int(inventory.get(card_id, 0))
	return total

func _wait(callable: Callable, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not callable.call() and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	return callable.call()

func _cleanup() -> void:
	for path in [SAVE, TEMP, SAVE + ".bak"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
