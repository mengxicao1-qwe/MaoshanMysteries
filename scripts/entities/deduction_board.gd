extends Node
## deduction_board.gd —— 推演板与矛盾高亮（M1 第 ④ 步 / Entities）
##
## 玩法定位：docs/market/01 §2.5「时间循环品类的五种死法」的死法 3 —— 玩家不知道该想什么。
## 本组件把玩家【已入录】的线索卡拼成推论、把"对不上"的地方顶到最前，并在连续若干遍没有新线索时
## 主动给出下一条线索的落点（room/second/npc_id 与案件拍点一致）。
##
## 数据（只读）：data/deduction/case_NN_deduction.json
##   deductions[]  : require_cards 全部入录 ⇒ 该推论成立（unlocked）；core = 它在结案主链上
##   conflicts[]   : require_cards 全部入录 ⇒ 该矛盾"点亮"（置顶高亮）；
##                   resolve_cards 全部入录 ⇒ resolved（写"已收束"，但仍留在板上——它仍是本案的结论之一）
##   stuck_hints[] : 阈值 + lead_clue + 拍点（room/second/npc_id）
## 卡面中文名来自 data/clues/case_NN_clues.json 的 clues[].name（**card_id 就是 clue_id**）。
##
## 为什么不引用 Autoload：与 scripts/entities/ 其它组件同一裁定（AGENTS.md §6）——"谁记得线索"靠
## set_memory_manager() 注入，无头测试能塞夹具，`--check-only --script` 也不会误报。
## 为什么 extends Node 而不是 RefCounted：表现层要 add_child() 进树、生命周期跟着 HUD；
## 本组件不订阅任何 Autoload 信号、不持有 RefCounted 外部引用 ⇒ free() 之后不留悬空引用。
## 为什么一个字节都不写 user://：线索是核心层（clue_store.gd 双档轮换）的持久状态，这里只读。
##
## 规格含糊处由本文件拍板的四点（改之前先看这里）：
##  1) resolve_cards 为空 ⇒ resolved 恒为 false。空集"全部入录"是逻辑上的真空真；若照真空真判真，
##     案一三个核心矛盾（cf_03 / cf_04 / cf_06，正是本案的"缝"）会在开局就被写成"已收束"，
##     板上再不会有未收束项 —— "矛盾高亮"这个玩法点直接消失。悬案的意义就是一直悬着。
##  2) stuck_hint 的取舍：meta.stuck_semantics 说"lead_clue 已入录就跳过这一条，取第一条'还没入录'的"，
##     但只说"取第一条"会卡死（第 1 条提示的线索一旦到手，同阈值下就再也不给东西，正好砸在死法 3 上）。
##     本实现：先定位【最早达到阈值】的那一条，再从那里往后找【第一条 lead 尚未入录】的；都入录了才返回 {}。
##     这样既不会一开局就剧透后面的落点（阈值没到不给），也不会因为前一条做完了就什么都不给。
##  3) 谁记得线索：显式 set_owned_clues() 优先于注入的 memory（测试夹具要钉住一个确定集合）；
##     两者都没有 = 空集（板上一无所有，但不算 error）。reset() 会清掉显式集合，【不碰】注入的 memory。
##  4) 线索卡计数口径：describe() 的分母/分子按【线索台账】算（案一 14 条），因为玩家眼里"我收集到的卡"
##     是台账口径；板上没用到的那张（sealed_01 缺损记录）也算他已入录的卡。板内查询仍只认板上出现过的卡。
##
## 用法（表现层）：
##     var board = preload("res://scripts/entities/deduction_board.gd").new()
##     board.name = "DeductionBoard"
##     add_child(board)
##     board.configure(1)
##     board.set_memory_manager(_lamp)     # 有 get_available_clues() 就用它；否则退回 has_clue()
##     board.refresh()                     # 线索一变就调：板上内容真的变了才广播 board_changed

# ============================================================================
#  信号与常量
# ============================================================================

## 板上内容真的变了才广播（不是每次 refresh 都广播）：HUD 用它刷新文本，不用自己比对。
signal board_changed(unlocked_count: int, ready_conflict_count: int)

const DEFAULT_CASE_ID: int = 1
const DATA_DIR: String = "res://data/deduction"
const CLUE_DIR: String = "res://data/clues"
const SCENARIO_DIR: String = "res://data/scenarios"

## 案一余页 = 360 秒（工程默认 420）。拍点 second 的合法上界：真的案件文件里
## loop_duration_seconds 有值时以它为准（换案更长的余页不用改代码），读不到才用这个默认值。
const DEFAULT_LOOP_SECONDS: int = 360

const SEVERITY_CORE: String = "核心"
const SEVERITY_MINOR: String = "次要"
const SEVERITIES: Array[String] = [SEVERITY_CORE, SEVERITY_MINOR]

## board_lines() 里各种行的前缀（表现层测试与 HUD 都按这个认）。
const PREFIX_CONFLICT: String = "⚠ 对不上："
const PREFIX_RESOLVED: String = "✓ 已收束："
const PREFIX_CORE: String = "★ "
const PREFIX_PLAIN: String = "· "
const PREFIX_NEARLY: String = "…差 "

# ============================================================================
#  状态
# ============================================================================

var _configured: bool = false
var _case_id: int = -1
var _source: String = ""
var _errors: Array[String] = []
var _warnings: Array[String] = []

## 表（解析后的归一化行；顺序 = 表内原顺序，"表内原顺序"是排序规则的最后一档，不能丢）。
var _deductions: Array[Dictionary] = []
var _conflicts: Array[Dictionary] = []
var _stuck_hints: Array[Dictionary] = []

