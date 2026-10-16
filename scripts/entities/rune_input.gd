extends Node
## scripts/entities/rune_input.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**输入状态机**
##
## 为什么需要它：M1 ① 的"秒级重演"里，玩家要照着余页上的原石，一笔一笔把「回照录」描出来。
## 这一步是玩家**唯一的手眼协调动作**，也是最容易做成"点一下就过"的地方——所以判定必须严格：
## 笔顺不对、缺一点、多一笔都算错，但**不扣心灯、不判负**（`data/runes/case_01_runes.json` 的
## `meta.failure_note` 就是这么定的：画错只是"没描上"，代价是你在余页里花掉的时间）。
##
## 状态机（四个状态，`rune_changed(state)` 只会在这四者之间跳，值不变不广播）：
##   idle    —— 没有在进行的仪式
##   step    —— 站在某一步上（gate/npc/choice 等确认，draw 等第一笔起笔）
##   drawing —— 正在描某一笔（token 在攒，还没提交）
##   done    —— 整道符完成（`rune_completed` 已广播）
##
## 判定语义（`commit_stroke()`，逐字照 `case_01_runes.json` 的 `discrimination_semantics`）：
##   1. 与当前笔 `pattern` 完全相等 ⇒ status="ok"：记进 `drawn_strokes()`、`stroke_index` 前进；
##      三笔都提交完 ⇒ `step_done=true`，state 回 `step`（**不自动推进下一步**，由表现层调 `advance()`）。
##   2. 与某条 `near_miss` 完全相等 ⇒ status="near_miss"：回填那条的 `attempt_id` 与 `hint`（原文照抄），
##      这一笔**不记入、不前进**。
##   3. 其它 ⇒ status="wrong"：给兜底文案 `"这一笔对不上原石：笔顺或方向不对。可以退一笔重描。"`。
##   4. 没在跑 / 不在 draw 步 / token 串为空 / 状态不是 drawing ⇒ status="wrong"，hint 说明原因。
##
## 三条设计取舍：
##   1. **零 Autoload 引用**：这个文件里不出现 `TimeLoopManager` / `PersistentMemoryManager` 标识符，
##      订阅一律 `get_node_or_null("/root/TimeLoopManager")` 相对解析 —— 好处是 `--check-only --script`
##      能直接过（AGENTS.md §4 说引用 Autoload 的脚本在该模式会误报），也便于无头测试注入假时钟。
##   2. **纯依赖注入**：门线（线索 / 遍数 / 房间）全部来自 `set_owned_clues()` 或注入的记忆对象；
##      组件自己不查任何全局状态。显式 `set_owned_clues()` 的集合**优先于**注入对象。
##   3. **不落盘**：本组件不碰 `user://`（心灯与线索落盘是 `clue_store.gd` 的事）。

const RuneLoader = preload("res://scripts/data/rune_loader.gd")

const DEFAULT_CASE_ID: int = 1

const STATE_IDLE: String = "idle"
const STATE_STEP: String = "step"
const STATE_DRAWING: String = "drawing"
const STATE_DONE: String = "done"

const STATUS_OK: String = "ok"
const STATUS_NEAR_MISS: String = "near_miss"
const STATUS_WRONG: String = "wrong"

## 兜底文案（与 `data/runes/case_01_runes.json` 的 `meta.failure_note` 一致：画错不扣灯、不判负）。
const WRONG_HINT: String = "这一笔对不上原石：笔顺或方向不对。可以退一笔重描。"

signal rune_changed(state: String)
signal rune_step_changed(step_id: String, step_index: int, total: int)
signal rune_stroke_drawn(stroke_index: int, tokens: Array)
signal rune_completed(rune_id: String)
signal rune_failed(rune_id: String, reason: String)

