extends Node
## ============================================================================
##  loop_mutation.gd —— 世界状态递进（玩法层组件 / Entities）
## ----------------------------------------------------------------------------
##  这是本作调研认定的【唯一空白差异位】：竞品的时间循环只做"物品重置 + 情报保留"，
##  世界本身每遍还原；本作让余页随遍数【变形】—— 权威语义见
##  docs/story/09_系统映射与数据规格.md:60-100 的 secret.per_loop_mutation：
##
##      {
##        "mode": "grow" | "shrink",     # grow = 每遍多一分 / shrink = 每遍少一项
##        "affected_rooms": [...],        # 变形的房间
##        "affected_entities": [...],     # 变形的实体（一条记 1；给了数字就用数字）
##        "note": "..."                   # 中文说明（策划口径）
##      }
##
##  案一（data/scenarios/case_01_baihu.json）：mode = "grow"，
##    affected_rooms  = ["baihutai_bei", "baihutai_yang", "phone"]
##    affected_entities = ["inscription_last_row", "rubbing_fragment", "paper_kite", "phone_call"]
##    → 拓纸上的旧凿痕多一道灰影、纸鹄落点上的灰多一层、电话里的杂音长一分。
##
##  【09:17 的契约】订阅 signal loop_reset 的组件必须清掉"仅属于上一遍的世界状态"。
##  本组件因此【每遍重算、绝不累积、绝不落盘】：
##      level = clamp(loop_index, 0, max_level)      ← 只由"现在是第几遍"决定
##      房间里这一遍的实体数 = 基础数 ± level         ← 基础数只来自数据文件
##      loop_reset 时 level 归零 = 回到未变形的原页（上一遍的杂讯一点不留），
##      随后的 loop_started(loop_index) 再按新的遍数重算。
##  所以 get_state() 里没有任何"上一遍"的字段：同一份数据 + 同一个 loop_index，
##  任何一次重算的结果都逐字相同（测试用两个实例互相对照来证明这一点）。
##  线索跨遍保留是 PersistentMemoryManager 的事，本组件不碰。
##
##  依赖注入（本脚本一行都不直接引用 Autoload，便于 --check-only 与无头测试）：
##      var mutation = preload("res://scripts/entities/loop_mutation.gd").new()
##      mutation.configure(case_data)      # case_loader.gd 的 CaseData 或案件原始 Dictionary
##      mutation.set_loop_index(TimeLoopManager.get_loop_index())
##      if mutation.auto_subscribe: add_child(mutation)   # 挂进树才会订阅 /root/TimeLoopManager
##
##  不写 class_name（依赖编辑器类缓存，刚 clone 时不可用），一律 preload()。
## ============================================================================


# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------

## 这一遍的强度（level）发生变化时广播一次；同一 level 重复 apply_loop() 不会重复广播。
signal loop_mutation_changed(loop_index: int, level: int)


# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

## grow：每多走一遍，"不属于这一天"的杂讯多一分（案一：谷虫）。
const MODE_GROW: String = "grow"
## shrink：每多走一遍，余页里少一项（案九：铁柜工作底稿每遍少一项）。
const MODE_SHRINK: String = "shrink"
## 时间循环管理器挂载点（核心层冻结，本组件只订阅信号；测试里 auto_subscribe = false 即可完全不碰）。
const LOOP_MANAGER_PATH: String = "/root/TimeLoopManager"
## 挂载点里的节点名：解析时从场景树根用【相对】路径取（见 _resolve_loop_manager()）——
## 绝对路径 get_node("/root/X") 在"自身还没进树"的节点上会报
## "Can't use get_node() with absolute paths from outside the active scene tree."，
## 而无头测试正是这种情形。
const LOOP_MANAGER_NAME: String = "TimeLoopManager"


# ---------------------------------------------------------------------------
# 配置（数据）
# ---------------------------------------------------------------------------

## 挂进场景树后是否自动订阅 /root/TimeLoopManager（无头测试设 false）。
var auto_subscribe: bool = true

var _configured: bool = false
var _errors: Array[String] = []
var _warnings: Array[String] = []