## id → 表内下标（排序用它做稳定 tiebreak：Godot 的 sort_custom() 不是稳定排序）。
var _deduction_index: Dictionary = {}
var _conflict_index: Dictionary = {}

## 板上出现过的 card_id（表内顺序，去重）：owned_cards() 按这个顺序出。
var _card_ids: Array[String] = []

## 线索台账：合法 clue_id / 卡面中文名 / 环节（校验与说明文案用）。
var _clue_ids: Dictionary = {}
var _clue_order: Array[String] = []
var _clue_names: Dictionary = {}
var _card_chains: Dictionary = {}

## 案里的 NPC 显示名（npc_id → display_name）；从案件场景读，读不到就空串（不是 error）。
var _npc_names: Dictionary = {}
var _loop_seconds: int = DEFAULT_LOOP_SECONDS

## 线索来源：显式集合优先，其次注入的 memory（详见头部裁定 3）。
var _manual_clues: Array[String] = []
var _manual_set: bool = false
var _memory: Node = null

## 运行期缓存（保持与"当前线索集合"同步）。
var _owned: Dictionary = {}
var _unlocked: Array[Dictionary] = []
var _locked: Array[Dictionary] = []
var _nearly: Array[Dictionary] = []
var _ready: Array[Dictionary] = []
var _pending: Array[Dictionary] = []

## 两个指纹：线索集合（决定要不要重算）/ 板上内容（决定要不要广播）。
var _signature: String = ""
var _board_signature: String = ""


# ============================================================================
#  配置：读数据
# ============================================================================

## 读真实数据：data/deduction/case_NN_deduction.json + data/clues/case_NN_clues.json。
## 返回 true = 装载成功且没有 error（数据有问题时表照样装进来，用 get_errors() 看，用 is_ok() 判可用性）。
func configure(case_id: int = DEFAULT_CASE_ID) -> bool:
	_reset_tables()
	_case_id = case_id
	_source = "%s/case_%02d_deduction.json" % [DATA_DIR, case_id]

	var data: Dictionary = _read_json(_source)
	if data.is_empty():
		_err("读不到推演板数据：%s" % _source)
		return false

	# 线索台账：卡面中文名与"合法 clue_id"的唯一来源。读不到不阻断（卡名退回 clue_id、引用不校验），
	# 因为这属于"降级但还能玩"，不是结构性坏掉。
	var clue_path: String = "%s/case_%02d_clues.json" % [CLUE_DIR, case_id]
	var clue_data: Dictionary = _read_json(clue_path, false)
	if clue_data.is_empty():
		_warn("读不到线索台账：%s（卡面名退回 clue_id，clue_id 引用不再校验）" % clue_path)
	else:
		_load_clue_registry(clue_data)

	_load_case_context(case_id)
	_build_from_data(data)
	return _finish_configure()


## 用内存里的表配置（测试夹具 / 以后的热更）。options 可给：
##   clue_names : {clue_id: 卡面中文名} —— 给了就【取代】文件台账充当合法 clue_id 名单（夹具要能钉死校验范围）
##   card_chains: {clue_id: 环节名}     —— 合并进环节表
func configure_with_rules(data: Dictionary, options: Dictionary = {}) -> bool:
	_reset_tables()
	_case_id = _as_int(_as_dict(data.get("meta")).get("case_id"), DEFAULT_CASE_ID)
	_source = "<inline>"
	_apply_options(options)
	_build_from_data(data)
	return _finish_configure()


func is_configured() -> bool:
	return _configured


## 配置成功且没有 error（warning 不算失败）。
func is_ok() -> bool:
	return _configured and _errors.is_empty()


func get_case_id() -> int:
	return _case_id


func get_source() -> String:
	return _source


func _finish_configure() -> bool:
	_configured = true
	# 装完先算一次：表里若有 require_cards 为空的推论，它在开局就成立，广播也要按真实内容给。
	_recompute()
	return is_ok()


func _reset_tables() -> void:
	_configured = false
	_source = ""
	_errors.clear()
	_warnings.clear()
	_deductions.clear()
	_conflicts.clear()
	_stuck_hints.clear()
	_deduction_index.clear()
	_conflict_index.clear()
	_card_ids.clear()
	_clue_ids.clear()
	_clue_order.clear()
	_clue_names.clear()
	_card_chains.clear()
	_npc_names.clear()
	_loop_seconds = DEFAULT_LOOP_SECONDS
	_manual_clues.clear()
	_manual_set = false
	# _memory 【不】在这里清：configure() 之后表现层才注入 memory，清掉会把注入顺序变成陷阱。
	_owned.clear()
	_unlocked.clear()
	_locked.clear()
	_nearly.clear()
	_ready.clear()
	_pending.clear()
	_signature = ""
	_board_signature = ""


## 线索台账：clues[].{clue_id, name, chain}。note_* 这类自注也在台账里，照样是合法 card_id。
func _load_clue_registry(clue_data: Dictionary) -> void:
	var rows: Variant = clue_data.get("clues")
	if not (rows is Array):
		_warn("线索台账没有 clues 数组：card_name() 退回 clue_id")
		return
	for item in (rows as Array):
		if not (item is Dictionary):
			continue
		var row: Dictionary = item
		var clue_id: String = _as_string(row.get("clue_id"))
		if clue_id.is_empty():
			continue
		if not _clue_ids.has(clue_id):
			_clue_ids[clue_id] = true
			_clue_order.append(clue_id)
		_clue_names[clue_id] = _as_string(row.get("name"))
		_card_chains[clue_id] = _as_string(row.get("chain"))


