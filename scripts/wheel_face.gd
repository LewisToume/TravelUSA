extends Control
class_name WheelFace

signal spin_finished

const SECTOR_COLORS := [
	Color("41b883"),
	Color("4b9fe1"),
	Color("7e6de0"),
	Color("df6f9f"),
	Color("e36b5d"),
	Color("e2a84a"),
]

var _spin_tween: Tween

func _ready() -> void:
	resized.connect(_update_pivot)
	_update_pivot()
	queue_redraw()

func _update_pivot() -> void:
	pivot_offset = size * 0.5
	queue_redraw()

func reset_wheel() -> void:
	if _spin_tween and _spin_tween.is_valid():
		_spin_tween.kill()
	rotation = 0.0

func spin_to_result(result: int, duration: float) -> void:
	var result_index := GameRules.WHEEL_RESULTS.find(result)
	if result_index < 0:
		push_error("Unknown wheel result: %d" % result)
		return
	if _spin_tween and _spin_tween.is_valid():
		_spin_tween.kill()
	var sector_angle := TAU / float(GameRules.WHEEL_RESULTS.size())
	var desired_rotation := -float(result_index) * sector_angle
	var current_mod := fposmod(rotation, TAU)
	var forward_delta := fposmod(desired_rotation - current_mod, TAU)
	var target_rotation := rotation + GameRules.WHEEL_FULL_SPINS * TAU + forward_delta
	_spin_tween = create_tween()
	_spin_tween.set_trans(Tween.TRANS_QUART)
	_spin_tween.set_ease(Tween.EASE_OUT)
	_spin_tween.tween_property(self, "rotation", target_rotation, duration)
	await _spin_tween.finished
	rotation = fposmod(desired_rotation, TAU)
	spin_finished.emit()

func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.46
	var sector_count := GameRules.WHEEL_RESULTS.size()
	var sector_angle := TAU / float(sector_count)
	for index in range(sector_count):
		var middle_angle := -PI * 0.5 + float(index) * sector_angle
		var start_angle := middle_angle - sector_angle * 0.5
		var points := PackedVector2Array([center])
		for segment in range(13):
			var angle := start_angle + sector_angle * float(segment) / 12.0
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_colored_polygon(points, SECTOR_COLORS[index])
		draw_line(center, center + Vector2(cos(start_angle), sin(start_angle)) * radius, Color("17242b"), 4.0, true)
		var value := int(GameRules.WHEEL_RESULTS[index])
		var label := "+%d" % value if value > 0 else str(value)
		var font := ThemeDB.fallback_font
		var font_size := 28
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		var label_center := center + Vector2(cos(middle_angle), sin(middle_angle)) * radius * 0.65
		draw_string(font, label_center + Vector2(-text_size.x * 0.5, text_size.y * 0.32), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
	draw_arc(center, radius, 0.0, TAU, 96, Color("dcebf2"), 7.0, true)
	draw_circle(center, radius * 0.16, Color("17242b"))
	draw_circle(center, radius * 0.09, Color("f2c94c"))
