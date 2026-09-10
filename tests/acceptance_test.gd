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

	_check(game.players_state.size() == 2, "同时创建两个玩家")
	_check(int(game.players_state[1]["coins"]) == 10000 and int(game.players_state[2]["coins"]) == 10000, "双方初始金币为 10000")
	_check(int(game.players_state[1]["diamonds"]) == 100 and int(game.players_state[2]["diamonds"]) == 100, "双方初始钻石为 100")
	_check(int(game.players_state[1]["player_level"]) == 10, "玩家初始等级为 10")
	_check(game.properties.size() == 30 and int(game.properties[8]["owner_id"]) == -1, "30 个地产状态初始化为空地")
	_check(game.player_1.visible and game.player_2.visible, "两个棋子同时显示")
	_check(game.turn_camera.enabled, "当前回合 Camera2D 已启用")
	_check(GameRules.capture_price(2, 0) == 2000 and GameRules.capture_price(2, 1) == 4000, "抢占价格按次数递增")
	_check(game.can_upgrade_property(10, 4) and not game.can_upgrade_property(3, 4), "房产等级判断为独立规则")

	var rolls_valid := true
	for _index in range(100):
		var roll: int = game.generate_roll()
		rolls_valid = rolls_valid and roll >= 1 and roll <= 6
	_check(rolls_valid, "随机骰子范围为 1～6")

	game._host_try_roll(2, 6)
	_check(game.phase == "waiting" and int(game.players_state[2]["cell"]) == 0, "非当前玩家的掷骰请求被拒绝")

	game._host_try_roll(1, 2)
	_check(await _wait_for_prompt(game), "P1 移动后收到买地操作")
	_check(String(game.pending_action["type"]) == "buy", "空地产生购买选项")
	game._host_resolve_property(1, true)
	_check(int(game.properties[2]["owner_id"]) == 1 and int(game.properties[2]["property_level"]) == 1, "P1 买下格子 2 并成为 L1")
	_check(int(game.players_state[1]["coins"]) == 9000 and game.current_player_id == 2, "P1 扣除 1000 并切换 P2")

	game._host_try_roll(2, 1)
	_check(await _wait_for_prompt(game), "P2 移动后收到买地操作")
	game._host_resolve_property(2, true)
	_check(int(game.properties[1]["owner_id"]) == 2 and int(game.players_state[2]["coins"]) == 9000, "P2 买地状态正确")

	game._host_try_roll(1, 30)
	_check(await _wait_for_prompt(game, 5.0), "P1 闭环回到自有地产")
	_check(String(game.pending_action["type"]) == "upgrade" and int(game.pending_action["price"]) == 2000, "L1 升 L2 价格为 2000")
	game._host_resolve_property(1, true)
	_check(int(game.properties[2]["property_level"]) == 2 and int(game.players_state[1]["coins"]) == 7000, "P1 升级成功并正确扣款")

	game._host_try_roll(2, 1)
	_check(await _wait_for_prompt(game), "P2 落在 P1 地产后收到抢占操作")
	_check(String(game.pending_action["type"]) == "capture" and int(game.pending_action["price"]) == 2000, "L2 首次抢占价格为 2000")
	game._host_resolve_property(2, true)
	var captured: Dictionary = game.properties[2]
	_check(int(captured["owner_id"]) == 2 and int(captured["property_level"]) == 3 and int(captured["capture_count"]) == 1, "抢占后归属、等级、次数正确")
	_check(int(game.players_state[2]["coins"]) == 7000, "抢占者扣除 2000")
	_check(int(game.players_state[1]["coins"]) == 8600, "原房主获得抢占价格的 80%")
	_check(game.current_player_id == 1 and game.phase == "waiting", "抢占后正确切回 P1")
	_check(not game.game_ui.roll_button.disabled, "当前本地玩家掷骰按钮启用")

	if _failures.is_empty():
		print("ACCEPTANCE RESULT | PASS | 单机权威规则与 UI 检查全部通过")
		quit(0)
	else:
		print("ACCEPTANCE RESULT | FAIL | ", _failures)
		quit(1)

func _wait_for_prompt(game, timeout_seconds: float = 3.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while game.pending_action.is_empty() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return not game.pending_action.is_empty()
