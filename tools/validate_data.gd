extends RefCounted
## ============================================================================
##  数据 schema + 设计不变量校验器（工具链第 4 步）
## ----------------------------------------------------------------------------
##  为什么需要它：
##    策划文档里的硬约束（余页长度、房间表、线索命名、"缝"的补写条件）如果只写在
##    散文里，实现阶段一定会跑偏，而且错了要到运行时才发现。这里把文档里的规则
##    变成**可执行的断言**：写完 JSON 立刻知道哪里违反了规格，错误信息还带拼写建议。
##
##  规格来源（权威）：
##    · docs/story/09_系统映射与数据规格.md §3 / §3.1 / §4.1 / §6
##    · docs/story/*.md 各案「余页」「活人动线」「证据链」小节
##    · README.md §3（原有 npc_timelines.json schema，保持向后兼容）
##
##  设计原则：
##    1. **只读**：绝不修改数据文件，只报告；
##    2. **错误与警告分离**：错误 = 违反规格（必须改）；警告 = 可疑但可能是刻意的；
##    3. **拼写建议**：房间名、线索名写错时给出最接近的候选，避免对着报错猜；
##    4. 不依赖 Godot 编辑器、不写 class_name —— 由 tools/cli.gd 用 preload 引用。
## ============================================================================

const Parser = preload("res://scripts/data/npc_timeline_parser.gd")
## 走位地图装载器（M1 走位耗时）：用来校验 data/maps/*.json 与案件 meta.rooms 的房间集合一致
const MapLoader = preload("res://scripts/data/map_loader.gd")

const SCENARIO_DIR := "res://data/scenarios"
const CLUE_DIR := "res://data/clues"
const DIALOGUE_DIR := "res://data/dialogues"
const DEDUCTION_DIR := "res://data/deduction"
## 画符输入（M1 ⑤）：每案一个 case_NN_runes.json（装载器 RuneLoader 负责结构校验）
const RUNE_DIR := "res://data/runes"
const LEGACY_TIMELINE := "res://data/npc_timelines.json"

## yuchen_archive 这样的房间名；写错时用来给建议
const ROOM_PATTERN := "^[a-z][a-z0-9_]*$"
## 线索命名法：clue_<案号两位>_<对象>[_<细节>]，跨案共用走 clue_base_，
## 自注走 note_，被删（封印）走 sealed_（见 spec §4）。
const CLUE_PATTERN := "^(clue|note|sealed)_[a-z0-9]+(_[a-z0-9]+)*$"
const CASE_FILE_PATTERN := "^case_(\\d{2})_[a-z0-9_]+\\.json$"

## 余页长度的合理区间（秒）：短于 1 分钟没有推演空间，长于 1 小时不像"一页"
const MIN_LOOP_SECONDS := 60
const MAX_LOOP_SECONDS := 3600

var errors: Array[String] = []
var warnings: Array[String] = []
var stats := {
	"scenario_files": 0,
	"cases": 0,
	"npcs": 0,
	"timeline_nodes": 0,
	"clue_refs": 0,
	"clues_declared": 0,
	"dialogues_declared": 0,
	"runes_declared": 0,
	"rune_steps_declared": 0,
	"rune_strokes_declared": 0,
}

# 跨文件状态（用于唯一性检查）
var _clue_owner := {}          # clue_id -> 首次出现的位置（"文件:字段"）
var _declared_clues := {}      # data/clues/*.json 里正式登记的 clue_id
var _declared_dialogues := {}  # data/dialogues/*.json 里定义的 dialogue_id
var _case_ids := {}            # case_id -> 文件，查重复案件号


func _err(location: String, message: String) -> void:
	errors.append("%s: %s" % [location, message])


func _warn(location: String, message: String) -> void:
	warnings.append("%s: %s" % [location, message])


# ---------------------------------------------------------------------------
#  入口
# ---------------------------------------------------------------------------
func run() -> Dictionary:
	errors.clear()
	warnings.clear()
	for key in stats.keys():
		stats[key] = 0
	_clue_owner.clear()
	_declared_clues.clear()
	_declared_dialogues.clear()
	_case_ids.clear()

	_collect_declared_clues()
	_collect_declared_dialogues()
	_check_legacy_timeline()
	_check_scenarios()
	_check_maps()
	_check_deduction()
	_check_runes()

	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"stats": stats,
	}


## 原有样例数据表：直接复用解析器，保证"解析器的契约"也是闸门的一部分
func _check_legacy_timeline() -> void:
	if not FileAccess.file_exists(LEGACY_TIMELINE):
		_warn(LEGACY_TIMELINE, "文件不存在（阶段一样例数据表）")
		return
	var result = Parser.load_from_file(LEGACY_TIMELINE)
	if result == null:
		_err(LEGACY_TIMELINE, "解析器返回 null（严重：连错误信息都没给出）")
		return
	for e in result.errors:
		_err(LEGACY_TIMELINE, str(e))
	for w in result.warnings:
		_warn(LEGACY_TIMELINE, str(w))
	if not result.ok:
		return
	# 注意 ParseResult 的真实字段名：ok / npcs(字典) / npc_order / get_schedule()，
	# 不是 success / schedules —— 写错时 Godot 只在运行时抛
	# "Invalid access to property or key 'success' on a base object of type 'RefCounted (ParseResult)'"。
	stats["npcs"] += result.npc_count()
	for npc_id in result.npc_order:
		var schedule := result.get_schedule(npc_id)
		if schedule != null:
			stats["timeline_nodes"] += schedule.nodes.size()


