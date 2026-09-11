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
	game.test_wheel_spin_duration = 0.15
	for player in [game.player_1, game.player_2]:
		player.move_speed_pixels_per_second = 100000.0
		player.minimum_step_duration = 0.01
	game.start_local_test_game()

	_check(_valid_initial_states(game), "两名玩家初始状态包含 1000 金币、20 活力与 IDLE")
	_check(GameRules.INITIAL_STAMINA == 20, "初始活力集中配置为 20")
	_check("当前玩家" not in game.game_ui.player_label.text and "等待 Player" not in game.game_ui.action_status_label.text, "HUD 不再显示回合或等待另一玩家")

	# The host accepts both actions before either animation/event completes.
	_check(game._host_try_roll(1, 2), "P1 可独立提交掷骰请求")
	_check(not game._host_try_roll(1, 2), "P1 RESOLVING 时重复请求被拒绝")
	_check(game._host_try_roll(2, 2), "P1 处理中时 P2 仍可提交掷骰请求")
	_check(int(game.players_state[1]["stamina"]) == 19 and int(game.players_state[2]["stamina"]) == 19, "每名玩家各自扣除 1 点活力")
	_check(_both_resolving(game), "两名玩家可同时处于 RESOLVING")

	_check(await _wait_host_action(game, 1, "buy"), "先处理的 P1 获得空地购买资格")
	_respond(game, 1, "decision", true)
	_check(await _wait_host_action(game, 2, "toll"), "同格后处理的 P2 读取到更新后的房主并支付过路费")
	_check(int(game.properties[2]["owner_id"]) == 1 and int(game.players_state[1]["coins"]) == 975 and int(game.players_state[2]["coins"]) == 975, "同格购买原子化且过路费由 Host 结算")
	_respond(game, 2, "decision", true)
	_check(await _wait_host_action(game, 2, "capture"), "过路费确认后才进入抢占选项")
	_respond(game, 2, "decision", false)
	_check(await _wait_idle(game, 1) and await _wait_idle(game, 2), "两名玩家分别完成动作并恢复 IDLE")

	# Passing an enemy property no longer charges; only the final landing does.
	_set_property(game, 3, 1, 5)
	_check(game._host_try_roll(2, 2), "P2 发起经过敌产的移动")
	_check(await _wait_host_action(game, 2, "buy"), "经过格 3 不收费，最终空地格 4 进入购买")
	_check(int(game.players_state[2]["coins"]) == 975, "路过敌方房产金币不变")
	_respond(game, 2, "decision", false)
	_check(await _wait_idle(game, 2), "跳过购买后 P2 独立恢复可行动")

	# Reward and wheel remain host-authoritative and do not block the other player.
	_check(game._host_try_roll(1, 3), "P1 可移动到奖励格")
	_check(await _wait_host_action(game, 1, "reward"), "奖励只在最终落点触发")
	_check(int(game.players_state[1]["coins"]) == 1075, "Host 发放奖励格 100 金币")
	_respond(game, 1, "decision", true)
	_check(await _wait_idle(game, 1), "奖励确认后仅 P1 恢复 IDLE")

	game.test_wheel_result_override = 200
	_check(game._host_try_roll(2, 5), "P2 可移动到大转盘格")
	_check(await _wait_host_action(game, 2, "wheel"), "Host 预先确定大转盘结果")
	_check(game._host_try_roll(1, 1), "P2 操作转盘期间 P1 仍可开始自己的动作")
	_check(await _wait_host_action(game, 1, "buy"), "P1 与 P2 的落点事件可并行处理")
	_respond(game, 1, "decision", false)
	var wheel_event := int(game.pending_actions[2]["event_id"])
	game._host_record_response(2, wheel_event, "wheel_spin", true)
	_check(await _wait_until(func() -> bool: return game.last_wheel_result == 200 and int(game.players_state[2]["coins"]) == 1175), "转盘动画使用 Host 的 +200 结果并同步金币")
	game._host_record_response(2, wheel_event, "wheel_confirm", true)
	_check(await _wait_idle(game, 1) and await _wait_idle(game, 2), "并行动作各自完成，不切换全局回合")

	var saved_stamina := int(game.players_state[1]["stamina"])
	var state: Dictionary = game.players_state[1]
	state["stamina"] = 0
	game.players_state[1] = state
	_check(not game._host_try_roll(1, 1) and int(game.players_state[1]["stamina"]) == 0, "stamina 为 0 时 Host 拒绝掷骰")
	state["stamina"] = saved_stamina
	game.players_state[1] = state

	if _failures.is_empty():
		print("ACCEPTANCE RESULT | PASS | 异步行动、活力、最终落点事件与房产冲突全部通过")
		quit(0)
	else:
		print("ACCEPTANCE RESULT | FAIL | ", _failures)
		quit(1)

func _valid_initial_states(game) -> bool:
	for player_id in [1, 2]:
		var state: Dictionary = game.players_state[player_id]
		if int(state["player_id"]) != player_id or int(state["coins"]) != 1000 or int(state["stamina"]) != 20 or String(state["action_state"]) != GameRules.ACTION_IDLE:
			return false
	return true

func _both_resolving(game) -> bool:
	return String(game.players_state[1]["action_state"]) == GameRules.ACTION_RESOLVING and String(game.players_state[2]["action_state"]) == GameRules.ACTION_RESOLVING

func _respond(game, player_id: int, response_type: String, accepted: bool) -> void:
	var event_id := int(game.pending_actions[player_id]["event_id"])
	game._host_record_response(player_id, event_id, response_type, accepted)

func _wait_host_action(game, player_id: int, action_type: String, timeout_seconds := 5.0) -> bool:
	return await _wait_until(func() -> bool: return game.pending_actions.has(player_id) and String(game.pending_actions[player_id].get("type", "")) == action_type, timeout_seconds)

func _wait_idle(game, player_id: int, timeout_seconds := 5.0) -> bool:
	return await _wait_until(func() -> bool: return String(game.players_state[player_id]["action_state"]) == GameRules.ACTION_IDLE, timeout_seconds)

func _wait_until(predicate: Callable, timeout_seconds := 5.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	return predicate.call()

func _set_property(game, cell_index: int, owner_id: int, level: int) -> void:
	var property: Dictionary = game.properties[cell_index]
	property["owner_id"] = owner_id
	property["property_level"] = level
	game.properties[cell_index] = property
