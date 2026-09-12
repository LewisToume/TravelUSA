extends SceneTree

var failures: Array[String] = []
var game
const SAVE := "user://map-debug-test.json"
const TEMP := "user://map-debug-test.tmp"
const OLD_SAVE := "user://map-debug-old-test.json"
const OLD_TEMP := "user://map-debug-old-test.tmp"

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	if value: print("PASS | ", message)
	else: failures.append(message); push_error("FAIL | " + message)

func _run() -> void:
	_cleanup()
	game = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(game)
	await process_frame; await process_frame
	game.test_mode = true; game.is_host = true; game.local_player_id = 1; game.game_is_started = true; game.active_player_ids.assign([1, 2]); game.known_player_ids.assign([1, 2, 3])
	game.save_path = SAVE; game.save_temp_path = TEMP
	_test_map()
	_test_encounter_display()
	_test_offline_leaderboard()
	_test_debug_modifier()
	await _test_save_compatibility()
	game.is_host = false
	_cleanup()
	if failures.is_empty(): print("MAP/DEBUG RESULT | PASS"); quit(0)
	else: print("MAP/DEBUG RESULT | FAIL | ", failures); quit(1)

func _test_map() -> void:
	check(game.board.get_cell_count() == 50 and GameRules.MAP_CELL_TYPES.size() == 50, "地图与规则均为 50 格")
	check(GameRules.MAP_CELL_TYPES.count(GameRules.CELL_START) == 1 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_PROPERTY) == 25 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_QUIZ) == 15 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_ENCOUNTER) == 5 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_WHEEL) == 2 and GameRules.MAP_CELL_TYPES.count(GameRules.CELL_SHOP) == 2, "50 格类型数量分布正确")
	check(GameRules.MAP_CELL_TYPES.count(GameRules.CELL_REWARD) == 0, "地图不包含 REWARD")
	var houses := 0; var hotels := 0
	for property in game.properties:
		if String(property["cell_type"]) != GameRules.CELL_PROPERTY: continue
		if String(property["property_type"]) == GameRules.PROPERTY_HOTEL: hotels += 1
		else: houses += 1
	check(houses == 20 and hotels == 5, "25 个房产由 20 个 HOUSE 和 5 个 HOTEL 组成")
	check(String(game.properties[0]["cell_type"]) == GameRules.CELL_START and game._build_property_action(1, 0).is_empty(), "START 是不触发事件的普通起点格")
	var bounds: Rect2 = game.board.get_route_bounds(); var has_inset_point := false; var direction_changes := 0
	var previous_direction := Vector2.ZERO
	for index in range(game.board.get_cell_count()):
		var point: Vector2 = game.board.get_cell_position(index)
		if point.x > bounds.position.x + 100 and point.x < bounds.end.x - 100 and point.y > bounds.position.y + 100 and point.y < bounds.end.y - 100: has_inset_point = true
		var direction: Vector2 = (game.board.get_cell_position(index + 1) - point).normalized()
		if index > 0 and absf(previous_direction.cross(direction)) > 0.08: direction_changes += 1
		previous_direction = direction
	check(has_inset_point and direction_changes >= 10, "显式坐标路线包含多次转弯和凹凸，不是矩形口字形")
	check(game.board.get_cell_position(49).distance_to(game.board.get_cell_position(0)) < 400.0, "49→0 以相邻坐标闭环")
	check(game.board.get_building_anchor(8).distance_to(game.board.get_cell_position(8)) >= game.board.cell_size * 0.9, "建筑锚点保持在道路外侧")

func _test_encounter_display() -> void:
	check(game.board.get_cell_display_text(GameRules.CELL_ENCOUNTER) == "奇遇", "ENCOUNTER 格直接显示奇遇")
	var state: Dictionary = game.players_state[1]
	state["encounter_type"] = GameRules.ENCOUNTER_PROPERTY_GUEST; state["encounter_remaining_steps"] = 11; state["encounter_trigger_count"] = 1; game.players_state[1] = state
	game.game_ui.update_game_state(1, game.players_state, game.active_player_ids, game.last_rolls)
	check("地产客" in game.game_ui.encounter_label.text and "剩余 11 格" in game.game_ui.encounter_label.text and "剩余触发 1 次" in game.game_ui.encounter_label.text, "HUD 显示奇遇、剩余格数和剩余触发次数")