# ---------------------------------------------------------------------------
#  场景文件（每案一个 data/scenarios/case_NN_*.json）
# ---------------------------------------------------------------------------
func _check_scenarios() -> void:
	var files := _list_files(SCENARIO_DIR, ".json")
	if files.is_empty():
		_warn(SCENARIO_DIR, "目录为空：尚无案件数据（按 docs/story/09 §2，每案一个 case_NN_*.json）")
		return
	for path in files:
		_check_scenario(path)


func _check_scenario(path: String) -> void:
	var base := path.get_file()
	stats["scenario_files"] += 1

	# --- 文件名 → 案号（文件名与 case_id 必须一致，否则存档/线索前缀会串案）---
	var file_case := -1
	var re := RegEx.new()
	re.compile(CASE_FILE_PATTERN)
	var m := re.search(base)
	if m == null:
		_err(path, "文件名不符合 case_NN_<slug>.json（NN 为两位案号）")
	else:
		file_case = int(m.get_string(1))

	var data: Variant = _parse_json_file(path)
	if data == null:
		return
	if typeof(data) != TYPE_DICTIONARY:
		_err(path, "顶层必须是 JSON 对象")
		return

	# --- meta ---
	var meta = data.get("meta", null)
	if typeof(meta) != TYPE_DICTIONARY:
		_err(path, "缺少 meta 对象")
		return

	var case_id := int(meta.get("case_id", -1))
	if meta.has("case_id") and file_case >= 0 and case_id != file_case:
		_err(path, "meta.case_id=%d 与文件名案号 %02d 不一致" % [case_id, file_case])
	if _case_ids.has(case_id):
		_err(path, "案号 %d 与 %s 重复（同一 case_id 只能有一个案件文件）" % [case_id, _case_ids[case_id]])
	else:
		_case_ids[case_id] = base

	var duration := float(meta.get("loop_duration_seconds", -1))
	if duration <= 0.0:
		_err(path, "meta.loop_duration_seconds 必须为正数（当前 %s）" % str(meta.get("loop_duration_seconds")))
	elif duration < float(MIN_LOOP_SECONDS) or duration > float(MAX_LOOP_SECONDS):
		_warn(path, "meta.loop_duration_seconds=%d 超出常见区间 %d–%d 秒" % [int(duration), MIN_LOOP_SECONDS, MAX_LOOP_SECONDS])
	if int(meta.get("schema_version", 0)) != 1:
		_warn(path, "meta.schema_version 应为 1（追加字段不影响旧解析器，见 docs/story/09 §3）")
	for key in ["map_id", "case_title", "description"]:
		if str(meta.get(key, "")).strip_edges().is_empty():
			_warn(path, "meta.%s 为空（建议补齐，索引与 HUD 会用到）" % key)

	var rooms := _string_list(meta.get("rooms", []))
	if rooms.is_empty():
		_err(path, "meta.rooms 不能为空（NPC 动线的房间必须来自这里）")
	if rooms.size() != _unique(rooms).size():
		_err(path, "meta.rooms 有重复项：%s" % str(_duplicates(rooms)))
	for room in rooms:
		if not _matches(ROOM_PATTERN, room):
			_warn(path, "房间名 %s 建议用小写字母/数字/下划线" % room)

	_check_secret(path, meta, rooms, duration)
	_check_npcs(path, data, rooms, duration, case_id)
	stats["cases"] += 1


# ---------------------------------------------------------------------------
#  走位地图（每案一个 data/maps/case_NN_map.json，M1 走位耗时）
# ---------------------------------------------------------------------------
## 地图与案件必须是"同一张房间表"：地图多一间 = 玩家能走到案件里不存在的房间；
## 少一间 = 某条 NPC 动线所在的房间走不进去（线索永远拿不到）。两种都要报错。
## 地图文件缺失只报警告：老案子还没铺走位图时不该拦住整条闸门。
func _check_maps() -> void:
	var paths := MapLoader.list_map_files()
	if paths.is_empty():
		_warn(MapLoader.MAP_DIR, "目录为空：尚无走位地图（按 M1 走位耗时约定，每案一个 case_NN_map.json）")
		return
	for path in paths:
		var case_id: int = _case_number_of_map(path)
		if case_id < 0:
			_err(path, "文件名不符合 case_NN_map.json（NN 为两位案号）")
			continue
		if not _case_ids.has(case_id):
			_warn(path, "找不到对应的案件文件 case_%02d_*.json（案号 %d）" % [case_id, case_id])
			continue
		_check_map_for_case(path, case_id)


