extends RefCounted
## ============================================================================
##  map_loader.gd —— 案发地的走位图装载（data 层，纯只读，零 UI / 零场景引用）
## ----------------------------------------------------------------------------
##  为什么需要它：
##    NPC 动线（case_loader.gd）只回答"谁在第几秒在哪个房间"，那让玩家可以
##    用 1–9 直跳瞬间换房 —— "随便哪一遍都来得及"。走位耗时把房间之间的距离
##    变成**真实的余页秒数**，于是问题从"你在不在场"变成"你赶不赶得上"。
##
##  它认的数据（权威清单来自案一的 meta.rooms 与 data/maps/case_NN_map.json）：
##      res://data/maps/case_NN_map.json
##    schema（一行一条）：
##      schema_version : int           —— 数据格式版本，当前 1
##      case_id        : int           —— 对应案件号（validate_data.gd 用它配对案件）
##      map_id         : String        —— 与案件 meta.map_id 对应
##      display_name   : String        —— 地图标题（HUD 用）
##      rooms[]        : Array<Object> —— 房间表
##      rooms[].room_id        : String —— 房间 id，必须与案件 meta.rooms 完全一致
##      rooms[].display_name   : String —— 中文房名
##      rooms[].exits[]        : Array<Object> —— 有向边（只写单向也可以，反向边自行补）
##      rooms[].exits[].to             : String —— 目的房间 id
##      rooms[].exits[].travel_seconds : int    —— 整数秒；允许往返不对称（上山 ≠ 下山）
##
##  设计取舍：
##    1. **只读**：绝不写盘、不改数据，只回答"邻居 / 最短路 / 总耗时"；
##    2. **有向边**：台阶上下耗时不同是真实地形，不做"自动对称"的假设，
##       但"只写了一条方向"会给 warning（多半是漏写）；
##    3. **耗时一律整数秒**：JSON 里写 4.5 直接报错（半秒无意义，且便于用整数拍点）；
##    4. **错误 / 警告分离**：错误 = 规格违反（ok=false）；警告 = 可疑但可继续；
##    5. 不写 class_name（刚 clone 时类缓存不可用），调用方一律 preload()。
## ============================================================================


## 地图文件目录（与案件同案号配对：case_01_map.json ↔ data/scenarios/case_01_*.json）。
const MAP_DIR: String = "res://data/maps"

## 支持的 schema 版本。
const SUPPORTED_SCHEMA_VERSION: int = 1

## 比这更长的一步路就要求复核，多半是把"米"当成"秒"写了。
const LONG_TRAVEL_WARNING_SECONDS: int = 180

## 拼写建议的最大编辑距离（与 tools/validate_data.gd 的口径一致）。
const SUGGEST_MAX_DISTANCE: int = 3


# ============================================================================
#  内部类：一张走位图（装载结果）
# ============================================================================