## 时钟挂在哪个节点上（相对解析，不写死标识符）。
const LOOP_MANAGER_PATH: String = "/root/TimeLoopManager"
const LOOP_MANAGER_NAME: String = "TimeLoopManager"
## `true` = `_ready()` 时若挂得上 `/root/TimeLoopManager` 就订它的 `loop_reset`（本遍绘制清零）。
var auto_subscribe: bool = true

var _table: Variant = null
var _configured: bool = false
var _errors: Array[String] = []
var _warnings: Array[String] = []

var _memory: Node = null
var _manual_clues: Array[String] = []
var _manual_set: bool = false
var _owned: Array[String] = []

var _room: String = ""
var _loop_index: int = 0

var _state: String = STATE_IDLE
var _rune_id: String = ""
var _step_index: int = 0
var _stroke_index: int = 0
var _tokens: Array[String] = []
var _drawn: Array = []
var _choice_done: bool = false
var _last_message: String = ""
var _failed_reason: String = ""
var _subscribed: Node = null


func _ready() -> void:
	if auto_subscribe:
		_subscribe_loop_manager()


# ============================================================================
#  配置 / 装载
# ============================================================================

func configure(case_id: int = DEFAULT_CASE_ID) -> bool:
	var table: Variant = RuneLoader.load_for_case(case_id)
	return configure_with_table(table)


## 注入一张已装好的 `RuneTable`（测试夹具走这里）。
## options 认：`{"auto_subscribe": bool, "clues": Array, "room": String, "loop_index": int}`。
func configure_with_table(table: Variant, options: Dictionary = {}) -> bool:
	_reset_all()
	_table = table
	_configured = table != null
	if table == null:
		_errors.append("没拿到符表（table 为空）")
	else:
		_errors = _copy_strings(table.errors)
		_warnings = _copy_strings(table.warnings)
	if options.has("auto_subscribe"):
		auto_subscribe = bool(options["auto_subscribe"])
	if options.has("clues"):
		set_owned_clues(options["clues"])
	if options.has("room"):
		set_room(String(options["room"]))
	if options.has("loop_index"):
		set_loop_index(int(options["loop_index"]))
	if auto_subscribe:
		# 不要求 `is_inside_tree()`：无头脚本里 root 还没进树，但假时钟就挂在 root 下，
		# `_resolve_loop_manager()` 照样找得到（找不到时它自己返回 null，不报错）。
		_subscribe_loop_manager()
	return _table != null and _table.ok

func is_configured() -> bool:
	return _configured

func is_ok() -> bool:
	return _configured and _table != null and _table.ok

func get_table() -> Variant:
	return _table

func get_errors() -> Array[String]:
	return _errors.duplicate()

func get_warnings() -> Array[String]:
	return _warnings.duplicate()

func error_summary() -> String:
	if _table == null:
		# 还没装载：表现层问"为什么起不了符"时不能只拿到空串。
		if _errors.is_empty():
			return "符表还没装载：先 configure() 或 configure_with_table()。"
		return "；".join(_errors)
	if _errors.is_empty():
		return ""
	if not _table.ok:
		return _table.error_summary()
	var head: Array[String] = []
	for index in range(min(_errors.size(), 3)):
		head.append(_errors[index])
	var text: String = "；".join(head)
	if _errors.size() > 3:
		text += "（共 %d 条，余下略）" % _errors.size()
	return text


# ============================================================================
#  依赖注入：线索 / 房间 / 遍数
# ============================================================================

## 注入记忆对象（表现层实际注入 HeartLamp / PersistentMemoryManager）。
## 有 `get_available_clues()` 就优先用它（心灯的"可用"口径），否则退到 `has_clue()` / `get_clues()`。
func set_memory_manager(memory: Node) -> void:
	_memory = memory
	_refresh_owned()

func get_memory_manager() -> Node:
	return _memory

## 显式给出已拥有的线索集合（**优先于**注入对象；测试与夹具走这条）。
func set_owned_clues(clue_ids: Array) -> void:
	_manual_clues.clear()
	if clue_ids != null:
		for value in clue_ids:
			var clue_id: String = String(value)
			if clue_id != "" and not _manual_clues.has(clue_id):
				_manual_clues.append(clue_id)
	_manual_set = true
	_refresh_owned()