## 读案件文件的 meta.rooms，与地图的房间集合逐项比对。
func _check_map_for_case(path: String, case_id: int) -> void:
	var case_path := SCENARIO_DIR.path_join(str(_case_ids[case_id]))
	var case_data: Variant = _parse_json_file(case_path)
	if typeof(case_data) != TYPE_DICTIONARY:
		return
	var meta = case_data.get("meta", null)
	if typeof(meta) != TYPE_DICTIONARY:
		return
	var case_rooms := _string_list(meta.get("rooms", []))
	if case_rooms.is_empty():
		return

	var map := MapLoader.load_for_case(case_id)
	if not map.ok:
		_err(path, "地图本身不合法（%d 个错误）：%s" % [
			map.errors.size(),
			" / ".join(map.errors.slice(0, mini(3, map.errors.size()))),
		])
		return
	var map_rooms: Array = map.rooms.duplicate()
	var allowed: Array = case_rooms.duplicate()
	var missing := _unknown_against(allowed, map_rooms)
	if not missing.is_empty():
		_err(path, "地图缺少案件 %s 里的房间：%s；请在 data/maps/%s 里补上（否则这些房间走不进去）" % [
			case_path.get_file(), _with_suggestions(missing, map_rooms), path.get_file(),
		])
	var unknown := _unknown_against(map_rooms, allowed)
	if not unknown.is_empty():
		_err(path, "地图多出了案件 %s 里没有的房间：%s%s；请从地图里删掉，或把它们加进 meta.rooms" % [
			case_path.get_file(), _with_suggestions(_prefix_limited(unknown), allowed),
			"" if unknown.size() <= 6 else "（另有 %d 间未列出）" % (unknown.size() - 6),
		])


## 每案最多列出 6 间多余房间，避免手滑复制整张表时刷屏。
func _prefix_limited(rooms: Array) -> Array:
	return rooms.slice(0, mini(6, rooms.size()))


## case_01_map.json → 1；格式不对返回 -1。
func _case_number_of_map(path: String) -> int:
	var re := RegEx.new()
	if re.compile("^case_(\\d{2})_map\\.json$") != OK:
		return -1
	var m := re.search(path.get_file())
	if m == null:
		return -1
	return int(m.get_string(1))


# ---------------------------------------------------------------------------
#  推演板（每案一个 data/deduction/case_NN_deduction.json，M1 推演板与矛盾高亮）
# ---------------------------------------------------------------------------
## 推演板的契约（规格见该文件 meta 里的 card/deduction/conflict/stuck_semantics）：
##   · card_id 就是 clue_id ⇒ require_cards / resolve_cards / lead_clue 引用的每一个 id
##     都必须在 data/clues/ 里登记过。写错一个 id，那条推论在游戏里就永远不成立，
##     而玩家不会知道为什么 —— 这类"安静的死"必须在闸门里报出来，并给拼写建议；
##   · 结案必需的卡（案件 meta.secret.resolve_conditions.require_clues）每一张都要被至少一条
##     core 推论用到，否则"结案六环"与推演板各说各话，玩家拼出结论也结不了案；
##   · 卡关提示的落点必须能在案件里对上（room/npc_id/拍点秒数），否则提示永远指不到地方 ——
##     它本来就是防"卡住"的兜底，指错地方比不给更糟。
## 文件缺失只报警告：老案子还没铺推演板时不该拦住整条闸门（与 _check_maps 同一条裁定）。
func _check_deduction() -> void:
	var paths := _list_files(DEDUCTION_DIR, ".json")
	if paths.is_empty():
		_warn(DEDUCTION_DIR, "目录为空：尚无推演板数据（按 M1 约定，每案一个 case_NN_deduction.json）")
		return
	for path in paths:
		var case_id: int = _case_number_of_deduction(path)
		if case_id < 0:
			_err(path, "文件名不符合 case_NN_deduction.json（NN 为两位案号）")
			continue
		if not _case_ids.has(case_id):
			_warn(path, "找不到对应的案件文件 case_%02d_*.json（案号 %d）" % [case_id, case_id])
			continue
		_check_deduction_for_case(path, case_id)


## 画符输入（M1 ⑤）——`data/runes/case_NN_runes.json`。
## 裁定与 _check_deduction 同一条：装载器自己负责结构校验（steps/kind/pattern/choice/require_clues
## 都已在 RuneLoader.parse_* 里成体系地判过），这里只做两件它管不了的事：
##   1. 把装载器的 errors/warnings 原样接进闸门（同一个 location 前缀，便于按文件筛日志）；
##   2. 案件交叉引用：案件 meta.secret.resolve_conditions.require_ritual 必须指向表里的某道符
##      （否则玩家按案件结案条件永远开不了仪式）。装载器已把这一条记成 warning，这里不重复报，
##      只在**真的指不到**时补一条 —— 表本身读不出来（errors 非空）时不补，避免叠加误报。
## 与 _check_deduction 一致：文件缺失只告警，不拦整条闸门。
func _check_runes() -> void:
	var paths := _list_files(RUNE_DIR, ".json")
	if paths.is_empty():
		_warn(RUNE_DIR, "目录为空：尚无画符数据（按 M1 约定，每案一个 case_NN_runes.json）")
		return
	var loader := preload("res://scripts/data/rune_loader.gd")
	for path in paths:
		var table: Variant = loader.load_from_file(path)
		if table == null:
			_err(path, "符表装载器没返回结果（内部错误）")
			continue
		for message in table.errors:
			_err(path, String(message))
		for message in table.warnings:
			_warn(path, String(message))
		if not table.ok:
			continue
		stats["runes_declared"] = int(stats.get("runes_declared", 0)) + table.count()
		stats["rune_steps_declared"] = int(stats.get("rune_steps_declared", 0)) + table.total_steps()
		stats["rune_strokes_declared"] = int(stats.get("rune_strokes_declared", 0)) + table.total_strokes()
		var case_file: String = _case_file_for_ritual(int(table.case_id))
		if case_file == "":
			continue
		var ritual: String = _require_ritual_of(case_file)
		if ritual != "" and not table.has_rune(ritual):
			_err(case_file, "结案条件 require_ritual=「%s」在 %s 里没有对应的符%s"
				% [ritual, path, _with_suggestions([ritual], table.rune_ids())])


