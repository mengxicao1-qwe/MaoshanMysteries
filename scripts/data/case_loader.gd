extends RefCounted
## ============================================================================
##  case_loader.gd —— 案件数据装载（data 层，纯只读，零 UI / 零场景引用）
## ----------------------------------------------------------------------------
##  与 npc_timeline_parser.gd 的分工（两者不能互相替代）：
##    · npc_timeline_parser.gd 认的是阶段一遗留格式：data/npc_timelines.json，
##      其中 npcs 是「npcs -> { npc_id -> 时间表 }」的字典；它已被冻结，只读不改。
##    · 本文件认的是《茅山秘录·诡异录》的正式案件格式（契约见
##      docs/story/09_系统映射与数据规格.md §2/§3）：
##        data/scenarios/case_NN_<短名>.json
##      其中 npcs 是**数组**，meta 里多一个 secret（"缝"的定义）。
##  两者都只做"JSON → 结构化数据"，都不碰 TimeLoopManager / UI。
##
##  用法（表现层 / 实体层）：
##      const CaseLoader = preload("res://scripts/data/case_loader.gd")
##      var case: CaseLoader.CaseData = CaseLoader.load_case()   # 不传路径 = 自动取最小案号
##      if case.ok:
##          TimeLoopManager.set_loop_duration(float(case.loop_duration_seconds))
##
##  设计取舍：故意不做"每遍世界变化(shrink/grow)"的执行逻辑 —— 那只属于表现层/实体层；
##  本文件只负责把数据交出去，并回答"第 N 秒谁在哪、有哪些线索可观测"。
## ============================================================================


## 案件文件目录（与 docs/story/09 §2 一致）。
const SCENARIO_DIR: String = "res://data/scenarios"

## 节点字段缺省值：全部来自 docs/story/09 §3（与阶段一解析器保持同一套字段名）。
const NODE_FIELDS: Array[String] = [
	"second", "room", "action", "facing", "dialogue_id", "clue_id", "note",
]

## 合法朝向（仅用于给出拼写建议，不合法只报警告，不阻断）。
const FACINGS: Array[String] = ["north", "south", "east", "west", ""]


# ============================================================================
#  内部类 1：一个时间节点
# ============================================================================

class TimelineNode:
	var second: int = 0
	var room: String = ""
	var action: String = ""
	var facing: String = ""
	var dialogue_id: String = ""
	var clue_id: String = ""
	## 遍数锁（M2）：这一处从第几遍起才看得见（0 = 第一遍就看得见）。
	## 依据 `docs/story/04` 每条线索"获得方式"里写明的遍数（如半笔"寸"是余页第三遍）。
	var loop_min: int = 0
	var note: String = ""

	## 该节点是否会让玩家解锁一条线索（表现层据此判断"这一刻蹲在这里有没有收获"）。
	func has_clue() -> bool:
		return not clue_id.is_empty()

	func describe() -> String:
		var tail: String = ""
		if not note.is_empty():
			tail = "  // %s" % note
		return "%03d 秒 @ %s [%s]%s" % [second, room, action, tail]


# ============================================================================
#  内部类 2：一名 NPC 的秒级动线
# ============================================================================

class NPCSchedule:
	var npc_id: String = ""
	var display_name: String = ""
	var default_room: String = ""
	var nodes: Array[TimelineNode] = []

	## 第 second 秒时该 NPC 所在的节点（取"最后一个 second <= t"的节点）。
	## 早于首个节点时返回 null —— 由调用方决定显示 default_room 还是"尚未出现"。
	func node_at(second: int) -> TimelineNode:
		var found: TimelineNode = null
		for node in nodes:
			if node.second <= second:
				found = node
			else:
				break
		return found

	func node_index_at(second: int) -> int:
		var index: int = -1
		for i in range(nodes.size()):
			if nodes[i].second <= second:
				index = i
			else:
				break
		return index

	func last_second() -> int:
		if nodes.is_empty():
			return 0
		return nodes[nodes.size() - 1].second

	## second 之后（不含 second）的第一个节点 —— "一键重演/秒级跳过"要用它。
	func next_node_after(second: int) -> TimelineNode:
		for node in nodes:
			if node.second > second:
				return node
		return null

	## 该 NPC 身上所有会解锁线索的节点。
	func clue_nodes() -> Array[TimelineNode]:
		var result: Array[TimelineNode] = []
		for node in nodes:
			if node.has_clue():
				result.append(node)
		return result

	func room_at(second: int) -> String:
		var node := node_at(second)
		if node == null:
			return default_room
		return node.room


