extends RefCounted
class_name GameRules

const INITIAL_COINS := 1000
const INITIAL_STAMINA := 20
const INITIAL_PLAYER_LEVEL := 10
const ACTION_IDLE := "IDLE"
const ACTION_RESOLVING := "RESOLVING"
const BANKRUPTCY_NORMAL := "NORMAL"
const BANKRUPTCY_BANKRUPT := "BANKRUPT"
const BANKRUPTCY_PROTECTED := "PROTECTED"
const BANKRUPTCY_TAX_DEBT := "TAX_DEBT"
const BANKRUPTCY_RELIEF_COINS := 1000
const BANKRUPTCY_PROTECTION_SECONDS := 5 * 60 * 60
const DAILY_TAX_RATE := 0.10
const DAILY_TAX_HOUR := 20
const DAILY_TAX_MINUTE := 0
const SAVE_VERSION := 2
const MAX_STAMINA := 20
const STAMINA_RECOVERY_PER_HOUR := 5
const STAMINA_RECOVERY_SECONDS := 60 * 60
const QUIZ_QUESTION_COUNT := 5
const QUIZ_REWARD_PER_CORRECT := 40
const MAX_PROPERTY_LEVEL := 5
const MAX_CAPTURABLE_PROPERTY_LEVEL := 3
const CAPTURE_PRICE_MULTIPLIER := 1.2
const ASSET_SALE_RATE := 0.7

const PROPERTY_HOUSE := "HOUSE"
const PROPERTY_HOTEL := "HOTEL"

const CELL_START := "START"
const CELL_PROPERTY := "PROPERTY"
const CELL_REWARD := "REWARD"
const CELL_WHEEL := "WHEEL"
const CELL_SHOP := "SHOP"
const CELL_QUIZ := "QUIZ"

const CARD_REMOTE_DICE := "remote_dice"
const CARD_BUILD := "build_card"
const CARD_DEMOLISH := "demolish_card"
const CARD_FORCE_BUY := "force_buy_card"
const CARD_TOLL_FREE := "toll_free_card"
const CARD_REVERSE := "reverse_card"
const CARD_SPEED := "speed_card"
const CARD_EQUALIZE := "equalize_card"
const CARD_IDS := [CARD_REMOTE_DICE, CARD_BUILD, CARD_DEMOLISH, CARD_FORCE_BUY, CARD_TOLL_FREE, CARD_REVERSE, CARD_SPEED, CARD_EQUALIZE]
const CARD_NAMES := {
	CARD_REMOTE_DICE: "遥控骰子", CARD_BUILD: "建房卡", CARD_DEMOLISH: "拆房卡", CARD_FORCE_BUY: "强购卡",
	CARD_TOLL_FREE: "免租卡", CARD_REVERSE: "转向卡", CARD_SPEED: "加速卡", CARD_EQUALIZE: "均富卡",
}
const CARD_PRICES := {
	CARD_REMOTE_DICE: 200, CARD_BUILD: 300, CARD_DEMOLISH: 300, CARD_FORCE_BUY: 500,
	CARD_TOLL_FREE: 250, CARD_REVERSE: 150, CARD_SPEED: 200, CARD_EQUALIZE: 800,
}

const BUILD_COSTS := {1: 50, 2: 100, 3: 200, 4: 400, 5: 800}
const TOLL_FEES := {1: 25, 2: 50, 3: 100, 4: 200, 5: 400}
const HOTEL_BUILD_COSTS := {1: 150, 2: 300, 3: 600, 4: 1200}
const HOTEL_TOLL_FEES := {1: 75, 2: 150, 3: 300, 4: 600}
const HOTEL_MAX_LEVEL := 4
const HOTEL_CELLS := [8, 14, 21, 29]
const REWARD_COINS := 100
const WHEEL_RESULTS := [50, 100, 200, 500, -50, -100]
const WHEEL_SPIN_DURATION := 3.0
const WHEEL_FULL_SPINS := 6.0

# The complete 30-cell map layout lives here so board design changes stay data-only.
const MAP_CELL_TYPES := [
	CELL_START,     # 0
	CELL_PROPERTY, CELL_PROPERTY, CELL_PROPERTY, CELL_QUIZ,
	CELL_QUIZ,      # 5
	CELL_QUIZ, CELL_PROPERTY, CELL_PROPERTY,
	CELL_WHEEL,     # 9
	CELL_PROPERTY, CELL_QUIZ,
	CELL_QUIZ,      # 12
	CELL_QUIZ, CELL_PROPERTY,
	CELL_SHOP,      # 15
	CELL_QUIZ, CELL_PROPERTY, CELL_QUIZ,
	CELL_QUIZ,      # 19
	CELL_QUIZ, CELL_PROPERTY,
	CELL_WHEEL,     # 22
	CELL_PROPERTY, CELL_QUIZ, CELL_PROPERTY,
	CELL_QUIZ,      # 26
	CELL_QUIZ,
	CELL_SHOP,      # 28
	CELL_PROPERTY,  # 29
]