## 案号 → 案件文件全路径（`_case_ids` 只存文件名，在 _check_scenarios 里填好；找不到返回空串）。
func _case_file_for_ritual(case_id: int) -> String:
	if _case_ids.has(case_id):
		return SCENARIO_DIR.path_join(String(_case_ids[case_id]))
	return ""


## 读案件文件里的 meta.secret.resolve_conditions.require_ritual（没有就返回空串）。
func _require_ritual_of(case_file: String) -> String:
	var data: Variant = _parse_json_file(case_file)
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var secret: Variant = data.get("meta", {}).get("secret", {})
	if typeof(secret) != TYPE_DICTIONARY:
		return ""
	var conditions: Variant = secret.get("resolve_conditions", {})
	if typeof(conditions) != TYPE_DICTIONARY:
		return ""
	return String(conditions.get("require_ritual", ""))


## 逐表校验：推论（require_cards 全部入录才成立）、矛盾（点亮 + 收束卡）、卡关提示（阈值/落点）。
## 与案件文件交叉比对房间、NPC、余页秒数与结案必需卡；案件读不到时只做自洽校验（不误报）。
func _check_deduction_for_case(path: String, case_id: int) -> void:
	var data: Variant = _parse_json_file(path)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var meta = data.get("meta", null)
	if typeof(meta) != TYPE_DICTIONARY:
		_err(path, "缺少 meta（case_id / case_title / card_semantics / deduction_semantics / conflict_semantics / stuck_semantics）")
	else:
		var declared_id := int(meta.get("case_id", -1))
		if declared_id != case_id:
			_err(path, "meta.case_id=%d 与文件名案号 %02d 不一致（串了案号就会读错线索台账）" % [declared_id, case_id])
		for key in ["card_semantics", "deduction_semantics", "conflict_semantics", "stuck_semantics"]:
			if str(meta.get(key, "")).strip_edges().is_empty():
				_warn(path, "meta.%s 为空（这是推演板与表现层的契约说明，改数据前先读它）" % key)

	# 案件侧：房间表 / NPC 表 / 余页秒数 / 结案必需的卡（读不到就跳过交叉校验，不误报）
	var case_rooms: Array = []
	var case_npcs: Array = []
	var resolve_clues: Array = []
	var loop_seconds: int = 0
	if _case_ids.has(case_id):
		var case_data: Variant = _parse_json_file(SCENARIO_DIR.path_join(str(_case_ids[case_id])))
		if typeof(case_data) == TYPE_DICTIONARY:
			var case_meta = case_data.get("meta", null)
			if typeof(case_meta) == TYPE_DICTIONARY:
				case_rooms = _string_list(case_meta.get("rooms", []))
				loop_seconds = int(case_meta.get("loop_duration_seconds", 0))
				var secret = case_meta.get("secret", null)
				if typeof(secret) == TYPE_DICTIONARY:
					var conditions = secret.get("resolve_conditions", null)
					if typeof(conditions) == TYPE_DICTIONARY:
						resolve_clues = _string_list(conditions.get("require_clues", []))
			var npc_rows: Variant = case_data.get("npcs", [])
			if typeof(npc_rows) == TYPE_ARRAY:
				for item in npc_rows:
					if typeof(item) == TYPE_DICTIONARY and not str(item.get("npc_id", "")).strip_edges().is_empty():
						case_npcs.append(str(item["npc_id"]).strip_edges())

	# --- 推论：require_cards 全部入录才成立；core=true 表示它在结案六环上 ---
	var deductions: Variant = data.get("deductions", null)
	if typeof(deductions) != TYPE_ARRAY or (deductions as Array).is_empty():
		_err(path, "deductions 为空：推演板没有推论，玩家拼不出结论")
	else:
		var rows: Array = deductions
		var ded_ids: Array = []
		var core_cards: Dictionary = {}
		for index in range(rows.size()):
			var where := "%s deductions[%d]" % [path, index]
			if typeof(rows[index]) != TYPE_DICTIONARY:
				_err(where, "不是 JSON 对象")
				continue
			var row: Dictionary = rows[index]
			var deduction_id := str(row.get("deduction_id", "")).strip_edges()
			ded_ids.append(deduction_id)
			if deduction_id.is_empty():
				_err(where, "deduction_id 为空")
			for key in ["title", "text"]:
				if str(row.get(key, "")).strip_edges().is_empty():
					_err(where, "%s 缺失" % key)
			var cards := _string_list(row.get("require_cards", []))
			if cards.is_empty():
				_warn(where, "require_cards 为空：这条推论一开局就成立（确认是有意的）")
			_check_deduction_card_refs(where, "require_cards", cards)
			if bool(row.get("core", false)):
				for card in cards:
					core_cards[str(card)] = deduction_id
		var dup_deductions := _duplicates(ded_ids)
		if not dup_deductions.is_empty():
			_err(path, "deduction_id 重复：%s（同一 id 全作唯一）" % str(dup_deductions))
		for card in resolve_clues:
			if not core_cards.has(str(card)):
				_err(path, "结案必需的线索卡 %s 没有任何 core 推论用到它（推演板拼不出这条结案条件）%s" % [
					card, _suggest(str(card), core_cards.keys()),
				])

	# --- 矛盾：require_cards 全部入录 ⇒ 点亮；resolve_cards 全部入录 ⇒ 已收束（空 = 悬案）---
	var conflicts: Variant = data.get("conflicts", null)
	if typeof(conflicts) != TYPE_ARRAY or (conflicts as Array).is_empty():
		_warn(path, "没有 conflicts 表（本表没有矛盾可高亮，docs/market/01 §2.5 死法 3 的兜底就少一半）")
	else:
		var rows: Array = conflicts
		var conflict_ids: Array = []
		for index in range(rows.size()):
			var where := "%s conflicts[%d]" % [path, index]
			if typeof(rows[index]) != TYPE_DICTIONARY:
				_err(where, "不是 JSON 对象")
				continue
			var row: Dictionary = rows[index]
			var conflict_id := str(row.get("conflict_id", "")).strip_edges()
			conflict_ids.append(conflict_id)
			if conflict_id.is_empty():
				_err(where, "conflict_id 为空")
			for key in ["title", "text"]:
				if str(row.get(key, "")).strip_edges().is_empty():
					_err(where, "%s 缺失" % key)
			var severity := str(row.get("severity", "")).strip_edges()
			if not severity in ["核心", "次要"]:
				_err(where, "severity=%s 不在 {核心, 次要}（表现层按它决定置顶顺序）" % severity)
			var cards := _string_list(row.get("require_cards", []))
			if cards.is_empty():
				_err(where, "require_cards 为空：矛盾一开局就点亮（矛盾必须由线索顶出来）")
			_check_deduction_card_refs(where, "require_cards", cards)
			_check_deduction_card_refs(where, "resolve_cards", _string_list(row.get("resolve_cards", [])))
		var dup_conflicts := _duplicates(conflict_ids)
		if not dup_conflicts.is_empty():
			_err(path, "conflict_id 重复：%s（同一 id 全作唯一）" % str(dup_conflicts))

	# --- 卡关提示：连续 N 遍没有新线索时指一条落点（lead_clue 已入录的由组件跳过）---
	var hints: Variant = data.get("stuck_hints", null)
	if typeof(hints) != TYPE_ARRAY or (hints as Array).is_empty():
		_warn(path, "没有 stuck_hints 表：连续几遍没进展时玩家没有兜底提示（docs/market/01 §2.5 死法 3）")
	else:
		var rows: Array = hints
		for index in range(rows.size()):
			var where := "%s stuck_hints[%d]" % [path, index]
			if typeof(rows[index]) != TYPE_DICTIONARY:
				_err(where, "不是 JSON 对象")
				continue
			var row: Dictionary = rows[index]
			var threshold := int(row.get("after_loops_without_progress", 0))
			if threshold < 1:
				_err(where, "after_loops_without_progress=%d < 1（这条提示开局就会出现）" % threshold)
			if str(row.get("text", "")).strip_edges().is_empty():
				_err(where, "text 缺失（提示没话可说）")
			var room := str(row.get("room", "")).strip_edges()
			if room.is_empty():
				_err(where, "room 为空（提示必须指得出地方）")
			elif not case_rooms.is_empty() and not room in case_rooms:
				_err(where, "room=%s 不在案件的 meta.rooms 里%s（提示会指到一个走不进去的房间）" % [
					room, _suggest(room, case_rooms),
				])
			var second := int(row.get("second", -1))
			if second < 0 or (loop_seconds > 0 and second >= loop_seconds):
				_err(where, "second=%d 不在 0..%d（本遍只有 %d 秒）" % [second, maxi(loop_seconds - 1, 0), loop_seconds])
			var npc_id := str(row.get("npc_id", "")).strip_edges()
			if npc_id.is_empty():
				_err(where, "npc_id 为空（提示要指得出找谁）")
			elif not case_npcs.is_empty() and not npc_id in case_npcs:
				_err(where, "npc_id=%s 不是本案的 NPC%s" % [npc_id, _suggest(npc_id, case_npcs)])
			var lead := str(row.get("lead_clue", "")).strip_edges()
			if lead.is_empty():
				_err(where, "lead_clue 为空（提示要指得出下一条线索）")
			else:
				_check_deduction_card_refs(where, "lead_clue", [lead])