## 夹具给的 options 覆盖/取代文件台账。
func _apply_options(options: Dictionary) -> void:
	var names: Dictionary = _as_dict(options.get("clue_names"))
	if not names.is_empty():
		_clue_names = names.duplicate()
		_clue_ids.clear()
		_clue_order.clear()
		for key in _clue_names.keys():
			var clue_id: String = _as_string(key)
			_clue_ids[clue_id] = true
			_clue_order.append(clue_id)
	var chains: Dictionary = _as_dict(options.get("card_chains"))
	for key in chains.keys():
		_card_chains[_as_string(key)] = _as_string(chains[key])


## 案里的余页秒数与 NPC 显示名（stuck_hint 的 npc_name 用它）。纯尽力而为：读不到就留空，
## 不给 warning —— 这一步失败只影响"提示里多一个名字"，不该在 HUD 日志里刷噪声。
func _load_case_context(case_id: int) -> void:
	var path: String = _find_scenario_path(case_id)
	if path.is_empty():
		return
	var data: Dictionary = _read_json(path, false)
	if data.is_empty():
		return
	var duration: int = _as_int(data.get("loop_duration_seconds"), 0)
	if duration > 0:
		_loop_seconds = duration
	var rows: Variant = data.get("npcs")
	if not (rows is Array):
		return
	for item in (rows as Array):
		if not (item is Dictionary):
			continue
		var row: Dictionary = item
		var npc_id: String = _as_string(row.get("npc_id"))
		if npc_id.is_empty():
			continue
		var display: String = _as_string(row.get("display_name"))
		if display.is_empty():
			display = _as_string(row.get("name"))
		_npc_names[npc_id] = display


## data/scenarios/case_NN_*.json（找前缀，别把文件名写死：换案时文件名可能带别的后缀）。
func _find_scenario_path(case_id: int) -> String:
	var prefix: String = "case_%02d_" % case_id
	var files: PackedStringArray = DirAccess.get_files_at(SCENARIO_DIR)
	for file_name in files:
		if file_name.begins_with(prefix) and file_name.ends_with(".json"):
			return "%s/%s" % [SCENARIO_DIR, file_name]
	return ""


## 解析三张表 + 校验。顺序不可换：先解析（顺手做行级校验）再收 card 顺序，owned_cards() 靠它。
func _build_from_data(data: Dictionary) -> void:
	_parse_deductions(data.get("deductions"))
	_parse_conflicts(data.get("conflicts"))
	_parse_stuck_hints(data.get("stuck_hints"))
	_collect_card_ids()


func _parse_deductions(value: Variant) -> void:
	if value == null:
		_warn("推演板数据没有 deductions 表")
		return
	if not (value is Array):
		_err("deductions 不是数组（拿到了 %s）" % _type_name(value))
		return
	var rows: Array = value
	for index in range(rows.size()):
		var item: Variant = rows[index]
		var path: String = "deductions[%d]" % index
		if not (item is Dictionary):
			_err("%s 不是对象" % path)
			continue
		var raw: Dictionary = item
		var row: Dictionary = {}
		var deduction_id: String = _as_string(raw.get("deduction_id"))
		row["deduction_id"] = deduction_id
		row["title"] = _as_string(raw.get("title"))
		row["text"] = _as_string(raw.get("text"))
		row["chain"] = _as_string(raw.get("chain"))
		row["core"] = _as_bool(raw.get("core"))
		row["require_cards"] = _check_cards(raw.get("require_cards"), path, "require_cards")
		_check_common_row(row, path, "deduction_id")
		if _deduction_index.has(deduction_id) and not deduction_id.is_empty():
			_err("%s 的 deduction_id 重复：%s（前一条在 deductions[%d]）" % [
				path, deduction_id, int(_deduction_index[deduction_id]),
			])
			continue
		# require_cards 为空的推论一开局就成立 —— 数据上合法，但多半是漏了卡，只给 warning。
		if (row["require_cards"] as Array).is_empty():
			_warn("%s（%s）的 require_cards 为空：它在开局就算成立" % [path, _label_of(row, deduction_id)])
		_deduction_index[deduction_id] = _deductions.size()
		_deductions.append(row)


func _parse_conflicts(value: Variant) -> void:
	if value == null:
		_warn("推演板数据没有 conflicts 表")
		return
	if not (value is Array):
		_err("conflicts 不是数组（拿到了 %s）" % _type_name(value))
		return
	var rows: Array = value
	for index in range(rows.size()):
		var item: Variant = rows[index]
		var path: String = "conflicts[%d]" % index
		if not (item is Dictionary):
			_err("%s 不是对象" % path)
			continue
		var raw: Dictionary = item
		var row: Dictionary = {}
		var conflict_id: String = _as_string(raw.get("conflict_id"))
		row["conflict_id"] = conflict_id
		row["title"] = _as_string(raw.get("title"))
		row["text"] = _as_string(raw.get("text"))
		row["severity"] = _as_string(raw.get("severity"))
		row["require_cards"] = _check_cards(raw.get("require_cards"), path, "require_cards")
		row["resolve_cards"] = _check_cards(raw.get("resolve_cards"), path, "resolve_cards", false)
		_check_common_row(row, path, "conflict_id")
		if not SEVERITIES.has(String(row["severity"])):
			_err("%s 的 severity 非法：'%s'（只认 %s）" % [
				path, String(row["severity"]), "/".join(PackedStringArray(SEVERITIES)),
			])
		if _conflict_index.has(conflict_id) and not conflict_id.is_empty():
			_err("%s 的 conflict_id 重复：%s（前一条在 conflicts[%d]）" % [
				path, conflict_id, int(_conflict_index[conflict_id]),
			])
			continue
		if (row["require_cards"] as Array).is_empty():
			_warn("%s（%s）的 require_cards 为空：它在开局就点亮" % [path, _label_of(row, conflict_id)])
		_conflict_index[conflict_id] = _conflicts.size()
		_conflicts.append(row)


