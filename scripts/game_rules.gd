extends RefCounted
class_name GameRules

const INITIAL_COINS := 1000
const INITIAL_STAMINA := 20
const INITIAL_PLAYER_LEVEL := 10
const ACTION_IDLE := "IDLE"
const ACTION_RESOLVING := "RESOLVING"
const MAX_PROPERTY_LEVEL := 5
const MAX_CAPTURABLE_PROPERTY_LEVEL := 3
const CAPTURE_OWNER_SHARE := 0.8

const CELL_START := "START"
const CELL_PROPERTY := "PROPERTY"
const CELL_REWARD := "REWARD"
const CELL_WHEEL := "WHEEL"

const BUILD_COSTS := {1: 50, 2: 100, 3: 200, 4: 400, 5: 800}
const TOLL_FEES := {1: 25, 2: 50, 3: 100, 4: 200, 5: 400}
const REWARD_COINS := 100
const WHEEL_RESULTS := [50, 100, 200, 500, -50, -100]
const WHEEL_SPIN_DURATION := 3.0
const WHEEL_FULL_SPINS := 6.0

# The complete 30-cell map layout lives here so board design changes stay data-only.
const MAP_CELL_TYPES := [
	CELL_START,
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY,
	CELL_REWARD,
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY,
	CELL_WHEEL,
	CELL_PROPERTY, CELL_PROPERTY,
	CELL_REWARD,
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY,
	CELL_REWARD,
	CELL_PROPERTY, CELL_PROPERTY,
	CELL_WHEEL,
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY,
	CELL_REWARD,
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY,
]

static func build_player_state(player_id: int) -> Dictionary:
	return {
		"player_id": player_id,
		"cell": 0,
		"coins": INITIAL_COINS,
		"stamina": INITIAL_STAMINA,
		"action_state": ACTION_IDLE,
		"player_level": INITIAL_PLAYER_LEVEL,
	}

static func build_cells(cell_count: int) -> Array[Dictionary]:
	assert(cell_count == MAP_CELL_TYPES.size(), "Board cell count must match MAP_CELL_TYPES.")
	var result: Array[Dictionary] = []
	for index in range(cell_count):
		result.append({
			"cell_index": index,
			"cell_type": MAP_CELL_TYPES[index],
			"owner_id": -1,
			"property_level": 0,
			"capture_count": 0,
		})
	return result

static func build_cost(property_level: int) -> int:
	return int(BUILD_COSTS.get(property_level, 0))

static func toll_fee(property_level: int) -> int:
	return int(TOLL_FEES.get(property_level, 0))

static func purchase_price() -> int:
	return build_cost(1)

static func upgrade_price(current_property_level: int) -> int:
	return build_cost(current_property_level + 1)

static func capture_price(property_level: int, capture_count: int) -> int:
	return build_cost(property_level) * (capture_count + 1)

static func capture_owner_payout(capture_price_value: int) -> int:
	return roundi(float(capture_price_value) * CAPTURE_OWNER_SHARE)

static func can_upgrade_property(player_level: int, property_level: int) -> bool:
	return property_level < MAX_PROPERTY_LEVEL and player_level >= property_level + 1

static func is_wheel_result_valid(result: int) -> bool:
	return result in WHEEL_RESULTS