## 推演板引用的每一个 card_id 都必须在 data/clues/ 里登记过（card_id 就是 clue_id）。
## 为什么不复用 _check_clue_id()：那个函数还负责登记"线索出现在哪条 NPC 动线上"，
## 且只对 clue_* 前缀做"已登记就早退"，对 note_*/sealed_* 会误报
## "已出现在 data/clues/…" —— 而卡面中文名恰恰要用到 note_*（自注）。
func _check_deduction_card_refs(where: String, field: String, cards: Array) -> void:
	if _declared_clues.is_empty():
		return
	for card in cards:
		var card_id := str(card).strip_edges()
		if card_id.is_empty():
			_err(where, "%s 里有空的 clue_id" % field)
			continue
		if not _declared_clues.has(card_id):
			_err(where, "%s 引用了未登记的 clue_id=%s%s（card_id 就是 clue_id，见 data/clues/）" % [
				field, card_id, _suggest(card_id, _declared_clues.keys()),
			])


## case_01_deduction.json → 1；格式不对返回 -1。
func _case_number_of_deduction(path: String) -> int:
	var re := RegEx.new()
	if re.compile("^case_(\\d{2})_deduction\\.json$") != OK:
		return -1
	var m := re.search(path.get_file())
	if m == null:
		return -1
	return int(m.get_string(1))