class RoomMap:
	var ok: bool = false
	var error: String = ""
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var path: String = ""

	var schema_version: int = 0
	var case_id: int = -1
	var map_id: String = ""
	var display_name: String = ""

	## 房间 id，按首字母排序（保证同一份 JSON 每次装载的顺序一致）。
	var rooms: Array[String] = []
	## "房间 id → 中文名"。
	var room_names: Dictionary = {}
	## "房间 id → Array[Dictionary{to, travel_seconds}]"，有向边，保持 JSON 里的书写顺序。
	var neighbors: Dictionary = {}
	## 页外房间（JSON 里写了 "external": true）：故意走不到，不算漏连接边。
	## 案一的 off_page 就是这种：郑守录在页外的录房打电话，玩家永远走不进那一间。
	var external_rooms: Dictionary = {}

	# ------------------------------ 摘要 ------------------------------

	func room_count() -> int:
		return rooms.size()

	## 默认落位（没有指定出生点时的兜底：取排序后的第一个房间）。
	## 正式玩法层应当传自己的出生点，不该依赖这个兜底。
	func default_room() -> String:
		if rooms.is_empty():
			return ""
		return rooms[0]

	func has_room(room: String) -> bool:
		return rooms.has(room)

	## 全图的有向边条数（同一对房间的两个方向算两条）。
	func edge_count() -> int:
		var total: int = 0
		for room in rooms:
			total += (neighbors[room] as Array).size()
		return total

	func display_title() -> String:
		if display_name.is_empty():
			return "地图 %s" % map_id
		return "%s（%s）" % [display_name, map_id]

	func error_summary() -> String:
		if errors.is_empty():
			return error
		return "%s（%d 个问题）" % [error, errors.size()]

	# --------------------------- 查询接口 ---------------------------

	## 房间的中文名（查不到就原样返回 id —— 显示层不该因为缺名字而崩）。
	func get_display_name(room: String) -> String:
		if room_names.has(room):
			return str(room_names[room])
		return room

	## 某房间的邻居 id 列表（按耗时升序，同耗时按 id 排序；不可达房间返回空数组）。
	func get_neighbors(room: String) -> Array[String]:
		var result: Array[String] = []
		if not neighbors.has(room):
			return result
		for exit in _sorted_exits(room):
			result.append(str(exit["to"]))
		return result

	## 某房间的"出口表"副本：Array[Dictionary{to, travel_seconds}]（按耗时升序）。
	## 返回副本，调用方改它不会污染地图。
	func get_exits(room: String) -> Array[Dictionary]:
		return _sorted_exits(room)

	## 从 room 直接走一步到 to 的耗时；没有直接边返回 0（注意与"同房 0 秒"同形，
	## 调用方要区分时先看 has_edge()）。
	func get_direct_travel_seconds(room: String, to: String) -> int:
		if not neighbors.has(room):
			return 0
		for exit in (neighbors[room] as Array):
			if str(exit["to"]) == to:
				return int(exit["travel_seconds"])
		return 0

	func has_edge(room: String, to: String) -> bool:
		if not neighbors.has(room):
			return false
		for exit in (neighbors[room] as Array):
			if str(exit["to"]) == to:
				return true
		return false

	## 两房之间的最短耗时（整数秒；可含中间房）。同一间房 = 0；走不到 = 0。
	func travel_seconds(from_room: String, to_room: String) -> int:
		return _dijkstra(from_room, to_room)["seconds"]

	## 最短路径的房间序列，含起点与终点（同一间房 = [room]；走不到 = 空数组）。
	func find_path(from_room: String, to_room: String) -> Array[String]:
		return _dijkstra(from_room, to_room)["path"]

	## 一条路线（房间 id 序列）的总耗时。相邻两房之间若必须中转，自动按最短路补足。
	## 任何一段走不到 → 整条路线返回 0（表现层据此判"这趟去不了"）。
	func route_seconds(route: Array) -> int:
		if route.size() < 2:
			return 0
		var total: int = 0
		for i in range(1, route.size()):
			var leg := travel_seconds(str(route[i - 1]), str(route[i]))
			if leg <= 0:
				return 0
			total += leg
		return total

	# ------------------------------ 校验 ------------------------------

	## 装载时已经把问题分好类；这里只做一次汇总判断（供工具/测试断言用）。
	func validate() -> bool:
		return ok and errors.is_empty()

	# ---------------------------- 内部实现 ----------------------------

	## 该房间的出口副本，按 (耗时, 目的房间) 升序 —— 让 get_neighbors 的顺序稳定可断言。
	func _sorted_exits(room: String) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		if not neighbors.has(room):
			return result
		for exit in (neighbors[room] as Array):
			result.append({
				"to": str(exit["to"]),
				"travel_seconds": int(exit["travel_seconds"]),
			})
		result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["travel_seconds"]) != int(b["travel_seconds"]):
				return int(a["travel_seconds"]) < int(b["travel_seconds"])
			return str(a["to"]) < str(b["to"])
		)
		return result

	## Dijkstra（耗时全为正整数，不会踩负权坑；房间只有十几间，O(n²) 足够）。
	## 返回 {"seconds": int, "path": Array[String]}；走不到时 seconds = 0、path 为空。
	func _dijkstra(from_room: String, to_room: String) -> Dictionary:
		var empty: Dictionary = {"seconds": 0, "path": [] as Array[String]}
		if not neighbors.has(from_room) or not neighbors.has(to_room):
			return empty
		if from_room == to_room:
			var same: Array[String] = [from_room]
			return {"seconds": 0, "path": same}

		var best: Dictionary = {}      # room -> 已知最短秒数（未定型）
		var previous: Dictionary = {}  # room -> 上一跳房间
		var settled: Dictionary = {}   # room -> 已定型
		best[from_room] = 0

		while true:
			# 取未定型里最优的一间（不用堆：房间数少，且这样没有第三方依赖）
			var current: String = ""
			var current_cost: int = 0
			for room in best.keys():
				if settled.has(room):
					continue
				var cost: int = int(best[room])
				if current.is_empty() or cost < current_cost:
					current = str(room)
					current_cost = cost
			if current.is_empty():
				return empty
			if current == to_room:
				break
			settled[current] = true
			for exit in (neighbors[current] as Array):
				var next_room := str(exit["to"])
				var candidate: int = current_cost + int(exit["travel_seconds"])
				if not best.has(next_room) or candidate < int(best[next_room]):
					best[next_room] = candidate
					previous[next_room] = current

		# 回溯路径
		var reversed_path: Array[String] = [to_room]
		var cursor: String = to_room
		while cursor != from_room:
			cursor = str(previous[cursor])
			reversed_path.append(cursor)
		var path: Array[String] = []
		for i in range(reversed_path.size() - 1, -1, -1):
			path.append(reversed_path[i])
		return {"seconds": int(best[to_room]), "path": path}


