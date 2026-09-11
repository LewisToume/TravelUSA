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
	game.dice_animation_duration = 0.1
	game.save_path = "user://acceptance-save.json"
	game.save_temp_path = "user://acceptance-save.tmp"
	_cleanup_test_save()
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
	game.game_ui.show_property_prompt({"type": "capture", "cell_index": 1, "owner_id": 2, "property_level": 2, "price": 100, "force_buy_available": true})
	check(game.game_ui.force_buy_button.visible, "抢占界面显示可用的强购按钮")
	game.game_ui.show_event_prompt({"type": "reward", "amount": 100, "player_id": 1}, true)
	check(not game.game_ui.force_buy_button.visible, "奖励提示已重置且不显示强购按钮")
	game.game_ui.show_wheel_ready(1, true)
	check(not game.game_ui.force_buy_button.visible, "转盘界面不显示强购按钮")
	check(game.game_ui.modal_shade.mouse_filter == Control.MOUSE_FILTER_STOP and game.game_ui.active_modal == game.game_ui.wheel_overlay, "主窗口遮罩拦截背景点击")
	game.game_ui._show_inventory(); game.game_ui.show_leaderboard([])
	check(not game.game_ui.card_overlay.visible and game.game_ui.leaderboard_overlay.visible, "打开新主窗口会关闭旧主窗口")
	game.game_ui.modal_close_buttons["leaderboard"].pressed.emit()
	check(game.game_ui.active_modal == null and not game.game_ui.modal_shade.visible, "点击 X 后解除模态遮罩")
	check(game.game_ui.modal_close_buttons.size() == 7 and game.game_ui.modal_close_buttons["property"].disabled and game.game_ui.modal_close_buttons["wheel"].disabled and game.game_ui.modal_close_buttons["quiz"].disabled, "全部主窗口有大号 X 且强制流程不可绕过")
	var warm_panel := game.game_ui.card_overlay.get_theme_stylebox("panel") as StyleBoxFlat
	check(warm_panel != null and warm_panel.bg_color.a == 1.0 and warm_panel.bg_color.r > warm_panel.bg_color.b and warm_panel.border_width_left >= 3, "主窗口使用不透明暖色背景和棕色边框")
	check(BoardPath.PSEUDO_3D_ENABLED and BoardPlayer.PSEUDO_3D_ENABLED and BoardPath.BACKGROUND_COLOR.r > BoardPath.BACKGROUND_COLOR.b, "地图、角色与房产启用明亮暖色伪 3D 表现")
	game.game_ui.hide_all_prompts()

	_set_property(game, 1, 2, 1); _set_property(game, 2, 2, 2)
	check(game._host_try_roll(1, 3), "开始逐格移动")
	check(game.game_ui.dice_label.visible, "骰子动画在移动前显示服务器确定的最终点数")
	check(await _wait_action(game, 1, "buy"), "经过两个敌产后仍继续移动到最终格")
	check(int(game.players_state[1]["coins"]) == 925 and int(game.players_state[2]["coins"]) == 1075, "连续经过 L1/L2 分别结算 25/50 过路费")
	check(game.game_ui.toast_container.get_child_count() >= 2, "过路费使用可排队且不阻塞的 Toast")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)

	check(game._host_use_card(1, GameRules.CARD_TOLL_FREE, 0), "免租卡由 Host 验证使用")
	var p1: Dictionary = game.players_state[1]; p1["cell"] = 0; game.players_state[1] = p1
	var toll_free_coins := int(game.players_state[1]["coins"])
	check(game._host_try_roll(1, 2), "免租状态下进入连续敌产")
	check(await _wait_action(game, 1, "capture"), "免租只免收费，不跳过落点抢占")
	check(int(game.players_state[1]["coins"]) == toll_free_coins and not bool(game.players_state[1]["toll_free_next_action"]) and bool(game.players_state[1]["toll_free_this_action"]), "下一次完整行动免除所有过路费")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)
	check(not bool(game.players_state[1]["toll_free_this_action"]), "行动结束后免租状态清除")

	var stamina_before_remote := int(game.players_state[1]["stamina"])
	game.game_ui.show_remote_dice_selector()
	check(game.game_ui.selection_choices.get_child_count() == 6 and game.game_ui.selection_confirm_button.disabled, "遥控骰子显示独立 1～6 选择界面")
	game.game_ui.selection_choices.get_child(4).pressed.emit()
	check(game.game_ui.selected_remote_roll == 5 and not game.game_ui.selection_confirm_button.disabled, "遥控骰子数字 5 可高亮并启用确认")
	game.game_ui.hide_target_selector()
	check(game._host_use_card(1, GameRules.CARD_REMOTE_DICE, 5) and String(game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING and int(game.players_state[1]["stamina"]) == stamina_before_remote - 1, "遥控骰子确认后由 Host 扣活力并立即开始指定点数移动")
	check(int(game.last_rolls[1]) == 5, "遥控骰子选择 5 后服务器结果固定为 5")
	check(await _wait_action(game, 1, "buy"), "遥控骰子动画结束后按指定点数落地")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)
	check(game._host_use_card(1, GameRules.CARD_REVERSE, 0) and bool(game.players_state[1]["reverse_next_move"]), "转向卡设置下一次反向移动")
	check(game._host_use_card(1, GameRules.CARD_SPEED, 0) and bool(game.players_state[1]["speed_next_move"]), "加速卡设置下一次骰子距离 ×2")
	p1 = game.players_state[1]; p1["cell"] = 1; game.players_state[1] = p1; game.player_1.place_at_cell(1, game.board)
	check(game._host_try_roll(1, 4) and int(game.players_state[1]["last_move_distance"]) == 8, "加速时骰子 4 对应实际移动 8")
	check(await _wait_action(game, 1, "buy"), "加速移动完成并进入落点事件")
	_respond(game, 1, "decision", false); await _wait_idle(game, 1)
	p1 = game.players_state[1]; p1["cell"] = 1; game.players_state[1] = p1; game.player_1.place_at_cell(1, game.board)
	_set_property(game, 2, 1, 1)
	check(game._host_use_card(1, GameRules.CARD_BUILD, 2) and int(game.properties[2]["property_level"]) == 2, "建房卡免费升级自己的房产")
	_set_property(game, 3, 2, 3)
	check(game._host_use_card(1, GameRules.CARD_DEMOLISH, 3) and int(game.properties[3]["property_level"]) == 2, "拆房卡降低敌产一级且保留所有权")
	p1 = game.players_state[1]; p1["cell"] = 7; game.players_state[1] = p1; _set_property(game, 7, 2, 3)
	check(game._host_use_card(1, GameRules.CARD_FORCE_BUY, 0) and int(game.properties[7]["owner_id"]) == 1 and int(game.properties[7]["property_level"]) == 3, "强购 L3 只转移产权且不升级")
	_set_property(game, 6, 2, 1)
	game._apply_property_action(1, {"type": "capture", "cell_index": 6, "price": GameRules.capture_price(1, 0)})
	check(int(game.properties[6]["owner_id"]) == 1 and int(game.properties[6]["property_level"]) == 1, "普通抢占 L1 后仍为 L1")
	_set_property(game, 10, 2, 3)
	game._apply_property_action(1, {"type": "capture", "cell_index": 10, "price": GameRules.capture_price(3, 0)})
	check(int(game.properties[10]["owner_id"]) == 1 and int(game.properties[10]["property_level"]) == 3, "普通抢占 L3 后仍为 L3")
	p1 = game.players_state[1]; p1["cell"] = 1; game.players_state[1] = p1; game.player_1.place_at_cell(1, game.board)
	var before_total := int(game.players_state[1]["coins"]) + int(game.players_state[2]["coins"])
	check(game._host_use_card(1, GameRules.CARD_EQUALIZE, 2), "均富卡仅对合法目标执行")
	check(int(game.players_state[1]["coins"]) + int(game.players_state[2]["coins"]) == before_total and absi(int(game.players_state[1]["coins"]) - int(game.players_state[2]["coins"])) <= 1, "均富卡保持总金币并平均分配")

	# Clear one-shot movement cards before deterministic shop test.
	p1 = game.players_state[1]; p1["forced_next_roll"] = 0; p1["reverse_next_move"] = false; p1["speed_next_move"] = false; p1["cell"] = 14; game.players_state[1] = p1
	check(game._host_try_roll(1, 1) and await _wait_action(game, 1, "shop"), "最终停在 SHOP 只打开当前玩家商店")
	var old_count := int(game.players_state[1]["inventory"][GameRules.CARD_BUILD])
	var shop_state: Dictionary = game.players_state[1]; shop_state["coins"] = GameRules.card_price(GameRules.CARD_BUILD); shop_state["bankruptcy_state"] = GameRules.BANKRUPTCY_NORMAL; game.players_state[1] = shop_state
	check(not game._host_buy_card(1, GameRules.CARD_BUILD) and int(game.players_state[1]["coins"]) == GameRules.card_price(GameRules.CARD_BUILD) and String(game.players_state[1]["bankruptcy_state"]) == GameRules.BANKRUPTCY_NORMAL, "商店余额等于价格时提示不足且不会破产")
	await process_frame
	var unaffordable_disabled := false
	for card in game.game_ui.card_list.get_children():
		if card is Button and card.tooltip_text == String(GameRules.CARD_NAMES[GameRules.CARD_BUILD]): unaffordable_disabled = card.disabled
	check(unaffordable_disabled and game.game_ui.card_overlay.visible and _toast_contains(game, "金币不足"), "买不起的卡牌按钮变灰、提示金币不足且商店保持打开")
	shop_state = game.players_state[1]; shop_state["coins"] = GameRules.card_price(GameRules.CARD_BUILD) + 1; game.players_state[1] = shop_state
	check(game._host_buy_card(1, GameRules.CARD_BUILD), "商店购买由 Host 扣款")
	check(int(game.players_state[1]["inventory"][GameRules.CARD_BUILD]) == old_count + 1, "购买卡牌进入个人 inventory")
	_respond(game, 1, "shop_close", true); await _wait_idle(game, 1)

	check(not game._host_use_card(1, "fake_card", 0), "Host 拒绝不存在的卡牌")
	check(game.game_ui.find_children("*", "SpinBox", true, false).is_empty(), "卡牌界面已删除通用数字输入框")
	var offscreen_cell := -1
	for cell_index in range(game.properties.size()):
		if String(game.properties[cell_index]["cell_type"]) == GameRules.CELL_PROPERTY and not game._is_cell_in_player_view(1, cell_index): offscreen_cell = cell_index; break
	var inventory: Dictionary = game.players_state[1]["inventory"]; inventory[GameRules.CARD_BUILD] = 1; game.players_state[1]["inventory"] = inventory
	if offscreen_cell >= 0: _set_property(game, offscreen_cell, 1, 1)
	check(offscreen_cell >= 0 and not game._host_use_card(1, GameRules.CARD_BUILD, offscreen_cell) and int(game.players_state[1]["inventory"][GameRules.CARD_BUILD]) == 1, "屏幕外目标被 Host 拒绝且失败不扣卡牌")
	check(_card_prices_correct(), "8 种卡牌价格集中配置且数值正确")
	check(not game.game_ui.all_players_label.visible, "HUD 不显示其他玩家金币和活力")
	check(game.notifications.size() > 0 and game.notifications.size() <= 100, "重要事件写入最多 100 条的全局通知")

	# Empty land is deliberately not reserved: both see buy, first confirmation wins.
	for player_id in [1, 2]:
		var reset: Dictionary = game.players_state[player_id]; reset["cell"] = 7; reset["action_state"] = GameRules.ACTION_IDLE; reset["forced_next_roll"] = 0; reset["reverse_next_move"] = false; reset["speed_next_move"] = false; game.players_state[player_id] = reset; game._player_node(player_id).place_at_cell(7, game.board)
	check(game._host_try_roll(1, 1) and game._host_try_roll(2, 1), "同一空地可同时给多个玩家购买机会")
	check(await _wait_action(game, 1, "buy") and await _wait_action(game, 2, "buy"), "空地未被锁定或排队")
	var p1_coins := int(game.players_state[1]["coins"])
	_respond(game, 2, "decision", true); await _wait_idle(game, 2)
	_respond(game, 1, "decision", true); await _wait_idle(game, 1)
	check(int(game.properties[8]["owner_id"]) == 2 and int(game.players_state[1]["coins"]) == p1_coins, "先确认者获得土地，后确认者不扣金币")

	game.is_host = false
	_cleanup_test_save()
	if failures.is_empty(): print("ACCEPTANCE RESULT | PASS | 多人、逐格收费、建筑、商店和卡牌规则通过"); quit(0)
	else: print("ACCEPTANCE RESULT | FAIL | ", failures); quit(1)

func _cleanup_test_save() -> void:
	for path in ["user://acceptance-save.json", "user://acceptance-save.tmp", "user://acceptance-save.json.bak"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

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

func _toast_contains(game, text: String) -> bool:
	for child in game.game_ui.toast_container.get_children():
		if text in child.text: return true
	return false
