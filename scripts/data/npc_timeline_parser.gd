class_name NPCTimelineParser
extends RefCounted
## ============================================================================
##  npc_timeline_parser.gd —— NPC 动线 JSON 解析器（数据层 / Data）
## ----------------------------------------------------------------------------
##  职责：
##    读取本地 data/npc_timelines.json，校验后转换成结构化对象（见下方内部类），
##    供 NPC 控制器 / 世界状态机按"本轮已流逝秒数"查询位置与行为。
##
##  设计约束：
##    * 纯逻辑，不继承 Node、不引用任何 Autoload、不接触 UI —— 可以独立无头测试。
##    * 开发期严格校验（缺字段、越界、时间倒序、ID 重复都会记录 errors/warnings），
##      但"可恢复的小问题"（如节点顺序写错）只警告并自动纠正，避免游戏直接跑不起来。
##    * 校验结果通过 ParseResult 返回，绝不静默失败；调用方必须检查 result.ok。
##
##  数据结构（JSON）：
##    {
##      "meta": { "schema_version": 1, "map_id": "...", "loop_duration_seconds": 420,
##                "rooms": ["hall", "kitchen", ...] },
##      "npcs": [
##        { "npc_id": "npc_01_butler", "display_name": "执事", "default_room": "hall",
##          "timeline": [ { "second": 0, "room": "kitchen", "action": "prep_wine",
##                          "facing": "east", "dialogue_id": "...", "clue_id": "...",
##                          "note": "..." } ] }
##      ]
##    }
##
##  用法：
##      var result := NPCTimelineParser.load_from_file()          # 默认读数据表路径
##      if not result.ok:
##          push_error(result.error_summary())
##      else:
##          var schedule := result.npcs["npc_01_butler"]
##          var node := schedule.node_at(TimeLoopManager.get_elapsed_seconds())
##          print(node.room, node.action)
##
##  版本兼容说明：
##    刻意不使用"类型化字典 Array[String]/Dictionary[K, V]"里的 Dictionary[K,V] 语法
##    （该语法需要 Godot 4.4+），以保证在 Godot 4.0 ~ 4.4+ 全系列都能加载。
## ============================================================================


## 数据表默认路径（相对项目根目录）。
const DEFAULT_TIMELINE_PATH: String = "res://data/npc_timelines.json"

## 解析器支持的数据表格式版本。数据表里写得更高时视为错误（防止新表被旧代码误读）。
const SUPPORTED_SCHEMA_VERSION: int = 1

## 数据表未声明 meta.loop_duration_seconds 时使用的默认循环长度（7 分钟）。
const DEFAULT_LOOP_DURATION_SECONDS: int = 420


# ---------------------------------------------------------------------------
# 结构化数据 —— 单个时间节点
# ---------------------------------------------------------------------------

class TimelineNode:
	## 本轮已流逝秒数（>= 0 且 < 循环时长）——该状态从这一秒开始生效，直到下一个节点。
	var second: int = 0
	## 所在房间 ID（对应地图上的房间节点名，核心层只当作字符串标识使用）。
	var room: String = ""
	## 行为标识（如 idle / greet_guests / prep_wine），由 NPC 控制器解释执行。
	var action: String = "idle"
	## 朝向（可选，表现层使用）。
	var facing: String = ""
	## 对话树入口 ID（可选；空字符串表示此刻无可对话内容）。
	var dialogue_id: String = ""
	## 该节点首次被玩家目击时解锁的线索 ID（可选）。
	var clue_id: String = ""
	## 策划备注（可选，运行时不用）。
	var note: String = ""

	func _to_string() -> String:
		return "[%03d秒] %s / %s%s" % [
			second, room, action,
			"" if dialogue_id.is_empty() else " (对话:%s)" % dialogue_id,
		]


# ---------------------------------------------------------------------------
# 结构化数据 —— 单个 NPC 的完整动线
# ---------------------------------------------------------------------------

