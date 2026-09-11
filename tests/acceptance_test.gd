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
	_check(packed != null, "主场景与转盘场景可加载")
	if packed == null:
		quit(1)
		return
	var game = packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.test_mode = true
	game.test_wheel_spin_duration = 0.25
	game.player_1.move_speed_pixels_per_second = 100000.0
	game.player_2.move_speed_pixels_per_second = 100000.0
	game.player_1.minimum_step_duration = 0.001
	game.player_2.minimum_step_duration = 0.001
	game.start_local_test_game()

	_check(int(game.players_state[1]["coins"]) == 1000 and int(game.players_state[2]["coins"]) == 1000, "双方初始金币为 1000")
	_check(_build_costs_are_correct() and _toll_fees_are_correct(), "集中经济配置保持正确")
	_check(game.game_ui.wheel_overlay.wheel_face != null, "圆形六扇区转盘节点存在")

	game._host_try_roll(1, 2)
	_check(await _wait_prompt_type(game, "buy"), "P1 买地提示出现")
	game._host_resolve_property(1, true)
	_check(int(game.players_state[1]["coins"]) == 950, "P1 买地后金币正确")

	game._host_try_roll(2, 1)
	_check(await _wait_prompt_type(game, "buy"), "P2 买地提示出现")
	game._host_resolve_property(2, true)
	_check(int(game.players_state[2]["coins"]) == 950, "P2 买地后金币正确")

	game._host_try_roll(1, 30)
	_check(await _wait_prompt_type(game, "toll", 6.0), "经过敌产时弹出过路费提示")
	_check(game.phase == "toll" and not game.player_1.is_moving and game.player_1.current_cell_index == 1, "过路费确认前暂停剩余移动")
	_check("你支付了 25 金币" in game.game_ui.property_details.text, "付款方显示支付金额")
	await create_timer(0.05).timeout
	_check(game.player_1.current_cell_index == 1, "未确认时棋子保持在收费格")
	game._host_resolve_property(1, true)
	_check(await _wait_prompt_type(game, "upgrade"), "确认过路费后继续移动并进入升级")
	_check(int(game.players_state[1]["coins"]) == 925 and int(game.players_state[2]["coins"]) == 975, "过路费已由 Host 转账")
	game._host_resolve_property(1, true)

	game._host_try_roll(2, 1)
	_check(await _wait_prompt_type(game, "toll"), "最终落在敌产也先弹过路费")
	_check("向你支付了 50 金币" in game.game_ui.property_details.text, "房主客户端显示收款提示")
	game._host_resolve_property(2, true)
	_check(await _wait_prompt_type(game, "capture"), "确认收费后才进入抢占")
	game._host_resolve_property(2, true)
	_check(int(game.players_state[1]["coins"]) == 955 and int(game.players_state[2]["coins"]) == 825, "收费与抢占金币结算正确")

	_set_property(game, 3, 2, 1)
	_set_property(game, 4, 2, 4)
	game._host_try_roll(1, 3)
	_check(await _wait_prompt_type(game, "toll"), "连续收费的第一个弹窗出现")
	game._host_resolve_property(1, true)
	_check(await _wait_prompt_type(game, "toll"), "确认后继续到第二个收费弹窗")
	_check(int(game.pending_action["amount"]) == 200, "第二块 L4 房产收费 200")
	game._host_resolve_property(1, true)
	_check(await _wait_prompt_type(game, "reward"), "全部过路费确认后才触发最终奖励")
	_check(game.last_turn_tolls.size() == 2 and int(game.players_state[1]["coins"]) == 830 and int(game.players_state[2]["coins"]) == 1050, "连续弹窗收费与奖励结算正确")
	game._host_resolve_property(1, true)

	game.test_wheel_result_override = 200
	game._host_try_roll(2, 7)
	_check(await _wait_phase(game, "wheel_ready"), "到达转盘后先等待开始转动")
	_check(game.game_ui.wheel_overlay.visible and game.game_ui.wheel_overlay.spin_button.visible, "大转盘在屏幕中央可见")
	_check(int(game.players_state[2]["coins"]) == 1050, "动画开始前尚未结算转盘金币")
	var start_rotation: float = game.game_ui.wheel_overlay.wheel_face.rotation
	game._host_start_wheel_spin(2)
	_check(await _wait_phase(game, "wheel_spinning"), "点击开始后进入同步旋转阶段")
	await create_timer(0.08).timeout
	_check(not is_equal_approx(game.game_ui.wheel_overlay.wheel_face.rotation, start_rotation), "转盘播放可见旋转动画")
	_check(await _wait_phase(game, "wheel_result"), "减速旋转后显示 Host 结果")
	_check(game.last_wheel_result == 200 and int(game.players_state[2]["coins"]) == 1250, "Host 结果 +200 与金币变化一致")
	_check(game.game_ui.wheel_overlay.confirm_button.visible, "动画结束后出现确定按钮")
	game._host_confirm_wheel(2)
	_check(game.current_player_id == 1 and game.phase == "waiting", "确定转盘结果后才结束回合")

	if _failures.is_empty():
		print("ACCEPTANCE RESULT | PASS | 过路费暂停弹窗与可见转盘动画全部通过")
		quit(0)
	else:
		print("ACCEPTANCE RESULT | FAIL | ", _failures)
		quit(1)

func _wait_prompt_type(game, type: String, timeout_seconds: float = 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while (game.pending_action.is_empty() or String(game.pending_action.get("type", "")) != type) and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return not game.pending_action.is_empty() and String(game.pending_action.get("type", "")) == type

func _wait_phase(game, expected_phase: String, timeout_seconds: float = 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while game.phase != expected_phase and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return game.phase == expected_phase

func _set_property(game, cell_index: int, owner_id: int, level: int) -> void:
	var property: Dictionary = game.properties[cell_index]
	property["owner_id"] = owner_id
	property["property_level"] = level
	game.properties[cell_index] = property

func _build_costs_are_correct() -> bool:
	return GameRules.build_cost(1) == 50 and GameRules.build_cost(2) == 100 and GameRules.build_cost(3) == 200 and GameRules.build_cost(4) == 400 and GameRules.build_cost(5) == 800

func _toll_fees_are_correct() -> bool:
	return GameRules.toll_fee(1) == 25 and GameRules.toll_fee(2) == 50 and GameRules.toll_fee(3) == 100 and GameRules.toll_fee(4) == 200 and GameRules.toll_fee(5) == 400