## 「缝」的定义与补写条件：本作剧情与玩法的接口
func _check_secret(path: String, meta: Dictionary, rooms: Array, duration: float) -> void:
	var secret = meta.get("secret", null)
	if typeof(secret) != TYPE_DICTIONARY:
		_err(path, "缺少 meta.secret（本案的\"缝\"：kind/target/motive/per_loop_mutation/resolve_conditions）")
		return

	var kind := str(secret.get("kind", "")).strip_edges()
	var target := str(secret.get("target", "")).strip_edges()
	if kind.is_empty():
		_err(path, "meta.secret.kind 为空（缝的类型，如 generation_number）")
	if target.is_empty():
		_err(path, "meta.secret.target 为空（被改掉了什么）")

	# 策划硬约束：改写理由必须站得住 —— 一句话说不清的理由，剧情上就是没想清楚
	var motive := str(secret.get("motive", "")).strip_edges()
	if motive.is_empty():
		_err(path, "meta.secret.motive 为空（改成这样的理由必须站得住）")
	elif motive.length() < 6:
		_warn(path, "meta.secret.motive 过短（\"%s\"）：理由需要能自圆其说" % motive)

	# --- 每遍世界的变化：本作核心差异来源 ---
	var mutation = secret.get("per_loop_mutation", null)
	if typeof(mutation) != TYPE_DICTIONARY:
		_err(path, "缺少 meta.secret.per_loop_mutation（每遍世界如何变化）")
	else:
		var mode := str(mutation.get("mode", ""))
		if not (mode in ["shrink", "grow"]):
			_err(path, "per_loop_mutation.mode=\"%s\" 非法：只允许 shrink（每遍变少）或 grow（每遍变多）" % mode)
		var rooms_ok := _unknown_against(_string_list(mutation.get("affected_rooms", [])), rooms)
		if not rooms_ok.is_empty():
			_err(path, "per_loop_mutation.affected_rooms 不在 meta.rooms 内：%s" % _with_suggestions(rooms_ok, rooms))
		if _string_list(mutation.get("affected_entities", [])).is_empty():
			_err(path, "per_loop_mutation.affected_entities 为空：每遍变化必须落在具体实体上")

	# --- 补写条件：满足即结束余页 ---
	var cond = secret.get("resolve_conditions", null)
	if typeof(cond) != TYPE_DICTIONARY:
		_err(path, "缺少 meta.secret.resolve_conditions（补写条件）")
		return
	var require_clues := _string_list(cond.get("require_clues", []))
	if require_clues.is_empty():
		_warn(path, "resolve_conditions.require_clues 为空：没有任何线索要求的结案条件等于没有谜题")
	for clue_id in require_clues:
		_check_clue_id(path, "secret.resolve_conditions.require_clues", clue_id, _case_number_of(path))
	if int(cond.get("require_min_loop", 0)) < 0:
		_err(path, "resolve_conditions.require_min_loop 不能为负（0 起：第 0 遍即可回照）")
	if str(cond.get("require_ritual", "")).strip_edges().is_empty():
		_warn(path, "resolve_conditions.require_ritual 为空：'先证后仪'要求仪式只作确认，仍需写明")


