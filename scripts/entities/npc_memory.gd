extends Node
## ============================================================================
##  npc_memory.gd —— NPC 跨轮记忆（玩法层组件 / Entities）
## ----------------------------------------------------------------------------
##  本作调研认定的【唯一空白差异位】的核心：竞品的时间循环只做"物品重置 + 情报保留"，
##  NPC 的态度与台词每遍重置；本作让 NPC【记得你来过几遍】——
##  把"玩家到目前为止知道了什么（跨遍保留的线索）+ 走到第几遍"合起来，喂给每个 NPC 的
##  【记忆阶】（memory stage）：阶数变了，这个 NPC 就多认出一件事。
##
##  记忆阶 = 满足的规则条数（规则来自 data/npc_memory/case_NN_memory.json）：
##      阶 0 = 这一遍他对你仍是第一次见（余页把他重置了）；
##      阶 k = 前 k 条规则的条件都成立 → 生效第 k 条规则的 extra_dialogue_id / reveal_clue_id。
##  判据只有两类（09 的契约里没有第三种）：
##      * 玩家持有的线索：PersistentMemoryManager.has_clue() / has_all_clues()
##      * loop_index 下限：require_min_loop（**0 基**，与 dialogues 的 unlock_if.loop_min 同口径：
##        loop_min=2 ⇔ "第三遍起"；case_01 secret.resolve_conditions.require_min_loop=8 ⇔ 第 9 遍）
##  规则按【台阶】判定：第 k 条不成立就停（所以 require_clues 应当逐阶递增；
##  条件不比上一阶强时只给 warning —— 那不是 error，但台阶不会真的变高）。
##
##  【铁律】记忆阶只反映"玩家到此刻知道了什么 + 走到第几遍"：
##      * 不落盘、不新增持久状态（线索本身已经在 PersistentMemoryManager 里持久化了）；
##      * 本组件没有任何"记过的 NPC"字段 ⇒ 重开游戏、读档、被心灯划掉一条记忆，
##        阶数都会【立刻】跟着变：query 前自动比对签名（_ensure_fresh），refresh() 可显式重算；
##      * reveal_clue_id 只是"这个 NPC 在这一阶能交出哪条线索"的声明，
##        真正 add_clue() 由表现层做 —— 本组件绝不替玩家改记忆。
##
##  规则文件（data/npc_memory/case_NN_memory.json）：
##      { "meta":  { "schema_version": 1, "case_id": 1, ... },
##        "npcs":  [ { "npc_id": "npc_01_muqing", "display_name": "穆青", "rules": [
##            { "require_clues": ["clue_01_four_in_three"],   # 可选，默认 []
##              "require_min_loop": 0,                         # 可选，默认 0（0 基）
##              "extra_dialogue_id": "mq_02b_two_hands",       # 必须是字符串
##              "reveal_clue_id": "",                          # 可选
##              "note": "中文说明（策划口径）" } ] } ] }
##      "npcs" 也可以是 { npc_id: { ... } } 的字典形式。
##  校验（照 tools/validate_data.gd 的做法，错 id 给编辑距离拼写建议）：
##      * 规则里的 clue_id 不在 data/clues/case_NN_clues.json → **error**（不阻塞不了，就是错）
##      * extra_dialogue_id 不在 data/dialogues/case_NN_dialogues.json → **warning**（不阻塞）
##      * require_clues / extra_dialogue_id / note 类型不对 → error；规则挂到案里没有的 npc → warning
##
##  依赖注入（本脚本一行都不直接引用 Autoload，便于 --check-only 与无头测试）：
##      var memo = preload("res://scripts/entities/npc_memory.gd").new()
##      memo.auto_subscribe = false        # 测试里不订阅 /root/TimeLoopManager
##      memo.configure(1)                  # 读真实规则文件；测试也可 configure_with_rules(内联规则)
##      memo.set_memory_manager(PersistentMemoryManager)
##      if memo.auto_subscribe: add_child(memo)
##
##  不写 class_name（依赖编辑器类缓存，刚 clone 时不可用），一律 preload()。
## ============================================================================


# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------

## 某个 NPC 的记忆阶发生变化（refresh() 重算后逐个广播）。
signal npc_memory_stage_changed(npc_id: String, stage: int, max_stage: int)


# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