func _parse_stuck_hints(value: Variant) -> void:
	if value == null:
		_warn("推演板数据没有 stuck_hints 表")
		return
	if not (value is Array):
		_err("stuck_hints 不是数组（拿到了 %s）" % _type_name(value))
		return
	var rows: Array = value
	for index in range(rows.size()):
		var item: Variant = rows[index]
		var path: String = "stuck_hints[%d]" % index
		if not (item is Dictionary):
			_err("%s 不是对象" % path)
			continue
		var raw: Dictionary = item
		var row: Dictionary = {}
		var threshold: int = _as_int(raw.get("after_loops_without_progress"), 0)
		row["after_loops_without_progress"] = threshold
		row["lead_clue"] = _as_string(raw.get("lead_clue"))
		row["npc_id"] = _as_string(raw.get("npc_id"))
		row["room"] = _as_string(raw.get("room"))
		row["second"] = _as_int(raw.get("second"), -1)
		row["text"] = _as_string(raw.get("text"))
		if threshold < 1:
			_err("%s 的 after_loops_without_progress < 1：%d（这条提示开局就会出现）" % [path, threshold])
		if String(row["text"]).is_empty():
			_err("%s 的 text 缺失（提示没话可说）" % path)
		if String(row["room"]).is_empty():
			_err("%s 的 room 为空（提示必须指得出地方）" % path)
		var second: int = int(row["second"])
		if second < 0 or second >= _loop_seconds:
			_err("%s 的 second 不在 0..%d：%d" % [path, _loop_seconds - 1, second])
		var lead: String = String(row["lead_clue"])
		if lead.is_empty():
			_err("%s 的 lead_clue 缺失" % path)
		elif not _clue_ids.is_empty() and not _clue_ids.has(lead):
			_err("%s 的 lead_clue 引用了不存在的 clue_id：%s%s" % [
				path, lead, _suggest(lead, _clue_order) if not _clue_names.is_empty() else "",
			])
		_stuck_hints.append(row)
	# 按阈值升序（stuck_hint() 依赖这个顺序；同阈值保持表内原顺序 —— 用下标做稳定排序）。
	var decorated: Array = []
	for index in range(_stuck_hints.size()):
		decorated.append({"index": index, "row": _stuck_hints[index]})
	decorated.sort_custom(_compare_hint_entries)
	_stuck_hints.clear()
	for entry in decorated:
		_stuck_hints.append(entry["row"])


## 行级通用校验：id 为空 / title / text 缺失。
func _check_common_row(row: Dictionary, path: String, id_key: String) -> void:
	var row_id: String = String(row.get(id_key, ""))
	if row_id.is_empty():
		_err("%s 的 %s 为空" % [path, id_key])
	if String(row.get("title", "")).is_empty():
		_err("%s 的 title 缺失" % path)
	if String(row.get("text", "")).is_empty():
		_err("%s 的 text 缺失" % path)


## 校验一组卡：必须是字符串数组；每个 id 都要在线索台账里（要报出是哪个 id）。
## required = true 时"整个字段缺失"算 error；resolve_cards 缺失 = 没有卡能收束它，只当空表。
func _check_cards(value: Variant, path: String, field: String, required: bool = true) -> Array[String]:
	var result: Array[String] = []
	if value == null:
		if required:
			_err("%s 的 %s 缺失" % [path, field])
		return result
	if not (value is Array):
		_err("%s 的 %s 不是数组（拿到了 %s）" % [path, field, _type_name(value)])
		return result
	for item in (value as Array):
		if not (item is String):
			_err("%s 的 %s 里有非字符串项（拿到了 %s）" % [path, field, _type_name(item)])
			continue
		var clue_id: String = item
		if clue_id.is_empty():
			_err("%s 的 %s 里有空字符串" % [path, field])
			continue
		if not _clue_ids.is_empty() and not _clue_ids.has(clue_id):
			_err("%s 的 %s 引用了不存在的 clue_id：%s%s" % [
				path, field, clue_id, _suggest(clue_id, _clue_order) if not _clue_names.is_empty() else "",
			])
		result.append(clue_id)
	return result


## 板上出现过的卡（推论在前、矛盾在后，各自按表内顺序；去重）—— 表内顺序是 owned_cards() 的口径。
func _collect_card_ids() -> void:
	_card_ids.clear()
	var seen: Dictionary = {}
	for row in _deductions:
		_add_card_ids(row["require_cards"], seen)
	for row in _conflicts:
		_add_card_ids(row["require_cards"], seen)
		_add_card_ids(row["resolve_cards"], seen)


func _add_card_ids(cards: Array[String], seen: Dictionary) -> void:
	for clue_id in cards:
		if seen.has(clue_id):
			continue
		seen[clue_id] = true
		_card_ids.append(clue_id)


# ============================================================================
#  注入与刷新
# ============================================================================

## 注入"谁记得线索"。有 get_available_clues()（心灯）就用它；否则退回 get_clues() / has_clue()。
## 与 npc_memory.set_memory_manager() 同一风格：注入即刷新一次。
func set_memory_manager(memory: Node) -> void:
	_memory = memory
	refresh()


func get_memory_manager() -> Node:
	return _memory


## 直接给一份已入录的线索集合（测试夹具 / 无 memory 的场景）。给了它就以它为准。
func set_owned_clues(clue_ids: Array) -> void:
	_manual_clues.clear()
	var seen: Dictionary = {}
	for item in clue_ids:
		if not (item is String):
			continue
		var clue_id: String = item
		if clue_id.is_empty() or seen.has(clue_id):
			continue
		seen[clue_id] = true
		_manual_clues.append(clue_id)
	_manual_set = true
	refresh()