# ============================================================================
#  内部类 3：一个案件（装载结果）
# ============================================================================

class CaseData:
	var ok: bool = false
	var error: String = ""
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var path: String = ""

	var map_id: String = ""
	var case_id: int = -1
	var case_title: String = ""
	var description: String = ""
	var loop_duration_seconds: int = 0
	var rooms: Array[String] = []
	var secret: Dictionary = {}

	var npc_order: Array[String] = []
	var npcs: Dictionary = {}          # npc_id -> NPCSchedule

	# ------------------------------ 摘要 ------------------------------

	func npc_count() -> int:
		return npc_order.size()

	func total_nodes() -> int:
		var total: int = 0
		for npc_id in npc_order:
			total += (npcs[npc_id] as NPCSchedule).nodes.size()
		return total

	func total_clues() -> int:
		return all_clue_ids().size()

	## 全案线索 id（按"解锁时刻"排序，表现层可直接当进度条用）。
	func all_clue_ids() -> Array[String]:
		var result: Array[String] = []
		for event in clue_events():
			var clue_id: String = event["clue_id"]
			if not result.has(clue_id):
				result.append(clue_id)
		return result

	## "案一《白鹄不举》" 这样的显示标题。
	func display_title() -> String:
		if case_title.is_empty():
			return "案 %02d（未命名）" % case_id
		return "案 %02d《%s》" % [case_id, case_title]

	func error_summary() -> String:
		if errors.is_empty():
			return error
		return "%s（%d 个问题）" % [error, errors.size()]

	# --------------------------- 查询接口 ---------------------------

	## 第 second 秒时，每个房间里有哪些 NPC（显示名）。房间没有 NPC 时该键不存在。
	func rooms_at(second: int) -> Dictionary:
		var result: Dictionary = {}
		for npc_id in npc_order:
			var schedule := npcs[npc_id] as NPCSchedule
			var room := schedule.room_at(second)
			if not result.has(room):
				result[room] = []
			(result[room] as Array).append(schedule.display_name)
		return result

	## 全案的"可观测线索事件"列表：谁在第几秒、在哪个房间、能给出哪条线索。
	## 表现层只需要"玩家在不在那个房间"就能完成解锁判定。
	func clue_events() -> Array[Dictionary]:
		var events: Array[Dictionary] = []
		for npc_id in npc_order:
			var schedule := npcs[npc_id] as NPCSchedule
			for node in schedule.clue_nodes():
				events.append({
					"second": node.second,
					"npc_id": npc_id,
					"display_name": schedule.display_name,
					"room": node.room,
					"clue_id": node.clue_id,
					"loop_min": node.loop_min,
					"note": node.note,
				})
		events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["second"]) < int(b["second"])
		)
		return events

	## 下一处"值得一看"的时刻（任一 NPC 的节点秒 > after）。没有则返回 -1。
	## 这是"秒级跳过"的原语：玩家不必真的等满 360 秒。
	func next_interesting_second(after: int) -> int:
		var best: int = -1
		for npc_id in npc_order:
			var schedule := npcs[npc_id] as NPCSchedule
			var node := schedule.next_node_after(after)
			if node == null:
				continue
			if best < 0 or node.second < best:
				best = node.second
		return best

	## 第 second 秒起、哪些线索已经"可观测但还没到手"（供 HUD 提示玩家蹲哪个房间）。
	func observable_clues(second: int) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for event in clue_events():
			if int(event["second"]) <= second:
				result.append(event)
		return result


# ============================================================================
#  装载入口
# ============================================================================

## 列出 data/scenarios 下的全部案件文件（按文件名排序，case_01 在前）。
## 目录不存在时返回空数组（尚未写案件数据是合法状态，不是错误）。
static func list_case_files() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	# 不能用 globalize_path() + dir_exists_absolute() 判断存在性：导出成 .pck 之后
	# `res://` 不是本地目录，Web（和桌面导出）都会在这里误判成“目录不存在”，
	# 症状是编辑器里一切正常、导出包里案件装载失败（HUD 打印“先空跑时钟”）。
	var dir := DirAccess.open(SCENARIO_DIR)
	if dir == null:
		return result
	var files := dir.get_files()
	for file_name in files:
		if file_name.begins_with("case_") and file_name.ends_with(".json"):
			result.append("%s/%s" % [SCENARIO_DIR, file_name])
	result.sort()
	return result


## 找到要装载的案件路径：指定 case_id 时找 case_NN_*，否则取编号最小的那个。
static func find_case_path(case_id: int = -1) -> String:
	var files := list_case_files()
	if files.is_empty():
		return ""
	if case_id < 0:
		return files[0]
	var prefix := "case_%02d" % case_id
	for path in files:
		if path.get_file().begins_with(prefix):
			return path
	return ""


