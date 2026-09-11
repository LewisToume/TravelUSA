extends RefCounted
class_name QuestionBank

const TYPE_EN_TO_ZH := "EN_TO_ZH"
const TYPE_ZH_TO_EN := "ZH_TO_EN"
const TYPE_SPELLING := "SPELLING"
const WORD_HEADERS := ["word", "单词", "英文", "vocabulary", "term"]
const MEANING_HEADERS := ["meaning", "中文", "释义", "翻译", "definition"]

const DEFAULT_ENTRIES := [
	{"word": "apple", "meaning": "苹果"}, {"word": "book", "meaning": "书"},
	{"word": "camera", "meaning": "相机"}, {"word": "dream", "meaning": "梦想"},
	{"word": "earth", "meaning": "地球"}, {"word": "family", "meaning": "家庭"},
	{"word": "garden", "meaning": "花园"}, {"word": "happy", "meaning": "快乐的"},
	{"word": "island", "meaning": "岛屿"}, {"word": "journey", "meaning": "旅程"},
	{"word": "knowledge", "meaning": "知识"}, {"word": "language", "meaning": "语言"},
	{"word": "mountain", "meaning": "山"}, {"word": "nature", "meaning": "自然"},
	{"word": "ocean", "meaning": "海洋"}, {"word": "people", "meaning": "人们"},
	{"word": "question", "meaning": "问题"}, {"word": "river", "meaning": "河流"},
	{"word": "school", "meaning": "学校"}, {"word": "travel", "meaning": "旅行"},
	{"word": "umbrella", "meaning": "雨伞"}, {"word": "village", "meaning": "村庄"},
	{"word": "window", "meaning": "窗户"}, {"word": "yellow", "meaning": "黄色"},
]

static func default_entries() -> Array:
	return DEFAULT_ENTRIES.duplicate(true)

static func parse_content(content: String, extension: String) -> Dictionary:
	return parse_csv(content) if extension.to_lower() == "csv" else parse_txt(content)

static func parse_csv(content: String) -> Dictionary:
	var lines := content.replace("\r\n", "\n").replace("\r", "\n").split("\n", true)
	if lines.is_empty(): return _parse_result([], 0)
	var headers := _parse_csv_line(String(lines[0]))
	var word_index := -1
	var meaning_index := -1
	for index in range(headers.size()):
		var header := String(headers[index]).strip_edges().trim_prefix("﻿").to_lower()
		if header in WORD_HEADERS: word_index = index
		if header in MEANING_HEADERS: meaning_index = index
	if word_index < 0 or meaning_index < 0:
		return _parse_result([], maxi(0, lines.size() - 1))
	var entries: Array = []
	var failed := 0
	for line_index in range(1, lines.size()):
		var line := String(lines[line_index]).strip_edges()
		if line.is_empty(): continue
		var columns := _parse_csv_line(line)
		if word_index >= columns.size() or meaning_index >= columns.size() or not _append_entry(entries, String(columns[word_index]), String(columns[meaning_index])):
			failed += 1
	return _parse_result(entries, failed)

static func parse_txt(content: String) -> Dictionary:
	var entries: Array = []
	var failed := 0
	var expression := RegEx.new()
	expression.compile("^\\s*([A-Za-z][A-Za-z'\\-]*(?:\\s+[A-Za-z][A-Za-z'\\-]*)*)\\s*(?:[-–—:=：,，\\t]\\s*|\\s+)([^\\r\\n]+?)\\s*$")
	for raw_line in content.replace("\r\n", "\n").replace("\r", "\n").split("\n", true):
		var line := String(raw_line).strip_edges()
		if line.is_empty(): continue
		var matched := expression.search(line)
		if matched == null or not _contains_cjk(matched.get_string(2)) or not _append_entry(entries, matched.get_string(1), matched.get_string(2)):
			failed += 1
	return _parse_result(entries, failed)

