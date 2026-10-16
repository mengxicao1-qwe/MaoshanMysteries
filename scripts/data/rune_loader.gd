extends RefCounted
## scripts/data/rune_loader.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**数据层**
##
## 为什么需要它：案一的"补写仪式"（回照颂碑）不是一次按键，而是一段有门槛、有步骤、
## 有笔画判定的仪式：先摊录，再照原石画三笔（回 / 照 / 录），让她读完，再说一句"不重刻"，
## 最后把末行诵完。这些内容全部来自 `data/runes/case_01_runes.json`（唯一数据来源），
## 本文件只做「认数据 + 校验 + 查询」，不做任何输入状态机（那是 `scripts/entities/rune_input.gd`）。
##
## 认的数据形状（case_01_runes.json，schema_version 1）：
##   meta  —— schema_version / case_id / case_title / purpose / source / input_semantics /
##            stroke_semantics / discrimination_semantics / step_semantics / cost_note / failure_note
##   runes[] —— rune_id / name / display_name / source_note / require_clues[] / require_min_loop /
##            gate_note / room / npc_id / steps[] / success_text / fail_text
##   steps[] —— 五种 kind 里实际用四种：gate / draw / npc / choice
##            （`meta.step_semantics` 把它们写成"摊/照/录/诵"四拍，kind 是机器可读的那一维）
##   inputs  —— tokens[]（八个方向）/ key_map（token→Godot Key 枚举名，如 `"up": "KEY_UP"`）/
##            key_map_alt（备用键位，数字小键盘等）/ backspace_key / commit_key / note
##
## 校验分两层（与 map_loader 一致）：
##   * 进 errors ⇒ `ok = false`（结构性/契约错误）：rune_id 空或重复、steps 空、
##     step_id 空或重复、kind 不在四值内、draw 步没笔、笔画 pattern 空或含未登记 token、
##     choice 步没有 options 或 correct:true 不是恰好一个、require_clues 引用未登记线索、require_min_loop < 0。
##   * 进 warnings ⇒ 不影响 ok（内容/设计层提醒，表现层可照用）：案件 `require_ritual` 与本表
##     rune_id 对不上（loader 与案件数据的交叉引用）、gate/npc 步缺 text、未知字段名、
##     step/stroke 的序号字段与下标不一致。真数据（case_01）**零 error 零 warning** 是硬要求：
##     所以 `step` / `strokes[].index` 这类"已在数据里写着的下标"只做一致性校验，不当未知字段报。
##
## 三条设计取舍（写在这里免得下次又猜）：
##   1. **不做 `class_name`**：全项目工具与测试一律 `preload()`（AGENTS.md §4：class_name 依赖编辑器
##      生成的类缓存，刚 clone 时不可用）。
##   2. **线索交叉引用只在"登记表非空"时才判**：线索台账 `data/clues/case_NN_clues.json` 是
##      `require_clues` 的真名来源；登记表读不到（账号/环境问题、或纯内存夹具）时**不报错**，
##      只留一条 warning 说明"本轮没做交叉引用"。这样纯内存夹具（无线索台账）不会被误判成坏数据。
##   3. **token 判定序列一律用 `Array[String]`**、`matches()` 逐元素比字符串，避免 JSON 数字 float 化
##      之类的类型抖动；整数字段（require_min_loop / schema_version / index）过 `_ints_back()` 还原。
##
## 静态入口挂在外层（不是内部类 RuneTable 上）：`preload("…rune_loader.gd")` 拿到的脚本变量
## **不能**对内部类做静态调用（实测 `Parse Error: Static function "load_for_case()" not found in
## base "res://scripts/data/rune_loader.gd"`），而表现层与测试要写 `RuneLoader.load_for_case(1)`。
## 同理，内部类内部**既调不到外层的静态函数、也写不出 `RuneLoader.xxx` 这个名字**
## （Parse Error: Identifier "RuneLoader" not declared in the current scope——脚本没有
## `class_name`，它只认得 preload 它的那个调用方作用域）⇒ 内部类需要的静态工具
## （`_read_json` / `_edit_distance` / 线索台账扫描）全部挂在 `RuneTable` 自己身上，
## 外层入口再用 `RuneTable.xxx()` 去调。

const DEFAULT_CASE_ID: int = 1
const RUNE_DIR: String = "res://data/runes"
const CLUE_DIR: String = "res://data/clues"
const SCENARIO_DIR: String = "res://data/scenarios"

## 认的 schema 版本（> 它 = warning，不是 error：新版本多的字段忽略就好，别把老 loader 判死）。
const SUPPORTED_SCHEMA_VERSION: int = 1

## 四种 step kind（`meta.step_semantics` 的机器可读那一维）。
const KINDS: Array[String] = ["gate", "draw", "npc", "choice"]

