extends Node2D
class_name BoardPath
const PSEUDO_3D_ENABLED := true

signal target_cell_selected(cell_index: int)

@export_range(8, 100, 1) var cell_count: int = 50
@export_range(120.0, 600.0, 10.0) var cell_spacing: float = 320.0
@export_range(60.0, 240.0, 5.0) var cell_size: float = 150.0
@export_range(1000.0, 3000.0, 50.0) var background_margin: float = 1600.0

const EXPLICIT_CELL_POSITIONS := [
	Vector2(-2150, -1000), Vector2(-1900, -1100), Vector2(-1660, -1160), Vector2(-1420, -1120), Vector2(-1190, -1000),
	Vector2(-970, -860), Vector2(-750, -990), Vector2(-520, -1130), Vector2(-280, -1220), Vector2(-30, -1240),
	Vector2(220, -1190), Vector2(450, -1080), Vector2(660, -930), Vector2(900, -1040), Vector2(1140, -1120),
	Vector2(1380, -1080), Vector2(1610, -970), Vector2(1820, -820), Vector2(2010, -640), Vector2(2160, -430),
	Vector2(2220, -190), Vector2(2110, 30), Vector2(2240, 250), Vector2(2200, 500), Vector2(2070, 720),
	Vector2(1880, 900), Vector2(1650, 1010), Vector2(1410, 1040), Vector2(1190, 950), Vector2(970, 1080),
	Vector2(730, 1180), Vector2(480, 1200), Vector2(240, 1130), Vector2(20, 990), Vector2(-210, 1100),
	Vector2(-450, 1190), Vector2(-700, 1160), Vector2(-930, 1060), Vector2(-1140, 910), Vector2(-1370, 1030),
	Vector2(-1610, 1000), Vector2(-1830, 890), Vector2(-2020, 730), Vector2(-2170, 530), Vector2(-2250, 290),
	Vector2(-2160, 50), Vector2(-2290, -180), Vector2(-2240, -430), Vector2(-2140, -650), Vector2(-2350, -820),
]

var _cell_positions: PackedVector2Array = PackedVector2Array()
var _route_bounds: Rect2
var property_states: Array = []
var building_effects: Dictionary = {}
var selectable_cells: Array[int] = []
var selection_active := false

const BACKGROUND_COLOR := Color("f4dfae")
const GRID_COLOR := Color(0.55, 0.38, 0.20, 0.18)
const ROAD_COLOR := Color("d9b879")
const ROAD_EDGE_COLOR := Color("9d6c39")
const EMPTY_PROPERTY_COLOR := Color("ead7ad")
const PLAYER_COLORS := [Color("65b9ed"), Color("f08caf"), Color("f5a856"), Color("78d49b"), Color("c796e8"), Color("70d6df")]
const REWARD_COLOR := Color("f5cf59")
const WHEEL_COLOR := Color("c39be8")
const SHOP_COLOR := Color("f3a75f")
const START_COLOR := Color("83d59e")
const QUIZ_COLOR := Color("78d4c5")
const ENCOUNTER_COLOR := Color("ef8f71")
const CELL_BORDER_COLOR := Color("684223")


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
	assert(cell_count == EXPLICIT_CELL_POSITIONS.size(), "Board cell_count must match explicit coordinates.")
	for point in EXPLICIT_CELL_POSITIONS: _cell_positions.append(point)
	var minimum := _cell_positions[0]
	var maximum := _cell_positions[0]
	for point in _cell_positions:
		minimum = Vector2(minf(minimum.x, point.x), minf(minimum.y, point.y))
		maximum = Vector2(maxf(maximum.x, point.x), maxf(maximum.y, point.y))
	_route_bounds = Rect2(minimum, maximum - minimum)


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
		var property_type := String(property.get("property_type", GameRules.PROPERTY_HOUSE))
		var fill_color := EMPTY_PROPERTY_COLOR
		if cell_type == GameRules.CELL_START:
			fill_color = START_COLOR
		elif cell_type == GameRules.CELL_REWARD:
			fill_color = REWARD_COLOR
		elif cell_type == GameRules.CELL_WHEEL:
			fill_color = WHEEL_COLOR
		elif cell_type == GameRules.CELL_SHOP:
			fill_color = SHOP_COLOR
		elif cell_type == GameRules.CELL_QUIZ:
			fill_color = QUIZ_COLOR
		elif cell_type == GameRules.CELL_ENCOUNTER:
			fill_color = ENCOUNTER_COLOR
		var depth := Vector2(11.0, 14.0)
		draw_rect(Rect2(rect.position + depth + Vector2(3, 4), rect.size), Color(0.35, 0.22, 0.10, 0.22), true)
		draw_colored_polygon(PackedVector2Array([rect.end - Vector2(rect.size.x, 0), rect.end, rect.end + depth, rect.end - Vector2(rect.size.x, 0) + depth]), fill_color.darkened(0.28))
		draw_colored_polygon(PackedVector2Array([Vector2(rect.end.x, rect.position.y), rect.end, rect.end + depth, Vector2(rect.end.x, rect.position.y) + depth]), fill_color.darkened(0.38))
		draw_rect(rect, fill_color, true)
		draw_rect(rect, CELL_BORDER_COLOR, false, 6.0)
		draw_string(font, rect.position + Vector2(10.0, 28.0), str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 21, CELL_BORDER_COLOR)
		var center_text := get_cell_display_text(cell_type, String(property.get("encounter_type", GameRules.ENCOUNTER_NONE)))
		if not center_text.is_empty():
			var text_size := font.get_string_size(center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
			var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.32)
			draw_string(font, baseline, center_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, CELL_BORDER_COLOR)
		if cell_type == GameRules.CELL_PROPERTY and owner_id >= 1 and property_level >= 1:
			_draw_building(get_building_anchor(index), owner_id, property_level, property_type)
			if building_effects.has(index):
				_draw_building_effect(get_building_anchor(index), String(building_effects[index]["type"]))
		if selection_active and cell_type == GameRules.CELL_PROPERTY:
			if index in selectable_cells:
				var pulse := 9.0 + 5.0 * sin(float(Time.get_ticks_msec()) * 0.007)
				draw_circle(get_building_anchor(index), cell_size * 0.55 + pulse, Color(1.0, 0.9, 0.25, 0.18))
				draw_arc(get_building_anchor(index), cell_size * 0.55 + pulse, 0.0, TAU, 40, Color("ffe45c"), 7.0)
			else:
				draw_circle(get_building_anchor(index), cell_size * 0.5, Color(0.02, 0.03, 0.05, 0.58))