class NPCSchedule:
	var npc_id: String = ""
	var display_name: String = ""
	## 第 0 秒之前（首个节点生效前）的默认位置。
	var default_room: String = ""
	## 按 second 升序排列的时间节点。
	var nodes: Array[TimelineNode] = []

	## 查询"本轮已经过去 second 秒时"NPC 应在的时间节点。
	## 返回最后一个 second <= 参数 的节点；若比首个节点还早则返回 null。
	## 数据量很小（每个 NPC 几十个节点），线性扫描即可，无需二分。
	func node_at(second: int) -> TimelineNode:
		var found: TimelineNode = null
		for node in nodes:
			if node.second <= second:
				found = node
			else:
				break
		return found

	## 查询某秒的房间 ID；早于首个节点时回落到 default_room。
	func room_at(second: int) -> String:
		var node := node_at(second)
		if node != null:
			return node.room
		return default_room

	## 查询某秒的节点下标，没有则返回 -1。
	func node_index_at(second: int) -> int:
		var index: int = -1
		for i in nodes.size():
			if nodes[i].second <= second:
				index = i
			else:
				break
		return index

	## 动线总时长覆盖到哪一秒（最后一个节点的时间）。
	func last_second() -> int:
		return nodes[-1].second if not nodes.is_empty() else 0

	func _to_string() -> String:
		return "%s(%s) %d 个节点" % [npc_id, display_name, nodes.size()]


# ---------------------------------------------------------------------------
# 解析结果容器
# ---------------------------------------------------------------------------

class ParseResult:
	## 是否解析成功（errors 为空才算成功）。
	var ok: bool = false
	## 致命问题：调用方不应使用本次结果。
	var errors: Array[String] = []
	## 非致命问题：可用，但建议修数据表。
	var warnings: Array[String] = []
	## 数据来源（文件路径或 "<memory>"），便于日志定位。
	var source: String = ""
	var schema_version: int = SUPPORTED_SCHEMA_VERSION
	var map_id: String = ""
	var loop_duration_seconds: int = DEFAULT_LOOP_DURATION_SECONDS
	## npc_id -> NPCSchedule
	var npcs: Dictionary = {}
	## 保持 JSON 中的书写顺序，便于调试输出与确定性遍历。
	var npc_order: Array[String] = []

	func get_schedule(npc_id: String) -> NPCSchedule:
		return npcs.get(npc_id)

	func npc_count() -> int:
		return npcs.size()

	func error_summary() -> String:
		if errors.is_empty():
			return "无错误"
		return " | ".join(PackedStringArray(errors))

	func warning_summary() -> String:
		if warnings.is_empty():
			return "无警告"
		return " | ".join(PackedStringArray(warnings))

	func _to_string() -> String:
		return "[%s] ok=%s NPC=%d 循环=%d秒 错误=%d 警告=%d" % [
			source, str(ok), npcs.size(), loop_duration_seconds, errors.size(), warnings.size(),
		]


# ---------------------------------------------------------------------------
# 对外 API —— 加载与解析
# ---------------------------------------------------------------------------