func _check_npcs(path: String, data: Dictionary, rooms: Array, duration: float, case_id: int) -> void:
	var npcs = data.get("npcs", null)
	if typeof(npcs) != TYPE_ARRAY:
		_err(path, "缺少 npcs 数组")
		return
	if npcs.is_empty():
		_err(path, "npcs 为空：一个余页至少要有活人动线")
		return
	if npcs.size() < 2:
		_warn(path, "只有 %d 个 NPC：'差异即线索'需要至少两条独立动线才成立" % npcs.size())

	var seen_ids := {}
	for i in npcs.size():
		var npc = npcs[i]
		var where := "%s npcs[%d]" % [path, i]
		if typeof(npc) != TYPE_DICTIONARY:
			_err(where, "必须是对象")
			continue
		var npc_id := str(npc.get("npc_id", "")).strip_edges()
		if npc_id.is_empty():
			_err(where, "缺少 npc_id")
		elif seen_ids.has(npc_id):
			_err(where, "npc_id=%s 重复" % npc_id)
		else:
			seen_ids[npc_id] = true
		if npc_id.begins_with("npc_") and case_id >= 0:
			# 约定：npc_<案号><序号>_<名字>，串案时一眼能看出来
			var m := RegEx.new()
			m.compile("^npc_(\\d{2})(\\d)?_")
			var hit := m.search(npc_id)
			if hit != null and int(hit.get_string(1)) != case_id:
				_warn(where, "npc_id=%s 的案号前缀 %s 与 case_id=%d 不一致" % [npc_id, hit.get_string(1), case_id])

		var default_room := str(npc.get("default_room", ""))
		if default_room.is_empty():
			_err(where, "缺少 default_room")
		elif not default_room in rooms:
			_err(where, "default_room=%s 不在 meta.rooms 内%s" % [default_room, _suggest(default_room, rooms)])

		var timeline = npc.get("timeline", null)
		if typeof(timeline) != TYPE_ARRAY or timeline.is_empty():
			_err(where, "timeline 为空：至少要有第 0 秒节点")
			continue

		var used_seconds := {}
		var last_second := -1
		var has_zero := false
		for j in timeline.size():
			var node = timeline[j]
			var node_where := "%s timeline[%d]" % [where, j]
			if typeof(node) != TYPE_DICTIONARY:
				_err(node_where, "必须是对象")
				continue
			if not node.has("second"):
				_err(node_where, "缺少 second")
				continue
			var second := int(node.get("second"))
			if second < 0 or float(second) >= duration:
				_err(node_where, "second=%d 越界：必须 0 <= second < %d（余页长度）" % [second, int(duration)])
			if used_seconds.has(second):
				_err(node_where, "同一 NPC 在第 %d 秒有重复节点（解析器会直接报错）" % second)
			used_seconds[second] = true
			if second == 0:
				has_zero = true
			if second < last_second:
				_warn(node_where, "second=%d 出现在 %d 之后：规格要求按升序书写" % [second, last_second])
			last_second = second

			var room := str(node.get("room", ""))
			if room.is_empty():
				_err(node_where, "缺少 room")
			elif not room in rooms:
				_err(node_where, "room=%s 不在 meta.rooms 内%s" % [room, _suggest(room, rooms)])

			var clue_id := str(node.get("clue_id", "")).strip_edges()
			if not clue_id.is_empty():
				_check_clue_id(path, node_where, clue_id, case_id)
				stats["clue_refs"] += 1

			# 观察点的遍数锁（M2）：`loop_min` = 从第几遍起才看得见（0 = 第一遍就看得见）。
			# 设计依据：docs/story/04 每条线索的"获得方式"写明了它是第几遍才被发现的。
			if node.has("loop_min"):
				var loop_min := int(node.get("loop_min"))
				if loop_min < 0:
					_err(node_where, "loop_min=%d 不能是负数（0 = 第一遍就看得见）" % loop_min)
				elif loop_min > 12:
					_warn(node_where, "loop_min=%d 太大：玩家可能永远看不到这一处" % loop_min)
				elif clue_id.is_empty():
					_warn(node_where, "只有 loop_min 没有 clue_id：这一处的遍数锁拦不住任何东西")

			var dialogue_id := str(node.get("dialogue_id", "")).strip_edges()
			if not dialogue_id.is_empty() and not _declared_dialogues.is_empty() and not _declared_dialogues.has(dialogue_id):
				_warn(node_where, "dialogue_id=%s 未在 data/dialogues/ 中定义%s" % [dialogue_id, _suggest(dialogue_id, _declared_dialogues.keys())])

			stats["timeline_nodes"] += 1
		if not has_zero:
			_err(where, "缺少 second=0 的节点（规格：一律补齐第 0 秒节点，不留警告）")
		stats["npcs"] += 1


# ---------------------------------------------------------------------------
#  线索命名法与唯一性（spec §4.1）
# ---------------------------------------------------------------------------
func _check_clue_id(path: String, where: String, clue_id: String, case_number: int) -> void:
	var re := RegEx.new()
	if not _matches(CLUE_PATTERN, clue_id):
		_err(where, "clue_id=%s 不符合命名法 clue_<案号两位>_<对象>[_<细节>]（跨案共用 clue_base_*，自注 note_*，封印 sealed_*）" % clue_id)
		return
	var parts := clue_id.split("_")
	var prefix := parts[0]
	var body := parts[1] if parts.size() > 1 else ""
	if prefix == "clue" and body != "base" and body.length() >= 2 and body.is_valid_int():
		# 案号前缀必须与本案一致；像 clue_91_* 这种"9+1"的写法很容易写错，必须挡住
		var num := int(body)
		if case_number >= 0 and num != case_number and num != case_number * 10 and num != case_number * 10 + 1:
			_warn(where, "clue_id=%s 的案号段 %s 与 case_id=%d 不一致（案号两位，如案九→clue_91_*）" % [clue_id, body, case_number])
	if prefix == "clue" and _declared_clues.has(clue_id):
		return
	if _clue_owner.has(clue_id):
		var owner: String = _clue_owner[clue_id]
		# 同一线索在多个 NPC 动线里被"目击"是合法的；同文件重复也只是噪声，故降为警告
		if not owner.begins_with(path):
			_warn(where, "clue_id=%s 已出现在 %s（同一 id 全作唯一，跨案共用请用 clue_base_ 前缀）" % [clue_id, owner])
	else:
		_clue_owner[clue_id] = where
	if not _declared_clues.is_empty() and not _declared_clues.has(clue_id):
		_warn(where, "clue_id=%s 未在 data/clues/ 登记%s" % [clue_id, _suggest(clue_id, _declared_clues.keys())])