## 归一化后的数据（全部来自数据文件，运行期绝不被改写）。
var _mode: String = ""
var _note: String = ""
var _affected_rooms: Array[String] = []
## room -> Array[String]：该房间的实体名，长度恒等于该房间的【基础数】
## （数据里一条 entity 给了 base = 3 时，这里就重复 3 次同一个名字 = "同一处的三层"）。
var _entities_by_room: Dictionary = {}
## room -> int：基础数（只有数据能给，运行期不改）。
var _base_by_room: Dictionary = {}
var _base_total: int = 0
## 强度上限；-1 = 不封顶（只有数据显式给了 max_level 才封顶）。
var _max_level: int = -1


# ---------------------------------------------------------------------------
# 运行期（每遍重算，不累积、不落盘）
# ---------------------------------------------------------------------------

var _loop_index: int = 0
var _level: int = 0
## 可选注入：本组件【不消费】线索（杂讯只随遍数增长，见 09:60-100），
## 引用只保留给表现层的对象图与后续步骤，不参与任何计算。
var _memory: Node = null
var _subscribed: bool = false


# ---------------------------------------------------------------------------
# 生命周期 / 订阅
# ---------------------------------------------------------------------------

func _ready() -> void:
	if auto_subscribe:
		subscribe_loop_manager()


func _exit_tree() -> void:
	unsubscribe_loop_manager()


## 订阅 /root/TimeLoopManager 的 loop_reset / loop_started；成功返回 true。
## 场景树里没有它（工具脚本、无头测试）时只记一条 warning，不报错、不影响查询。
func subscribe_loop_manager() -> bool:
	if _subscribed:
		return true
	var manager: Node = _resolve_loop_manager()
	if manager == null:
		_warnings.append("订阅失败：场景树里没有 %s（工具/测试模式正常；引导层可自行 set_loop_index()）"
			% LOOP_MANAGER_PATH)
		return false
	if manager.has_signal("loop_reset") and not manager.is_connected("loop_reset", on_loop_reset):
		manager.connect("loop_reset", on_loop_reset)
	if manager.has_signal("loop_started") and not manager.is_connected("loop_started", on_loop_started):
		manager.connect("loop_started", on_loop_started)
	_subscribed = true
	return true


func unsubscribe_loop_manager() -> void:
	if not _subscribed:
		return
	var manager: Node = _resolve_loop_manager()
	if manager != null:
		if manager.is_connected("loop_reset", on_loop_reset):
			manager.disconnect("loop_reset", on_loop_reset)
		if manager.is_connected("loop_started", on_loop_started):
			manager.disconnect("loop_started", on_loop_started)
	_subscribed = false


## 取 /root/TimeLoopManager：从场景树根用相对路径找（自身在不在树里都能用）。
## 不直接引用 Autoload 标识符 ⇒ --check-only 不会误报 Identifier not found。
func _resolve_loop_manager() -> Node:
	var tree: SceneTree = null
	if is_inside_tree():
		tree = get_tree()
	if tree == null:
		var main_loop: MainLoop = Engine.get_main_loop()
		if main_loop is SceneTree:
			tree = main_loop as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(LOOP_MANAGER_NAME)


## 09:17 契约：清掉"仅属于上一遍的世界状态"——世界回到未变形的原页（level 0）。
## 遍历计数交给随后的 loop_started(loop_index)；两次信号之间 get_level() 恒为 0。
func on_loop_reset() -> void:
	reset()


## 新一遍开始：按 loop_index 重算这一遍的世界状态（覆盖式，不累积）。
func on_loop_started(loop_index: int) -> void:
	apply_loop(loop_index)


# ---------------------------------------------------------------------------
# 依赖注入
# ---------------------------------------------------------------------------

