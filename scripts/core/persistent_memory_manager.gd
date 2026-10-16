extends Node
## ============================================================================
##  persistent_memory_manager.gd —— 跨循环记忆 / 线索管理器（核心系统 / Core）
## ----------------------------------------------------------------------------
##  职责：
##    持有玩家"跨循环保留"的线索卡片（Memory Items）集合，以及每条线索的来源元数据
##    （第几轮循环解锁的、解锁顺序）。它是整个时间循环机制中唯一的"持久层"。
##
##  ★ 铁律（本阶段最重要的验收点）：
##    * 无论触发多少次 loop_reset / trigger_loop_reset()，本管理器的数据都不清空；
##    * 本脚本【不订阅】任何时间循环信号，也不提供任何"重置"入口，
##      唯一能清空数据的是显式的 reset_for_new_game()（开新档专用），
##      从结构上杜绝"循环重置顺手把线索也清掉"这类 bug。
##
##  挂载方式：项目设置 → 自动加载(Autoload) → 名称 PersistentMemoryManager
##  注意：脚本刻意【不写】 class_name，否则会与同名 Autoload 单例冲突。
##
##  典型用法：
##      PersistentMemoryManager.clue_added.connect(_on_clue_added)
##      if PersistentMemoryManager.add_clue("clue_letter_under_plate", 3):
##          show_toast("获得线索：盘子下的信")
##      if PersistentMemoryManager.has_clue("clue_letter_under_plate"):
##          unlock_dialogue_option("ask_butler_about_letter")
## ============================================================================


# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------

## 新线索解锁（首次加入时才触发；source_loop = 解锁时的循环编号，未知为 -1）。
signal clue_added(clue_id: String, source_loop: int)

## 重复解锁被忽略（幂等调用，方便做"重复调查同一物体"的提示）。
signal clue_duplicate_ignored(clue_id: String)

## 记忆被整体清空（仅开新档 / 调试时发生，正常循环绝不会触发）。
signal memory_reset


# ---------------------------------------------------------------------------
# 内部数据（外部只能通过下方 API 访问，避免被意外修改）
# ---------------------------------------------------------------------------

## 已解锁线索 ID（有序去重，保留解锁顺序）。
var _clues: Array[String] = []

## clue_id -> { "source_loop": int, "order": int }
var _clue_records: Dictionary = {}

## 存档格式版本号，便于后续升级存档结构。
const SAVE_VERSION: int = 1


# ---------------------------------------------------------------------------
# 对外 API —— 写入
# ---------------------------------------------------------------------------

## 解锁一条线索。
## 返回值：true = 本次确实新解锁；false = 已存在（幂等）或参数非法。
func add_clue(clue_id: String, source_loop: int = -1) -> bool:
	if clue_id.is_empty():
		push_warning("[PersistentMemoryManager] add_clue() 收到空 clue_id，已忽略。")
		return false
	if has_clue(clue_id):
		clue_duplicate_ignored.emit(clue_id)
		return false

	_clues.append(clue_id)
	_clue_records[clue_id] = {
		"source_loop": source_loop,
		"order": _clues.size() - 1,
	}
	clue_added.emit(clue_id, source_loop)
	return true


## 批量解锁，返回本次新解锁的数量。
func add_clues(clue_ids: Array, source_loop: int = -1) -> int:
	var added: int = 0
	for id in clue_ids:
		if typeof(id) == TYPE_STRING and add_clue(id, source_loop):
			added += 1
	return added


# ---------------------------------------------------------------------------
# 对外 API —— 查询
# ---------------------------------------------------------------------------

## 玩家是否已解锁该线索（对话选项、场景交互的解锁条件就查这个）。
func has_clue(clue_id: String) -> bool:
	return _clue_records.has(clue_id)


## 是否已集齐给定的一组线索（用于开启"真相结局"的判定）。
func has_all_clues(clue_ids: Array) -> bool:
	for id in clue_ids:
		if typeof(id) != TYPE_STRING or not has_clue(id):
			return false
	return true


## 返回线索 ID 列表的【副本】，外部修改不会影响内部数据。
func get_clues() -> Array[String]:
	var snapshot: Array[String] = []
	snapshot.assign(_clues)
	return snapshot


func get_clue_count() -> int:
	return _clues.size()


## 返回某条线索的元数据副本（不存在则返回空字典）。
func get_clue_record(clue_id: String) -> Dictionary:
	if not _clue_records.has(clue_id):
		return {}
	var record: Dictionary = _clue_records[clue_id]
	return record.duplicate(true)


# ---------------------------------------------------------------------------
# 对外 API —— 存档（阶段一只做纯数据转换，不写文件；落盘留给后续阶段）
# ---------------------------------------------------------------------------

func get_save_data() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"clues": _clues.duplicate(),
		"records": _clue_records.duplicate(true),
	}


## 从存档数据恢复。数据非法时返回 false 且不修改现有状态。
func apply_save_data(data: Dictionary) -> bool:
	if not data.has("clues") or typeof(data["clues"]) != TYPE_ARRAY:
		push_warning("[PersistentMemoryManager] apply_save_data() 数据缺少合法的 clues 字段。")
		return false

	var raw_clues: Array = data["clues"]
	var restored: Array[String] = []
	for id in raw_clues:
		if typeof(id) == TYPE_STRING and not id.is_empty() and not restored.has(id):
			restored.append(id)

	_clues = restored
	_clue_records.clear()
	for i in _clues.size():
		_clue_records[_clues[i]] = {
			"source_loop": -1,
			"order": i,
		}
	if data.has("records") and typeof(data["records"]) == TYPE_DICTIONARY:
		var raw_records: Dictionary = data["records"]
		for clue_id in raw_records.keys():
			if _clue_records.has(clue_id) and typeof(raw_records[clue_id]) == TYPE_DICTIONARY:
				var record: Dictionary = raw_records[clue_id]
				_clue_records[clue_id] = record.duplicate(true)
	return true


# ---------------------------------------------------------------------------
# 对外 API —— 清空（唯一入口，且明确标注用途）
# ---------------------------------------------------------------------------

## 清空全部记忆。★ 仅用于"开新档"或调试，绝对不要在循环重置流程里调用。
func reset_for_new_game() -> void:
	_clues.clear()
	_clue_records.clear()
	memory_reset.emit()