static func build_question(entry: Dictionary, all_entries: Array, question_type: String, random: RandomNumberGenerator) -> Dictionary:
	var word := String(entry.get("word", ""))
	var meaning := String(entry.get("meaning", ""))
	var question := ""
	var correct_answer := ""
	var distractor_key := "meaning"
	if question_type == TYPE_ZH_TO_EN:
		question = "%s\n对应哪个英文单词？" % meaning
		correct_answer = word
		distractor_key = "word"
	elif question_type == TYPE_SPELLING:
		var spelling := _build_spelling(word, random)
		question = "%s\n%s\n请选择缺失字母" % [meaning, spelling["masked"]]
		correct_answer = spelling["answer"]
		var spelling_options := [correct_answer]
		while spelling_options.size() < 4:
			var candidate := _random_letters(correct_answer.length(), random)
			if candidate not in spelling_options: spelling_options.append(candidate)
		_shuffle_with_rng(spelling_options, random)
		return {"word": word, "question_type": question_type, "question": question, "options": spelling_options, "correct": spelling_options.find(correct_answer)}
	else:
		question = "%s 的中文含义是？" % word
		correct_answer = meaning
	var options: Array = [correct_answer]
	var candidates: Array = []
	for candidate_entry in all_entries:
		var candidate := String(candidate_entry.get(distractor_key, ""))
		if not candidate.is_empty() and candidate not in options and candidate not in candidates:
			candidates.append(candidate)
	_shuffle_with_rng(candidates, random)
	for candidate in candidates:
		if options.size() >= 4: break
		options.append(candidate)
	while options.size() < 4: options.append("—%d—" % options.size())
	_shuffle_with_rng(options, random)
	return {"word": word, "question_type": question_type, "question": question, "options": options, "correct": options.find(correct_answer)}

static func _build_spelling(word: String, random: RandomNumberGenerator) -> Dictionary:
	var positions: Array[int] = []
	for index in range(word.length()):
		var character := word.substr(index, 1)
		if character.to_lower() != character.to_upper(): positions.append(index)
	_shuffle_with_rng(positions, random)
	var hidden_count := mini(positions.size(), random.randi_range(1, 3))
	positions.resize(hidden_count)
	positions.sort()
	var masked := ""
	var answer := ""
	for index in range(word.length()):
		var character := word.substr(index, 1)
		if index in positions:
			masked += "_"; answer += character
		else: masked += character
	return {"masked": masked, "answer": answer}

static func _random_letters(length: int, random: RandomNumberGenerator) -> String:
	var value := ""
	for _index in range(maxi(1, length)): value += String.chr(97 + random.randi_range(0, 25))
	return value

static func _append_entry(entries: Array, raw_word: String, raw_meaning: String) -> bool:
	var word := raw_word.strip_edges().trim_prefix("\"").trim_suffix("\"")
	var meaning := raw_meaning.strip_edges().trim_prefix("\"").trim_suffix("\"")
	if word.is_empty() or meaning.is_empty() or not _is_english_term(word): return false
	var key := word.to_lower()
	for existing in entries:
		if String(existing.get("word", "")).to_lower() == key: return false
	entries.append({"word": word, "meaning": meaning})
	return true

static func _is_english_term(value: String) -> bool:
	var expression := RegEx.new(); expression.compile("^[A-Za-z][A-Za-z'\\-]*(?:\\s+[A-Za-z][A-Za-z'\\-]*)*$")
	return expression.search(value) != null

static func _contains_cjk(value: String) -> bool:
	for index in range(value.length()):
		var code := value.unicode_at(index)
		if code >= 0x3400 and code <= 0x9fff: return true
	return false

static func _parse_csv_line(line: String) -> Array:
	var result: Array = []
	var current := ""
	var quoted := false
	var index := 0
	while index < line.length():
		var character := line.substr(index, 1)
		if character == "\"":
			if quoted and index + 1 < line.length() and line.substr(index + 1, 1) == "\"": current += "\""; index += 1
			else: quoted = not quoted
		elif character == "," and not quoted: result.append(current); current = ""
		else: current += character
		index += 1
	result.append(current)
	return result

static func _parse_result(entries: Array, failed: int) -> Dictionary:
	return {"entries": entries, "success_count": entries.size(), "failed_count": failed, "preview": entries.slice(0, mini(5, entries.size()))}

static func _shuffle_with_rng(values: Array, random: RandomNumberGenerator) -> void:
	for index in range(values.size() - 1, 0, -1):
		var swap_index := random.randi_range(0, index)
		var temporary = values[index]; values[index] = values[swap_index]; values[swap_index] = temporary