# ============================================================================
#  装载入口（静态，形状与 case_loader.gd 一致）
# ============================================================================

## 列出 data/maps 下的全部地图文件（按文件名排序，case_01 在前）。
## 目录不存在时返回空数组（还没画图是合法状态，不是错误）。
static func list_map_files() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	# 同 case_loader.list_case_files()：导出包里没有本地目录，必须用 DirAccess.open 判存在性。
	var dir := DirAccess.open(MAP_DIR)
	if dir == null:
		return result
	var files := dir.get_files()
	for file_name in files:
		if file_name.begins_with("case_") and file_name.ends_with("_map.json"):
			result.append("%s/%s" % [MAP_DIR, file_name])
	result.sort()
	return result


## 找到某案的地图路径（case_NN_map.json）。找不到返回空串。
static func find_map_path(case_id: int = 1) -> String:
	var target := "%s/case_%02d_map.json" % [MAP_DIR, case_id]
	if FileAccess.file_exists(target):
		return target
	return ""


## 装载某案的地图。path 为空时按 case_id 自动找 case_NN_map.json。
static func load_for_case(case_id: int = 1) -> RoomMap:
	return load_from_file(find_map_path(case_id), case_id)


## 从文件装载。path 为空时给出"还没画图"的可读错误（不崩）。
static func load_from_file(path: String = "", case_id: int = -1) -> RoomMap:
	if path.is_empty():
		var missing_path := RoomMap.new()
		missing_path.error = "找不到地图文件：%s 下没有 case_NN_map.json（case_id=%d 的地图还没画）" % [
			MAP_DIR, case_id,
		]
		missing_path.errors.append(missing_path.error)
		return missing_path

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var unreadable := RoomMap.new()
		unreadable.path = path
		unreadable.error = "无法打开地图文件：%s（错误码 %d）" % [path, FileAccess.get_open_error()]
		unreadable.errors.append(unreadable.error)
		return unreadable

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		var bad := RoomMap.new()
		bad.path = path
		bad.error = "地图文件不是合法 JSON 对象：%s" % path
		bad.errors.append(bad.error)
		return bad

	return parse_dictionary(parsed as Dictionary, path)


static func parse_text(text: String, path: String = "<text>") -> RoomMap:
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		var bad := RoomMap.new()
		bad.path = path
		bad.error = "不是合法 JSON 对象：%s" % path
		bad.errors.append(bad.error)
		return bad
	return parse_dictionary(parsed as Dictionary, path)