## 目前生效的已入录集合（显式集合优先；否则读注入的 memory；都没有 = 空）。
func get_owned_clues() -> Array[String]:
	var result: Array[String] = []
	for clue_id in _manual_clues:
		result.append(clue_id)
	if _manual_set:
		return result
	return _read_memory_clues()


## 重算并（只在板上内容真的变了时）广播 board_changed。
func refresh() -> void:
	_recompute()


## 清空运行期状态，回到"什么线索都没有"的起点。【不碰】注入的 memory：
## 线索是核心层（clue_store.gd）的持久状态，本组件只读（与 npc_memory.reset() 同一裁定）。
## 显式 set_owned_clues() 的集合会被清掉 —— reset 是"回到起点"，不是"保留我上次塞的夹具"。
func reset() -> void:
	_manual_clues.clear()
	_manual_set = false
	_owned.clear()
	_unlocked.clear()
	_locked.clear()
	_nearly.clear()
	_ready.clear()
	_pending.clear()
	_recompute()


# ============================================================================
#  查询：卡与推论
# ============================================================================

## 已入录且【本表出现过】的 card_id，保持表内顺序。
func owned_cards() -> Array[String]:
	_ensure_fresh()
	var result: Array[String] = []
	for clue_id in _card_ids:
		if _owned.has(clue_id):
			result.append(clue_id)
	return result


func unlocked_deductions() -> Array[Dictionary]:
	_ensure_fresh()
	return _copy_rows(_unlocked)


## 还没成立的推论：同形 + missing_cards / missing_names。
func locked_deductions() -> Array[Dictionary]:
	_ensure_fresh()
	return _copy_rows(_locked)


## 恰好差 1 张卡的那些（"差一步"显示用），顺序 = 表内原顺序。
func nearly_locked() -> Array[Dictionary]:
	_ensure_fresh()
	return _copy_rows(_nearly)


## 已经点亮的矛盾。排序：resolved == false 在前 → severity == "核心" 在前 → 表内原顺序。
func ready_conflicts() -> Array[Dictionary]:
	_ensure_fresh()
	return _copy_rows(_ready)


## 还没点亮的矛盾：同形 + missing_cards / missing_names。
func pending_conflicts() -> Array[Dictionary]:
	_ensure_fresh()
	return _copy_rows(_pending)


func get_deduction(deduction_id: String) -> Dictionary:
	_ensure_fresh()
	if not _deduction_index.has(deduction_id):
		return {}
	var row: Dictionary = _deductions[int(_deduction_index[deduction_id])]
	return _deduction_view(row)


func has_deduction(deduction_id: String) -> bool:
	return _deduction_index.has(deduction_id)


func get_conflict(conflict_id: String) -> Dictionary:
	_ensure_fresh()
	if not _conflict_index.has(conflict_id):
		return {}
	var row: Dictionary = _conflicts[int(_conflict_index[conflict_id])]
	return _conflict_view(row)


func has_conflict(conflict_id: String) -> bool:
	return _conflict_index.has(conflict_id)


func deduction_ids() -> Array[String]:
	var result: Array[String] = []
	for row in _deductions:
		result.append(String(row["deduction_id"]))
	return result


func conflict_ids() -> Array[String]:
	var result: Array[String] = []
	for row in _conflicts:
		result.append(String(row["conflict_id"]))
	return result


## 这张卡在游戏里叫什么。台账里没有就退回 clue_id —— HUD 直接贴文本，宁可显示 id 也不要空串。
func card_name(clue_id: String) -> String:
	var name: String = _as_string(_clue_names.get(clue_id))
	if name.is_empty():
		return clue_id
	return name


## 这张卡属于哪一环（说明文案用）。台账/夹具都没有就给空串。
func card_chain(clue_id: String) -> String:
	return _as_string(_card_chains.get(clue_id))


func npc_name(npc_id: String) -> String:
	return _as_string(_npc_names.get(npc_id))


## 该推论现在成立吗（不在表里 = false）。
func is_deduction_unlocked(deduction_id: String) -> bool:
	_ensure_fresh()
	for row in _unlocked:
		if String(row["deduction_id"]) == deduction_id:
			return true
	return false


## 该矛盾现在点亮了吗（不在表里 = false）。
func is_conflict_ready(conflict_id: String) -> bool:
	_ensure_fresh()
	for row in _ready:
		if String(row["conflict_id"]) == conflict_id:
			return true
	return false


func total_deduction_count() -> int:
	return _deductions.size()


func total_conflict_count() -> int:
	return _conflicts.size()


func total_stuck_hint_count() -> int:
	return _stuck_hints.size()


## 线索台账条数（案一 14；没读台账 = 0）。HUD 的"N/14"分母用它。
func total_clue_count() -> int:
	return _clue_order.size()


# ============================================================================
#  查询：卡关提示
# ============================================================================

## 连续 loops_without_progress 遍没有新线索时，下一条该去哪儿找。
## 规则（见头部裁定 2）：先定位【最早达到阈值】的那一条，再从那里往后找【第一条 lead 尚未入录】的；
## 一条都找不到（阈值还没到，或所有 lead 都已入录）⇒ {}。
## loop_index 目前只作记录用（提示文案/后续按遍数分支的裁定留给表现层），不影响返回。
func stuck_hint(loops_without_progress: int, loop_index: int = -1) -> Dictionary:
	_ensure_fresh()
	if _stuck_hints.is_empty():
		return {}
	var start: int = -1
	for index in range(_stuck_hints.size()):
		if int(_stuck_hints[index]["after_loops_without_progress"]) <= loops_without_progress:
			start = index
			break
	if start < 0:
		return {}
	for index in range(start, _stuck_hints.size()):
		var row: Dictionary = _stuck_hints[index]
		var lead: String = String(row["lead_clue"])
		if _owned.has(lead):
			continue
		var npc_id: String = String(row["npc_id"])
		return {
			"after_loops_without_progress": int(row["after_loops_without_progress"]),
			"text": String(row["text"]),
			"lead_clue": lead,
			"lead_name": card_name(lead),
			"npc_id": npc_id,
			"npc_name": npc_name(npc_id),
			"room": String(row["room"]),
			"second": int(row["second"]),
		}
	return {}