const MEMORY_DIR: String = "res://data/npc_memory"
const CLUE_DIR: String = "res://data/clues"
const DIALOGUE_DIR: String = "res://data/dialogues"
const LOOP_MANAGER_PATH: String = "/root/TimeLoopManager"
## 挂载点里的节点名：解析时从场景树根用【相对】路径取（见 _resolve_loop_manager()）——
## 绝对路径 get_node("/root/X") 在"自身还没进树"的节点上会报
## "Can't use get_node() with absolute paths from outside the active scene tree."，无头测试正是这种情形。
const LOOP_MANAGER_NAME: String = "TimeLoopManager"
const DEFAULT_CASE_ID: int = 1

## 效果字典的三个键（阶 0 时恒为空串；键永远齐，HUD 可以直接取）。
const EFFECT_KEYS: Array[String] = ["extra_dialogue_id", "reveal_clue_id", "note"]


# ---------------------------------------------------------------------------
# 配置（数据 / 登记表）
# ---------------------------------------------------------------------------

## 挂进场景树后是否自动订阅 /root/TimeLoopManager（无头测试设 false）。
var auto_subscribe: bool = true

var _configured: bool = false
var _case_id: int = -1
var _source: String = ""
var _errors: Array[String] = []
var _warnings: Array[String] = []

## npc_id -> Array[Dictionary]（归一化后的台阶，顺序 = 阶序）。
var _rules: Dictionary = {}
## 规则文件里的 NPC 顺序（list_changed_npcs() / get_state() 按它排，稳定可比对）。
var _npc_order: Array[String] = []
var _display_names: Dictionary = {}

## 线索登记表 / 对话登记表（只用于校验与拼写建议，不参与阶数计算）。
var _clue_ids: Dictionary = {}
var _dialogue_ids: Dictionary = {}
var _clues_loaded: bool = false
var _dialogues_loaded: bool = false

## 案里存在的 NPC（可选注入，用来发现"规则挂到拼错的 npc_id 上"）。
var _known_npcs: Dictionary = {}


# ---------------------------------------------------------------------------
# 运行期（每遍重算，不累积、不落盘）
# ---------------------------------------------------------------------------

var _memory: Node = null
var _loop_index: int = 0
var _stage_cache: Dictionary = {}
var _effects_cache: Dictionary = {}
## "loop_index + 线索集合"的签名：签名没变就不重算（query 前自动比对，见 _ensure_fresh）。
var _signature: String = ""
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


## 09:17 契约：与"遍数"有关的部分清零重算（NPC 靠 loop_index 才成立的那几阶退回 0），
## 但【线索记忆不清】—— 线索是跨遍永久保留的持久状态，清掉它才是错的。
## 真正的重算紧跟其后的 loop_started(loop_index)。
func on_loop_reset() -> void:
	_loop_index = 0
	refresh()


## 新一遍开始：按新的 loop_index 重算全部 NPC 的记忆阶。
func on_loop_started(loop_index: int) -> void:
	set_loop_index(loop_index)


# ---------------------------------------------------------------------------
# 依赖注入 / 配置
# ---------------------------------------------------------------------------

## 读真实规则文件：data/npc_memory/case_NN_memory.json（同时装载线索/对话登记表做校验）。
func configure(case_id: int = DEFAULT_CASE_ID) -> void:
	_clear_rules()
	_case_id = case_id
	_source = "%s/case_%02d_memory.json" % [MEMORY_DIR, case_id]
	_load_clue_registry(case_id)
	_load_dialogue_registry(case_id)
	if not FileAccess.file_exists(_source):
		_errors.append("规则文件不存在：%s（案 %d 的 NPC 跨轮记忆没有数据来源）"
			% [_source, case_id])
		return
	var parsed: Variant = _read_json(_source)
	if not (parsed is Dictionary):
		if not _errors.is_empty():
			return
		_errors.append("%s 的顶层必须是字典" % _source)
		return
	_configured = true
	_parse_rule_document(parsed as Dictionary, _source)
	_recompute()
	_signature = _make_signature()