func get_owned_clues() -> Array[String]:
	return _owned.duplicate()

func set_room(room_id: String) -> void:
	_room = room_id

func get_room() -> String:
	return _room

func set_loop_index(index: int) -> void:
	_loop_index = max(index, 0)

func get_loop_index() -> int:
	return _loop_index


# ============================================================================
#  起符 / 门线
# ============================================================================

## 能不能起这道符（rune_id 为空 = 用表里唯一/第一条符）。
func can_start(rune_id: String = "") -> bool:
	_refresh_owned()   # 线索可能刚入账 ⇒ 每次问都重算（别拿旧快照卡住玩家）
	var entry: Variant = _resolve_rune(rune_id)
	if entry == null:
		return false
	return entry.is_available(_loop_index, _owned) and _room_ok(entry)


## 起符。门槛：`require_clues` 全在 owned + `loop_index >= require_min_loop` + 房间对
## （符的 `room` 为空则不校验房间）。不满足 ⇒ false，并把 `gate_note` 记进 `_last_message`。
func start_rune(rune_id: String = "") -> bool:
	_refresh_owned()   # 同上：起手那一刻以最新线索为准
	if not is_ok():
		_last_message = "符表没装载好：%s" % error_summary()
		return false
	var entry: Variant = _resolve_rune(rune_id)
	if entry == null:
		_last_message = "没有这道符：'%s'" % rune_id
		return false
	var missing: Array[String] = entry.missing_clues(_owned)
	if not missing.is_empty():
		_last_message = _gate_message(entry, "线索还差 %d 条：%s" % [missing.size(), ", ".join(missing)])
		return false
	if _loop_index < entry.require_min_loop:
		_last_message = _gate_message(entry, "要第 %d 遍才能回照（现在是第 %d 遍）" % [
			entry.require_min_loop + 1, _loop_index + 1,
		])
		return false
	if not _room_ok(entry):
		_last_message = _gate_message(entry, "这里画不出这道符（要在 %s，现在是 %s）" % [
			entry.room, _room if _room != "" else "未指定",
		])
		return false
	_rune_id = entry.rune_id
	_step_index = 0
	_stroke_index = 0
	_drawn.clear()
	_tokens.clear()
	_choice_done = false
	_last_message = entry.gate_note
	_state = STATE_IDLE
	_set_state(STATE_STEP)
	_emit_step()
	return true


# ============================================================================
#  运行状态查询
# ============================================================================

func is_running() -> bool:
	if _state == STATE_IDLE or _state == STATE_DONE:
		return false
	return _rune_id != ""

func get_state() -> String:
	return _state

func get_current_rune_id() -> String:
	return _rune_id

func get_current_step() -> Variant:
	var entry: Variant = _current_entry()
	if entry == null:
		return null
	if _step_index < 0 or _step_index >= entry.steps.size():
		return null
	return entry.steps[_step_index]

func get_step_index() -> int:
	return _step_index

func get_step_count() -> int:
	var entry: Variant = _current_entry()
	if entry == null:
		return 0
	return entry.step_count()


# ============================================================================
#  画一笔：攒 token → 提交
# ============================================================================

## 起笔：从"站在 draw 步上"进到 drawing（重复调 = 清掉这一笔已攒的 token 重来）。
func begin_stroke() -> void:
	var step: Variant = get_current_step()
	if step == null or not step.is_draw():
		return
	_tokens.clear()
	_set_state(STATE_DRAWING)

## 收一个方向 token。不在 drawing / 不是登记 token ⇒ false（不改任何状态）。
func feed_token(token: String) -> bool:
	if _state != STATE_DRAWING:
		return false
	if _table == null or not _table.input_tokens.has(token):
		return false
	_tokens.append(token)
	return true

