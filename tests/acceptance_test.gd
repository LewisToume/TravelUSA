extends SceneTree

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS | ", description)
	else:
		_failures.append(description)
		push_error("FAIL | " + description)

func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	_check(packed != null, "主场景可加载")
	if packed == null:
		quit(1)
		return
	var game = packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.test_mode = true
	game.player_1.move_speed_pixels_per_second = 100000.0
	game.player_2.move_speed_pixels_per_second = 100000.0
	game.player_1.minimum_step_duration = 0.001
	game.player_2.minimum_step_duration = 0.001
	game.start_local_test_game()

	_check(_build_costs_are_correct(), "L1～L5 建造费用正确")
	_check(_toll_fees_are_correct(), "L1～L5 过路费正确")
	_check(not game.players_state[1].has("diamonds"), "经济状态只保留金币")
	_check(game.properties.size() == 30, "地图包含 30 个集中配置格子")
	_check(_cell_types_match(game.properties), "START/PROPERTY/REWARD/WHEEL 类型配置正确")
	_check(game.properties == game_state_round_trip(game), "格子类型可通过状态快照完整同步")

	game._host_try_roll(1, 2)
	_check(await _wait_for_prompt(game), "P1 到达空地产生买地提示")
	_check(String(game.pending_action["type"]) == "buy" and int(game.pending_action["price"]) == 50, "空地到 L1 支付 50")
	game._host_resolve_property(1, true)
	_check(int(game.players_state[1]["coins"]) == 9950, "P1 买地扣除 50")

	game._host_try_roll(2, 1)
	_check(await _wait_for_prompt(game), "P2 到达空地产生买地提示")
	game._host_resolve_property(2, true)
	_check(int(game.players_state[2]["coins"]) == 9950, "P2 买地扣除 50")

	game._host_try_roll(1, 30)
	_check(await _wait_for_prompt(game, 6.0), "P1 绕圈回到自己的房产")
	_check(game.last_turn_tolls.size() == 1 and int(game.last_turn_tolls[0]["cell_index"]) == 1, "路过敌方 L1 立即收取一次过路费")
	_check(int(game.players_state[1]["coins"]) == 9925 and int(game.players_state[2]["coins"]) == 9975, "过路费从经过者转给房主")
	_check(game.last_event.is_empty(), "路过奖励格和转盘格不触发最终事件")
	_check(String(game.pending_action["type"]) == "upgrade" and int(game.pending_action["price"]) == 100, "L1 升 L2 费用为 100")
	game._host_resolve_property(1, true)

	var before_own := int(game.players_state[2]["coins"])
	_check(not game._settle_toll(2, 1) and int(game.players_state[2]["coins"]) == before_own, "路过自己的房产不收费")
	_check(not game._settle_toll(2, 6) and int(game.players_state[2]["coins"]) == before_own, "路过空地不收费")

	game._host_try_roll(2, 1)
	_check(await _wait_for_prompt(game), "P2 最终到达敌方房产进入抢占流程")
	_check(game.last_turn_tolls.size() == 1 and int(game.last_turn_tolls[0]["amount"]) == 50, "最终落在敌产先收 L2 过路费")
	_check(int(game.players_state[2]["coins"]) == 9925 and String(game.pending_action["type"]) == "capture", "收费完成后才提供抢占选项")
	_check(int(game.pending_action["price"]) == 100, "L2 首次抢占价格使用建造费用 100")
	game._host_resolve_property(2, true)
	_check(int(game.properties[2]["owner_id"]) == 2 and int(game.properties[2]["property_level"]) == 3, "抢占后归属和等级正确")

	_set_property(game, 3, 2, 1)
	_set_property(game, 4, 2, 4)
	game._host_try_roll(1, 3)
	_check(await _wait_for_prompt(game), "P1 最终停在奖励格后显示事件")
	_check(game.last_turn_tolls.size() == 2, "一次移动经过多个敌产连续收费")
	_check(int(game.last_turn_tolls[0]["amount"]) == 25 and int(game.last_turn_tolls[1]["amount"]) == 200, "多个过路费按房产等级计算")
	_check(String(game.pending_action["type"]) == "reward" and int(game.pending_action["amount"]) == 100, "REWARD 最终停下触发 +100")
	_check(int(game.players_state[1]["coins"]) == 9830 and int(game.players_state[2]["coins"]) == 10050, "连续过路费与奖励金币结算正确")
	_check(game.current_player_id == 1 and game.phase == "event", "奖励确认前不切换回合")
	game._host_resolve_property(1, true)
	_check(game.current_player_id == 2, "奖励确认后切换回合")

	game.test_wheel_result_override = 200
	game._host_try_roll(2, 7)
	_check(await _wait_for_prompt(game), "WHEEL 仅最终停下时触发")
	_check(String(game.pending_action["type"]) == "wheel" and game.last_wheel_result == 200, "转盘结果由 Host 产生")
	_check(int(game.players_state[2]["coins"]) == 10250, "转盘 +200 金币正确")
	_check(game.current_player_id == 2 and game.phase == "event", "转盘确认前不切换回合")
	game._host_resolve_property(2, true)
	_check(game.current_player_id == 1 and game.phase == "waiting", "转盘确认后切换回合")

	if _failures.is_empty():
		print("ACCEPTANCE RESULT | PASS | 经济、过路费、格子事件与顺序检查全部通过")
		quit(0)
	else:
		print("ACCEPTANCE RESULT | FAIL | ", _failures)
		quit(1)

func _wait_for_prompt(game, timeout_seconds: float = 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while game.pending_action.is_empty() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return not game.pending_action.is_empty()

func _set_property(game, cell_index: int, owner_id: int, level: int) -> void:
	var property: Dictionary = game.properties[cell_index]
	property["owner_id"] = owner_id
	property["property_level"] = level
	game.properties[cell_index] = property

func _cell_types_match(cells: Array) -> bool:
	for index in range(cells.size()):
		if String(cells[index]["cell_type"]) != String(GameRules.MAP_CELL_TYPES[index]):
			return false
	return true

func _build_costs_are_correct() -> bool:
	return GameRules.build_cost(1) == 50 and GameRules.build_cost(2) == 100 and GameRules.build_cost(3) == 200 and GameRules.build_cost(4) == 400 and GameRules.build_cost(5) == 800

func _toll_fees_are_correct() -> bool:
	return GameRules.toll_fee(1) == 25 and GameRules.toll_fee(2) == 50 and GameRules.toll_fee(3) == 100 and GameRules.toll_fee(4) == 200 and GameRules.toll_fee(5) == 400

func game_state_round_trip(game) -> Array:
	return game._make_snapshot()["properties"].duplicate(true)
