extends Node2D
class_name BoardPath

signal target_cell_selected(cell_index: int)

@export_range(8, 100, 1) var cell_count: int = 30
@export_range(120.0, 600.0, 10.0) var cell_spacing: float = 320.0
@export_range(60.0, 240.0, 5.0) var cell_size: float = 150.0
@export_range(1.0, 2.5, 0.01) var route_aspect_ratio: float = 1.63
@export_range(1000.0, 3000.0, 50.0) var background_margin: float = 1600.0

var _cell_positions: PackedVector2Array = PackedVector2Array()
var _route_bounds: Rect2
var property_states: Array = []
var building_effects: Dictionary = {}
var selectable_cells: Array[int] = []
var selection_active := false

const BACKGROUND_COLOR := Color("132331")
const GRID_COLOR := Color(0.16, 0.25, 0.31, 0.5)
const ROAD_COLOR := Color("304a58")
const ROAD_EDGE_COLOR := Color("6e98a8")
const EMPTY_PROPERTY_COLOR := Color("aab6bb")
const PLAYER_COLORS := [Color("55aee8"), Color("e879a9"), Color("f2994a"), Color("6fcf97"), Color("bb6bd9"), Color("56ccf2")]
const REWARD_COLOR := Color("f2c94c")
const WHEEL_COLOR := Color("9b72e8")
const SHOP_COLOR := Color("f29d49")
const START_COLOR := Color("65d394")
const CELL_BORDER_COLOR := Color("18323e")


func _ready() -> void:
	_rebuild_path()
	set_process(true)
	queue_redraw()

func _process(_delta: float) -> void:
	if selection_active:
		queue_redraw()

func set_selectable_cells(cells: Array[int]) -> void:
	selectable_cells = cells.duplicate()
	selection_active = true
	queue_redraw()

func clear_target_selection() -> void:
	selectable_cells.clear()
	selection_active = false
	queue_redraw()

func _unhandled_input(event: InputEvent) -> void:
	if not selection_active:
		return
	var screen_position := Vector2.ZERO
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		screen_position = event.position
	elif event is InputEventScreenTouch and event.pressed:
		screen_position = event.position
	else:
		return
	var world_position := get_canvas_transform().affine_inverse() * screen_position
	var closest := -1
	var closest_distance := INF
	for cell_index in selectable_cells:
		var distance := world_position.distance_to(get_building_anchor(cell_index))
		if distance < closest_distance:
			closest = cell_index
			closest_distance = distance
	if closest >= 0 and closest_distance <= cell_size * 0.75:
		target_cell_selected.emit(closest)
		get_viewport().set_input_as_handled()


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

func get_building_anchor(index: int) -> Vector2:
	var current := get_cell_position(index)
	var previous := get_cell_position(index - 1)
	var following := get_cell_position(index + 1)
	var tangent := (following - previous).normalized()
	var normal := Vector2(-tangent.y, tangent.x)
	if normal.dot(current - _route_bounds.get_center()) < 0.0:
		normal = -normal
	return current + normal * (cell_size * 0.92)


func get_route_bounds() -> Rect2:
	return _route_bounds

func set_property_states(states: Array) -> void:
	property_states = states.duplicate(true)
	queue_redraw()

func play_building_effect(cell_index: int, effect_type: String) -> void:
	building_effects[cell_index] = {"type": effect_type, "started": Time.get_ticks_msec()}
	queue_redraw()
	await get_tree().create_timer(0.55).timeout
	building_effects.erase(cell_index)
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
		var cell_type := String(property.get("cell_type", GameRules.CELL_PROPERTY))
		var owner_id := int(property.get("owner_id", -1))
		var property_level := int(property.get("property_level", 0))
		var fill_color := EMPTY_PROPERTY_COLOR
		if cell_type == GameRules.CELL_START:
			fill_color = START_COLOR
		elif cell_type == GameRules.CELL_REWARD:
			fill_color = REWARD_COLOR
		elif cell_type == GameRules.CELL_WHEEL:
			fill_color = WHEEL_COLOR
		elif cell_type == GameRules.CELL_SHOP:
			fill_color = SHOP_COLOR
		draw_rect(rect, fill_color, true)
		draw_rect(rect, CELL_BORDER_COLOR, false, 6.0)
		draw_string(font, rect.position + Vector2(10.0, 28.0), str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 21, CELL_BORDER_COLOR)
		var center_text := ""
		if cell_type == GameRules.CELL_REWARD:
			center_text = "奖励"
		elif cell_type == GameRules.CELL_WHEEL:
			center_text = "转盘"
		elif cell_type == GameRules.CELL_START:
			center_text = "起点"
		elif cell_type == GameRules.CELL_SHOP:
			center_text = "商店"
		if not center_text.is_empty():
			var text_size := font.get_string_size(center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.32)
			draw_string(font, baseline, center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, CELL_BORDER_COLOR)
		if cell_type == GameRules.CELL_PROPERTY and owner_id >= 1 and property_level >= 1:
			_draw_building(get_building_anchor(index), owner_id, property_level)
			if building_effects.has(index):
				_draw_building_effect(get_building_anchor(index), String(building_effects[index]["type"]))
		if selection_active and cell_type == GameRules.CELL_PROPERTY:
			if index in selectable_cells:
				var pulse := 9.0 + 5.0 * sin(float(Time.get_ticks_msec()) * 0.007)
				draw_circle(get_building_anchor(index), cell_size * 0.55 + pulse, Color(1.0, 0.9, 0.25, 0.18))
				draw_arc(get_building_anchor(index), cell_size * 0.55 + pulse, 0.0, TAU, 40, Color("ffe45c"), 7.0)
			else:
				draw_circle(get_building_anchor(index), cell_size * 0.5, Color(0.02, 0.03, 0.05, 0.58))

func _draw_building_effect(anchor: Vector2, effect_type: String) -> void:
	var color := Color(0.9, 0.95, 1.0, 0.7) if effect_type == "upgrade" else Color(0.55, 0.55, 0.55, 0.7)
	for offset in [Vector2(-24, -48), Vector2(8, -76), Vector2(30, -38)]:
		draw_circle(anchor + offset, 16.0, color)

func _draw_building(anchor: Vector2, owner_id: int, level: int) -> void:
	var color: Color = PLAYER_COLORS[posmod(owner_id - 1, PLAYER_COLORS.size())]
	var width := 44.0 + float(level) * 9.0
	var floor_height := 23.0
	var floors := level if level <= 3 else level + 1
	var height := floor_height * float(floors)
	var body := Rect2(anchor + Vector2(-width * 0.5, -height), Vector2(width, height))
	draw_rect(body, color, true)
	draw_rect(body, CELL_BORDER_COLOR, false, 4.0)
	if level <= 2:
		var roof := PackedVector2Array([body.position + Vector2(-8, 0), body.position + Vector2(width * 0.5, -24), body.position + Vector2(width + 8, 0)])
		draw_colored_polygon(roof, color.lightened(0.18))
		draw_polyline(PackedVector2Array([roof[0], roof[1], roof[2]]), CELL_BORDER_COLOR, 4.0)
	for floor_index in range(floors):
		var y := body.end.y - 14.0 - floor_index * floor_height
		draw_rect(Rect2(Vector2(anchor.x - width * 0.27, y - 7), Vector2(11, 13)), Color("d9f3ff"), true)
		draw_rect(Rect2(Vector2(anchor.x + width * 0.10, y - 7), Vector2(11, 13)), Color("d9f3ff"), true)
	var level_text := "L%d" % level
	draw_string(ThemeDB.fallback_font, anchor + Vector2(-15, 22), level_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, color)


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