## 退一个 token：空则 false。
func undo_token() -> bool:
	if _state != STATE_DRAWING:
		return false
	if _tokens.is_empty():
		return false
	_tokens.remove_at(_tokens.size() - 1)
	return true

func current_tokens() -> Array[String]:
	return _tokens.duplicate()

func current_stroke_index() -> int:
	return _stroke_index

## 已提交的笔（元素是 `Array[String]`，已拷贝 —— 外面改不动内部状态）。
func drawn_strokes() -> Array:
	var result: Array = []
	for row in _drawn:
		result.append(_copy_strings(row))
	return result

## 退一整笔：把上一笔从已提交里撤掉，并把它重新装回 token 串（可以改一个方向再描）。
func undo_stroke() -> bool:
	if _state == STATE_IDLE or _state == STATE_DONE:
		return false
	if _state == STATE_DRAWING:
		_set_state(STATE_STEP)
	if _drawn.is_empty():
		return false
	var last: Array = _drawn.pop_back()
	_stroke_index = _drawn.size()
	_tokens = _copy_strings(last)
	_set_state(STATE_DRAWING)
	return true


## 判定当前 token 串（语义见文件头）。返回键：ok / status / attempt_id / hint /
## stroke_index / stroke_name / expected / got / step_done。
func commit_stroke() -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"status": STATUS_WRONG,
		"attempt_id": "",
		"hint": "",
		"stroke_index": _stroke_index,
		"stroke_name": "",
		"expected": [],
		"got": _tokens.duplicate(),
		"step_done": false,
	}
	if not is_running():
		result["hint"] = "还没开始画符。"
		return result
	var step: Variant = get_current_step()
	if step == null or not step.is_draw():
		result["hint"] = "现在这一步不用画：先照着提示做完这一拍。"
		return result
	if _state != STATE_DRAWING:
		result["hint"] = "先起笔再描。"
		return result
	if _tokens.is_empty():
		result["hint"] = "这一笔还是空的：先用方向键描出来。"
		return result

	var stroke: Variant = _current_stroke(step)
	if stroke == null:
		result["hint"] = "这一步的笔画数据缺了第 %d 笔。" % (_stroke_index + 1)
		return result
	result["stroke_name"] = stroke.name
	result["expected"] = _copy_strings(stroke.pattern)

	if stroke.matches(_tokens):
		_drawn.append(_tokens.duplicate())
		result["ok"] = true
		result["status"] = STATUS_OK
		result["hint"] = "描上了：第 %d 笔「%s」。" % [_stroke_index + 1, stroke.name]
		result["stroke_index"] = _stroke_index
		_stroke_index = _drawn.size()
		_tokens.clear()
		result["step_done"] = _stroke_index >= step.stroke_count()
		_set_state(STATE_STEP)
		rune_stroke_drawn.emit(result["stroke_index"], _drawn[result["stroke_index"]].duplicate())
		return result

	for miss in step.near_miss:
		if miss != null and miss.matches(_tokens):
			result["status"] = STATUS_NEAR_MISS
			result["attempt_id"] = miss.attempt_id
			result["hint"] = miss.hint
			return result

	result["hint"] = WRONG_HINT
	return result


# ============================================================================
#  选项 / 推进
# ============================================================================

## 选一个选项（只在 choice 步有意义）。选对 ⇒ 本步完成；选错 ⇒ `ok=false` **不推进**。
## 返回键：ok / correct / reply / step_done / hint。
func choose_option(option_id: String) -> Dictionary:
	var result: Dictionary = {
		"ok": false,
		"correct": false,
		"reply": "",
		"step_done": false,
		"hint": "",
	}
	if not is_running():
		result["hint"] = "还没开始画符。"
		return result
	var step: Variant = get_current_step()
	if step == null or not step.is_choice():
		result["hint"] = "现在这一步不是选言。"
		return result
	var option: Variant = step.get_option(option_id)
	if option == null:
		result["hint"] = "没有这个选项：'%s'" % option_id
		return result
	result["reply"] = option.reply
	if not option.correct:
		result["hint"] = "他把这句记下来了 —— 但这一步不该这么回。"
		_last_message = result["hint"]
		return result
	result["ok"] = true
	result["correct"] = true
	result["step_done"] = true
	_choice_done = true
	result["hint"] = option.reply
	_last_message = option.reply
	return result