func _collect_declared_clues() -> void:
	for path in _list_files(CLUE_DIR, ".json"):
		var data: Variant = _parse_json_file(path)
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var entries = data.get("clues", data)
		var list: Array = []
		if typeof(entries) == TYPE_ARRAY:
			list = entries
		elif typeof(entries) == TYPE_DICTIONARY:
			list = entries.values()
		for item in list:
			if typeof(item) == TYPE_DICTIONARY:
				var id := str(item.get("clue_id", "")).strip_edges()
				if not id.is_empty():
					_declared_clues[id] = path
	stats["clues_declared"] = _declared_clues.size()


func _collect_declared_dialogues() -> void:
	for path in _list_files(DIALOGUE_DIR, ".json"):
		var data: Variant = _parse_json_file(path)
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var entries = data.get("dialogues", {})
		if typeof(entries) == TYPE_DICTIONARY:
			for key in entries.keys():
				_declared_dialogues[str(key)] = path
	stats["dialogues_declared"] = _declared_dialogues.size()


# ---------------------------------------------------------------------------
#  小工具
# ---------------------------------------------------------------------------
func _parse_json_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		_err(path, "文件不存在")
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_err(path, "无法打开：%s" % error_string(FileAccess.get_open_error()))
		return null
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		# 注意：Godot 4 的 JSON 只有 get_error_line()（0 基）与 get_error_message()，
		# 不存在 get_error_column() —— 早期版本踩过这个坑。
		_err(path, "JSON 语法错误：第 %d 行 %s" % [json.get_error_line() + 1, json.get_error_message()])
		return null
	return json.data


func _list_files(dir_path: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(suffix):
			out.append(dir_path.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _string_list(value: Variant) -> Array:
	var out: Array = []
	if typeof(value) == TYPE_ARRAY:
		for item in value:
			out.append(str(item))
	return out


## 正则匹配。注意：`RegEx.compile()` 返回的是 Error 枚举而不是 RegEx 本身，
## 所以 `re.compile(P).search(s)` 这种链式写法会报
## "Cannot call function on enum value" —— 必须分两步。
func _matches(pattern: String, text: String) -> bool:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return false
	return re.search(text) != null


func _unique(list: Array) -> Array:
	var seen := {}
	var out: Array = []
	for item in list:
		var key := str(item)
		if not seen.has(key):
			seen[key] = true
			out.append(item)
	return out


func _duplicates(list: Array) -> Array:
	var seen := {}
	var dups: Array = []
	for item in list:
		var key := str(item)
		if seen.has(key) and not key in dups:
			dups.append(key)
		seen[key] = true
	return dups


## 返回 candidates 中"不在 allowed 里"的项（保持原顺序）
func _unknown_against(candidates: Array, allowed: Array) -> Array:
	var out: Array = []
	for item in candidates:
		if not str(item) in allowed:
			out.append(item)
	return out


func _with_suggestions(bad: Array, allowed: Array) -> String:
	var parts: Array[String] = []
	for item in bad:
		parts.append("%s%s" % [str(item), _suggest(str(item), allowed)])
	return ", ".join(parts)


## 拼写建议：编辑距离最近且距离 <= 3 的候选（"对着报错猜名字"是纯粹的时间浪费）
func _suggest(word: String, candidates: Array) -> String:
	var best := ""
	var best_distance := 4
	for candidate in candidates:
		var text := str(candidate)
		var distance := _edit_distance(word, text)
		if distance < best_distance:
			best_distance = distance
			best = text
	if best.is_empty():
		return ""
	return "（是否想写 \"%s\"？）" % best


func _edit_distance(a: String, b: String) -> int:
	var la := a.length()
	var lb := b.length()
	if la == 0:
		return lb
	if lb == 0:
		return la
	var previous: Array[int] = []
	for j in lb + 1:
		previous.append(j)
	for i in range(1, la + 1):
		var current: Array[int] = [i]
		for j in range(1, lb + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			current.append(min(min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost))
		previous = current
	return previous[lb]


func _case_number_of(path: String) -> int:
	var re := RegEx.new()
	re.compile(CASE_FILE_PATTERN)
	var m := re.search(path.get_file())
	if m == null:
		return -1
	return int(m.get_string(1))
