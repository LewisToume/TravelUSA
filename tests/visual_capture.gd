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

	game.start_local_test_game()
	await process_frame
	_save_view("res://artifacts/game_view.png")
	quit(0)


func _save_view(path: String) -> void:
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		print("CAPTURED | ", path, " | ", image.get_size())
	else:
		push_error("Could not save capture: %s (error %d)" % [path, error])
