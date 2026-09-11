extends Control

func _draw() -> void:
	var x := size.x * 0.5
	var points := PackedVector2Array([
		Vector2(x - 25.0, 5.0),
		Vector2(x + 25.0, 5.0),
		Vector2(x, 65.0),
	])
	draw_colored_polygon(points, Color("ffdf5d"))
	draw_polyline(PackedVector2Array([points[0], points[1], points[2], points[0]]), Color("402b10"), 5.0, true)