## 确认推进：`gate` / `npc` 步直接过；`draw` 步要三笔全对才过；`choice` 步必须走 `choose_option()`，
## 这里返回 false（防表现层"一路空格冲过去"）。
func advance() -> bool:
	if not is_running():
		return false
	var step: Variant = get_current_step()
	if step == null:
		return false
	if step.is_choice():
		# 选言步：没选对之前不许往下（防表现层"一路空格冲过去"）；
		# 选对了（choose_option 置 _choice_done）才放行。
		if not _choice_done:
			_last_message = "这一步要选一句：空格没用。"
			return false
	if step.is_draw():
		if _stroke_index < step.stroke_count():
			_last_message = "还差 %d 笔没描。" % (step.stroke_count() - _stroke_index)
			return false
	_step_index += 1
	_stroke_index = 0
	_drawn.clear()
	_tokens.clear()
	_choice_done = false
	var entry: Variant = _current_entry()
	if entry == null or _step_index >= entry.step_count():
		if entry != null:
			_step_index = max(entry.step_count() - 1, 0)
		_set_state(STATE_DONE)
		rune_completed.emit(_rune_id)
		return true
	_set_state(STATE_STEP)
	_emit_step()
	return true


# ============================================================================
#  完成 / 失败 / 重置
# ============================================================================

func is_completed() -> bool:
	return _state == STATE_DONE

func completed_rune_id() -> String:
	if _state != STATE_DONE:
		return ""
	return _rune_id


## 中止当前仪式（表现层在余页结束 / 玩家被赶走时调；不扣心灯、不判负）。
func fail_rune(reason: String = "") -> bool:
	if not is_running():
		return false
	var rune_id: String = _rune_id
	_failed_reason = reason
	_last_message = reason
	_reset_progress()
	_set_state(STATE_IDLE)
	rune_failed.emit(rune_id, reason)
	return true


## 清空本遍绘制状态（回到 idle；符表与注入的线索不动）。
func reset() -> void:
	if _state != STATE_IDLE:
		_reset_progress()
		_set_state(STATE_IDLE)


# ============================================================================
#  文本 / 快照
# ============================================================================

func get_last_message() -> String:
	return _last_message

func describe() -> String:
	var entry: Variant = _current_entry()
	if entry == null:
		if is_ok():
			return "符表就绪：%s（未起符）" % _table.case_title
		return "符表没就绪：%s" % error_summary()
	var text: String = "%s / %s：第 %d/%d 步" % [
		entry.display_name, _rune_id, _step_index + 1, entry.step_count(),
	]
	var step: Variant = get_current_step()
	if step != null:
		text += "（%s %s）" % [step.kind, step.step_id]
		if step.is_draw():
			text += " 已描 %d/%d 笔" % [_stroke_index, step.stroke_count()]
	return text

func describe_step() -> String:
	var step: Variant = get_current_step()
	if step == null:
		return get_last_message()
	var text: String = "%s" % step.name
	if step.kind == "draw":
		text += "：第 %d/%d 笔" % [_stroke_index + 1, step.stroke_count()]
		var stroke: Variant = _current_stroke(step)
		if stroke != null and _tokens.size() > stroke.token_count():
			text += "（已经描长了）"
	return text

