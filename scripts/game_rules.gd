extends RefCounted
class_name GameRules

const INITIAL_COINS := 10000
const INITIAL_DIAMONDS := 100
const INITIAL_PLAYER_LEVEL := 10
const MAX_PROPERTY_LEVEL := 5
const PURCHASE_PRICE := 1000

static func build_player_state() -> Dictionary:
	return {"cell": 0, "coins": INITIAL_COINS, "diamonds": INITIAL_DIAMONDS, "player_level": INITIAL_PLAYER_LEVEL}

static func build_properties(cell_count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(cell_count):
		result.append({"cell_index": index, "owner_id": -1, "property_level": 0, "capture_count": 0})
	return result

static func base_build_price(property_level: int) -> int:
	return clampi(property_level, 1, MAX_PROPERTY_LEVEL) * 1000

static func upgrade_price(current_property_level: int) -> int:
	return base_build_price(current_property_level + 1)

static func capture_price(property_level: int, capture_count: int) -> int:
	return base_build_price(property_level) * (capture_count + 1)

static func can_upgrade_property(player_level: int, property_level: int) -> bool:
	return property_level < MAX_PROPERTY_LEVEL and player_level >= property_level + 1