## 喂入案件数据。两种形状都吃：
##   ① case_loader.gd 的 CaseData（读它的 secret / rooms）
##   ② 原始 Dictionary —— 整份案件数据（meta.secret）或单独的 secret 块（含 per_loop_mutation）
func configure(case_data: Variant) -> void:
	_clear_rules()
	var secret: Dictionary = _extract_secret(case_data)
	if secret.is_empty():
		_errors.append("configure()：输入里找不到 secret（既不是 case_loader.gd 的 CaseData，"
			+ "也不含 meta.secret / per_loop_mutation 的 Dictionary）")
		return
	var mutation_value: Variant = secret.get("per_loop_mutation", null)
	if mutation_value == null and secret.has("mode"):
		# 喂进来的就是裸的 per_loop_mutation 块本身（_extract_secret() 会把它当 secret 返回）
		mutation_value = secret
	if mutation_value == null:
		_errors.append("secret.per_loop_mutation 缺失：本案的世界状态不随遍数变化"
			+ "（docs/story/09:60-100 要求核心案件给出 mode / affected_rooms / affected_entities）")
		_configured = true
		return
	if not (mutation_value is Dictionary):
		_errors.append("secret.per_loop_mutation 必须是字典，实际是 %s"
			% type_string(typeof(mutation_value)))
		return
	var mutation: Dictionary = mutation_value
	var rooms: Array[String] = _extract_rooms(case_data)

	# --- mode ---
	var mode_value: Variant = mutation.get("mode", "")
	if not (mode_value is String):
		_errors.append("per_loop_mutation.mode 必须是字符串（%s / %s），实际是 %s"
			% [MODE_GROW, MODE_SHRINK, type_string(typeof(mode_value))])
		return
	var mode: String = mode_value
	if mode != MODE_GROW and mode != MODE_SHRINK:
		_errors.append("per_loop_mutation.mode=%s 不认识（只支持 %s / %s）"
			% [mode, MODE_GROW, MODE_SHRINK])
		return
	_mode = mode

	# --- note ---
	var note_value: Variant = mutation.get("note", "")
	if note_value is String:
		_note = note_value
	else:
		_warnings.append("per_loop_mutation.note 不是字符串（已忽略；建议写中文策划口径）")

	# --- affected_rooms ---
	_affected_rooms = _read_room_list(mutation, rooms)
	if _affected_rooms.is_empty():
		_errors.append("per_loop_mutation.affected_rooms 必须是非空的房间 id 数组")
		return

	# --- affected_entities ---
	_read_entity_list(mutation)
	if _base_total <= 0:
		_errors.append("per_loop_mutation.affected_entities 必须是非空数组"
			+ "（字符串实体名，或 {id, room?, base?} 字典）")
		return

	# --- max_level（可选扩展：09 没规定上限时用 -1 = 不封顶）---
	var cap_value: Variant = mutation.get("max_level", -1)
	if cap_value is int or cap_value is float:
		_max_level = _as_int(cap_value, -1)
	elif cap_value is String and (cap_value as String).is_valid_int():
		_max_level = (cap_value as String).to_int()
	else:
		_warnings.append("per_loop_mutation.max_level 不是整数（按不封顶处理）")
		_max_level = -1

	_configured = true
	_level = _computed_level(_loop_index)


## 注入记忆管理器（可选）。本组件不消费线索，只保留引用以便表现层共用同一个对象图。
func set_memory_manager(memory: Node) -> void:
	_memory = memory


func get_memory_manager() -> Node:
	return _memory


# ---------------------------------------------------------------------------
# 循环驱动（每遍重算）
# ---------------------------------------------------------------------------

## 直接指定"现在是第几遍"（0 基，口径同 TimeLoopManager.get_loop_index()）。
func set_loop_index(loop_index: int) -> void:
	var next_index: int = maxi(0, loop_index)
	var next_level: int = _computed_level(next_index)
	var changed: bool = next_level != _level
	_loop_index = next_index
	_level = next_level
	if changed:
		loop_mutation_changed.emit(_loop_index, _level)


## set_loop_index() 的同义入口：引导层在 loop_started 里调这个（名字更贴近"每遍重算一遍"）。
func apply_loop(loop_index: int) -> void:
	set_loop_index(loop_index)


## 回到未变形的原页（level 0，遍历计数 0）。on_loop_reset() 就是调它。
func reset() -> void:
	set_loop_index(0)


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func is_configured() -> bool:
	return _configured


## 配置成功且没有 error（warning 不算失败）。
func is_ok() -> bool:
	return _configured and _errors.is_empty()

func get_mode() -> String:
	return _mode