func get_cell_display_text(cell_type: String, encounter_type: String = GameRules.ENCOUNTER_NONE) -> String:
	if cell_type == GameRules.CELL_ENCOUNTER:
		return GameRules.encounter_display_name(encounter_type)
	return {
		GameRules.CELL_START: "起点",
		GameRules.CELL_WHEEL: "转盘",
		GameRules.CELL_SHOP: "商店",
		GameRules.CELL_QUIZ: "答题",
	}.get(cell_type, "")

func _draw_building_effect(anchor: Vector2, effect_type: String) -> void:
	var color := Color(0.9, 0.95, 1.0, 0.7) if effect_type == "upgrade" else Color(0.55, 0.55, 0.55, 0.7)
	for offset in [Vector2(-24, -48), Vector2(8, -76), Vector2(30, -38)]:
		draw_circle(anchor + offset, 16.0, color)

func _draw_building(anchor: Vector2, owner_id: int, level: int, property_type: String = GameRules.PROPERTY_HOUSE) -> void:
	var color: Color = PLAYER_COLORS[posmod(owner_id - 1, PLAYER_COLORS.size())]
	var is_hotel := property_type == GameRules.PROPERTY_HOTEL
	var width := (68.0 if is_hotel else 44.0) + float(level) * (11.0 if is_hotel else 9.0)
	var floor_height := 27.0 if is_hotel else 23.0
	var floors := level + 1 if is_hotel else (level if level <= 3 else level + 1)
	var height := floor_height * float(floors)
	var body := Rect2(anchor + Vector2(-width * 0.5, -height), Vector2(width, height))
	var depth := Vector2(16.0, 11.0)
	draw_rect(Rect2(body.position + Vector2(12, 17), body.size + Vector2(8, 3)), Color(0.30, 0.18, 0.08, 0.25), true)
	draw_colored_polygon(PackedVector2Array([Vector2(body.end.x, body.position.y), body.end, body.end + depth, Vector2(body.end.x, body.position.y) + depth]), color.darkened(0.34))
	draw_rect(body, color, true)
	draw_rect(body, CELL_BORDER_COLOR, false, 4.0)
	if is_hotel:
		var roof := PackedVector2Array([body.position + Vector2(-10, 0), body.position + Vector2(10, -20), body.position + Vector2(width + 14, -20), body.position + Vector2(width, 0)])
		draw_colored_polygon(roof, Color("f7cc72"))
		draw_polyline(PackedVector2Array([roof[0], roof[1], roof[2], roof[3], roof[0]]), CELL_BORDER_COLOR, 4.0)
		draw_string(ThemeDB.fallback_font, body.position + Vector2(width * 0.18, -3), "HOTEL", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, CELL_BORDER_COLOR)
	elif level <= 2:
		var roof := PackedVector2Array([body.position + Vector2(-8, 0), body.position + Vector2(width * 0.5, -24), body.position + Vector2(width + 8, 0)])
		draw_colored_polygon(roof, color.lightened(0.18))
		draw_polyline(PackedVector2Array([roof[0], roof[1], roof[2]]), CELL_BORDER_COLOR, 4.0)
	else:
		var roof := PackedVector2Array([body.position + Vector2(-7, 0), body.position + Vector2(9, -14), body.position + Vector2(width + 10, -14), body.position + Vector2(width, 0)])
		draw_colored_polygon(roof, color.lightened(0.25))
		draw_polyline(PackedVector2Array([roof[0], roof[1], roof[2], roof[3], roof[0]]), CELL_BORDER_COLOR, 3.0)
	for floor_index in range(floors):
		var y := body.end.y - 14.0 - floor_index * floor_height
		draw_rect(Rect2(Vector2(anchor.x - width * 0.27, y - 7), Vector2(11, 13)), Color("d9f3ff"), true)
		draw_rect(Rect2(Vector2(anchor.x + width * 0.10, y - 7), Vector2(11, 13)), Color("d9f3ff"), true)
	var level_text := "%s L%d" % ["H" if is_hotel else "", level]
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