## 把地图字典转成 RoomMap。校验分两级：
##   · errors  —— 结构性错误：缺 rooms / 房间名重复 / 未知房间 / 自环 / 耗时非正数 /
##                耗时非整数 / 同一方向写了两条不同耗时的边 / 声明的房间没有任何边；
##   · warnings —— 可疑但可继续：只写了一个方向、孤岛房间、一步超过 180 秒、单出口死胡同。
static func parse_dictionary(data: Dictionary, path: String = "<dict>") -> RoomMap:
	var result := RoomMap.new()
	result.path = path
	result.schema_version = int(data.get("schema_version", 0))
	result.case_id = int(data.get("case_id", -1))
	result.map_id = str(data.get("map_id", ""))
	result.display_name = str(data.get("display_name", ""))

	if result.schema_version != SUPPORTED_SCHEMA_VERSION:
		result.warnings.append("schema_version 应为 %d（当前 %d）；追加字段不影响旧解析器" % [
			SUPPORTED_SCHEMA_VERSION, result.schema_version,
		])
	if result.case_id < 0:
		result.warnings.append("缺少 case_id：validate_data.gd 无法把它和案件配对")
	if result.map_id.is_empty():
		result.warnings.append("缺少 map_id（建议与案件 meta.map_id 一致）")

	var rooms_value: Variant = data.get("rooms", null)
	if not (rooms_value is Array) or (rooms_value as Array).is_empty():
		result.errors.append("rooms 必须是非空数组（每个房间一个对象，含 exits）")
		result.error = result.errors[0]
		return result

	# --- 第一遍：房间清单（先收齐 id，后面才能对未知房间名给拼写建议）---
	var declared: Array = rooms_value as Array
	for room_value in declared:
		if not (room_value is Dictionary):
			result.errors.append("rooms 里出现了非对象元素，已跳过")
			continue
		var room_dict: Dictionary = room_value
		var room_id := str(room_dict.get("room_id", ""))
		if room_id.is_empty():
			result.errors.append("有房间缺少 room_id")
			continue
		if result.rooms.has(room_id):
			result.errors.append("房间 id 重复：%s" % room_id)
			continue
		result.rooms.append(room_id)
		result.room_names[room_id] = str(room_dict.get("display_name", room_id))
		if bool(room_dict.get("external", false)):
			result.external_rooms[room_id] = true

	if result.rooms.is_empty():
		result.errors.append("没有任何可用房间")
		result.error = result.errors[0]
		return result

	result.rooms.sort()
	for room in result.rooms:
		result.neighbors[room] = [] as Array

	# --- 第二遍：有向边 ---
	var seen_edges: Dictionary = {}   # "from|to" -> 已记录的耗时，查重复边
	for room_value in declared:
		if not (room_value is Dictionary):
			continue
		var room_dict: Dictionary = room_value
		var room_id := str(room_dict.get("room_id", ""))
		if not result.neighbors.has(room_id):
			continue
		var exits_value: Variant = room_dict.get("exits", [])
		if not (exits_value is Array):
			result.errors.append("%s 的 exits 必须是数组" % room_id)
			continue
		for exit_value in (exits_value as Array):
			if not (exit_value is Dictionary):
				result.errors.append("%s 的 exits 里出现了非对象元素" % room_id)
				continue
			_parse_exit(room_id, exit_value as Dictionary, result, seen_edges)

	_analyze_edges(result)
	_analyze_isolated_rooms(result)

	result.ok = result.errors.is_empty()
	if not result.ok:
		result.error = result.errors[0]
	return result


# ---------------------------------------------------------------------------
#  内部：单条边
# ---------------------------------------------------------------------------