## 各层字段白名单：出现名单外的键 = warning（typo 的第一道网；`"second"` 这类越界键就靠它）。
const RUNE_KEYS: Array[String] = [
	"rune_id", "name", "display_name", "source_note", "require_clues", "require_min_loop",
	"gate_note", "room", "npc_id", "steps", "success_text", "fail_text",
]
const STEP_KEYS: Array[String] = [
	"step", "step_id", "name", "kind", "require_clues", "gate_note", "text", "note", "npc_id", "room",
	"cost_text", "success_text", "strokes", "near_miss", "options",
]
const STROKE_KEYS: Array[String] = ["index", "name", "pattern", "note"]
const NEAR_MISS_KEYS: Array[String] = ["attempt_id", "pattern", "hint", "clue_note"]
const OPTION_KEYS: Array[String] = ["option_id", "text", "correct", "reply"]
## 兜底提示语（`rune_input.gd` 的 STATUS_WRONG 用它；写在这里是因为它属于"数据怎么说"）。
const WRONG_HINT: String = "这一笔对不上原石：笔顺或方向不对。可以退一笔重描。"


# ============================================================================
#  内部类 1：一笔（原石上的一段纹路）
# ============================================================================

class RuneStroke extends RefCounted:
	var index: int = 0
	var name: String = ""
	var pattern: Array[String] = []
	var note: String = ""

	func token_count() -> int:
		return pattern.size()

	func matches(tokens: Array) -> bool:
		if tokens == null:
			return false
		if tokens.size() != pattern.size():
			return false
		for position in range(pattern.size()):
			if String(tokens[position]) != pattern[position]:
				return false
		return true

	func describe() -> String:
		var text: String = "第 %d 笔「%s」：%s" % [index + 1, name, " → ".join(pattern)]
		if note != "":
			text += "（%s）" % note
		return text


# ============================================================================
#  内部类 2：近似笔（差一点就对的错笔；要给出"差在哪"的提示）
# ============================================================================

class RuneNearMiss extends RefCounted:
	var attempt_id: String = ""
	var pattern: Array[String] = []
	var hint: String = ""
	var clue_note: String = ""

	func matches(tokens: Array) -> bool:
		if tokens == null:
			return false
		if tokens.size() != pattern.size():
			return false
		for position in range(pattern.size()):
			if String(tokens[position]) != pattern[position]:
				return false
		return true

	func describe() -> String:
		return "%s：%s（%s）" % [attempt_id, " → ".join(pattern), hint]


# ============================================================================
#  内部类 3：choice 步的一个选项
# ============================================================================

class RuneOption extends RefCounted:
	var option_id: String = ""
	var text: String = ""
	var correct: bool = false
	var reply: String = ""

	func describe() -> String:
		var mark: String = "✓" if correct else "✗"
		return "%s %s：%s（%s）" % [mark, option_id, text, reply]


# ============================================================================
#  内部类 4：仪式的一步
# ============================================================================

class RuneStep extends RefCounted:
	var index: int = 0
	var step_id: String = ""
	var name: String = ""
	var kind: String = ""
	var require_clues: Array[String] = []
	var gate_note: String = ""
	var text: String = ""
	var note: String = ""
	var npc_id: String = ""
	var room: String = ""
	var cost_text: String = ""
	var success_text: String = ""
	var strokes: Array = []
	var near_miss: Array = []
	var options: Array = []

	func is_gate() -> bool:
		return kind == "gate"

	func is_draw() -> bool:
		return kind == "draw"

	func is_npc() -> bool:
		return kind == "npc"

	func is_choice() -> bool:
		return kind == "choice"

	func stroke_count() -> int:
		return strokes.size()

	func option_count() -> int:
		return options.size()

	## 唯一 `correct: true` 的选项 id；没有（或有多条 = 坏数据）时返回 ""。
	func correct_option_id() -> String:
		var found: String = ""
		var hits: int = 0
		for option in options:
			if option != null and option.correct:
				found = option.option_id
				hits += 1
		if hits != 1:
			return ""
		return found

	func get_option(option_id: String) -> Variant:
		for option in options:
			if option != null and option.option_id == option_id:
				return option
		return null

	func describe() -> String:
		var text: String = "第 %d 步 [%s] %s（%s）" % [index + 1, kind, step_id, name]
		if is_draw():
			text += "：%d 笔 / %d 条近似笔" % [stroke_count(), near_miss.size()]
		elif is_choice():
			text += "：%d 个选项" % option_count()
		return text


# ============================================================================
#  内部类 5：一道符（一个仪式）
# ============================================================================