## 当前这一遍的强度（grow = 多出来的层数 / shrink = 少掉的项数）。
func get_level() -> int:
	return _level

func get_loop_index() -> int:
	return _loop_index

## 第几遍（1 基口径，与 docs/story/04 的"余页第 N 遍"一致：loop_index 0 = 第 1 遍）。
func get_loop_number() -> int:
	return _loop_index + 1

func get_max_level() -> int:
	return _max_level

func get_note() -> String:
	return _note

func get_affected_rooms() -> Array[String]:
	var result: Array[String] = []
	for room in _affected_rooms:
		result.append(room)
	return result

func is_affected(room: String) -> bool:
	return _affected_rooms.has(room) and int(_base_by_room.get(room, 0)) > 0

## 该房间这一遍的基础数（数据口径；不受 level 影响，便于 HUD 显示"原页 N 处"）。
func base_count(room: String) -> int:
	return int(_base_by_room.get(room, 0))

## 该房间这一遍实际有多少实体：
##   grow   : 基础数 + level
##   shrink : 基础数 − level（硬性下限 0，绝不出现负数）
func entity_count(room: String) -> int:
	var base: int = int(_base_by_room.get(room, 0))
	if base <= 0:
		return 0
	if _mode == MODE_SHRINK:
		return maxi(0, base - _level)
	return base + _level

## 所有受影响房间的实体总数。
func total_entity_count() -> int:
	var total: int = 0
	for room in _affected_rooms:
		total += entity_count(room)
	return total

## 该房间这一遍能观测到的实体名列表。
## 恒等式：list_entities(room).size() == entity_count(room)
##   grow   ：基础实体按顺序【轮转补齐】——同一个名字重复出现 = 同一处又叠了一层
##            （案一：拓纸上的旧凿痕多一道灰影）
##   shrink ：从尾部开始少（保留前 N 个）——案九"工作底稿每遍少一项"去掉的是最后一项
func list_entities(room: String) -> Array[String]:
	var result: Array[String] = []
	var base_ids: Array[String] = _room_entity_ids(room)
	if base_ids.is_empty():
		return result
	var wanted: int = entity_count(room)
	var index: int = 0
	while result.size() < wanted:
		result.append(base_ids[index % base_ids.size()])
		index += 1
	return result

## 一行中文，给 HUD 用（例：余页杂讯：第 3 遍｜3 间房共 7 处不属于这一天的痕迹（原页 4 处，+3））。
func describe() -> String:
	if not _configured:
		return "世界状态递进：未配置（先调 configure() 喂入案件数据）"
	if _mode.is_empty():
		return "余页无异变：本案没有 per_loop_mutation（世界状态不随遍数变化）"
	var room_count: int = _affected_rooms.size()
	var total: int = total_entity_count()
	if _mode == MODE_SHRINK:
		var empty_tail: String = "，已空" if total == 0 else ""
		return "余页缺损：第 %d 遍｜%d 间房共 %d 项（原页 %d 项，−%d%s）%s" % [
			_loop_index + 1, room_count, total, _base_total, _base_total - total, empty_tail, _cap_suffix(),
		]
	return "余页杂讯：第 %d 遍｜%d 间房共 %d 处不属于这一天的痕迹（原页 %d 处，+%d）%s" % [
		_loop_index + 1, room_count, total, _base_total, total - _base_total, _cap_suffix(),
	]

## 只读快照（便于断言：同一份数据 + 同一个 loop_index ⇒ 逐字相同，没有任何上一遍的残留）。
func get_state() -> Dictionary:
	var rooms: Dictionary = {}
	var total: int = 0
	for room in _affected_rooms:
		var count: int = entity_count(room)
		var base: int = int(_base_by_room.get(room, 0))
		total += count
		rooms[room] = {
			"base": base,
			"count": count,
			"delta": count - base,
			"entities": list_entities(room),
		}
	var state: Dictionary = {
		"configured": _configured,
		"mode": _mode,
		"loop_index": _loop_index,
		"loop_number": _loop_index + 1,
		"level": _level,
		"max_level": _max_level,
		"note": _note,
		"affected_rooms": get_affected_rooms(),
		"rooms": rooms,
		"total": total,
		"base_total": _base_total,
		"errors": get_errors(),
		"warnings": get_warnings(),
	}
	return state

