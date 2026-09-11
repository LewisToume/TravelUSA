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
	check(GameRules.MAP_CELL_TYPES.count(GameRules.CELL_REWARD) == 0 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_QUIZ) == 9 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_ENCOUNTER) == 4, "地图包含 9 个答题格和 4 个奇遇格")
	check(QuestionBank.DEFAULT_ENTRIES.size() >= GameRules.QUIZ_QUESTION_COUNT, "QuestionBank 独立并提供足够词条")

	_set_property(1, 2, 3)
	var p1: Dictionary = game.players_state[1]; p1["coins"] = 40; game.players_state[1] = p1
	check(game._settle_step_toll(1, 1), "余额不足时仍由 Host 结算过路费")
	check(int(game.players_state[1]["coins"]) == 0 and String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "100 过路费只实付 40 且进入破产")
	check(game.player_nodes[1].is_bankrupt and game.player_nodes[1]._bankruptcy_effect_until > Time.get_ticks_msec(), "本地破产播放灰化、抖动与破碎金币强化动画")
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
	game.game_is_started = false
	check(String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_NORMAL, "5 小时后自动恢复 NORMAL")
	game.server_time_override = bankrupt_day + 2 * 86400

	await _run_quiz(3, true)
	check(int(game.players_state[3]["coins"]) == 1200 and int(game.players_state[3]["daily_taxable_income"]) == 200, "十题全答对共奖励 200 且全部计税")
	await _run_quiz(4, false)
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
	var p4_equal: Dictionary = game.players_state[4]; p4_equal["coins"] = 200; game.players_state[4] = p4_equal
	var user_coins_before := int(game.players_state[2]["coins"])
	var taxable_before := int(p3["daily_taxable_income"]) + int(p4_equal["daily_taxable_income"])
	game._card_equalize(2, [3, 4])
	check(int(game.players_state[2]["coins"]) == user_coins_before and int(game.players_state[3]["coins"]) == 750 and int(game.players_state[4]["coins"]) == 750, "均富卡只平分两个其他玩家且使用者不参与")
	check(int(game.players_state[3]["daily_taxable_income"]) + int(game.players_state[4]["daily_taxable_income"]) == taxable_before, "均富卡资产转移不计税")
	_set_property(3, 2, 2)
	var owner_tax_before := int(game.players_state[2]["daily_taxable_income"])
	game._apply_property_action(3, {"type": "capture", "cell_index": 3, "price": 100})
	check(int(game.players_state[2]["daily_taxable_income"]) == owner_tax_before, "产权补偿不计税")

	_set_property(7, 2, 5); _set_property(8, 3, 1)
	var ranking: Array = game._calculate_leaderboard()
	check(int(ranking[0]["total_wealth"]) >= int(ranking[1]["total_wealth"]), "财富榜按总财富降序")
	var p2_rank: Dictionary = _rank_entry(ranking, 2)
	check(int(p2_rank["property_value"]) >= 800, "财富榜按 L1～L5 建造价值统计房产")

	var before_tax_time := Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 12, "hour": 19, "minute": 59, "second": 0})
	var tax_time := Time.get_unix_time_from_datetime_dict({"year": 2026, "month": 9, "day": 12, "hour": 20, "minute": 1, "second": 0})
	p2 = game.players_state[2]; p2["coins"] = 10; p2["daily_taxable_income"] = 149; p2["last_tax_date"] = "2026-09-11"; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; p2["tax_debt"] = 0; game.players_state[2] = p2
	game.server_time_override = before_tax_time
	check(not game._check_player_tax(2) and int(game.players_state[2]["coins"]) == 10, "20:00 前不结算税收")
	game.server_time_override = tax_time
	check(game._check_player_tax(2) and int(game.players_state[2]["coins"]) == 0 and int(game.players_state[2]["tax_debt"]) == 5 and String(game.players_state[2]["bankruptcy_state"]) == GameRules.BANKRUPTCY_TAX_DEBT, "20:00 按 round 结税且现金不足进入 TAX_DEBT 而非直接破产")
	check(not game._check_player_tax(2), "同一天税收绝不重复结算")
	var p4: Dictionary = game.players_state[4]; p4["coins"] = 500; p4["daily_taxable_income"] = 0; p4["last_tax_date"] = "2026-09-11"; p4["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; p4["tax_debt"] = 0; game.players_state[4] = p4
	var toast_count: int = game.game_ui.toast_container.get_child_count()
	check(game._check_player_tax(4) and String(game.notifications[0]["event_type"]) == "daily_tax" and int(game.notifications[0]["amount"]) == 0, "tax=0 仍生成 daily_tax 邮箱记录")
	check(game.game_ui.toast_container.get_child_count() > toast_count, "每日税收结算一定显示 Toast")
	game.game_ui.update_game_state(1, game.players_state, game.active_player_ids, game.last_rolls, game.notifications)
	check(_mailbox_contains("【税收】"), "税收消息以税收前缀进入邮箱")
	check(GameRules.daily_tax(15) == 2 and GameRules.asset_recovery(200) == 140 and GameRules.capture_price(3, 0) == 240, "税收、资产折价与抢占溢价统一使用 round")

	# TAX_DEBT keeps movement/income available while blocking new investments.
	p2 = game.players_state[2]; p2["coins"] = 0; p2["tax_debt"] = 380; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_TAX_DEBT; p2["action_state"] = GameRules.ACTION_IDLE; game.players_state[2] = p2
	game.game_ui.update_game_state(2, game.players_state, game.active_player_ids, game.last_rolls, game.notifications)
	check("预计税款：" in game.game_ui.estimated_tax_label.text and game.game_ui.tax_debt_label.visible and "欠税：380" in game.game_ui.tax_debt_label.text and game.game_ui.repay_tax_button.visible and game.game_ui.asset_management_button.visible, "HUD 明确显示预计税款、欠税金额、处理资产与立即还税")
	game.local_player_id = 2
	game._show_asset_management()
	check(game.game_ui.active_modal == game.game_ui.asset_overlay and game.game_ui.asset_list.get_child_count() > 0, "欠税资产处理窗口列出自己的房产")
	game.game_ui._close_modal(game.game_ui.asset_overlay)
	game.local_player_id = 1
	game.pending_actions[2] = {"type": "shop", "cell_index": 15, "event_id": 9001}
	check(game.can_player_roll(2) and game._build_property_action(2, 10).is_empty() and not game._host_buy_card(2, GameRules.CARD_BUILD) and not game._host_use_card(2, GameRules.CARD_BUILD, 7), "欠税仍可移动，但不能买房、升级、抢占、强购或买卡")
	game.pending_actions.erase(2)
	_set_property(1, 2, 3)
	var payer: Dictionary = game.players_state[1]; payer["coins"] = 500; payer["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; game.players_state[1] = payer
	var owner_coins_before := int(game.players_state[2]["coins"])
	check(game._settle_step_toll(1, 1) and int(game.players_state[1]["coins"]) == 400, "欠税玩家的房产仍向经过者正常收取过路费")
	check(int(game.players_state[2]["coins"]) == owner_coins_before and int(game.players_state[2]["tax_debt"]) == 380 and "系统收取" in String(game.notifications[0]["message"]), "欠税房主不收过路费且不会自动偿还欠税")
	p2 = game.players_state[2]; p2["coins"] = 120; game.players_state[2] = p2
	check(game._host_repay_tax(2) and int(game.players_state[2]["coins"]) == 0 and int(game.players_state[2]["tax_debt"]) == 260, "立即还税按现金与欠税较小值支付")
	_set_property(7, 2, 4)
	check(game._host_process_asset(2, 7, "downgrade") and int(game.properties[7]["property_level"]) == 3 and int(game.players_state[2]["tax_debt"]) == 0 and int(game.players_state[2]["coins"]) == 20, "L4 降级按 70% 回收 280，优先还税后余额进现金")
	p2 = game.players_state[2]; p2["coins"] = 0; p2["tax_debt"] = 500; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_TAX_DEBT; game.players_state[2] = p2
	_set_property(8, 2, 2); game.properties[8]["capture_count"] = 3
	check(String(game.properties[8]["property_type"]) == GameRules.PROPERTY_HOTEL and game._host_process_asset(2, 8, "sell"), "酒店可以整块卖给系统还税")
	check(int(game.properties[8]["owner_id"]) == -1 and int(game.properties[8]["property_level"]) == 0 and int(game.properties[8]["capture_count"]) == 0 and String(game.properties[8]["property_type"]) == GameRules.PROPERTY_HOTEL, "卖地清空产权等级和抢占次数但保留 property_type")
	var repurchase: Dictionary = game._build_property_action(3, 8)
	check(String(repurchase.get("type", "")) == "buy" and int(repurchase.get("price", 0)) == 150, "系统收回的酒店地块可再次按酒店 L1 价格购买")

	# Capture uses a fixed 1.2 buyer premium; indebted sellers repay debt first.
	p2 = game.players_state[2]; p2["coins"] = 0; p2["tax_debt"] = 100; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_TAX_DEBT; game.players_state[2] = p2
	_set_property(3, 2, 3); game.properties[3]["capture_count"] = 0
	p3 = game.players_state[3]; p3["coins"] = 1000; p3["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; p3["tax_debt"] = 0; game.players_state[3] = p3
	check(game._apply_property_action(3, {"type": "capture", "cell_index": 3, "price": 240}), "L3 首次抢占买家支付固定 1.2 溢价 240")
	check(int(game.players_state[3]["coins"]) == 760 and int(game.players_state[2]["tax_debt"]) == 0 and int(game.players_state[2]["coins"]) == 100 and int(game.properties[3]["capture_count"]) == 1, "卖家基础转手价 200 优先还欠税，余款才进入现金")
	check(GameRules.capture_price(3, 1) == 480 and GameRules.capture_price(3, 2) == 720, "第二、三次抢占为固定 1.2 溢价且不复利")

	# Offline stamina and hotel-specific rules.
	p3 = game.players_state[3]; p3["stamina"] = 7; p3["last_stamina_recovery_time"] = tax_time - 2 * 3600; game.players_state[3] = p3
	game.server_time_override = tax_time
	check(game._recover_player_stamina(3) and int(game.players_state[3]["stamina"]) == 17, "离线每完整小时恢复 5 活力")
	p3 = game.players_state[3]; p3["stamina"] = 18; p3["last_stamina_recovery_time"] = tax_time - 2 * 3600; game.players_state[3] = p3
	check(game._recover_player_stamina(3) and int(game.players_state[3]["stamina"]) == GameRules.MAX_STAMINA, "活力恢复不超过 20 上限")
	check(GameRules.property_value(4, GameRules.PROPERTY_HOTEL) == 1200 and GameRules.toll_fee(3, GameRules.PROPERTY_HOTEL) == 300 and not GameRules.can_force_buy(GameRules.PROPERTY_HOTEL, 1), "酒店 L1～L4 价值、过路费及禁止强购规则生效")
	_set_property(8, 2, 4)
	payer = game.players_state[1]; payer["stamina"] = 10; payer["cell"] = 8; payer["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; game.players_state[1] = payer
	await game._resolve_property_landing(1, 8, true)
	check(int(game.players_state[1]["stamina"]) == 8, "最终停在敌方 L3～L4 酒店额外消耗 2 活力")
	check(not game._card_force_buy(1), "酒店不能使用强购卡")

	# Only exhausted indebted players without any asset become truly bankrupt.
	for property_index in range(game.properties.size()):
		if int(game.properties[property_index].get("owner_id", -1)) == 4:
			game.properties[property_index]["owner_id"] = -1; game.properties[property_index]["property_level"] = 0; game.properties[property_index]["capture_count"] = 0
	p4 = game.players_state[4]; p4["coins"] = 0; p4["tax_debt"] = 50; p4["bankruptcy_state"] = GameRules.BANKRUPTCY_TAX_DEBT; game.players_state[4] = p4
	check(game._maybe_declare_tax_bankruptcy(4) and String(game.players_state[4]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "没钱、欠税且无可处理资产时才进入真正破产")

	var saved_cell := 14
	p3 = game.players_state[3]; p3["cell"] = saved_cell; p3["stamina"] = 7; p3["inventory"][GameRules.CARD_BUILD] = 4; p3["coins"] = 1000; p3["daily_taxable_income"] = 100; p3["last_tax_date"] = "2026-09-11"; game.players_state[3] = p3
	p2 = game.players_state[2]; p2["coins"] = 0; p2["tax_debt"] = 0; p2["bankruptcy_state"] = GameRules.BANKRUPTCY_BANKRUPT; p2["bankrupt_date"] = "2026-09-12"; game.players_state[2] = p2
	p4 = game.players_state[4]; p4["bankruptcy_state"] = GameRules.BANKRUPTCY_PROTECTED; p4["protection_end_time"] = tax_time + 3600; game.players_state[4] = p4
	_set_property(14, 3, 4)
	check(game._save_game(), "Host 使用临时文件原子保存")
	var restored = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(restored); await process_frame
	restored.is_host = true; restored.save_path = SAVE; restored.save_temp_path = TEMP; restored.server_time_override = game.server_time_override
	check(restored._load_game(), "Host 可加载并恢复当前版本存档")
	check(int(restored.players_state[3]["cell"]) == saved_cell and int(restored.players_state[3]["stamina"]) == 7 and int(restored.players_state[3]["inventory"][GameRules.CARD_BUILD]) == 4 and int(restored.properties[14]["property_level"]) == 4, "coins/stamina/cell/cards/房产及永久状态完整恢复")
	check(String(restored.players_state[2]["bankruptcy_state"]) == GameRules.BANKRUPTCY_BANKRUPT, "Host 重启后破产状态保持")
	check(int(restored.players_state[4]["protection_end_time"]) - restored.server_time_override == 3600, "Host 重启后保护剩余时间正确")
	restored._check_player_login(3)
	check(int(restored.players_state[3]["coins"]) == 990 and String(restored.players_state[3]["last_tax_date"]) == "2026-09-12", "20:00 离线后登录会补结算当日税收")

	var corrupt = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(corrupt); await process_frame
	corrupt.is_host = true; corrupt.save_path = "user://corrupt-save.json"; corrupt.save_temp_path = "user://corrupt-save.tmp"
	var bad := FileAccess.open(corrupt.save_path, FileAccess.WRITE); bad.store_string("{broken"); bad.close()
	check(not corrupt._load_game() and corrupt.save_load_failed and not corrupt._save_game(), "损坏存档不崩溃且不会被自动覆盖")

	game.is_host = false; restored.is_host = false; corrupt.is_host = false
	_cleanup()
	if failures.is_empty(): print("ECONOMY RESULT | PASS | 破产、保护、答题、税收、排行和持久化通过"); quit(0)
	else: print("ECONOMY RESULT | FAIL | ", failures); quit(1)

func _run_quiz(player_id: int, answer_correctly: bool) -> void:
	var state: Dictionary = game.players_state[player_id]; state["action_state"] = GameRules.ACTION_RESOLVING; game.players_state[player_id] = state
	game._resolve_quiz(player_id, 4)
	for question_number in range(1, GameRules.QUIZ_QUESTION_COUNT + 1):
		await _wait(func(): return game.pending_actions.has(player_id) and int(game.pending_actions[player_id].get("question_number", 0)) == question_number)
		var pending: Dictionary = game.pending_actions[player_id]
		var answer := int(pending["correct"]) if answer_correctly else (int(pending["correct"]) + 1) % 4
		game._host_record_response(player_id, int(pending["event_id"]), "quiz_answer", false, answer)
	await _wait(func(): return not game.pending_actions.has(player_id))

func _set_property(index: int, owner: int, level: int) -> void:
	var value: Dictionary = game.properties[index]; value["owner_id"] = owner; value["property_level"] = level; game.properties[index] = value

func _rank_entry(entries: Array, player_id: int) -> Dictionary:
	for entry in entries:
		if int(entry["player_id"]) == player_id: return entry
	return {}

func _mailbox_contains(text: String) -> bool:
	for child in game.game_ui.mailbox_list.get_children():
		if text in child.text: return true
	return false

func _wait(callable: Callable, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not callable.call() and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	return callable.call()

func _cleanup() -> void:
	for path in [SAVE, TEMP, SAVE + ".bak", "user://corrupt-save.json", "user://corrupt-save.tmp"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