## 用内联规则配置（测试/工具用，不读磁盘）。options 可选键：
##   "case_id": int                  —— 只用于元信息与登记表路径（默认读案 1 的登记表）
##   "clue_ids": Array[String]       —— 内联线索登记表（给了就不再读 data/clues/**）
##   "dialogue_ids": Array[String]   —— 内联对话登记表
##   "known_npcs": Array[String]     —— 案里存在的 npc_id（用于"规则挂错 NPC"warning）
##   "skip_registries": bool         —— true = 不校验 clue_id / dialogue_id（只记一条 warning）
func configure_with_rules(rules: Dictionary, options: Dictionary = {}) -> void:
	_clear_rules()
	var case_id: int = _as_int(options.get("case_id", DEFAULT_CASE_ID), DEFAULT_CASE_ID)
	_case_id = case_id
	_source = "<inline>"
	var skip_registries: bool = bool(options.get("skip_registries", false))
	var clue_ids_value: Variant = options.get("clue_ids", null)
	var dialogue_ids_value: Variant = options.get("dialogue_ids", null)
	if clue_ids_value is Array:
		_clues_loaded = true
		for clue_id in (clue_ids_value as Array):
			if clue_id is String:
				_clue_ids[clue_id] = true
	elif not skip_registries:
		_load_clue_registry(case_id)
	if dialogue_ids_value is Array:
		_dialogues_loaded = true
		for dialogue_id in (dialogue_ids_value as Array):
			if dialogue_id is String:
				_dialogue_ids[dialogue_id] = true
	elif not skip_registries:
		_load_dialogue_registry(case_id)
	var known_value: Variant = options.get("known_npcs", null)
	if known_value is Array:
		set_known_npcs(known_value as Array)
	if skip_registries:
		_warnings.append("skip_registries = true：本次不校验 clue_id / dialogue_id 是否登记")
	if not _clues_loaded:
		_warnings.append("未提供线索登记表：跳过 clue_id 登记校验（内联规则请用 options.clue_ids）")
	if not _dialogues_loaded:
		_warnings.append("未提供对话登记表：跳过 extra_dialogue_id 校验（内联规则请用 options.dialogue_ids）")
	_configured = true
	_parse_rule_document(rules, "<inline>")
	_recompute()
	_signature = _make_signature()


## 注入记忆管理器（PersistentMemoryManager）。没有它也能跑：线索集合按空处理。
func set_memory_manager(memory: Node) -> void:
	_memory = memory
	refresh()


func get_memory_manager() -> Node:
	return _memory


## 告诉本组件"案里存在哪些 NPC"（可选）：规则挂到案里没有的 npc_id 上时给 warning。
## 要在 configure() / configure_with_rules() 之前调用才参与本次校验。
func set_known_npcs(npc_ids: Array) -> void:
	_known_npcs.clear()
	for npc_id in npc_ids:
		if npc_id is String:
			_known_npcs[npc_id] = true


# ---------------------------------------------------------------------------
# 循环驱动 / 重算
# ---------------------------------------------------------------------------

## 设定"现在是第几遍"（0 基）并按当前线索重算；返回本次【阶数发生变化】的 NPC 数。
func set_loop_index(loop_index: int) -> int:
	_loop_index = maxi(0, loop_index)
	return refresh()


## set_loop_index() 的同义入口（引导层在 loop_started 里调）。
func apply_loop(loop_index: int) -> int:
	return set_loop_index(loop_index)


## 按"当前线索集合 + 当前 loop_index"重算所有 NPC 的记忆阶。
## 返回阶数发生变化的 NPC 数（0 = 没人变）；变化的 NPC 逐个广播 npc_memory_stage_changed。
func refresh() -> int:
	var before: Dictionary = _stage_cache.duplicate()
	_recompute()
	_signature = _make_signature()
	var changed: int = 0
	for npc_id in _npc_order:
		if int(before.get(npc_id, -1)) != int(_stage_cache.get(npc_id, 0)):
			changed += 1
			npc_memory_stage_changed.emit(npc_id, get_stage(npc_id), get_max_stage(npc_id))
	return changed


## 清掉全部运行期缓存并回到第 1 遍（loop_index = 0）后按当前线索重算；
## 【不碰 PersistentMemoryManager】：线索是核心层的持久状态，本组件只读它。
## 不广播信号（reset 是"回到起点"，不是"某个 NPC 变了"）。
func reset() -> void:
	_loop_index = 0
	_stage_cache.clear()
	_effects_cache.clear()
	_recompute()
	_signature = _make_signature()


# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

func is_configured() -> bool:
	return _configured


## 配置成功且没有 error（warning 不算失败）。
func is_ok() -> bool:
	return _configured and _errors.is_empty()