## 给人看的提示行（表现层直接铺在 HUD 上）；`max_lines` 是硬上限，`max_lines <= 0` ⇒ 空数组。
func prompt_lines(max_lines: int = 6) -> Array[String]:
	var lines: Array[String] = []
	if max_lines <= 0:
		return lines
	var entry: Variant = _current_entry()
	if entry == null:
		if is_ok():
			lines.append("原石上的符还没起：先去对的地方、拿齐线索、等到该回照的那一遍。")
		else:
			lines.append("符表没装载好：%s" % error_summary())
		return _truncate(lines, max_lines)
	if _state == STATE_DONE:
		if entry.success_text != "":
			lines.append(entry.success_text)
		else:
			lines.append("这道符已经描成了。")
		return _truncate(lines, max_lines)

	var step: Variant = get_current_step()
	if _state == STATE_DRAWING and step != null and step.is_draw():
		var stroke: Variant = _current_stroke(step)
		var remain: int = 0
		if stroke != null:
			remain = max(stroke.token_count() - _tokens.size(), 0)
		lines.append("正在描第 %d 笔「%s」：已 %d 画，还差 %d 画。" % [
			_stroke_index + 1, stroke.name if stroke != null else "?", _tokens.size(), remain,
		])
		lines.append("方向：%s" % (" → ".join(_tokens) if not _tokens.is_empty() else "（还没落笔）"))
		if _table != null:
			lines.append("退一笔 %s / 提交 %s" % [_table.backspace_key, _table.commit_key])
		return _truncate(lines, max_lines)

	if step == null:
		lines.append(get_last_message())
		return _truncate(lines, max_lines)
	lines.append("第 %d/%d 步：%s（%s）" % [_step_index + 1, entry.step_count(), step.name, step.step_id])
	if step.text != "":
		lines.append(step.text)
	if step.gate_note != "":
		lines.append(step.gate_note)
	if step.is_draw():
		lines.append("要描 %d 笔：%s。" % [
			step.stroke_count(), "、".join(_stroke_names(step)),
		])
		if _table != null and not _table.input_tokens.is_empty():
			lines.append("方向 token：%s" % ", ".join(_table.input_tokens))
		lines.append("已描 %d/%d 笔，退一笔 %s / 提交 %s" % [
			_stroke_index, step.stroke_count(), _table.backspace_key, _table.commit_key,
		])
	elif step.is_choice():
		for option in step.options:
			if option != null:
				lines.append("· %s：%s" % [option.option_id, option.text])
	elif step.cost_text != "":
		lines.append(step.cost_text)
	if step.note != "":
		lines.append(step.note)
	if _last_message != "" and _last_message != step.gate_note:
		lines.append(_last_message)
	return _truncate(lines, max_lines)

## 状态快照：必须能被 `JSON.stringify()`（表现层存档 / 调试面板用）。
## 注意：这里**不含 RuneTable / Node** —— 只放可序列化的值。
func get_state_snapshot() -> Dictionary:
	var entry: Variant = _current_entry()
	var step: Variant = get_current_step()
	return {
		"configured": _configured,
		"ok": is_ok(),
		"state": _state,
		"rune_id": _rune_id,
		"rune_title": entry.display_name if entry != null else "",
		"step_index": _step_index,
		"step_count": entry.step_count() if entry != null else 0,
		"step_id": step.step_id if step != null else "",
		"step_kind": step.kind if step != null else "",
		"stroke_index": _stroke_index,
		"stroke_count": step.stroke_count() if step != null and step.is_draw() else 0,
		"tokens": _copy_strings(_tokens),
		"drawn": drawn_strokes(),
		"drawn_count": _drawn.size(),
		"loop_index": _loop_index,
		"room": _room,
		"owned_clues": _owned.duplicate(),
		"completed": is_completed(),
		"last_message": _last_message,
		"failed_reason": _failed_reason,
	}


# ============================================================================
#  内部：订阅 / 解析 / 小工具
# ============================================================================