class RuneEntry extends RefCounted:
	var rune_id: String = ""
	var name: String = ""
	var display_name: String = ""
	var source_note: String = ""
	var require_clues: Array[String] = []
	var require_min_loop: int = 0
	var gate_note: String = ""
	var room: String = ""
	var npc_id: String = ""
	var success_text: String = ""
	var fail_text: String = ""
	var steps: Array = []

	func step_ids() -> Array[String]:
		var result: Array[String] = []
		for step in steps:
			if step != null:
				result.append(step.step_id)
		return result

	func step_count() -> int:
		return steps.size()

	func total_strokes() -> int:
		var total: int = 0
		for step in steps:
			if step != null:
				total += step.stroke_count()
		return total

	func total_near_miss() -> int:
		var total: int = 0
		for step in steps:
			if step != null:
				total += step.near_miss.size()
		return total

	func get_step(step_id: String) -> Variant:
		for step in steps:
			if step != null and step.step_id == step_id:
				return step
		return null

	## 门槛的"线索 + 遍数"两维（房间这一维不在签名里：契约固定了这两参，房间由
	## `rune_input.start_rune()` 拿 `get_room()` 与 `room` 比）。
	func is_available(loop_index: int, owned_clues: Array) -> bool:
		if loop_index < require_min_loop:
			return false
		return missing_clues(owned_clues).is_empty()

	## 只回答"线索这一维"：返回还没拿到的那几条（空 = 齐了）。
	func missing_clues(owned_clues: Array) -> Array[String]:
		var owned: Array[String] = []
		if owned_clues != null:
			for value in owned_clues:
				owned.append(String(value))
		var missing: Array[String] = []
		for clue_id in require_clues:
			if not owned.has(clue_id):
				missing.append(clue_id)
		return missing

	func describe() -> String:
		var text: String = "%s（%s）：%d 步 / %d 笔，需线索 %d 条、第 %d 遍起" % [
			display_name, rune_id, step_count(), total_strokes(), require_clues.size(), require_min_loop,
		]
		if room != "":
			text += "，地点 %s" % room
		return text


# ============================================================================
#  内部类 6：整张符表（装载结果 + 校验报告 + 查询）
# ============================================================================