## 从本地 JSON 文件加载并解析（默认 data/npc_timelines.json）。
## 文件不存在 / 无权限 / JSON 语法错误 / 结构非法，都会在返回结果里说明。
static func load_from_file(path: String = DEFAULT_TIMELINE_PATH) -> ParseResult:
	if not FileAccess.file_exists(path):
		var missing := ParseResult.new()
		missing.source = path
		missing.errors.append("找不到动线数据表：%s（请确认文件位于项目根目录下的 data/ 内）" % path)
		return missing

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var failed := ParseResult.new()
		failed.source = path
		failed.errors.append("无法打开动线数据表：%s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return failed

	var text := file.get_as_text()
	file.close()
	return parse_text(text, path)


## 解析一段 JSON 文本（便于单元测试直接喂字符串）。
static func parse_text(text: String, source_label: String = "<memory>") -> ParseResult:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		# 注意：Godot 4 的 JSON 只提供 get_error_line() / get_error_message()，
		# 没有"列号"接口，不要凭直觉调用 get_error_column()（那是 C++ 侧的东西）。
		# 另外 get_error_line() 是 0 基的，+1 之后才和编辑器行号一致。
		var broken := ParseResult.new()
		broken.source = source_label
		broken.errors.append("JSON 语法错误：%s 第 %d 行 —— %s" % [
			source_label, json.get_error_line() + 1, json.get_error_message(),
		])
		return broken

	if typeof(json.data) != TYPE_DICTIONARY:
		var wrong_root := ParseResult.new()
		wrong_root.source = source_label
		wrong_root.errors.append("数据表根节点必须是 JSON 对象（{}），实际为 %s" % type_string(typeof(json.data)))
		return wrong_root

	var root: Dictionary = json.data
	return parse_dictionary(root, source_label)


## 解析已经变成 Dictionary 的数据（便于从存档 / 网络 / 测试注入数据）。
static func parse_dictionary(root: Dictionary, source_label: String = "<memory>") -> ParseResult:
	var result := ParseResult.new()
	result.source = source_label

	# ---------- meta ----------
	var meta: Dictionary = {}
	if root.has("meta"):
		if typeof(root["meta"]) == TYPE_DICTIONARY:
			meta = root["meta"]
		else:
			result.warnings.append("meta 字段不是对象，已忽略其内容")

	result.schema_version = _read_int(meta, "schema_version", SUPPORTED_SCHEMA_VERSION)
	if result.schema_version > SUPPORTED_SCHEMA_VERSION:
		result.errors.append("数据表格式版本 %d 高于解析器支持的版本 %d，请升级解析器" % [
			result.schema_version, SUPPORTED_SCHEMA_VERSION,
		])
	result.map_id = _read_string(meta, "map_id", "")

	var duration: int = _read_int(meta, "loop_duration_seconds", DEFAULT_LOOP_DURATION_SECONDS)
	if duration <= 0:
		result.errors.append("meta.loop_duration_seconds 必须为正整数，当前为 %d" % duration)
		duration = DEFAULT_LOOP_DURATION_SECONDS
	result.loop_duration_seconds = duration

	# 已知房间集合（可选）：只用于对未知房间发警告，不做强制限制。
	var known_rooms: Dictionary = {}
	if meta.has("rooms") and typeof(meta["rooms"]) == TYPE_ARRAY:
		for room_id in meta["rooms"]:
			if typeof(room_id) == TYPE_STRING:
				known_rooms[room_id] = true

	# ---------- npcs ----------
	if not root.has("npcs"):
		result.errors.append("缺少 npcs 数组")
		return result
	if typeof(root["npcs"]) != TYPE_ARRAY:
		result.errors.append("npcs 必须是数组，实际为 %s" % type_string(typeof(root["npcs"])))
		return result

	var raw_npcs: Array = root["npcs"]
	if raw_npcs.is_empty():
		result.errors.append("npcs 为空数组，至少需要 1 名 NPC")
		return result

	for i in raw_npcs.size():
		var where := "npcs[%d]" % i
		if typeof(raw_npcs[i]) != TYPE_DICTIONARY:
			result.errors.append("%s 不是对象，已跳过" % where)
			continue
		var npc: Dictionary = raw_npcs[i]

		var npc_id := _read_string(npc, "npc_id", "")
		if npc_id.is_empty():
			result.errors.append("%s 缺少 npc_id，已跳过" % where)
			continue
		if result.npcs.has(npc_id):
			result.errors.append("%s npc_id 重复：%s（已保留首个定义）" % [where, npc_id])
			continue

		var schedule := _parse_schedule(npc, npc_id, where, duration, known_rooms, result)
		if schedule != null:
			result.npcs[npc_id] = schedule
			result.npc_order.append(npc_id)

	if result.npcs.is_empty():
		result.errors.append("没有任何有效的 NPC 动线定义")

	result.ok = result.errors.is_empty()
	return result


# ---------------------------------------------------------------------------
# 内部实现 —— 单个 NPC 动线
# ---------------------------------------------------------------------------

static func _parse_schedule(
	npc: Dictionary,
	npc_id: String,
	where: String,
	loop_duration: int,
	known_rooms: Dictionary,
	result: ParseResult
) -> NPCSchedule:
	var schedule := NPCSchedule.new()
	schedule.npc_id = npc_id
	schedule.display_name = _read_string(npc, "display_name", npc_id)
	schedule.default_room = _read_string(npc, "default_room", "")

	if not npc.has("timeline"):
		result.errors.append("%s(%s) 缺少 timeline 数组" % [where, npc_id])
		return null
	if typeof(npc["timeline"]) != TYPE_ARRAY:
		result.errors.append("%s(%s) timeline 必须是数组" % [where, npc_id])
		return null

	var raw_nodes: Array = npc["timeline"]
	if raw_nodes.is_empty():
		result.errors.append("%s(%s) timeline 为空数组" % [where, npc_id])
		return null

	var seen_seconds: Dictionary = {}
	for j in raw_nodes.size():
		var node_where := "%s(%s).timeline[%d]" % [where, npc_id, j]
		if typeof(raw_nodes[j]) != TYPE_DICTIONARY:
			result.errors.append("%s 不是对象，已跳过" % node_where)
			continue
		var raw_node: Dictionary = raw_nodes[j]

		var node := TimelineNode.new()
		node.second = _read_int(raw_node, "second", -1)
		if node.second < 0:
			result.errors.append("%s 缺少合法的 second（必须为 >= 0 的整数）" % node_where)
			continue
		if node.second >= loop_duration:
			result.errors.append("%s second=%d 超出循环时长 %d 秒" % [node_where, node.second, loop_duration])
			continue
		if seen_seconds.has(node.second):
			result.errors.append("%s second=%d 与同一 NPC 前面的节点重复（同一秒只能有一个状态）" % [node_where, node.second])
			continue

		node.room = _read_string(raw_node, "room", "")
		if node.room.is_empty():
			result.errors.append("%s 缺少 room" % node_where)
			continue
		if not known_rooms.is_empty() and not known_rooms.has(node.room):
			result.warnings.append("%s room=\"%s\" 不在 meta.rooms 声明的房间列表中（可能是拼写错误）" % [node_where, node.room])

		seen_seconds[node.second] = true
		node.action = _read_string(raw_node, "action", "idle")
		node.facing = _read_string(raw_node, "facing", "")
		node.dialogue_id = _read_string(raw_node, "dialogue_id", "")
		node.clue_id = _read_string(raw_node, "clue_id", "")
		node.note = _read_string(raw_node, "note", "")
		schedule.nodes.append(node)

	if schedule.nodes.is_empty():
		result.errors.append("%s(%s) 没有任何有效的时间节点" % [where, npc_id])
		return null

	# 时间顺序：允许数据表写乱，但必须报警告并在内存中纠正，保证 node_at() 的正确性。
	var original_seconds: Array[int] = []
	for node in schedule.nodes:
		original_seconds.append(node.second)
	schedule.nodes.sort_custom(func(a: TimelineNode, b: TimelineNode) -> bool: return a.second < b.second)
	for k in schedule.nodes.size():
		if schedule.nodes[k].second != original_seconds[k]:
			result.warnings.append("%s(%s) timeline 未按 second 升序书写，已在内存中重新排序（建议修正数据表）" % [where, npc_id])
			break

	if schedule.nodes[0].second != 0:
		result.warnings.append("%s(%s) 首个节点在第 %d 秒而非第 0 秒，此前将回落 default_room=\"%s\"" % [
			where, npc_id, schedule.nodes[0].second, schedule.default_room,
		])

	return schedule


# ---------------------------------------------------------------------------
# 内部实现 —— 宽容取值（JSON 里秒数可能被写成 25.0 或 "25"）
# ---------------------------------------------------------------------------

static func _read_int(source: Dictionary, key: String, default_value: int) -> int:
	if not source.has(key):
		return default_value
	var value = source[key]
	match typeof(value):
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value)
		TYPE_STRING:
			var text: String = value
			if text.is_valid_int():
				return text.to_int()
			return default_value
		_:
			return default_value


static func _read_string(source: Dictionary, key: String, default_value: String) -> String:
	if not source.has(key):
		return default_value
	var value = source[key]
	match typeof(value):
		TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return String(value)
		_:
			return default_value