# ============================================================================
#  表现层文案
# ============================================================================

## 一行汇总（HUD 顶栏）。例：推演板：3 条推论成立 / 6 条对不上（其中 2 条未收束）｜线索卡 4/14
## "对不上"的口径 = 【已点亮】的矛盾数（不是表里一共几条），否则没点亮时也会报"6 条对不上"。
func describe() -> String:
	_ensure_fresh()
	return "推演板：%d 条推论成立 / %d 条对不上（其中 %d 条未收束）｜线索卡 %d/%d" % [
		_unlocked.size(), _ready.size(), _unresolved_count(), _owned_clue_count(), _clue_total_count(),
	]


## 一处矛盾的一行说明（含标题与"已收束/未收束"）。id 不在表里 = 空串。
func describe_conflict(conflict_id: String) -> String:
	_ensure_fresh()
	if not _conflict_index.has(conflict_id):
		return ""
	var row: Dictionary = _conflicts[int(_conflict_index[conflict_id])]
	var resolved: bool = _is_resolved(row)
	var state: String = "已收束" if resolved else "未收束"
	# 已收束仍写 severity：它还是本案的结论之一，只是不再顶在最前（数据 meta.conflict_semantics）。
	return "%s｜%s｜%s%s" % [
		String(row["title"]), String(row["severity"]), state,
		"（本案的结论之一）" if resolved else "",
	]


## 可直接贴到 HUD 的文本行：点亮的矛盾在最前（已收束的写 ✓），其后是成立的推论（core 加 ★），
## 再其后是"差一步"的推论（写出缺哪张卡的中文名）。
## max_lines = 能贴几行；超出就截断，末行写"（还有 N 条未列）"（N = 被截掉的行数）。
func board_lines(max_lines: int = 12) -> Array[String]:
	_ensure_fresh()
	var all: Array[String] = []
	for row in _ready:
		var resolved: bool = bool(row["resolved"])
		all.append(("%s%s" % [PREFIX_RESOLVED if resolved else PREFIX_CONFLICT, String(row["title"])]))
	for row in _unlocked:
		all.append("%s%s" % [PREFIX_CORE if bool(row["core"]) else PREFIX_PLAIN, String(row["title"])])
	for row in _nearly:
		var names: Array[String] = row["missing_names"]
		var missing: String = names[0] if not names.is_empty() else ""
		all.append("%s%s：%s" % [PREFIX_NEARLY, missing, String(row["title"])])
	if max_lines <= 0:
		return []
	if all.size() <= max_lines:
		return all
	# 截断后总行数恰好 = max_lines：留 max_lines-1 行正文，末行是"还有 N 条未列"。
	var kept: Array[String] = []
	for index in range(max_lines - 1):
		kept.append(all[index])
	kept.append("（还有 %d 条未列）" % (all.size() - (max_lines - 1)))
	return kept


# ============================================================================
#  自检
# ============================================================================

func get_errors() -> Array[String]:
	return _copy_strings(_errors)


func get_warnings() -> Array[String]:
	return _copy_strings(_warnings)


func error_summary() -> String:
	if _errors.is_empty():
		return ""
	return "deduction_board：%d 个错误｜%s" % [_errors.size(), "\n".join(PackedStringArray(_errors))]


## 可序列化快照（JSON.stringify 安全）：给 dump-state / 调试 HUD 用。
func get_state() -> Dictionary:
	_ensure_fresh()
	var unlocked_ids: Array[String] = []
	for row in _unlocked:
		unlocked_ids.append(String(row["deduction_id"]))
	var locked_ids: Array[String] = []
	var nearly_ids: Array[String] = []
	for row in _locked:
		locked_ids.append(String(row["deduction_id"]))
	for row in _nearly:
		nearly_ids.append(String(row["deduction_id"]))
	var ready_ids: Array[String] = []
	var resolved_ids: Array[String] = []
	for row in _ready:
		ready_ids.append(String(row["conflict_id"]))
		if bool(row["resolved"]):
			resolved_ids.append(String(row["conflict_id"]))
	var pending_ids: Array[String] = []
	for row in _pending:
		pending_ids.append(String(row["conflict_id"]))
	return {
		"configured": _configured,
		"ok": is_ok(),
		"case_id": _case_id,
		"source": _source,
		"loop_seconds": _loop_seconds,
		"clue_registry_size": _clue_order.size(),
		"npc_names_size": _npc_names.size(),
		"deduction_count": _deductions.size(),
		"conflict_count": _conflicts.size(),
		"stuck_hint_count": _stuck_hints.size(),
		"owned_clue_count": _owned.size(),
		"owned_card_count": owned_cards().size(),
		"unlocked_count": _unlocked.size(),
		"unlocked_ids": unlocked_ids,
		"locked_ids": locked_ids,
		"nearly_locked_ids": nearly_ids,
		"ready_conflict_count": _ready.size(),
		"ready_conflict_ids": ready_ids,
		"resolved_conflict_ids": resolved_ids,
		"pending_conflict_ids": pending_ids,
		"unresolved_conflict_count": _unresolved_count(),
		"memory_connected": _memory != null,
		"manual_clues": _manual_set,
		"errors": _copy_strings(_errors),
		"warnings": _copy_strings(_warnings),
	}