class RuneTable extends RefCounted:
	var ok: bool = false
	var error: String = ""
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var path: String = ""
	var schema_version: int = 0
	var case_id: int = 0
	var case_title: String = ""
	var purpose: String = ""
	var input_tokens: Array[String] = []
	var key_map: Dictionary = {}
	var key_map_alt: Dictionary = {}
	var backspace_key: String = ""
	var commit_key: String = ""
	var input_note: String = ""
	var runes: Dictionary = {}
	var rune_order: Array[String] = []

	## 以下三个是"校验用的上下文"，不进对外契约，但测试与排障要看。
	var clue_registry_size: int = 0
	var case_require_ritual: String = ""
	var case_ritual_checked: bool = false

	## 线索台账（由 `parse_dictionary()` 从外层注入）。
	var _known_clues: Array[String] = []
	var _seen_step_ids: Dictionary = {}

	# ---------------------------------------------------------------- 查询

	func count() -> int:
		return rune_order.size()

	func rune_ids() -> Array[String]:
		return rune_order.duplicate()

	func get_rune(rune_id: String) -> Variant:
		if runes.has(rune_id):
			return runes[rune_id]
		return null

	func has_rune(rune_id: String) -> bool:
		return runes.has(rune_id)

	func total_steps() -> int:
		var total: int = 0
		for rune_id in rune_order:
			var entry: RuneEntry = runes[rune_id]
			total += entry.step_count()
		return total

	func total_strokes() -> int:
		var total: int = 0
		for rune_id in rune_order:
			var entry: RuneEntry = runes[rune_id]
			total += entry.total_strokes()
		return total

	func total_near_miss() -> int:
		var total: int = 0
		for rune_id in rune_order:
			var entry: RuneEntry = runes[rune_id]
			total += entry.total_near_miss()
		return total

	func error_summary() -> String:
		if errors.is_empty():
			return ""
		var head: Array[String] = []
		for index in range(min(errors.size(), 3)):
			head.append(errors[index])
		var text: String = "；".join(head)
		if errors.size() > 3:
			text += "（共 %d 条，余下略）" % errors.size()
		return text

	## 一句话：给人看的装载结果。
	func describe() -> String:
		if not ok:
			return "符表装载失败：%s" % error_summary()
		return "符表 %s：%d 道符 / %d 步 / %d 笔 / %d 条近似笔（%d 警告）" % [
			case_title, count(), total_steps(), total_strokes(), total_near_miss(), warnings.size(),
		]

	# ---------------------------------------------------------------- 校验

	## 线索交叉引用：只在登记表非空时判（见文件头取舍 2）。
	func _cross_reference_clues() -> void:
		var known: Array[String] = _known_clues
		clue_registry_size = known.size()
		if known.is_empty():
			_warn("线索台账为空（%s）：本轮没做 require_clues 交叉引用" % CLUE_DIR)
			return
		for rune_id in rune_order:
			var entry: RuneEntry = runes[rune_id]
			for clue_id in entry.require_clues:
				if clue_id == "":
					_error("符 %s：require_clues 里有空的 clue_id" % rune_id)
					continue
				if not known.has(clue_id):
					_error("符 %s：require_clues 引用了未登记的线索 '%s'%s" % [
						rune_id, clue_id, _suggest(clue_id, known),
					])
			for step in entry.steps:
				if step == null:
					continue
				for clue_id in step.require_clues:
					if clue_id != "" and not known.has(clue_id):
						_error("符 %s 步骤 %s：require_clues 引用了未登记的线索 '%s'%s" % [
							rune_id, step.step_id, clue_id, _suggest(clue_id, known),
						])

	## 与案件数据的交叉引用：`meta.secret.resolve_conditions.require_ritual` 必须点得到一道符。
	func _cross_reference_scenario(case_path: String) -> void:
		if case_path == "":
			return
		case_ritual_checked = true
		var scenario: Dictionary = _read_json(case_path)
		if scenario.is_empty():
			_warn("案件数据读不到（%s）：没做 require_ritual 交叉引用" % case_path)
			return
		var meta: Dictionary = _as_dict(scenario.get("meta", {}))
		var secret: Dictionary = _as_dict(meta.get("secret", {}))
		var conditions: Dictionary = _as_dict(secret.get("resolve_conditions", {}))
		case_require_ritual = _as_string(conditions.get("require_ritual", ""))
		if case_require_ritual == "":
			return
		if not runes.has(case_require_ritual):
			_warn("案件 meta.secret.resolve_conditions.require_ritual = '%s'，本符表里没有这道符（有：%s）——结案门槛会点空" % [
				case_require_ritual, ", ".join(rune_order),
			])

	func _finish() -> void:
		ok = errors.is_empty()
		error = error_summary()

	func _add_rune(data: Dictionary, position: int) -> void:
		var prefix: String = "runes[%d]" % position
		var rune_id: String = _as_string(data.get("rune_id", ""))
		if rune_id == "":
			_error("%s：rune_id 为空" % prefix)
			return
		if runes.has(rune_id):
			_error("%s：rune_id 重复 '%s'" % [prefix, rune_id])
			return

		var entry: RuneEntry = RuneEntry.new()
		entry.rune_id = rune_id
		entry.name = _as_string(data.get("name", ""))
		entry.display_name = _as_string(data.get("display_name", ""))
		if entry.display_name == "":
			entry.display_name = entry.name
		entry.source_note = _as_string(data.get("source_note", ""))
		entry.require_clues = _string_list(data.get("require_clues", []))
		entry.require_min_loop = _ints_back(data.get("require_min_loop", 0), 0)
		entry.gate_note = _as_string(data.get("gate_note", ""))
		entry.room = _as_string(data.get("room", ""))
		entry.npc_id = _as_string(data.get("npc_id", ""))
		entry.success_text = _as_string(data.get("success_text", ""))
		entry.fail_text = _as_string(data.get("fail_text", ""))
		_warn_unknown_keys(data, RUNE_KEYS, "%s（%s）" % [prefix, rune_id])

		if entry.require_min_loop < 0:
			_error("符 %s：require_min_loop 不能是负数（%d）" % [rune_id, entry.require_min_loop])

		var steps_value: Variant = data.get("steps", [])
		if not (steps_value is Array) or (steps_value as Array).is_empty():
			_error("符 %s：steps 为空（仪式至少要有一拍）" % rune_id)
		else:
			var steps: Array = steps_value
			for step_index in range(steps.size()):
				var step_data: Variant = steps[step_index]
				if not (step_data is Dictionary):
					_error("符 %s steps[%d]：不是对象" % [rune_id, step_index])
					continue
				entry.steps.append(_add_step(step_data, rune_id, step_index, entry))

		runes[rune_id] = entry
		rune_order.append(rune_id)

	## 解析并校验一步；坏数据只记 error，不做半截丢弃。
	func _add_step(data: Dictionary, rune_id: String, position: int, entry: RuneEntry) -> RuneStep:
		var prefix: String = "符 %s steps[%d]" % [rune_id, position]
		var step: RuneStep = RuneStep.new()
		step.index = position
		step.step_id = _as_string(data.get("step_id", ""))
		step.name = _as_string(data.get("name", ""))
		step.kind = _as_string(data.get("kind", ""))
		step.require_clues = _string_list(data.get("require_clues", []))
		step.gate_note = _as_string(data.get("gate_note", ""))
		step.text = _as_string(data.get("text", ""))
		step.note = _as_string(data.get("note", ""))
		step.npc_id = _as_string(data.get("npc_id", ""))
		step.room = _as_string(data.get("room", ""))
		step.cost_text = _as_string(data.get("cost_text", ""))
		step.success_text = _as_string(data.get("success_text", ""))
		_warn_unknown_keys(data, STEP_KEYS, prefix)

		if step.step_id == "":
			_error("%s：step_id 为空" % prefix)
		else:
			var key: String = "%s/%s" % [rune_id, step.step_id]
			if _seen_step_ids.has(key):
				_error("%s：step_id 重复 '%s'" % [prefix, step.step_id])
			else:
				_seen_step_ids[key] = true
		if not KINDS.has(step.kind):
			_error("%s：kind '%s' 不在 %s 里" % [prefix, step.kind, ", ".join(KINDS)])
		if data.has("step"):
			var declared: int = _ints_back(data.get("step", -1), -1)
			if declared >= 0 and declared != position + 1:
				_warn("%s：step 字段是 %d，与下标（%d）对不上——按下标 %d 走" % [prefix, declared, position + 1, position])
		if step.is_draw():
			step.strokes = _read_strokes(data.get("strokes", []), prefix)
			step.near_miss = _read_near_miss(data.get("near_miss", []), prefix)
			if step.strokes.is_empty():
				_error("%s：draw 步没有 strokes（画不出笔）" % prefix)
		elif step.is_choice():
			step.options = _read_options(data.get("options", []), prefix)
			var correct_count: int = 0
			for option in step.options:
				if option != null and option.correct:
					correct_count += 1
			if step.options.is_empty():
				_error("%s：choice 步没有 options" % prefix)
			elif correct_count != 1:
				_error("%s：choice 步的 correct:true 必须是恰好一个，实际 %d 个" % [prefix, correct_count])
		else:
			if step.is_gate() or step.is_npc():
				if step.text == "":
					_warn("%s：%s 步缺 text（表现层没词可念）" % [prefix, step.kind])
			if data.has("strokes") or data.has("options"):
				_warn("%s：%s 步带了 strokes/options，忽略" % [prefix, step.kind])
		if entry.room != "" and step.room != "" and step.room != entry.room:
			_warn("%s：room '%s' 与符的 room '%s' 不一致" % [prefix, step.room, entry.room])
		return step

	func _read_strokes(value: Variant, prefix: String) -> Array:
		var result: Array = []
		if not (value is Array):
			return result
		var rows: Array = value
		var seen_names: Array[String] = []
		for position in range(rows.size()):
			var row: Variant = rows[position]
			if not (row is Dictionary):
				_error("%s strokes[%d]：不是对象" % [prefix, position])
				continue
			var data: Dictionary = row
			var stroke: RuneStroke = RuneStroke.new()
			# 数据里的 `index` 与 `step` 一样是 1 基序号，这里统一转成 0 基下标暴露。
			var declared_stroke: int = _ints_back(data.get("index", position + 1), position + 1) - 1
			stroke.index = position
			if declared_stroke != position:
				_warn("%s strokes[%d]：index 字段是 %d，与下标（%d）对不上——按下标走" % [
					prefix, position, declared_stroke + 1, position + 1,
				])
			stroke.name = _as_string(data.get("name", ""))
			stroke.note = _as_string(data.get("note", ""))
			_warn_unknown_keys(data, STROKE_KEYS, "%s strokes[%d]" % [prefix, position])
			if stroke.name == "":
				_error("%s strokes[%d]：name 为空（笔没有字）" % [prefix, position])
			elif seen_names.has(stroke.name):
				_error("%s strokes[%d]：笔名 '%s' 重复" % [prefix, position, stroke.name])
			else:
				seen_names.append(stroke.name)
			stroke.pattern = _string_list(data.get("pattern", []))
			_check_tokens(stroke.pattern, "%s strokes[%d]（%s）" % [prefix, position, stroke.name])
			result.append(stroke)
		return result

	func _read_near_miss(value: Variant, prefix: String) -> Array:
		var result: Array = []
		if not (value is Array):
			return result
		var rows: Array = value
		var seen_ids: Array[String] = []
		for position in range(rows.size()):
			var row: Variant = rows[position]
			if not (row is Dictionary):
				_error("%s near_miss[%d]：不是对象" % [prefix, position])
				continue
			var data: Dictionary = row
			var miss: RuneNearMiss = RuneNearMiss.new()
			miss.attempt_id = _as_string(data.get("attempt_id", ""))
			miss.hint = _as_string(data.get("hint", ""))
			miss.clue_note = _as_string(data.get("clue_note", ""))
			_warn_unknown_keys(data, NEAR_MISS_KEYS, "%s near_miss[%d]" % [prefix, position])
			if miss.attempt_id == "":
				_error("%s near_miss[%d]：attempt_id 为空" % [prefix, position])
			elif seen_ids.has(miss.attempt_id):
				_error("%s near_miss[%d]：attempt_id 重复 '%s'" % [prefix, position, miss.attempt_id])
			else:
				seen_ids.append(miss.attempt_id)
			if miss.hint == "":
				_warn("%s near_miss[%d]：hint 为空（错笔没提示）" % [prefix, position])
			miss.pattern = _string_list(data.get("pattern", []))
			_check_tokens(miss.pattern, "%s near_miss[%d]（%s）" % [prefix, position, miss.attempt_id])
			result.append(miss)
		return result

	func _read_options(value: Variant, prefix: String) -> Array:
		var result: Array = []
		if not (value is Array):
			return result
		var rows: Array = value
		var seen_ids: Array[String] = []
		for position in range(rows.size()):
			var row: Variant = rows[position]
			if not (row is Dictionary):
				_error("%s options[%d]：不是对象" % [prefix, position])
				continue
			var data: Dictionary = row
			var option: RuneOption = RuneOption.new()
			option.option_id = _as_string(data.get("option_id", ""))
			option.text = _as_string(data.get("text", ""))
			option.correct = _as_bool(data.get("correct", false))
			option.reply = _as_string(data.get("reply", ""))
			_warn_unknown_keys(data, OPTION_KEYS, "%s options[%d]" % [prefix, position])
			if option.option_id == "":
				_error("%s options[%d]：option_id 为空" % [prefix, position])
			elif seen_ids.has(option.option_id):
				_error("%s options[%d]：option_id 重复 '%s'" % [prefix, position, option.option_id])
			else:
				seen_ids.append(option.option_id)
			if option.text == "":
				_warn("%s options[%d]：text 为空" % [prefix, position])
			result.append(option)
		return result

	func _check_tokens(pattern: Array[String], prefix: String) -> void:
		if pattern.is_empty():
			_error("%s：pattern 为空" % prefix)
			return
		for token in pattern:
			if not input_tokens.has(token):
				_error("%s：token '%s' 不在 inputs.tokens 里（%s）%s" % [
					prefix, token, ", ".join(input_tokens), _suggest(token, input_tokens),
				])

	# ---------------------------------------------------------------- 读头部

	func _read_meta(data: Dictionary) -> void:
		var meta: Dictionary = _as_dict(data.get("meta", {}))
		if meta.is_empty():
			_warn("缺 meta（没有 schema_version / case_title / 语义说明）")
		schema_version = _ints_back(meta.get("schema_version", 1), 1)
		if schema_version > SUPPORTED_SCHEMA_VERSION:
			_warn("schema_version %d 高于本 loader 支持的 %d：新字段会被忽略" % [
				schema_version, SUPPORTED_SCHEMA_VERSION,
			])
		var declared_case: int = _ints_back(meta.get("case_id", 0), 0)
		if declared_case > 0 and declared_case != case_id:
			_warn("meta.case_id 是 %d，与路径/入参推出的 %d 对不上" % [declared_case, case_id])
		if declared_case > 0:
			case_id = declared_case
		case_title = _as_string(meta.get("case_title", ""))
		purpose = _as_string(meta.get("purpose", ""))
		if case_title == "":
			_warn("meta.case_title 为空")

	func _read_inputs(data: Dictionary) -> void:
		var inputs: Dictionary = _as_dict(data.get("inputs", {}))
		if inputs.is_empty():
			_error("缺 inputs（没有 tokens / key_map：画符没法收键）")
			return
		input_tokens = _string_list(inputs.get("tokens", []))
		if input_tokens.is_empty():
			_error("inputs.tokens 为空（没有可用的方向 token）")
		backspace_key = _as_string(inputs.get("backspace_key", ""))
		commit_key = _as_string(inputs.get("commit_key", ""))
		if backspace_key == "":
			_warn("inputs.backspace_key 为空（退笔键没定）")
		if commit_key == "":
			_warn("inputs.commit_key 为空（提交键没定）")
		# key_map 是 token → Godot Key 枚举名（`"up": "KEY_UP"`）。loader 只透传给表现层，
		# 不把枚举名解析成 InputEvent（那是 InputMap 的事），也不校验 token 值域。
		var primary: Variant = inputs.get("key_map", {})
		if primary is Dictionary:
			key_map = primary
			if key_map.is_empty():
				_warn("inputs.key_map 为空（键盘映射没定，表现层要自己拍）")
		else:
			_warn("inputs.key_map 不是对象，忽略")
		var alternative: Variant = inputs.get("key_map_alt", {})
		if alternative is Dictionary:
			key_map_alt = alternative
		input_note = _as_string(inputs.get("note", ""))

	func _read_runes(data: Dictionary) -> void:
		var value: Variant = data.get("runes", [])
		if not (value is Array):
			_error("runes 必须是数组，实际是 %s" % type_string(typeof(value)))
			return
		var rows: Array = value
		if rows.is_empty():
			_error("runes 为空（这道案没有仪式）")
			return
		for position in range(rows.size()):
			var row: Variant = rows[position]
			if not (row is Dictionary):
				_error("runes[%d]：不是对象" % position)
				continue
			_add_rune(row, position)

	# ---------------------------------------------------------------- 小工具

	func _error(message: String) -> void:
		errors.append(message)

	func _warn(message: String) -> void:
		warnings.append(message)

	func _warn_unknown_keys(data: Dictionary, allowed: Array[String], prefix: String) -> void:
		for key in data.keys():
			var name: String = String(key)
			if not allowed.has(name):
				_warn("%s：未知字段 '%s'（本 loader 忽略它）" % [prefix, name])

	## 拼写建议：编辑距离最近的登记项（够近才提，避免瞎猜）。
	func _suggest(word: String, candidates: Array) -> String:
		var best: String = ""
		var best_distance: int = 0x7FFFFFFF
		for candidate in candidates:
			var name: String = String(candidate)
			var distance: int = _edit_distance(word, name)
			if distance < best_distance:
				best_distance = distance
				best = name
		if best == "" or best_distance > 4:
			return ""
		return "（是不是想写 '%s'？）" % best

	## 线索台账里登记的 clue_id（`require_clues` 的真名来源）。读不到 = 空数组，不报错。
	static func _read_clue_registry() -> Array[String]:
		var result: Array[String] = []
		var dir: DirAccess = DirAccess.open("res://data/clues")
		if dir == null:
			return result
		var names: PackedStringArray = dir.get_files()
		names.sort()
		for name in names:
			if not name.ends_with(".json"):
				continue
			var data: Dictionary = _read_json("res://data/clues/%s" % name)
			_collect_ids(data.get("clues", []), "clue_id", result)
		return result

	static func _read_json(path: String) -> Dictionary:
		if not FileAccess.file_exists(path):
			return {}
		var json: JSON = JSON.new()
		if json.parse(FileAccess.get_file_as_string(path)) != OK:
			return {}
		var data: Variant = json.data
		if data is Dictionary:
			return data
		return {}

	## 编辑距离（用于 id 拼写建议；两串都按 UTF-8 字节算，中文/下划线/数字混编也够用）。
	static func _edit_distance(left: String, right: String) -> int:
		var a: Array = left.to_utf8_buffer()
		var b: Array = right.to_utf8_buffer()
		if a.is_empty():
			return b.size()
		if b.is_empty():
			return a.size()
		var previous: Array[int] = []
		for index in range(b.size() + 1):
			previous.append(index)
		for i in range(1, a.size() + 1):
			var current: Array[int] = [i]
			for j in range(1, b.size() + 1):
				var cost: int = 0 if a[i - 1] == b[j - 1] else 1
				var deletion: int = previous[j] + 1
				var insertion: int = current[j - 1] + 1
				var substitution: int = previous[j - 1] + cost
				current.append(min(min(deletion, insertion), substitution))
			previous = current
		return previous[b.size()]

	static func _ints_back(value: Variant, fallback: int) -> int:
		if typeof(value) == TYPE_INT:
			return value
		if typeof(value) == TYPE_FLOAT:
			var number: float = value
			if floor(number) == number:
				return int(number)
			return int(floor(number))
		if typeof(value) == TYPE_STRING:
			var text: String = value
			if text.is_valid_int():
				return text.to_int()
		return fallback

	static func _as_string(value: Variant) -> String:
		if value == null:
			return ""
		if typeof(value) == TYPE_STRING:
			return value
		return str(value)

	static func _as_bool(value: Variant) -> bool:
		if typeof(value) == TYPE_BOOL:
			return value
		if typeof(value) == TYPE_STRING:
			var text: String = String(value).strip_edges().to_lower()
			return text == "true" or text == "1" or text == "yes"
		if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
			return float(value) != 0.0
		return false

	static func _as_dict(value: Variant) -> Dictionary:
		if value is Dictionary:
			return value
		return {}

	static func _string_list(value: Variant) -> Array[String]:
		var result: Array[String] = []
		if not (value is Array):
			return result
		var rows: Array = value
		for row in rows:
			result.append(_as_string(row))
		return result

	static func _case_id_from_path(path: String) -> int:
		var marker: int = path.find("case_")
		if marker < 0:
			return 0
		var digits: String = ""
		var position: int = marker + 5
		while position < path.length() and digits.length() < 2:
			var character: String = path[position]
			if character < "0" or character > "9":
				break
			digits += character
			position += 1
		if digits == "":
			return 0
		return digits.to_int()

	static func _collect_ids(value: Variant, key: String, into: Array[String]) -> void:
		if value is Array:
			var rows: Array = value
			for row in rows:
				if row is Dictionary:
					var data: Dictionary = row
					var id: String = _as_string(data.get(key, ""))
					if id != "" and not into.has(id):
						into.append(id)
		elif value is Dictionary:
			var table: Dictionary = value
			for map_key in table.keys():
				var id: String = String(map_key)
				if id != "" and not into.has(id):
					into.append(id)