func get_errors() -> Array[String]:
	var result: Array[String] = []
	for message in _errors:
		result.append(message)
	return result

func get_warnings() -> Array[String]:
	var result: Array[String] = []
	for message in _warnings:
		result.append(message)
	return result

func error_summary() -> String:
	if _errors.is_empty():
		return ""
	return "loop_mutation：%d 个错误｜%s" % [_errors.size(), "\n".join(PackedStringArray(_errors))]


# ---------------------------------------------------------------------------
# 内部：输入形状
# ---------------------------------------------------------------------------

func _clear_rules() -> void:
	_configured = false
	_errors.clear()
	_warnings.clear()
	_mode = ""
	_note = ""
	_affected_rooms.clear()
	_entities_by_room.clear()
	_base_by_room.clear()
	_base_total = 0
	_max_level = -1
	_loop_index = 0
	_level = 0


## 从 CaseData / 原始 Dictionary 里取出 secret 块（四种形状都认，见 configure() 的注释）。
func _extract_secret(source: Variant) -> Dictionary:
	if source == null:
		return {}
	if source is Dictionary:
		var data: Dictionary = source
		var meta_value: Variant = data.get("meta", null)
		if meta_value is Dictionary:
			var meta: Dictionary = meta_value
			var nested: Variant = meta.get("secret", null)
			if nested is Dictionary:
				return nested
		if data.has("per_loop_mutation"):
			return data
		# 裸的 per_loop_mutation 块本身（data/*.json 里抠出来直接喂进来）
		if data.has("mode") and (data.has("affected_rooms") or data.has("affected_entities")):
			return data
		var direct: Variant = data.get("secret", null)
		if direct is Dictionary:
			return direct
		return {}
	if source is Object and "secret" in source:
		var value: Variant = source.get("secret")
		if value is Dictionary:
			return value
	return {}


func _extract_rooms(source: Variant) -> Array[String]:
	var result: Array[String] = []
	var raw: Variant = null
	if source is Dictionary:
		var data: Dictionary = source
		var meta_value: Variant = data.get("meta", null)
		if meta_value is Dictionary:
			var meta: Dictionary = meta_value
			raw = meta.get("rooms", null)
		elif data.has("rooms"):
			raw = data.get("rooms")
	elif source is Object and "rooms" in source:
		raw = source.get("rooms")
	if not (raw is Array):
		return result
	for item in (raw as Array):
		if item is String:
			result.append(item)
	return result


## affected_rooms：必须是字符串数组；若同时给了案件的 rooms，则逐个校验（拼错 → error + 拼写建议）。
func _read_room_list(mutation: Dictionary, case_rooms: Array[String]) -> Array[String]:
	var result: Array[String] = []
	var value: Variant = mutation.get("affected_rooms", [])
	if not (value is Array):
		return result
	var index: int = 0
	for item in (value as Array):
		if not (item is String):
			_errors.append("affected_rooms[%d] 必须是字符串（实际 %s）"
				% [index, type_string(typeof(item))])
			index += 1
			continue
		var room: String = item
		if room.is_empty():
			_errors.append("affected_rooms[%d] 是空字符串" % index)
		elif result.has(room):
			_warnings.append("affected_rooms[%d] 重复出现 %s（按一次算）" % [index, room])
		elif not case_rooms.is_empty() and not case_rooms.has(room):
			_errors.append("affected_rooms[%d]=%s 不在案件 meta.rooms 里%s"
				% [index, room, _suggest(room, case_rooms)])
		else:
			result.append(room)
		index += 1
	return result