# ============================================================================
#  内部：重算
# ============================================================================

## 查询入口先对指纹：线索集合没变就不重算（同 npc_memory._ensure_fresh()）。
func _ensure_fresh() -> void:
	if not _configured:
		return
	var current: String = _make_signature()
	if current == _signature:
		return
	_recompute()


func _recompute() -> void:
	_owned = _collect_owned()
	_signature = _make_signature()
	_unlocked.clear()
	_locked.clear()
	_nearly.clear()
	_ready.clear()
	_pending.clear()
	for row in _deductions:
		var view: Dictionary = _deduction_view(row)
		var missing: Array[String] = _missing_of(row["require_cards"])
		if missing.is_empty():
			_unlocked.append(view)
		else:
			var locked_view: Dictionary = view.duplicate(true)
			locked_view["missing_cards"] = missing
			locked_view["missing_names"] = _names_of(missing)
			_locked.append(locked_view)
			if missing.size() == 1:
				_nearly.append(locked_view)
	for row in _conflicts:
		var conflict_view: Dictionary = _conflict_view(row)
		var missing_cards: Array[String] = _missing_of(row["require_cards"])
		if missing_cards.is_empty():
			_ready.append(conflict_view)
		else:
			var pending_view: Dictionary = conflict_view.duplicate(true)
			pending_view["missing_cards"] = missing_cards
			pending_view["missing_names"] = _names_of(missing_cards)
			_pending.append(pending_view)
	_sort_ready()
	_emit_if_changed()


## 排序：resolved == false 在前 → severity == "核心" 在前 → 表内原顺序。
## Godot 的 sort_custom() 不保证稳定，所以把表内下标一起带进来当最后一档。
func _sort_ready() -> void:
	var decorated: Array = []
	for row in _ready:
		decorated.append({
			"index": int(_conflict_index.get(String(row["conflict_id"]), 9999)),
			"row": row,
		})
	decorated.sort_custom(_compare_conflict_entries)
	_ready.clear()
	for entry in decorated:
		_ready.append(entry["row"])


func _compare_conflict_entries(a: Dictionary, b: Dictionary) -> bool:
	var left: Dictionary = a["row"]
	var right: Dictionary = b["row"]
	var left_resolved: bool = bool(left["resolved"])
	var right_resolved: bool = bool(right["resolved"])
	if left_resolved != right_resolved:
		return not left_resolved
	var left_core: bool = String(left["severity"]) == SEVERITY_CORE
	var right_core: bool = String(right["severity"]) == SEVERITY_CORE
	if left_core != right_core:
		return left_core
	return int(a["index"]) < int(b["index"])


func _compare_hint_entries(a: Dictionary, b: Dictionary) -> bool:
	var left: Dictionary = a["row"]
	var right: Dictionary = b["row"]
	var left_threshold: int = int(left["after_loops_without_progress"])
	var right_threshold: int = int(right["after_loops_without_progress"])
	if left_threshold != right_threshold:
		return left_threshold < right_threshold
	return int(a["index"]) < int(b["index"])


## 板上内容真的变了才广播（HUD 靠它决定要不要重画，不用自己比对）。
func _emit_if_changed() -> void:
	var signature: String = _make_board_signature()
	if signature == _board_signature:
		return
	_board_signature = signature
	board_changed.emit(_unlocked.size(), _ready.size())


## 线索集合指纹：变了才值得重算。
func _make_signature() -> String:
	var clues: Array[String] = []
	for clue_id in _collect_owned().keys():
		clues.append(String(clue_id))
	clues.sort()
	return _join(clues, ",")


## 板上内容指纹：成立的推论 + 点亮的矛盾（含收束状态）变了才值得广播。
func _make_board_signature() -> String:
	var parts: Array[String] = []
	for row in _unlocked:
		parts.append("u:" + String(row["deduction_id"]))
	for row in _ready:
		parts.append("c:%s:%s" % [String(row["conflict_id"]), "1" if bool(row["resolved"]) else "0"])
	return _join(parts, "|")


# ============================================================================
#  内部：线索集合与视图
# ============================================================================

## 当前生效的已入录集合（字典当集合用）。显式集合优先，其次注入的 memory。
## 只收板上有用的卡无所谓——这里照实收，owned_cards() 再按表内顺序过滤（describe() 要用台账口径）。
func _collect_owned() -> Dictionary:
	var owned: Dictionary = {}
	if _manual_set:
		for clue_id in _manual_clues:
			owned[clue_id] = true
		return owned
	if _memory == null or not is_instance_valid(_memory):
		return owned
	if _memory.has_method("get_available_clues"):
		_add_ids(owned, _memory.get_available_clues())
	elif _memory.has_method("get_clues"):
		_add_ids(owned, _memory.get_clues())
	elif _memory.has_method("has_clue"):
		# 只有 has_clue() 的对象：只能按板上的卡逐张问（顺序无所谓，反正是集合）。
		for clue_id in _card_ids:
			if bool(_memory.has_clue(clue_id)):
				owned[clue_id] = true
	return owned


func _add_ids(owned: Dictionary, value: Variant) -> void:
	if not (value is Array):
		return
	for item in (value as Array):
		if item is String:
			var clue_id: String = item
			if not clue_id.is_empty():
				owned[clue_id] = true


## 读注入的 memory 的线索（get_owned_clues() 用）。
func _read_memory_clues() -> Array[String]:
	var result: Array[String] = []
	if _memory == null or not is_instance_valid(_memory):
		return result
	if _memory.has_method("get_available_clues"):
		_add_into(result, _memory.get_available_clues())
	elif _memory.has_method("get_clues"):
		_add_into(result, _memory.get_clues())
	else:
		for clue_id in _card_ids:
			if _memory.has_method("has_clue") and bool(_memory.has_clue(clue_id)):
				result.append(clue_id)
	return result