func get_case_id() -> int:
	return _case_id

func get_source() -> String:
	return _source

func get_loop_index() -> int:
	return _loop_index

## 第几遍（1 基口径：loop_index 0 = 第 1 遍）。
func get_loop_number() -> int:
	return _loop_index + 1

## 当前记忆阶（满足的规则条数）；没有规则 / 条件不成立 = 0。
func get_stage(npc_id: String) -> int:
	_ensure_fresh()
	return int(_stage_cache.get(npc_id, 0))


## 这个 NPC 的规则层数（阶的上限）。
func get_max_stage(npc_id: String) -> int:
	if not _rules.has(npc_id):
		return 0
	var rules: Array = _rules[npc_id]
	return rules.size()


## 当前阶生效的效果，键恒为 EFFECT_KEYS 三个（阶 0 时都是空串）。
func get_effects(npc_id: String) -> Dictionary:
	_ensure_fresh()
	if not _effects_cache.has(npc_id):
		return _empty_effects()
	var cached: Dictionary = _effects_cache[npc_id]
	var result: Dictionary = {}
	for key in EFFECT_KEYS:
		result[key] = String(cached.get(key, ""))
	return result


## 记忆阶 > 0 的 NPC（数据文件顺序）。
func list_changed_npcs() -> Array[String]:
	_ensure_fresh()
	var result: Array[String] = []
	for npc_id in _npc_order:
		if int(_stage_cache.get(npc_id, 0)) > 0:
			result.append(npc_id)
	return result


## 当前所有阶 > 0 的 NPC 声明可交出的线索（去重，按 NPC 顺序）。
## 表现层用它决定要不要调 PersistentMemoryManager.add_clue() —— 本组件自己不调。
func get_reveal_clue_ids() -> Array[String]:
	_ensure_fresh()
	var result: Array[String] = []
	for npc_id in _npc_order:
		var reveal: String = String(get_effects(npc_id).get("reveal_clue_id", ""))
		if not reveal.is_empty() and not result.has(reveal):
			result.append(reveal)
	return result


## 一行中文，给 HUD / 审讯台用。
func describe(npc_id: String) -> String:
	_ensure_fresh()
	var display_name: String = get_display_name(npc_id)
	if not _rules.has(npc_id):
		return "%s：没有记忆规则（%s 未在规则文件里登记）" % [display_name, npc_id]
	var stage: int = get_stage(npc_id)
	var max_stage: int = get_max_stage(npc_id)
	if stage <= 0:
		return "%s：记忆阶 0/%d —— 还没认出你来过（这一遍他仍是第一次见你）" % [display_name, max_stage]
	var effects: Dictionary = get_effects(npc_id)
	var tail: String = String(effects.get("note", ""))
	if tail.is_empty():
		tail = "已生效"
	var extra: String = String(effects.get("extra_dialogue_id", ""))
	if not extra.is_empty():
		tail += "；额外台词 %s" % extra
	var reveal: String = String(effects.get("reveal_clue_id", ""))
	if not reveal.is_empty():
		tail += "；可交出线索 %s" % reveal
	return "%s：记忆阶 %d/%d —— %s" % [display_name, stage, max_stage, tail]

func get_npc_ids() -> Array[String]:
	var result: Array[String] = []
	for npc_id in _npc_order:
		result.append(npc_id)
	return result

func get_display_name(npc_id: String) -> String:
	var value: Variant = _display_names.get(npc_id, "")
	var text: String = ""
	if value is String:
		text = value
	if text.is_empty():
		return npc_id
	return text

func has_rules(npc_id: String) -> bool:
	return _rules.has(npc_id)

## 规则条数合计（便于断言"覆盖了几个 NPC / 几条规则"）。
func total_rule_count() -> int:
	var total: int = 0
	for npc_id in _npc_order:
		var rules: Array = _rules[npc_id]
		total += rules.size()
	return total

func is_clue_known(clue_id: String) -> bool:
	return _clue_ids.has(clue_id)

func get_clue_registry_size() -> int:
	return _clue_ids.size()

