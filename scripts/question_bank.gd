extends RefCounted
class_name QuestionBank

# UI and game flow consume this data-only layer. Future CSV/XLSX/import adapters can
# return the same dictionary shape without changing quiz presentation code.
const QUESTIONS := [
	{"id": 1, "question": "测试题 1：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 2, "question": "测试题 2：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 3, "question": "测试题 3：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 4, "question": "测试题 4：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 5, "question": "测试题 5：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 6, "question": "测试题 6：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 7, "question": "测试题 7：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 8, "question": "测试题 8：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 9, "question": "测试题 9：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
	{"id": 10, "question": "测试题 10：请选择正确答案", "options": ["A 正确", "B", "C", "D"], "correct": 0},
]

static func get_question(index: int) -> Dictionary:
	return QUESTIONS[posmod(index, QUESTIONS.size())].duplicate(true)