# ============================================================================
#  静态入口：装载 / 定位
# ============================================================================

static func load_for_case(case_id: int = DEFAULT_CASE_ID) -> RuneTable:
	var target: String = find_rune_path(case_id)
	if target == "":
		var missing: RuneTable = RuneTable.new()
		missing.path = ""
		missing.case_id = case_id
		missing.error = "找不到案 %02d 的符表（%s/case_%02d_runes.json）" % [case_id, RUNE_DIR, case_id]
		missing.errors.append(missing.error)
		return missing
	return load_from_file(target, find_scenario_path(case_id))


static func load_from_file(path: String, case_path: String = "") -> RuneTable:
	if not FileAccess.file_exists(path):
		var missing: RuneTable = RuneTable.new()
		missing.path = path
		missing.error = "符表文件不存在：%s" % path
		missing.errors.append(missing.error)
		return missing
	var text: String = FileAccess.get_file_as_string(path)
	return parse_text(text, path, case_path)


static func parse_text(text: String, path: String = "", case_path: String = "") -> RuneTable:
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		# AGENTS.md §4：JSON.get_error_column() 不存在 → 只有 get_error_line()（0 基，+1 才是行号）。
		var failed: RuneTable = RuneTable.new()
		failed.path = path
		failed.error = "JSON 解析失败：第 %d 行 %s" % [json.get_error_line() + 1, json.get_error_message()]
		failed.errors.append(failed.error)
		return failed
	var data: Variant = json.data
	if not (data is Dictionary):
		var wrong_type: RuneTable = RuneTable.new()
		wrong_type.path = path
		wrong_type.error = "符表根节点必须是对象，实际是 %s" % type_string(typeof(data))
		wrong_type.errors.append(wrong_type.error)
		return wrong_type
	return parse_dictionary(data, path, case_path)