## 相对解析 `/root/TimeLoopManager`（本文件不出现 Autoload 标识符，见文件头取舍 1）。
## 无头脚本（`--script`）里 `root` 在 `_initialize()` 期间还没进树，绝对路径解析会失败 ⇒ 退到
## "从 root 逐级 get_node_or_null"，两条路都不写死任何 Autoload 标识符。
func _subscribe_loop_manager() -> void:
	_subscribed = _resolve_loop_manager()
	if _subscribed == null:
		return
	var callback: Callable = Callable(self, "_on_loop_reset")
	if _subscribed.is_connected("loop_reset", callback):
		return
	if _subscribed.connect("loop_reset", callback) != OK:
		_subscribed = null

func _unsubscribe_loop_manager() -> void:
	_subscribed = _resolve_loop_manager()
	if _subscribed != null:
		var callback: Callable = Callable(self, "_on_loop_reset")
		if _subscribed.is_connected("loop_reset", callback):
			_subscribed.disconnect("loop_reset", callback)
	_subscribed = null

## 把 `_subscribed` 与实际连接对齐：**以连接为准**，不用 `_subscribed` 缓存当唯一真相。
## 这样"假时钟被顶开/换掉"或"外部手工 connect 过"都不会让订阅状态错位（`_ready()` 里
## 已连过而 `_subscribed` 还没回填的情况也靠这一步补上）。
func _refresh_subscription() -> void:
	var manager: Node = _resolve_loop_manager()
	var callback: Callable = Callable(self, "_on_loop_reset")
	if manager == null or not manager.is_connected("loop_reset", callback):
		_subscribed = null
	else:
		_subscribed = manager

## 订阅是否真的在（`_subscribed != null` 就等于"连接存在"，两条路径都维护这个不变量）。
func is_subscribed() -> bool:
	_refresh_subscription()
	return _subscribed != null

## 新的一遍：本遍绘制状态清零（线索与符表不动）。
func _on_loop_reset(_loop_index: int = 0) -> void:
	reset()

## 找时钟：① 相对路径 `/root/TimeLoopManager`（正常挂树时）；② 退到 root 的子节点里按名字找
## （无头脚本里 root 自身还没进树、绝对路径解析会报错时走这条）。
## 顺序上"逐级查找"优先于绝对路径：无头测试里 `/root/TimeLoopManager` 可能被 Autoload 占着，
## 而挂在根下的假时钟才是当下真正要订的那个（两者同名同路径，只能按挂载位置判先后）。
## 找不到 ⇒ null，不报错（工具/测试模式正常，引导层可自行 set_loop_index()）。
func _resolve_loop_manager() -> Node:
	var tree: SceneTree = _scene_tree()
	if tree == null or tree.root == null:
		return null
	var root: Node = tree.root
	for child in root.get_children():
		if child != null and child.name == LOOP_MANAGER_NAME:
			return child
	if is_inside_tree():
		return get_node_or_null(LOOP_MANAGER_PATH)
	return null

## 场景树：挂树时用 get_tree()，没挂树时退回 Engine 的主循环（无头脚本模式）。
func _scene_tree() -> SceneTree:
	if is_inside_tree():
		return get_tree()
	var loop: MainLoop = Engine.get_main_loop()
	if loop is SceneTree:
		return loop
	return null

func _exit_tree() -> void:
	_unsubscribe_loop_manager()

func _reset_all() -> void:
	_errors.clear()
	_warnings.clear()
	_configured = false
	_table = null
	_reset_progress()
	_last_message = ""
	_failed_reason = ""
	_state = STATE_IDLE
	# 订阅不在这里动：重新配置不该把 loop_reset 解绑（否则每配一次就少一条，
	# 而无头/未挂树的场景下 `is_inside_tree()` 为假、补订也补不回来）。
	# 订阅与否统一由 `_subscribe_loop_manager()` / `_unsubscribe_loop_manager()` 管（幂等）。
	if auto_subscribe:
		_subscribe_loop_manager()