func _test_offline_leaderboard() -> void:
	var p2: Dictionary = game.players_state[2]; p2["coins"] = 2000; game.players_state[2] = p2
	var property: Dictionary = game.properties[8]; property["owner_id"] = 2; property["property_level"] = 2; game.properties[8] = property
	game.active_player_ids.assign([1])
	var entries: Array = game._calculate_leaderboard(); var p2_entry := _rank_entry(entries, 2)
	check(not p2_entry.is_empty() and not bool(p2_entry["online"]) and int(p2_entry["coins"]) == 2000 and int(p2_entry["property_value"]) == GameRules.property_value(2, GameRules.PROPERTY_HOTEL), "离线玩家仍保留现金、房产价值与总财富")
	game.game_ui.show_leaderboard(entries)
	check(_leaderboard_contains("Player 2（离线）"), "排行榜明确显示在线/离线状态")
	game.game_ui._close_modal(game.game_ui.leaderboard_overlay)

func _test_debug_modifier() -> void:
	game.game_ui.set_host_controls(true, game.room_wordbook_name, game.room_wordbook.size())
	check(game.game_ui.debug_button.visible, "调试修改器按钮仅供 Host 显示")
	game._show_debug_modifier()
	check(game.game_ui.active_modal == game.game_ui.debug_overlay and game.game_ui.debug_player_selector.item_count == 3, "Host 可在弹窗选择任意已加入玩家")
	var taxable_before := int(game.players_state[2]["daily_taxable_income"])
	var inventory: Dictionary = game.players_state[2]["inventory"].duplicate(true)
	for card_id in GameRules.CARD_IDS: inventory[card_id] = 7
	check(game._host_apply_debug_modifier(2, 4321, 99, inventory), "Host 可应用玩家金币、活力和全部卡牌数量")
	check(int(game.players_state[2]["coins"]) == 4321 and int(game.players_state[2]["stamina"]) == 20 and int(game.players_state[2]["inventory"][GameRules.CARD_EQUALIZE]) == 7, "调试值按金币非负、活力 0～20、卡牌非负生效")
	check(int(game.players_state[2]["daily_taxable_income"]) == taxable_before, "调试增加金币不计入 daily_taxable_income")
	game.is_host = false
	check(not game._host_apply_debug_modifier(2, 9999, 20, {}) and int(game.players_state[2]["coins"]) == 4321, "Client 不能使用调试修改器")
	game.game_ui.set_host_controls(false, game.room_wordbook_name, game.room_wordbook.size())
	check(not game.game_ui.debug_button.visible, "Client 看不到调试修改器入口")
	game.is_host = true

func _test_save_compatibility() -> void:
	check(game._save_game(), "新版存档保留所有曾加入玩家")
	var restored = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(restored); await process_frame
	restored.is_host = true; restored.save_path = SAVE; restored.save_temp_path = TEMP
	check(restored._load_game() and 2 in restored.known_player_ids and 3 in restored.known_player_ids, "Host 重启后仍保留离线玩家名单")
	var restored_rank: Dictionary = _rank_entry(restored._calculate_leaderboard(), 2)
	check(not restored_rank.is_empty() and not bool(restored_rank["online"]), "重启后离线玩家仍进入排行榜")
	restored.is_host = false

	var old_file := FileAccess.open(OLD_SAVE, FileAccess.WRITE)
	old_file.store_string(JSON.stringify({"save_version": GameRules.SAVE_VERSION - 1, "players_state": {"1": {"coins": 999999}}, "properties": []})); old_file.close()
	var reset_game = (load("res://scenes/main.tscn") as PackedScene).instantiate(); root.add_child(reset_game); await process_frame
	reset_game.is_host = true; reset_game.save_path = OLD_SAVE; reset_game.save_temp_path = OLD_TEMP
	check(not reset_game._load_game() and not reset_game.save_load_failed, "旧 save_version 自动失效且不会当作损坏存档")
	var new_file := FileAccess.open(OLD_SAVE, FileAccess.READ); var parsed = JSON.parse_string(new_file.get_as_text()); new_file.close()
	check(int(parsed["save_version"]) == GameRules.SAVE_VERSION and int(reset_game.players_state[1]["coins"]) == GameRules.INITIAL_COINS and reset_game.properties.size() == 50, "旧存档被全新 50 格存档替换")
	check(String(reset_game.properties[5]["cell_type"]) == GameRules.CELL_ENCOUNTER, "旧存档不能覆盖新版 cell_type")
	reset_game.is_host = false

func _rank_entry(entries: Array, player_id: int) -> Dictionary:
	for entry in entries:
		if int(entry["player_id"]) == player_id: return entry
	return {}

func _leaderboard_contains(text: String) -> bool:
	for child in game.game_ui.leaderboard_list.get_children():
		if child is Label and text in child.text: return true
	return false

func _cleanup() -> void:
	for path in [SAVE, TEMP, SAVE + ".bak", OLD_SAVE, OLD_TEMP, OLD_SAVE + ".bak"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