## 纯内存装载（测试夹具走这里；`case_id` 缺省时从 `path` 的 case_NN 反推）。
static func parse_dictionary(data: Dictionary, path: String = "", case_path: String = "") -> RuneTable:
	var table: RuneTable = RuneTable.new()
	table.path = path
	table.case_id = RuneTable._case_id_from_path(path)
	if table.case_id <= 0:
		table.case_id = DEFAULT_CASE_ID
	# 线索台账在外层读好再注入：内部类的静态作用域只认自己，调不到外层静态函数。
	table._known_clues = load_known_clue_ids()
	table._read_meta(data)
	table._read_inputs(data)
	table._read_runes(data)
	table._cross_reference_clues()
	table._cross_reference_scenario(case_path)
	table._finish()
	return table


static func list_rune_files() -> Array[String]:
	var result: Array[String] = []
	var dir: DirAccess = DirAccess.open(RUNE_DIR)
	if dir == null:
		return result
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for name in names:
		if name.ends_with(".json"):
			result.append("%s/%s" % [RUNE_DIR, name])
	return result


static func find_rune_path(case_id: int = -1) -> String:
	if case_id > 0:
		var direct: String = "%s/case_%02d_runes.json" % [RUNE_DIR, case_id]
		if FileAccess.file_exists(direct):
			return direct
		return ""
	var files: Array[String] = list_rune_files()
	if files.is_empty():
		return ""
	return files[0]


static func find_scenario_path(case_id: int = -1) -> String:
	if case_id > 0:
		var direct: String = "%s/case_%02d_baihu.json" % [SCENARIO_DIR, case_id]
		if FileAccess.file_exists(direct):
			return direct
		return ""
	var dir: DirAccess = DirAccess.open(SCENARIO_DIR)
	if dir == null:
		return ""
	var names: PackedStringArray = dir.get_files()
	names.sort()
	for name in names:
		if name.begins_with("case_") and name.ends_with(".json"):
			return "%s/%s" % [SCENARIO_DIR, name]
	return ""


## 线索台账里登记的 clue_id（`require_clues` 的真名来源）。读不到 = 空数组，不报错。
## 实现在 `RuneTable._read_clue_registry()`：内部类写不出外层脚本名，工具只能挂在表上。
static func load_known_clue_ids() -> Array[String]:
	return RuneTable._read_clue_registry()