## affected_entities：字符串（记 1）或 {id/entity_id, room?, base?} 字典。
## 没写 room 的条目按顺序【轮转】分配给 affected_rooms（总数守恒，结果确定）：
##   案一 4 条实体 → baihutai_bei 2 条（末行 + 拓纸残纸）、baihutai_yang 1 条（纸鹄）、phone 1 条（电话）。
## 写清了 room 的条目按 room 归位；base 给了数字就重复那么多次（"同一处的 N 层"）。
func _read_entity_list(mutation: Dictionary) -> void:
	var value: Variant = mutation.get("affected_entities", [])
	if not (value is Array):
		return
	# 轮转分配的下标基准在循环开始前固定下来（后面 _add_entity() 可能给 _affected_rooms 追加房间）。
	var room_slots: Array[String] = get_affected_rooms()
	var index: int = 0
	for item in (value as Array):
		var entity_id: String = ""
		var room: String = ""
		var base: int = 1
		if item is String:
			entity_id = item
		elif item is Dictionary:
			var row: Dictionary = item
			var id_value: Variant = row.get("id", row.get("entity_id", ""))
			if id_value is String:
				entity_id = id_value
			var room_value: Variant = row.get("room", "")
			if room_value is String:
				room = room_value
			var base_value: Variant = row.get("base", row.get("count", 1))
			base = maxi(1, _as_int(base_value, 1))
		else:
			_errors.append("affected_entities[%d] 必须是字符串或字典（实际 %s）"
				% [index, type_string(typeof(item))])
			index += 1
			continue
		if entity_id.is_empty():
			_errors.append("affected_entities[%d] 没有 id" % index)
			index += 1
			continue
		if room.is_empty():
			room = room_slots[index % room_slots.size()]
		elif not _affected_rooms.has(room) and not _base_by_room.has(room):
			_errors.append("affected_entities[%d]=%s 的 room=%s 不在 affected_rooms 里"
				% [index, entity_id, room])
			index += 1
			continue
		_add_entity(room, entity_id, base)
		index += 1


func _add_entity(room: String, entity_id: String, base: int) -> void:
	var ids: Array[String] = []
	if _entities_by_room.has(room):
		ids = _entities_by_room[room]
	for _repeat in range(base):
		ids.append(entity_id)
	_entities_by_room[room] = ids
	if not _base_by_room.has(room):
		_base_by_room[room] = 0
		# affected_rooms 里可能已经有这间房（那批是先声明、后由实体挂上去的），
		# 这里必须去重 —— 否则 total_entity_count() 会把同一间房算两遍。
		if not _affected_rooms.has(room):
			_affected_rooms.append(room)
	_base_by_room[room] = int(_base_by_room[room]) + base
	_base_total += base


func _room_entity_ids(room: String) -> Array[String]:
	var result: Array[String] = []
	if not _entities_by_room.has(room):
		return result
	var ids: Array[String] = _entities_by_room[room]
	for entity_id in ids:
		result.append(entity_id)
	return result


# ---------------------------------------------------------------------------
# 内部：数值 / 文本
# ---------------------------------------------------------------------------

func _computed_level(loop_index: int) -> int:
	var level: int = maxi(0, loop_index)
	if _max_level >= 0:
		level = mini(level, _max_level)
	return level


func _cap_suffix() -> String:
	if _max_level >= 0 and _loop_index > _max_level:
		return "（已封顶 %d）" % _max_level
	return ""


func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(round(value))
	if value is String and (value as String).is_valid_int():
		return (value as String).to_int()
	return fallback


## 拼写建议（照 tools/validate_data.gd 的做法：编辑距离 ≤ 3 才给建议）。
func _suggest(word: String, candidates: Array) -> String:
	var best: String = ""
	var best_distance: int = 4
	for candidate_value in candidates:
		if not (candidate_value is String):
			continue
		var candidate: String = candidate_value
		var distance: int = _edit_distance(word, candidate)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	if best.is_empty():
		return ""
	return "（是否想写 \"%s\"？）" % best


func _edit_distance(a: String, b: String) -> int:
	var rows: int = a.length() + 1
	var cols: int = b.length() + 1
	var previous: Array[int] = []
	var current: Array[int] = []
	for col in range(cols):
		previous.append(col)
	for row in range(1, rows):
		current = [row]
		for col in range(1, cols):
			var cost: int = 0 if a[row - 1] == b[col - 1] else 1
			var deletion: int = previous[col] + 1
			var insertion: int = current[col - 1] + 1
			var substitution: int = previous[col - 1] + cost
			current.append(mini(mini(deletion, insertion), substitution))
		previous = current
	return previous[cols - 1]