static func _parse_exit(room: String, exit: Dictionary, result: RoomMap, seen_edges: Dictionary) -> void:
	var to := str(exit.get("to", ""))
	if to.is_empty():
		result.errors.append("%s 有一条出口没写 to" % room)
		return
	if not result.rooms.has(to):
		result.errors.append("%s 的出口指向未知房间「%s」%s" % [
			room, to, _suggest_room(to, result.rooms),
		])
		return
	if to == room:
		result.errors.append("%s 的出口指向自己（自环没有意义：同房耗时恒为 0）" % room)
		return

	var seconds_value: Variant = exit.get("travel_seconds", null)
	if typeof(seconds_value) != TYPE_INT and typeof(seconds_value) != TYPE_FLOAT:
		result.errors.append("%s → %s 的 travel_seconds 必须是整数秒" % [room, to])
		return
	var seconds_float := float(seconds_value)
	if is_nan(seconds_float) or is_inf(seconds_float):
		result.errors.append("%s → %s 的 travel_seconds 不是有限数" % [room, to])
		return
	if seconds_float != floor(seconds_float):
		result.errors.append("%s → %s 的 travel_seconds=%s 必须是整数秒（JSON 里不要写小数）" % [
			room, to, str(seconds_value),
		])
		return
	var seconds := int(seconds_float)

	# 页外房间是同一栋楼里的两个屋子或同一间屋子："0 秒"在那里是合法的，
	# 其余房间的耗时必须是正数（0 秒等于瞬移，会把走位耗时整个架空）。
	if seconds < 0:
		result.errors.append("%s → %s 的 travel_seconds=%d 不能为负数" % [room, to, seconds])
		return
	if seconds == 0 and room != "off_page":
		result.errors.append("%s → %s 的 travel_seconds=0 不是正数（同房耗时恒为 0，正数才是一条路）" % [
			room, to,
		])
		return

	var key := "%s|%s" % [room, to]
	if seen_edges.has(key):
		var previous: int = int(seen_edges[key])
		if previous == seconds:
			result.errors.append("%s → %s 重复写了两条一样的出口（删掉一条）" % [room, to])
		else:
			result.errors.append("%s → %s 写了两条耗时不同的出口（%d 与 %d）；一个方向只能有一条边" % [
				room, to, previous, seconds,
			])
		return
	seen_edges[key] = seconds
	(result.neighbors[room] as Array).append({"to": to, "travel_seconds": seconds})

	if seconds > LONG_TRAVEL_WARNING_SECONDS:
		result.warnings.append("%s → %s 一步要走 %d 秒，超过 %d 秒；确认不是把米当成了秒" % [
			room, to, seconds, LONG_TRAVEL_WARNING_SECONDS,
		])


# ---------------------------------------------------------------------------
#  内部：全图层面的检查
# ---------------------------------------------------------------------------

## 反向边与死胡同。
static func _analyze_edges(result: RoomMap) -> void:
	for room in result.rooms:
		var exits: Array = result.neighbors[room]
		if exits.is_empty():
			result.errors.append("房间「%s」没有任何出口：孤岛房间到不了也出不去（补一条边，或从 rooms 里删掉）" % room)
			continue
		if exits.size() == 1:
			var only_to := str((exits[0] as Dictionary)["to"])
			if not result.has_edge(only_to, room):
				result.warnings.append("房间「%s」只有一个出口且是单向（%s → %s）；多半是漏了回程边" % [
					room, room, only_to,
				])
		for exit in exits:
			var to := str((exit as Dictionary)["to"])
			if not result.has_edge(to, room):
				result.warnings.append("%s → %s 只写了一个方向（回程耗时按另一条边算；漏了就补一条）" % [
					room, to,
				])


## 从第一个房间出发做一次可达性遍历：走不到的房间多半是漏了连接边。
## （注意：某房间"有出口"不等于"到得了" —— 两个互不连通的小环也能各自有边。）
static func _analyze_isolated_rooms(result: RoomMap) -> void:
	if result.rooms.is_empty() or not result.errors.is_empty():
		return
	var reached: Dictionary = {}
	var queue: Array[String] = [result.rooms[0]]
	reached[result.rooms[0]] = true
	var cursor: int = 0
	while cursor < queue.size():
		var room := queue[cursor]
		cursor += 1
		for exit in (result.neighbors[room] as Array):
			var to := str((exit as Dictionary)["to"])
			if not reached.has(to):
				reached[to] = true
				queue.append(to)
	for room in result.rooms:
		if not reached.has(room):
			if result.external_rooms.has(room):
				continue                      # 页外房间：走不到是设计，不是漏边
			result.warnings.append("房间「%s」从「%s」走不到（漏了连接边？走位计算会把它当成不可达）" % [
				room, result.rooms[0],
			])


# ---------------------------------------------------------------------------
#  内部：拼写建议（口径与 case_loader.gd / tools/validate_data.gd 一致）
# ---------------------------------------------------------------------------

static func _suggest_room(room: String, rooms: Array[String]) -> String:
	var best: String = ""
	var best_distance: int = SUGGEST_MAX_DISTANCE + 1
	for candidate in rooms:
		var distance := _edit_distance(room, candidate)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	if best.is_empty():
		return "（可用房间：" + ", ".join(rooms) + "）"
	return "（是否想写 \"%s\"？）" % best


static func _edit_distance(a: String, b: String) -> int:
	var rows: int = a.length() + 1
	var cols: int = b.length() + 1
	var previous: Array[int] = []
	var current: Array[int] = []
	for _j in range(cols):
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
