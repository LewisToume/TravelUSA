extends Node2D
class_name BoardPath

@export_range(8, 100, 1) var cell_count: int = 30
@export_range(120.0, 600.0, 10.0) var cell_spacing: float = 320.0
@export_range(60.0, 240.0, 5.0) var cell_size: float = 150.0
@export_range(1.0, 2.5, 0.01) var route_aspect_ratio: float = 1.63
@export_range(1000.0, 3000.0, 50.0) var background_margin: float = 1600.0

var _cell_positions: PackedVector2Array = PackedVector2Array()
var _route_bounds: Rect2
var property_states: Array = []

const BACKGROUND_COLOR := Color("132331")
const GRID_COLOR := Color(0.16, 0.25, 0.31, 0.5)
const ROAD_COLOR := Color("304a58")
const ROAD_EDGE_COLOR := Color("6e98a8")
const EMPTY_PROPERTY_COLOR := Color("aab6bb")
const PLAYER_1_PROPERTY_COLOR := Color("55aee8")
const PLAYER_2_PROPERTY_COLOR := Color("e879a9")
const START_COLOR := Color("65d394")
const CELL_BORDER_COLOR := Color("18323e")


func _ready() -> void:
	_rebuild_path()
	queue_redraw()


func _rebuild_path() -> void:
	_cell_positions.clear()
	var perimeter := float(cell_count) * cell_spacing
	var half_perimeter := perimeter * 0.5
	var board_width := half_perimeter * route_aspect_ratio / (route_aspect_ratio + 1.0)
	var board_height := half_perimeter - board_width
	var top_left := Vector2(-board_width * 0.5, -board_height * 0.5)

	for index in range(cell_count):
		var distance := float(index) * perimeter / float(cell_count)
		_cell_positions.append(_point_on_rectangle(distance, board_width, board_height, top_left))

	_route_bounds = Rect2(top_left, Vector2(board_width, board_height))


func _point_on_rectangle(distance: float, width: float, height: float, top_left: Vector2) -> Vector2:
	if distance < width:
		return top_left + Vector2(distance, 0.0)
	distance -= width
	if distance < height:
		return top_left + Vector2(width, distance)
	distance -= height
	if distance < width:
		return top_left + Vector2(width - distance, height)
	distance -= width
	return top_left + Vector2(0.0, height - distance)


func get_cell_position(index: int) -> Vector2:
	assert(not _cell_positions.is_empty(), "Board path must be initialized before use.")
	return _cell_positions[posmod(index, _cell_positions.size())]


func get_cell_count() -> int:
	return _cell_positions.size()


func get_route_bounds() -> Rect2:
	return _route_bounds

func set_property_states(states: Array) -> void:
	property_states = states.duplicate(true)
	queue_redraw()


func _draw() -> void:
	if _cell_positions.is_empty():
		return

	var world_rect := _route_bounds.grow(background_margin)
	draw_rect(world_rect, BACKGROUND_COLOR)
	_draw_background_grid(world_rect)

	var loop_points := _cell_positions.duplicate()
	loop_points.append(_cell_positions[0])
	draw_polyline(loop_points, ROAD_EDGE_COLOR, cell_size * 0.78, true)
	draw_polyline(loop_points, ROAD_COLOR, cell_size * 0.64, true)

	var font := ThemeDB.fallback_font
	var font_size := 30
	for index in range(_cell_positions.size()):
		var center := _cell_positions[index]
		var rect := Rect2(center - Vector2.ONE * cell_size * 0.5, Vector2.ONE * cell_size)
		var property: Dictionary = property_states[index] if index < property_states.size() else {}
		var owner_id := int(property.get("owner_id", -1))
		var property_level := int(property.get("property_level", 0))
		var fill_color := EMPTY_PROPERTY_COLOR
		if index == 0:
			fill_color = START_COLOR
		elif owner_id == 1:
			fill_color = PLAYER_1_PROPERTY_COLOR
		elif owner_id == 2:
			fill_color = PLAYER_2_PROPERTY_COLOR
		draw_rect(rect, fill_color, true)
		draw_rect(rect, CELL_BORDER_COLOR, false, 6.0)
		draw_string(font, rect.position + Vector2(10.0, 28.0), str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 21, CELL_BORDER_COLOR)
		if property_level > 0:
			var level_text := "L%d" % property_level
			var text_size := font.get_string_size(level_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.32)
			draw_string(font, baseline, level_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, CELL_BORDER_COLOR)


func _draw_background_grid(rect: Rect2) -> void:
	var grid_step := cell_spacing
	var start_x: float = floorf(rect.position.x / grid_step) * grid_step
	var start_y: float = floorf(rect.position.y / grid_step) * grid_step
	var x: float = start_x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), GRID_COLOR, 2.0)
		x += grid_step
	var y: float = start_y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), GRID_COLOR, 2.0)
		y += grid_step
