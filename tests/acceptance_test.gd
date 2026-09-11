extends SceneTree

var failures: Array[String] = []

func _initialize() -> void: call_deferred("_run")
func check(value: bool, message: String) -> void:
	if value: print("PASS | ", message)
	else: failures.append(message); push_error("FAIL | " + message)

func _run() -> void:
	var game = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(game)
	await process_frame; await process_frame
	game.test_mode = true
	game.test_wheel_spin_duration = 0.1
	for player_id in game.player_nodes:
		game.player_nodes[player_id].move_speed_pixels_per_second = 100000.0
		game.player_nodes[player_id].minimum_step_duration = 0.01
	game.start_local_test_game()

	check(game.player_nodes.size() == 6 and game.players_state.size() == 6, "已准备 1～6 号玩家状态与棋子")
	check(BoardPath.PLAYER_COLORS.size() == 6, "房产和棋子支持 6 种玩家颜色")
	check(GameRules.MAP_CELL_TYPES[15] == GameRules.CELL_SHOP and GameRules.MAP_CELL_TYPES[28] == GameRules.CELL_SHOP, "15 与 28 为集中配置的 SHOP 格")
	var every_inventory_ready := true
	for player_id in range(1, 7): every_inventory_ready = every_inventory_ready and _all_cards_start_at_one(game.players_state[player_id]["inventory"])
	check(every_inventory_ready, "所有玩家开局 8 种卡牌各发 1 张")
	check(game.board.get_building_anchor(1).distance_to(game.board.get_cell_position(1)) >= 100.0, "建筑锚点位于道路格旁边")

	_set_property(game, 1, 2, 1); _set_property(game, 2, 2, 2)
	check(game._host_try_roll(1, 3), "开始逐格移动")
	check(await _wait_action(game, 1, "buy"), "经过两个敌产后仍继续移动到最终格")
	check(int(game.players_state[1]["coins"]) == 925 and int(game.players_state[2]["coins"]) == 1075, "连续经过 L1/L2 分别结算 25/50 过路费")
	check(game.game_ui.toast_container.get_child_count() >= 2, "过路费使用可排队且不阻塞的 Toast")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)

	check(game._host_use_card(1, GameRules.CARD_TOLL_FREE, 0), "免租卡由 Host 验证使用")
	var p1: Dictionary = game.players_state[1]; p1["cell"] = 0; game.players_state[1] = p1
	check(game._host_try_roll(1, 1), "免租状态下进入敌产")
	check(await _wait_action(game, 1, "capture"), "免租只免收费，不跳过落点抢占")
	check(int(game.players_state[1]["coins"]) == 925 and not bool(game.players_state[1]["next_toll_free"]), "下一次过路费被免除并消耗状态")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)

	check(game._host_use_card(1, GameRules.CARD_REMOTE_DICE, 6) and int(game.players_state[1]["forced_next_roll"]) == 6, "遥控骰子记录 Host 验证的 1～6 点")
	check(game._host_use_card(1, GameRules.CARD_REVERSE, 0) and bool(game.players_state[1]["reverse_next_move"]), "转向卡设置下一次反向移动")
	check(game._host_use_card(1, GameRules.CARD_SPEED, 0) and bool(game.players_state[1]["speed_next_move"]), "加速卡设置下一次骰子距离 +3")
	_set_property(game, 4, 1, 1)
	check(game._host_use_card(1, GameRules.CARD_BUILD, 4) and int(game.properties[4]["property_level"]) == 2, "建房卡免费升级自己的房产")
	_set_property(game, 6, 2, 3)
	check(game._host_use_card(1, GameRules.CARD_DEMOLISH, 6) and int(game.properties[6]["property_level"]) == 2, "拆房卡降低敌产一级且保留所有权")
	p1 = game.players_state[1]; p1["cell"] = 7; game.players_state[1] = p1; _set_property(game, 7, 2, 1)
	check(game._host_use_card(1, GameRules.CARD_FORCE_BUY, 0) and int(game.properties[7]["owner_id"]) == 1, "强购卡按当前抢占费用取得脚下敌产")
	var before_total := int(game.players_state[1]["coins"]) + int(game.players_state[2]["coins"])
	check(game._host_use_card(1, GameRules.CARD_EQUALIZE, 2), "均富卡仅对合法目标执行")
	check(int(game.players_state[1]["coins"]) + int(game.players_state[2]["coins"]) == before_total and absi(int(game.players_state[1]["coins"]) - int(game.players_state[2]["coins"])) <= 1, "均富卡保持总金币并平均分配")

	# Clear one-shot movement cards before deterministic shop test.
	p1 = game.players_state[1]; p1["forced_next_roll"] = 0; p1["reverse_next_move"] = false; p1["speed_next_move"] = false; p1["cell"] = 14; game.players_state[1] = p1
	check(game._host_try_roll(1, 1) and await _wait_action(game, 1, "shop"), "最终停在 SHOP 只打开当前玩家商店")
	var old_count := int(game.players_state[1]["inventory"][GameRules.CARD_BUILD])
	check(game._host_buy_card(1, GameRules.CARD_BUILD), "商店购买由 Host 扣款")
	check(int(game.players_state[1]["inventory"][GameRules.CARD_BUILD]) == old_count + 1, "购买卡牌进入个人 inventory")
	_respond(game, 1, "shop_close", true); await _wait_idle(game, 1)

	check(not game._host_use_card(1, "fake_card", 0), "Host 拒绝不存在的卡牌")
	check(_card_prices_correct(), "8 种卡牌价格集中配置且数值正确")

	if failures.is_empty(): print("ACCEPTANCE RESULT | PASS | 多人、逐格收费、建筑、商店和卡牌规则通过"); quit(0)
	else: print("ACCEPTANCE RESULT | FAIL | ", failures); quit(1)

func _all_cards_start_at_one(inventory: Dictionary) -> bool:
	for card_id in GameRules.CARD_IDS:
		if int(inventory.get(card_id, 0)) != 1: return false
	return true

func _card_prices_correct() -> bool:
	return GameRules.card_price(GameRules.CARD_REMOTE_DICE) == 200 and GameRules.card_price(GameRules.CARD_BUILD) == 300 and GameRules.card_price(GameRules.CARD_DEMOLISH) == 300 and GameRules.card_price(GameRules.CARD_FORCE_BUY) == 500 and GameRules.card_price(GameRules.CARD_TOLL_FREE) == 250 and GameRules.card_price(GameRules.CARD_REVERSE) == 150 and GameRules.card_price(GameRules.CARD_SPEED) == 200 and GameRules.card_price(GameRules.CARD_EQUALIZE) == 800

func _set_property(game, index: int, owner: int, level: int) -> void:
	var value: Dictionary = game.properties[index]; value["owner_id"] = owner; value["property_level"] = level; game.properties[index] = value

func _respond(game, player_id: int, kind: String, accepted: bool) -> void:
	game._host_record_response(player_id, int(game.pending_actions[player_id]["event_id"]), kind, accepted)

func _wait_action(game, player_id: int, kind: String, seconds := 5.0) -> bool:
	return await _wait_until(func(): return game.pending_actions.has(player_id) and String(game.pending_actions[player_id].get("type", "")) == kind, seconds)

func _wait_idle(game, player_id: int, seconds := 5.0) -> bool:
	return await _wait_until(func(): return String(game.players_state[player_id]["action_state"]) == GameRules.ACTION_IDLE, seconds)

func _wait_until(callable: Callable, seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not callable.call() and Time.get_ticks_msec() < deadline: await create_timer(0.01).timeout
	return callable.call()