func _reset_progress() -> void:
	_rune_id = ""
	_step_index = 0
	_stroke_index = 0
	_tokens.clear()
	_drawn.clear()
	_choice_done = false
	_last_message = ""
	_failed_reason = ""

func _set_state(next: String) -> void:
	if _state == next:
		return
	_state = next
	rune_changed.emit(_state)

func _emit_step() -> void:
	var step: Variant = get_current_step()
	if step == null:
		return
	var entry: Variant = _current_entry()
	var total: int = entry.step_count() if entry != null else 0
	rune_step_changed.emit(step.step_id, _step_index, total)

func _refresh_owned() -> void:
	if _manual_set:
		_owned = _manual_clues.duplicate()
		return
	_owned = _read_memory_clues()

func _read_memory_clues() -> Array[String]:
	var result: Array[String] = []
	if _memory == null or not is_instance_valid(_memory):
		return result
	if _memory.has_method("get_available_clues"):
		_add_into(result, _memory.call("get_available_clues"))
		return result
	if _memory.has_method("get_clues"):
		_add_into(result, _memory.call("get_clues"))
		return result
	# 只有 has_clue() 的对象（谓词式接口，枚举不出来）：拿符表登记的 require_clues 当候选集逐个问。
	if _memory.has_method("has_clue"):
		for candidate in _candidate_clues():
			if bool(_memory.call("has_clue", candidate)) and not result.has(candidate):
				result.append(candidate)
	return result

## 候选线索 = 表里所有符的 `require_clues` 并集（只用于"有没有"式接口的兜底询问）。
func _candidate_clues() -> Array[String]:
	var result: Array[String] = []
	if _table == null:
		return result
	for rune_id in _table.rune_order:
		var entry: Variant = _table.get_rune(rune_id)
		if entry == null:
			continue
		for clue_id in entry.require_clues:
			if not result.has(clue_id):
				result.append(clue_id)
	return result

func _add_into(result: Array[String], value: Variant) -> void:
	if value is Array:
		var rows: Array = value
		for row in rows:
			var clue_id: String = String(row)
			if clue_id != "" and not result.has(clue_id):
				result.append(clue_id)
	elif value is Dictionary:
		var table: Dictionary = value
		for key in table.keys():
			var clue_id: String = String(key)
			if clue_id != "" and not result.has(clue_id):
				result.append(clue_id)

func _current_entry() -> Variant:
	if _table == null or _rune_id == "":
		return null
	if not _table.has_rune(_rune_id):
		return null
	return _table.get_rune(_rune_id)

func _resolve_rune(rune_id: String) -> Variant:
	if _table == null or not _table.ok:
		return null
	if rune_id != "":
		if _table.has_rune(rune_id):
			return _table.get_rune(rune_id)
		return null
	# 空 = 表里唯一那道符；多道符时取第一道（案一只有一道）。
	if _table.rune_order.is_empty():
		return null
	return _table.get_rune(_table.rune_order[0])

func _current_stroke(step: Variant) -> Variant:
	if step == null:
		return null
	if _stroke_index < 0 or _stroke_index >= step.strokes.size():
		return null
	return step.strokes[_stroke_index]

func _room_ok(entry: Variant) -> bool:
	if entry == null or entry.room == "":
		return true
	return _room == entry.room

func _gate_message(entry: Variant, reason: String) -> String:
	var note: String = entry.gate_note if entry != null else ""
	if note == "":
		return reason
	return "%s %s" % [reason, note]

func _stroke_names(step: Variant) -> Array[String]:
	var names: Array[String] = []
	if step == null:
		return names
	for stroke in step.strokes:
		if stroke != null:
			names.append(stroke.name)
	return names

func _copy_strings(values: Array) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result

func _truncate(lines: Array[String], max_lines: int) -> Array[String]:
	var result: Array[String] = []
	for index in range(min(lines.size(), max_lines)):
		if lines[index] != "":
			result.append(lines[index])
	return result