## 装载案件。path 为空时自动选编号最小的案件文件。
static func load_case(path: String = "") -> CaseData:
	var target := path
	if target.is_empty():
		target = find_case_path()
	if target.is_empty():
		var empty := CaseData.new()
		empty.error = "找不到案件文件：%s 下没有 case_*.json（先按 docs/story/09 §3 写一个）" % SCENARIO_DIR
		return empty

	var file := FileAccess.open(target, FileAccess.READ)
	if file == null:
		var missing := CaseData.new()
		missing.path = target
		missing.error = "无法打开案件文件：%s（错误码 %d）" % [target, FileAccess.get_open_error()]
		return missing

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		var bad := CaseData.new()
		bad.path = target
		bad.error = "案件文件不是合法 JSON 对象：%s" % target
		return bad

	return parse_dictionary(parsed as Dictionary, target)


static func parse_text(text: String, path: String = "<text>") -> CaseData:
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		var bad := CaseData.new()
		bad.path = path
		bad.error = "不是合法 JSON 对象：%s" % path
		return bad
	return parse_dictionary(parsed as Dictionary, path)


## 把案件字典转成 CaseData。校验分两级：
##   · errors  —— 结构性错误（缺 meta / 缺 npcs / 节点缺 second 或 room），ok=false；
##   · warnings —— 可疑但可继续（乱序自动重排、缺 second:0、房间不在 meta.rooms、秒数越界）。
static func parse_dictionary(data: Dictionary, path: String = "<dict>") -> CaseData:
	var result := CaseData.new()
	result.path = path

	if not data.has("meta") or not (data["meta"] is Dictionary):
		result.errors.append("缺少 meta 对象")
		result.error = "案件数据缺少 meta"
		return result

	var meta: Dictionary = data["meta"]
	result.map_id = str(meta.get("map_id", ""))
	result.case_id = int(meta.get("case_id", -1))
	result.case_title = str(meta.get("case_title", ""))
	result.description = str(meta.get("description", ""))
	result.loop_duration_seconds = int(meta.get("loop_duration_seconds", 0))

	var rooms_value: Variant = meta.get("rooms", [])
	if rooms_value is Array:
		for room in (rooms_value as Array):
			var room_name := str(room)
			if result.rooms.has(room_name):
				result.warnings.append("meta.rooms 里重复的房间：%s" % room_name)
				continue
			result.rooms.append(room_name)
	if result.rooms.is_empty():
		result.errors.append("meta.rooms 为空：没有房间就无法校验 NPC 动线")
	if result.loop_duration_seconds <= 0:
		result.errors.append("meta.loop_duration_seconds 必须为正数（当前 %d）" % result.loop_duration_seconds)
	if result.case_id < 0:
		result.errors.append("meta.case_id 缺失或非法（当前 %d）" % result.case_id)

	var secret_value: Variant = meta.get("secret", {})
	if secret_value is Dictionary:
		result.secret = secret_value as Dictionary

	var npcs_value: Variant = data.get("npcs", [])
	if not (npcs_value is Array) or (npcs_value as Array).is_empty():
		result.errors.append("npcs 必须是非空数组（正式案件格式是数组，不是阶段一的字典）")
		result.error = "案件数据缺少 npcs"
		return result

	for npc_value in (npcs_value as Array):
		if not (npc_value is Dictionary):
			result.errors.append("npcs 里出现了非对象元素，已跳过")
			continue
		var npc: Dictionary = npc_value
		var npc_id := str(npc.get("npc_id", ""))
		if npc_id.is_empty():
			result.errors.append("有 NPC 缺少 npc_id")
			continue
		if result.npcs.has(npc_id):
			result.errors.append("NPC id 重复：%s" % npc_id)
			continue
		var schedule := _parse_npc(npc, npc_id, result)
		result.npcs[npc_id] = schedule
		result.npc_order.append(npc_id)

	if result.npcs.is_empty():
		result.errors.append("没有任何可用的 NPC 动线")

	result.ok = result.errors.is_empty()
	if not result.ok:
		result.error = result.errors[0]
	return result


# ---------------------------------------------------------------------------
#  内部：单个 NPC
# ---------------------------------------------------------------------------