## 只读快照（便于断言：同一份规则 + 同一份线索 + 同一个 loop_index ⇒ 逐字相同，
## 里面没有任何"上一遍残留"——阶数每次都由 memory + loop_index 现算）。
func get_state() -> Dictionary:
	_ensure_fresh()
	var stages: Dictionary = {}
	var max_stages: Dictionary = {}
	var effects: Dictionary = {}
	for npc_id in _npc_order:
		stages[npc_id] = get_stage(npc_id)
		max_stages[npc_id] = get_max_stage(npc_id)
		effects[npc_id] = get_effects(npc_id)
	var state: Dictionary = {
		"configured": _configured,
		"case_id": _case_id,
		"source": _source,
		"loop_index": _loop_index,
		"loop_number": _loop_index + 1,
		"npc_ids": get_npc_ids(),
		"npc_count": _npc_order.size(),
		"rule_count": total_rule_count(),
		"stages": stages,
		"max_stages": max_stages,
		"effects": effects,
		"changed_npcs": list_changed_npcs(),
		"reveal_clue_ids": get_reveal_clue_ids(),
		"clue_registry_loaded": _clues_loaded,
		"clue_registry_size": _clue_ids.size(),
		"dialogue_registry_loaded": _dialogues_loaded,
		"dialogue_registry_size": _dialogue_ids.size(),
		"memory_connected": _memory != null,
		"clues_in_memory": _memory_clues().size(),
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
	return "npc_memory：%d 个错误｜%s" % [_errors.size(), "\n".join(PackedStringArray(_errors))]


# ---------------------------------------------------------------------------
# 内部：运行期重算
# ---------------------------------------------------------------------------

func _ensure_fresh() -> void:
	if not _configured:
		return
	var current: String = _make_signature()
	if current == _signature:
		return
	_recompute()
	_signature = current


## 现算：每个 NPC 从第 1 阶往上走，遇到第一条不满足的规则就停（台阶式）。
func _recompute() -> void:
	var stages: Dictionary = {}
	var effects: Dictionary = {}
	for npc_id in _npc_order:
		var rules: Array = _rules.get(npc_id, [])
		var stage: int = 0
		var active: Dictionary = _empty_effects()
		for index in range(rules.size()):
			var rule: Dictionary = rules[index]
			if not _rule_satisfied(rule):
				break
			stage = index + 1
			active = _effects_of(rule)
		stages[npc_id] = stage
		effects[npc_id] = active
	_stage_cache = stages
	_effects_cache = effects


func _rule_satisfied(rule: Dictionary) -> bool:
	var min_loop: int = int(rule.get("require_min_loop", 0))
	if _loop_index < min_loop:
		return false
	var clues: Array[String] = rule.get("require_clues", [])
	return _has_all_clues(clues)


func _make_signature() -> String:
	var clues: Array[String] = _memory_clues()
	clues.sort()
	var text: String = ""
	for clue_id in clues:
		if not text.is_empty():
			text += ","
		text += clue_id
	return "%d|%s" % [_loop_index, text]


## 读记忆管理器里的线索（没有注入 = 空集，只有 require_min_loop 的规则照样能上台阶）。
func _memory_clues() -> Array[String]:
	var result: Array[String] = []
	if _memory == null:
		return result
	if not _memory.has_method("get_clues"):
		return result
	var value: Variant = _memory.get_clues()
	if not (value is Array):
		return result
	for item in (value as Array):
		if item is String:
			result.append(item)
	return result


func _has_clue(clue_id: String) -> bool:
	if _memory == null:
		return false
	if _memory.has_method("has_clue"):
		return bool(_memory.has_clue(clue_id))
	return false


func _has_all_clues(clue_ids: Array[String]) -> bool:
	if clue_ids.is_empty():
		return true
	if _memory == null:
		return false
	if _memory.has_method("has_all_clues"):
		return bool(_memory.has_all_clues(clue_ids))
	for clue_id in clue_ids:
		if not _has_clue(clue_id):
			return false
	return true


func _empty_effects() -> Dictionary:
	var result: Dictionary = {}
	for key in EFFECT_KEYS:
		result[key] = ""
	return result


func _effects_of(rule: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in EFFECT_KEYS:
		result[key] = String(rule.get(key, ""))
	return result


# ---------------------------------------------------------------------------
# 内部：规则解析与校验
# ---------------------------------------------------------------------------

func _clear_rules() -> void:
	_configured = false
	_errors.clear()
	_warnings.clear()
	_rules.clear()
	_npc_order.clear()
	_display_names.clear()
	_clue_ids.clear()
	_dialogue_ids.clear()
	_clues_loaded = false
	_dialogues_loaded = false
	_stage_cache.clear()
	_effects_cache.clear()
	_loop_index = 0
	_signature = ""


func _parse_rule_document(data: Dictionary, where: String) -> void:
	var meta_value: Variant = data.get("meta", null)
	if meta_value is Dictionary:
		var meta: Dictionary = meta_value
		var case_id_value: Variant = meta.get("case_id", null)
		if case_id_value != null:
			var declared: int = _as_int(case_id_value, _case_id)
			if declared != _case_id:
				_warnings.append("%s：meta.case_id=%d 与本次配置的 case_id=%d 不一致"
					% [where, declared, _case_id])
	var npcs_value: Variant = data.get("npcs", null)
	if npcs_value is Array:
		var index: int = 0
		for entry in (npcs_value as Array):
			if not (entry is Dictionary):
				_errors.append("%s：npcs[%d] 必须是字典（实际 %s）"
					% [where, index, type_string(typeof(entry))])
				index += 1
				continue
			var row: Dictionary = entry
			var npc_value: Variant = row.get("npc_id", "")
			var npc_id: String = ""
			if npc_value is String:
				npc_id = npc_value
			_parse_npc_entry(npc_id, row, "%s npcs[%d]" % [where, index])
			index += 1
		return
	if npcs_value is Dictionary:
		var table: Dictionary = npcs_value
		for key in table.keys():
			if not (key is String):
				_errors.append("%s：npcs 的键必须是 npc_id 字符串（实际 %s）"
					% [where, type_string(typeof(key))])
				continue
			var npc_id: String = key
			var row_value: Variant = table[key]
			if not (row_value is Dictionary):
				_errors.append("%s npcs.%s 必须是字典（实际 %s）"
					% [where, npc_id, type_string(typeof(row_value))])
				continue
			_parse_npc_entry(npc_id, row_value as Dictionary, "%s npcs.%s" % [where, npc_id])
		return
	_errors.append("%s：npcs 必须是数组或字典（实际 %s）"
		% [where, type_string(typeof(npcs_value))])


func _parse_npc_entry(npc_id: String, entry: Dictionary, where: String) -> void:
	if npc_id.is_empty():
		_errors.append("%s：npc_id 缺失或不是字符串" % where)
		return
	if _rules.has(npc_id):
		_errors.append("%s：npc_id=%s 重复定义（每个 NPC 只能有一组台阶）" % [where, npc_id])
		return
	if not _known_npcs.is_empty() and not _known_npcs.has(npc_id):
		var suggestions: Array = _known_npcs.keys()
		_warnings.append("%s：npc_id=%s 不在本案的 NPC 名单里%s"
			% [where, npc_id, _suggest(npc_id, suggestions)])
	var display_value: Variant = entry.get("display_name", "")
	if display_value is String:
		_display_names[npc_id] = display_value
	else:
		_warnings.append("%s：display_name 不是字符串（已忽略）" % where)
	var rules_value: Variant = entry.get("rules", null)
	if not (rules_value is Array):
		_errors.append("%s：rules 必须是数组（实际 %s）"
			% [where, type_string(typeof(rules_value))])
		return
	var rows: Array = rules_value
	if rows.is_empty():
		_errors.append("%s：rules 是空数组（NPC 要么别登记，要么至少给一阶）" % where)
		return
	var rules: Array = []
	var index: int = 0
	for item in rows:
		var rule_where: String = "%s rules[%d]" % [where, index]
		if not (item is Dictionary):
			_errors.append("%s：必须是字典（实际 %s）" % [rule_where, type_string(typeof(item))])
			index += 1
			continue
		var normalized: Dictionary = _parse_rule(item as Dictionary, rule_where, rules)
		if not normalized.is_empty():
			rules.append(normalized)
		index += 1
	_rules[npc_id] = rules
	_npc_order.append(npc_id)


## 解析并校验一条规则；返回归一化后的规则（有 error 时返回 {}，该阶被丢掉但其余阶照常）。
func _parse_rule(rule: Dictionary, where: String, previous_rules: Array) -> Dictionary:
	var empty_clues: Array[String] = []
	var normalized: Dictionary = {
		"require_clues": empty_clues,
		"require_min_loop": 0,
		"extra_dialogue_id": "",
		"reveal_clue_id": "",
		"note": "",
	}
	var had_error: bool = false

	# --- require_clues：线索登记表里必须真有这条 id ---
	var clues: Array[String] = []
	var clues_value: Variant = rule.get("require_clues", [])
	if clues_value is Array:
		var clue_index: int = 0
		for item in (clues_value as Array):
			if not (item is String) or (item as String).is_empty():
				_errors.append("%s.require_clues[%d] 必须是非空字符串（实际 %s）"
					% [where, clue_index, type_string(typeof(item))])
				had_error = true
			else:
				clues.append(item as String)
			clue_index += 1
	elif clues_value is String and not (clues_value as String).is_empty():
		_warnings.append("%s.require_clues 用单个字符串写了，建议写成数组" % where)
		clues.append(clues_value as String)
	else:
		_errors.append("%s.require_clues 必须是字符串数组（实际 %s）"
			% [where, type_string(typeof(clues_value))])
		had_error = true
	for clue_id in clues:
		if _clues_loaded and not _clue_ids.has(clue_id):
			_errors.append("%s.require_clues：clue_id=%s 未在 %s/case_%02d_clues.json 登记%s"
				% [where, clue_id, CLUE_DIR, _case_id, _suggest(clue_id, _clue_ids.keys())])
			had_error = true
	normalized["require_clues"] = clues

	# --- require_min_loop：0 基，与 dialogues 的 unlock_if.loop_min 同口径 ---
	var loop_value: Variant = rule.get("require_min_loop", 0)
	if loop_value is int or loop_value is float:
		var min_loop: int = _as_int(loop_value, 0)
		if min_loop < 0:
			_warnings.append("%s.require_min_loop=%d 是负数（按 0 处理）" % [where, min_loop])
			min_loop = 0
		normalized["require_min_loop"] = min_loop
	elif loop_value is String and (loop_value as String).is_valid_int():
		normalized["require_min_loop"] = (loop_value as String).to_int()
	else:
		_errors.append("%s.require_min_loop 必须是整数（0 基；实际 %s）"
			% [where, type_string(typeof(loop_value))])
		had_error = true

	# --- extra_dialogue_id：必须是字符串（数字 id 会让对话表查不到）---
	var dialogue_value: Variant = rule.get("extra_dialogue_id", "")
	if dialogue_value == null:
		dialogue_value = ""
	if dialogue_value is String:
		normalized["extra_dialogue_id"] = dialogue_value
	else:
		_errors.append("%s.extra_dialogue_id 必须是字符串（实际 %s：%s）"
			% [where, type_string(typeof(dialogue_value)), str(dialogue_value)])
		had_error = true

	# --- reveal_clue_id：可选，但写了就必须是登记过的线索 ---
	var reveal_value: Variant = rule.get("reveal_clue_id", "")
	if reveal_value == null:
		reveal_value = ""
	if reveal_value is String:
		normalized["reveal_clue_id"] = reveal_value
	else:
		_errors.append("%s.reveal_clue_id 必须是字符串（实际 %s）"
			% [where, type_string(typeof(reveal_value))])
		had_error = true
	var reveal: String = normalized["reveal_clue_id"]
	if not reveal.is_empty() and _clues_loaded and not _clue_ids.has(reveal):
		_errors.append("%s.reveal_clue_id=%s 未在 %s/case_%02d_clues.json 登记%s"
			% [where, reveal, CLUE_DIR, _case_id, _suggest(reveal, _clue_ids.keys())])
		had_error = true

	# --- note：中文说明 ---
	var note_value: Variant = rule.get("note", "")
	if note_value == null:
		note_value = ""
	if note_value is String:
		normalized["note"] = note_value
	else:
		_errors.append("%s.note 必须是字符串（实际 %s）"
			% [where, type_string(typeof(note_value))])
		had_error = true

	# --- 效果：extra_dialogue_id / reveal_clue_id 至少有一个 ---
	var extra: String = normalized["extra_dialogue_id"]
	if extra.is_empty() and reveal.is_empty():
		_errors.append("%s 没有任何效果：extra_dialogue_id / reveal_clue_id 至少要有一个" % where)
		had_error = true
	if not extra.is_empty() and _dialogues_loaded and not _dialogue_ids.has(extra):
		_warnings.append("%s.extra_dialogue_id=%s 未在 %s/case_%02d_dialogues.json 中定义%s"
			% [where, extra, DIALOGUE_DIR, _case_id, _suggest(extra, _dialogue_ids.keys())])

	# --- 设计不变量：台阶要真的往上走（条件不比上一阶强只给 warning）---
	if not previous_rules.is_empty():
		var previous: Dictionary = previous_rules[previous_rules.size() - 1]
		var previous_loop: int = int(previous.get("require_min_loop", 0))
		var previous_clues: Array[String] = previous.get("require_clues", [])
		var superset: bool = true
		for clue_id in previous_clues:
			if not clues.has(clue_id):
				superset = false
		if int(normalized["require_min_loop"]) < previous_loop:
			_warnings.append("%s：require_min_loop 比上一阶还低（%d → %d），台阶会倒着走"
				% [where, previous_loop, int(normalized["require_min_loop"])])
		elif int(normalized["require_min_loop"]) == previous_loop and not superset:
			_warnings.append("%s：条件不比上一阶强（仍是第 %d 遍起、线索没包含上一阶的），这一阶几乎不会单独出现"
				% [where, previous_loop])
	if had_error:
		return {}
	return normalized


# ---------------------------------------------------------------------------
# 内部：登记表 / JSON
# ---------------------------------------------------------------------------

func _load_clue_registry(case_id: int) -> void:
	_clues_loaded = false
	_clue_ids.clear()
	var path: String = "%s/case_%02d_clues.json" % [CLUE_DIR, case_id]
	if not FileAccess.file_exists(path):
		_warnings.append("线索登记表不存在：%s（跳过 clue_id 校验）" % path)
		return
	var parsed: Variant = _read_json(path)
	if not (parsed is Dictionary):
		_warnings.append("线索登记表 %s 解析失败（跳过 clue_id 校验）" % path)
		return
	var data: Dictionary = parsed
	var rows_value: Variant = data.get("clues", data)
	if rows_value is Array:
		for row in (rows_value as Array):
			if row is Dictionary:
				var clue_value: Variant = (row as Dictionary).get("clue_id", "")
				if clue_value is String and not (clue_value as String).is_empty():
					_clue_ids[clue_value] = true
	elif rows_value is Dictionary:
		for key in (rows_value as Dictionary).keys():
			if key is String and key != "meta":
				_clue_ids[key] = true
	else:
		_warnings.append("线索登记表 %s 结构无法识别（跳过 clue_id 校验）" % path)
		return
	_clues_loaded = _clue_ids.size() > 0
	if not _clues_loaded:
		_warnings.append("线索登记表 %s 里一条 clue_id 都没有（跳过 clue_id 校验）" % path)


func _load_dialogue_registry(case_id: int) -> void:
	_dialogues_loaded = false
	_dialogue_ids.clear()
	var path: String = "%s/case_%02d_dialogues.json" % [DIALOGUE_DIR, case_id]
	if not FileAccess.file_exists(path):
		_warnings.append("对话登记表不存在：%s（跳过 extra_dialogue_id 校验）" % path)
		return
	var parsed: Variant = _read_json(path)
	if not (parsed is Dictionary):
		_warnings.append("对话登记表 %s 解析失败（跳过 extra_dialogue_id 校验）" % path)
		return
	var data: Dictionary = parsed
	var rows_value: Variant = data.get("dialogues", data)
	if rows_value is Dictionary:
		for key in (rows_value as Dictionary).keys():
			if key is String:
				_dialogue_ids[key] = true
	else:
		_warnings.append("对话登记表 %s 结构无法识别（跳过 extra_dialogue_id 校验）" % path)
		return
	_dialogues_loaded = _dialogue_ids.size() > 0
	if not _dialogues_loaded:
		_warnings.append("对话登记表 %s 里一条 dialogue_id 都没有（跳过 extra_dialogue_id 校验）" % path)


## 读一份 JSON。解析失败时往 _errors 里记一条带行号的消息（JSON.get_error_column() 在 4.7 不存在）。
func _read_json(path: String) -> Variant:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_errors.append("无法读取 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return null
	var text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	var error: int = json.parse(text)
	if error != OK:
		_errors.append("%s 第 %d 行 JSON 解析失败：%s"
			% [path, json.get_error_line() + 1, json.get_error_message()])
		return null
	return json.data


# ---------------------------------------------------------------------------
# 内部：数值 / 文本
# ---------------------------------------------------------------------------

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