func _add_into(result: Array[String], value: Variant) -> void:
	if not (value is Array):
		return
	for item in (value as Array):
		if item is String and not result.has(item):
			result.append(item)


func _missing_of(cards: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for clue_id in cards:
		if not _owned.has(clue_id):
			result.append(clue_id)
	return result


func _names_of(cards: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for clue_id in cards:
		result.append(card_name(clue_id))
	return result


func _deduction_view(row: Dictionary) -> Dictionary:
	return {
		"deduction_id": String(row["deduction_id"]),
		"title": String(row["title"]),
		"text": String(row["text"]),
		"chain": String(row["chain"]),
		"core": bool(row["core"]),
		"require_cards": _cards_copy(row["require_cards"]),
	}


func _conflict_view(row: Dictionary) -> Dictionary:
	return {
		"conflict_id": String(row["conflict_id"]),
		"title": String(row["title"]),
		"text": String(row["text"]),
		"severity": String(row["severity"]),
		"require_cards": _cards_copy(row["require_cards"]),
		"resolve_cards": _cards_copy(row["resolve_cards"]),
		"resolved": _is_resolved(row),
	}


## resolve_cards 全部入录 ⇒ 已收束；**空表不算**（见头部裁定 1：真空真会让本案三个核心矛盾开局就"已收束"）。
func _is_resolved(row: Dictionary) -> bool:
	var resolve_cards: Array[String] = row["resolve_cards"]
	if resolve_cards.is_empty():
		return false
	return _missing_of(resolve_cards).is_empty()


func _cards_copy(cards: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for clue_id in cards:
		result.append(clue_id)
	return result


## 返回缓存行的深拷贝：调用方（HUD）改坏了自己那份也不影响板子。
func _copy_rows(rows: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row in rows:
		result.append(row.duplicate(true))
	return result


func _copy_strings(values: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(value)
	return result


## "对不上"里还没收束的条数（describe() 的"其中 N 条未收束"）。
func _unresolved_count() -> int:
	var count: int = 0
	for row in _ready:
		if not bool(row["resolved"]):
			count += 1
	return count


## 分子：已入录的线索卡数。有台账就按台账口径（玩家眼里"我的卡"），没台账退回板上用到的卡。
func _owned_clue_count() -> int:
	var pool: Array[String] = _clue_order if not _clue_order.is_empty() else _card_ids
	var count: int = 0
	for clue_id in pool:
		if _owned.has(clue_id):
			count += 1
	return count


func _clue_total_count() -> int:
	if not _clue_order.is_empty():
		return _clue_order.size()
	return _card_ids.size()


# ============================================================================
#  内部：JSON 与类型
# ============================================================================

## 读一份 JSON。解析失败时往 _errors 里记一条带行号的消息（JSON.get_error_column() 在 4.7 不存在）。
## report = false：降级读取（线索台账 / 案件场景），失败不当 error。
func _read_json(path: String, report: bool = true) -> Dictionary:
	if not FileAccess.file_exists(path):
		if report:
			_err("文件不存在：%s" % path)
		return {}
	var text: String = FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		if report:
			_err("文件是空的：%s" % path)
		return {}
	var json: JSON = JSON.new()
	var error: int = json.parse(text)
	if error != OK:
		if report:
			_err("%s 第 %d 行 JSON 解析失败：%s" % [path, json.get_error_line() + 1, json.get_error_message()])
		return {}
	var data: Variant = json.data
	if not (data is Dictionary):
		if report:
			_err("%s 顶层不是对象" % path)
		return {}
	return data


func _err(message: String) -> void:
	_errors.append(message)


func _warn(message: String) -> void:
	_warnings.append(message)


func _as_string(value: Variant) -> String:
	if value == null:
		return ""
	return String(value)


func _as_int(value: Variant, fallback: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and (value as String).is_valid_int():
		return int(value)
	return fallback


func _as_bool(value: Variant) -> bool:
	if value is bool:
		return value
	return false


func _as_dict(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	return {}


func _type_name(value: Variant) -> String:
	if value == null:
		return "null"
	return type_string(typeof(value))


func _join(parts: Array[String], separator: String) -> String:
	var text: String = ""
	for part in parts:
		if not text.is_empty():
			text += separator
		text += part
	return text


func _label_of(row: Dictionary, row_id: String) -> String:
	var title: String = String(row.get("title", ""))
	if title.is_empty():
		return row_id
	return title


## 写错 id 时给一个拼写建议（编辑距离 <= 3 才给，免得瞎猜）。
func _suggest(word: String, candidates: Array) -> String:
	var best: String = ""
	var best_distance: int = 4
	for item in candidates:
		var candidate: String = String(item)
		var distance: int = _edit_distance(word, candidate)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	if best.is_empty():
		return ""
	return "（是否想写 %s？）" % best


func _edit_distance(left: String, right: String) -> int:
	var a: String = left.to_lower()
	var b: String = right.to_lower()
	var rows: int = a.length() + 1
	var cols: int = b.length() + 1
	var previous: PackedInt32Array = PackedInt32Array()
	for col in range(cols):
		previous.append(col)
	for row in range(1, rows):
		var current: PackedInt32Array = PackedInt32Array()
		current.append(row)
		for col in range(1, cols):
			var cost: int = 0 if a[row - 1] == b[col - 1] else 1
			current.append(mini(mini(current[col - 1] + 1, previous[col] + 1), previous[col - 1] + cost))
		previous = current
	return previous[cols - 1]