static func build_player_state(player_id: int) -> Dictionary:
	return {
		"player_id": player_id,
		"cell": 0,
		"coins": INITIAL_COINS,
		"stamina": INITIAL_STAMINA,
		"action_state": ACTION_IDLE,
		"player_level": INITIAL_PLAYER_LEVEL,
		"inventory": build_initial_inventory(),
		"toll_free_next_action": false,
		"toll_free_this_action": false,
		"reverse_next_move": false,
		"speed_next_move": false,
		"forced_next_roll": 0,
		"last_move_distance": 0,
		"last_move_was_speed": false,
		"status_effects": {"toll_free_next_action": false, "reverse_next_move": false, "speed_multiplier_next_move": 1, "forced_next_roll": 0},
		"bankruptcy_state": BANKRUPTCY_NORMAL,
		"bankrupt_date": "",
		"protection_end_time": 0,
		"daily_taxable_income": 0,
		"last_tax_date": "",
		"tax_debt": 0,
		"last_stamina_recovery_time": int(Time.get_unix_time_from_system()),
	}

static func build_initial_inventory() -> Dictionary:
	var inventory := {}
	for card_id in CARD_IDS:
		inventory[card_id] = 1
	return inventory

static func card_price(card_id: String) -> int:
	return int(CARD_PRICES.get(card_id, 0))

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
			"property_type": (PROPERTY_HOTEL if index in HOTEL_CELLS else PROPERTY_HOUSE) if MAP_CELL_TYPES[index] == CELL_PROPERTY else "",
		})
	return result

static func build_cost(property_level: int, property_type: String = PROPERTY_HOUSE) -> int:
	return int((HOTEL_BUILD_COSTS if property_type == PROPERTY_HOTEL else BUILD_COSTS).get(property_level, 0))

static func toll_fee(property_level: int, property_type: String = PROPERTY_HOUSE) -> int:
	return int((HOTEL_TOLL_FEES if property_type == PROPERTY_HOTEL else TOLL_FEES).get(property_level, 0))

static func purchase_price(property_type: String = PROPERTY_HOUSE) -> int:
	return build_cost(1, property_type)

static func upgrade_price(current_property_level: int, property_type: String = PROPERTY_HOUSE) -> int:
	return build_cost(current_property_level + 1, property_type)

static func capture_base_price(property_level: int, capture_count: int, property_type: String = PROPERTY_HOUSE) -> int:
	return build_cost(property_level, property_type) * (capture_count + 1)

static func capture_price(property_level: int, capture_count: int, property_type: String = PROPERTY_HOUSE) -> int:
	return roundi(float(capture_base_price(property_level, capture_count, property_type)) * CAPTURE_PRICE_MULTIPLIER)

static func capture_seller_income(property_level: int, capture_count: int, property_type: String = PROPERTY_HOUSE) -> int:
	return capture_base_price(property_level, capture_count, property_type)

static func capture_owner_payout(capture_price_value: int) -> int:
	# Compatibility for callers that only have the final buyer price.
	return roundi(float(capture_price_value) / CAPTURE_PRICE_MULTIPLIER)

static func max_property_level(property_type: String) -> int:
	return HOTEL_MAX_LEVEL if property_type == PROPERTY_HOTEL else MAX_PROPERTY_LEVEL

static func can_upgrade_property(player_level: int, property_level: int, property_type: String = PROPERTY_HOUSE) -> bool:
	return property_level < max_property_level(property_type) and player_level >= property_level + 1

static func property_value(property_level: int, property_type: String = PROPERTY_HOUSE) -> int:
	return build_cost(property_level, property_type)

static func asset_recovery(value: int) -> int:
	return roundi(float(value) * ASSET_SALE_RATE)

static func daily_tax(income: int) -> int:
	return roundi(float(maxi(0, income)) * DAILY_TAX_RATE)

static func hotel_landing_stamina_cost(property_level: int) -> int:
	return 1 if property_level <= 2 else 2

static func can_force_buy(property_type: String, property_level: int) -> bool:
	return property_type == PROPERTY_HOUSE and property_level >= 1 and property_level <= MAX_CAPTURABLE_PROPERTY_LEVEL

static func is_wheel_result_valid(result: int) -> bool:
	return result in WHEEL_RESULTS
