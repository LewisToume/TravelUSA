extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	var game = packed.instantiate()
	root.add_child(game)

	for _frame in range(4):
		await process_frame
	_save_view("res://artifacts/startup_view.png")

	game.test_mode = true
	game.test_wheel_result_override = 200
	game.test_wheel_spin_duration = 0.8
	game.player_1.move_speed_pixels_per_second = 100000.0
	game.player_1.minimum_step_duration = 0.001
	game.start_local_test_game()
	game.request_test_roll(9)
	while game.phase != "wheel_ready":
		await process_frame
	_save_view("res://artifacts/game_view.png")
	game.request_wheel_spin()
	await create_timer(0.16).timeout
	_save_view("res://artifacts/wheel_spinning_view.png")
	while game.phase != "wheel_result":
		await process_frame
	_save_view("res://artifacts/wheel_result_view.png")
	quit(0)


func _save_view(path: String) -> void:
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("CAPTURED | ", path, " | ", image.get_size())
	else:
		push_error("Could not save capture: %s (error %d)" % [path, error])