static func _parse_npc(npc: Dictionary, npc_id: String, result: CaseData) -> NPCSchedule:
	var schedule := NPCSchedule.new()
	schedule.npc_id = npc_id
	schedule.display_name = str(npc.get("display_name", npc_id))
	schedule.default_room = str(npc.get("default_room", ""))

	if not schedule.default_room.is_empty() and not result.rooms.is_empty() \
			and not result.rooms.has(schedule.default_room):
		result.warnings.append("%s 的 default_room「%s」不在 meta.rooms 内；%s" % [
			schedule.display_name, schedule.default_room, _suggest_room(schedule.default_room, result.rooms),
		])

	var timeline_value: Variant = npc.get("timeline", [])
	if not (timeline_value is Array) or (timeline_value as Array).is_empty():
		result.errors.append("%s（%s）缺少 timeline 数组" % [schedule.display_name, npc_id])
		return schedule

	var seen_seconds: Dictionary = {}
	for node_value in (timeline_value as Array):
		if not (node_value is Dictionary):
			result.errors.append("%s 的 timeline 里出现了非对象元素" % schedule.display_name)
			continue
		var node_dict: Dictionary = node_value
		var node := TimelineNode.new()
		node.second = int(node_dict.get("second", -1))
		node.room = str(node_dict.get("room", ""))
		node.action = str(node_dict.get("action", ""))
		node.facing = str(node_dict.get("facing", ""))
		node.dialogue_id = str(node_dict.get("dialogue_id", ""))
		node.clue_id = str(node_dict.get("clue_id", ""))
		node.loop_min = int(node_dict.get("loop_min", 0))
		node.note = str(node_dict.get("note", ""))

		if node.second < 0:
			result.errors.append("%s 有节点缺少 second" % schedule.display_name)
			continue
		if node.room.is_empty():
			result.errors.append("%s 第 %d 秒的节点缺少 room" % [schedule.display_name, node.second])
			continue

		schedule.nodes.append(node)

		if seen_seconds.has(node.second):
			result.errors.append("%s 在第 %d 秒出现了两个节点（同秒不允许重复）" % [
				schedule.display_name, node.second,
			])
		seen_seconds[node.second] = true

		if not node.facing.is_empty() and not FACINGS.has(node.facing):
			result.warnings.append("%s 第 %d 秒的 facing「%s」不是 north/south/east/west" % [
				schedule.display_name, node.second, node.facing,
			])
		if not result.rooms.is_empty() and not result.rooms.has(node.room):
			result.warnings.append("%s 第 %d 秒要去房间「%s」，不在 meta.rooms 内；%s" % [
				schedule.display_name, node.second, node.room, _suggest_room(node.room, result.rooms),
			])
		if result.loop_duration_seconds > 0 and node.second >= result.loop_duration_seconds:
			result.errors.append("%s 第 %d 秒超出余页长度 %d 秒" % [
				schedule.display_name, node.second, result.loop_duration_seconds,
			])

	# 排序 + 乱序告警（不阻断：数据写错顺序不该让整局跑不起来）
	var was_sorted: bool = true
	for i in range(1, schedule.nodes.size()):
		if schedule.nodes[i].second < schedule.nodes[i - 1].second:
			was_sorted = false
			break
	if not was_sorted:
		result.warnings.append("%s 的 timeline 不是按秒升序，已自动重排" % schedule.display_name)
		schedule.nodes.sort_custom(func(a: TimelineNode, b: TimelineNode) -> bool:
			return a.second < b.second
		)

	if schedule.nodes.is_empty():
		result.errors.append("%s 没有任何可用节点" % schedule.display_name)
	elif schedule.nodes[0].second != 0:
		result.warnings.append("%s 的第 0 秒没有节点（每名 NPC 都必须有 second:0 的登场节点）" % schedule.display_name)

	return schedule


## 房间名打错时给一个"是不是想写 X"的提示（编辑距离 ≤ 3 才算）。
static func _suggest_room(room: String, rooms: Array[String]) -> String:
	var best: String = ""
	var best_distance: int = 4
	for candidate in rooms:
		var distance := _edit_distance(room, candidate)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	if best.is_empty():
		return "可用房间：" + ", ".join(rooms)
	return "是想写「%s」吗？可用房间：%s" % [best, ", ".join(rooms)]


static func _edit_distance(a: String, b: String) -> int:
	var rows: int = a.length() + 1
	var cols: int = b.length() + 1
	var previous: Array[int] = []
	var current: Array[int] = []
	for _i in range(cols):
		previous.append(0)
		current.append(0)
	for j in range(cols):
		previous[j] = j
	for i in range(1, rows):
		current[0] = i
		for j in range(1, cols):
			var cost: int = 0 if a[i - 1] == b[j - 1] else 1
			current[j] = mini(mini(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost)
		for j in range(cols):
			previous[j] = current[j]
	return previous[cols - 1]
