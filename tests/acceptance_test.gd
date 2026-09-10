extends SceneTree

var _failures: Array[String] = []
var _steps_seen: Array[int] = []


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
	_check(packed != null, "主场景可以加载")
	if packed == null:
		quit(1)
		return

	var game := packed.instantiate()
	root.add_child(game)
	await process_frame
	await process_frame

	var board = game.get_node("Board")
	var player = game.get_node("Player")
	var ui = game.get_node("GameUI")
	var camera: Camera2D = player.get_node("Camera2D")

	_check(board.get_cell_count() == 30, "棋盘生成 30 个连续格子")
	_check(board.get_route_bounds().size.x > 1920.0, "棋盘宽度大于设计视口")
	_check(board.get_route_bounds().size.y > 1080.0, "棋盘高度大于设计视口")
	_check(player.current_cell_index == 0, "玩家从第 0 格开始")
	_check(player.position.is_equal_approx(board.get_cell_position(0)), "玩家初始位置对齐第 0 格")
	_check(camera.enabled and camera.get_parent() == player, "Camera2D 启用并随玩家变换")
	_check(camera.limit_left < -9000000 and camera.limit_right > 9000000, "镜头未设置边界夹取，路线边缘仍以玩家为中心")
	_check(ui.layer > 0 and ui.get_node("HUD/RollButton") is Button, "UI 位于独立 CanvasLayer")

	var rolls_in_range := true
	for _i in range(100):
		var roll: int = game.generate_roll()
		rolls_in_range = rolls_in_range and roll >= 1 and roll <= 6
	_check(rolls_in_range, "随机骰子 100 次均在 1～6")

	_steps_seen.clear()
	player.step_reached.connect(_record_step)
	game.start_turn(3)
	_check(game.turn_in_progress and ui.roll_button.disabled, "移动开始后禁用掷骰子按钮")
	var first_roll: int = game.last_roll
	game.start_turn(6)
	_check(game.last_roll == first_roll, "移动中再次掷骰被忽略")
	await game.turn_finished
	_check(player.current_cell_index == 3, "点数 3 准确到达第 3 格")
	_check(_steps_seen == [1, 2, 3], "玩家按 1、2、3 逐格移动")
	_check(not game.turn_in_progress and not ui.roll_button.disabled, "移动结束后恢复掷骰")

	player.place_at_cell(28, board)
	ui.set_current_cell(28)
	_steps_seen.clear()
	game.start_turn(4)
	await game.turn_finished
	_check(player.current_cell_index == 2, "末尾循环后准确落在第 2 格")
	_check(_steps_seen == [29, 0, 1, 2], "循环路径按 29、0、1、2 连续逐格移动")
	_check(player.position.is_equal_approx(board.get_cell_position(2)), "循环移动最终位置正确")

	if _failures.is_empty():
		print("ACCEPTANCE RESULT | 12/12 核心检查通过，无脚本错误")
		quit(0)
	else:
		print("ACCEPTANCE RESULT | 失败项：", _failures)
		quit(1)


func _record_step(cell_index: int) -> void:
	_steps_seen.append(cell_index)
