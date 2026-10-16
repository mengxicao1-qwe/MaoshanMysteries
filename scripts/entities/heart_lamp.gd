extends Node
## ============================================================================
##  heart_lamp.gd —— 心灯（玩法层组件 / Entities）
## ----------------------------------------------------------------------------
##  世界观：心灯是主角"身神"的存量 —— 名籍上还没被划掉的那一部分。
##  玩法：它不是血条，消耗的是【记忆的代价】：
##      * 每一次重开余页（时间循环 +1）：-8      ← 反复推演是有代价的
##      * 余页之内每流逝 1 秒：-0.05（累积满 1 点才扣）
##      * 结案：+25（上限 max_value）
##      * 归零【不是死亡】：主角被"从录上划掉一笔"，永久丢失一条线索的记忆，
##        并广播 signal heart_lamp_extinguished(lost_clue_id)。
##      * 熄灯期间每一遍重开还要再划掉一笔（2026-10 验收员问题 9）：故意烧灯不再是纯赚。
##  详细契约见 docs/story/09_系统映射与数据规格.md §5。
##
##  与核心层的关系（重要）：
##    scripts/core/** 是冻结的，本组件【只订阅信号、只调用公开 API】，一行都不改核心：
##      * 重开一遍的 -8 由 TimeLoopManager.loop_started(loop_index>0) 驱动，
##        也可以由引导层直接调 reset_for_new_loop()；
##      * PersistentMemoryManager 没有"删除单条线索"的公开接口，
##        所以"遗忘"落在这两件事上：
##          1) 用公开的 get_save_data()/apply_save_data() 做一次存档往返，把线索移出记忆；
##          2) scripts/data/clue_store.gd 的"已遗忘"黑名单 —— 落盘、跨启动保留，
##             并且 load_clues() 不会再把它交还给记忆（可用于推理的线索数真的 -1）。
##    【遗忘能不能找回来，看心灯还亮不亮】（2026-10 验收员问题 8）：
##      * 心灯熄着（is_extinguished()）时：add_clue() 对黑名单里的 id 一律返回 false，
##        并且绝不解除遗忘 —— "心灯已熄，这段记忆找不回来了"；
##      * 心灯被重新点亮（restore() / resolve_case() / set_value() 让它 > 0）【之后】，
##        重新查获同一条线索才会解除遗忘（"记忆可以被重新找回"只在点亮之后成立）。
##
##  心灯数值也落盘（2026-10 验收员问题 7）：存在同一份 user://clue_store.json 的
##  "lamp_value" 键下，_value 每一次变化都写一次，restore_from_store() 连数值一起恢复。
##  否则"遗忘已经真的落盘、数值却在重启后白回 100"，玩家退出重进就能白嫖记忆。
##  _store_enabled = false 可以让本组件完全不写磁盘（测试用，见 set_store_enabled()）。
##
##  挂载方式：挂在游戏引导场景（阶段二为 GameBootstrap）下，再把 memory 注入进来：
##      var lamp = preload("res://scripts/entities/heart_lamp.gd").new()
##      lamp.set_memory_manager(PersistentMemoryManager)
##      add_child(lamp)
##
##  不写 class_name（依赖编辑器类缓存，刚 clone 时不可用），一律 preload()。
## ============================================================================


# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------

## 心灯数值变化（每一点变化都广播一次，UI 只订阅这一个信号）。
signal heart_lamp_changed(value: int, max_value: int)

## 心灯归零：不是死亡，而是永久丢失一条线索的记忆。
## lost_clue_id = 被划掉的那条线索；记忆里已经没有任何线索时为空字符串。
signal heart_lamp_extinguished(lost_clue_id: String)


# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

const ClueStore = preload("res://scripts/data/clue_store.gd")

## 心灯上限（设计文档固定值）。
const DEFAULT_MAX_VALUE: int = 100
## 每重开一遍余页的消耗。
## M2 平衡结论（2026-10）：**保持 8 不动**——`docs/story/04:1056` 的跨案心灯预算表就是按它算的
## （案一 9 遍 8 次重开 -64、案二 7 遍 6 次重开 -48、卷一合计 -112 + 结案 25 ⇒ 收卷余 ~13 的"卷末低谷"）。
## 真正需要下调的是"余页内每秒"的消耗，见下。
const DRAIN_PER_LOOP_RESET: int = 8
## 余页之内每秒的消耗（浮点，累积成整数点才扣）。
## M2 平衡调整（2026-10）：0.05 → 0.02。旧值下"正常玩"（每遍待 120 秒）9 遍要额外扣 -54，
## 叠上重开的 -64 就是 -118 ⇒ 必然熄灯、`require_min_loop: 8` 的案子永远结不了（设计上不成立）。
## 0.02 下每秒开销 ≈ -1.7/遍，跨案预算 -87 与"余 13"的低谷设计原样保留，而"每遍跑满 360 秒"仍会熄灯。
const DRAIN_PER_SECOND: float = 0.02
## 结案恢复量。
const RESTORE_PER_CASE_RESOLVED: int = 25
## 现实时间恢复速率：余页之外每过 1 分钟回 1 点（docs/story/09:175「现实时间（余页之外）按分钟 +1」）。
const RECOVER_PER_REAL_MINUTE: int = 1

## TimeLoopManager 的 Autoload 路径（找不到就静默跳过，方便无头测试）。
const LOOP_MANAGER_PATH: String = "/root/TimeLoopManager"


# ---------------------------------------------------------------------------
# 配置与内部状态
# ---------------------------------------------------------------------------

## 是否在 _ready() 时自动订阅 TimeLoopManager.loop_started。
var auto_subscribe: bool = true

var _max_value: int = DEFAULT_MAX_VALUE
var _value: int = DEFAULT_MAX_VALUE

## 当前心灯是否已熄（value == 0）。归零不是死亡：restore()/resolve_case() 后重新点亮。
var _extinguished: bool = false
## 被"从录上划掉"的总笔数（剧情/统计用）。
var _extinguish_count: int = 0

## tick() 的浮点累积器：0.05/秒 攒够 1.0 才真的扣 1 点。
var _drain_accum: float = 0.0

## 是否身处余页之内（余页之外不流逝心灯）。
var _in_loop: bool = true

## 注入的记忆管理器（PersistentMemoryManager 或任何实现了同名公开 API 的节点）。
var _memory: Node = null

## 是否把"心灯数值 + 线索"落盘（问题 7）。默认 true；
## 关掉之后本组件不写盘，add_clue() 的"落盘成功"要求也随之取消（只要求线索进了记忆）。
var _store_enabled: bool = true

## 开档时从存档里读到的"上次活跃时间戳"（Unix 秒）。它是离线恢复的起点：
## 必须在任何 set_value()/restore() 落盘【之前】抓住，否则时间戳会被刷成"现在"，离线时长就永远是 0。
var _offline_seen_unix: int = 0
## 上一次 apply_offline_recovery() 实际补回来的点数（表现层拿去写一句"离线恢复"）。
var _last_offline_recovery: int = 0


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

func _ready() -> void:
	_value = clampi(_value, 0, _max_value)
	if auto_subscribe:
		_subscribe_time_loop_manager()


# ---------------------------------------------------------------------------
# 公开 API —— 注入
# ---------------------------------------------------------------------------

## 注入记忆管理器（由 PersistentMemoryManager 决定"移除哪一条线索"）。
func set_memory_manager(memory: Node) -> void:
	_memory = memory


func get_memory_manager() -> Node:
	return _memory


## 打开/关闭落盘（默认开）。关掉后本组件不写磁盘：加线索只要求"进了记忆"，
## 心灯数值也不再落盘（问题 7 的开关，测试可以借此完全不污染 user:// 存档）。
func set_store_enabled(enabled: bool) -> void:
	_store_enabled = enabled


func is_store_enabled() -> bool:
	return _store_enabled


# ---------------------------------------------------------------------------
# 公开 API —— 只读查询
# ---------------------------------------------------------------------------

func get_value() -> int:
	return _value


func get_max_value() -> int:
	return _max_value


## 此刻心灯是否已熄（value == 0）。注意：这不是死亡标记，恢复后会自动变回 false。
func is_extinguished() -> bool:
	return _extinguished


## 被心灯烧掉过多少条线索的记忆（= 归零次数）。
func get_extinguish_count() -> int:
	return _extinguish_count


func is_in_loop() -> bool:
	return _in_loop


## 目前"还能用于推理"的线索（记忆里的线索减去被遗忘的黑名单）。
func get_available_clues() -> Array[String]:
	var available: Array[String] = []
	for clue_id in _memory_clues():
		if not ClueStore.is_forgotten(clue_id):
			available.append(clue_id)
	return available


## 已经被心灯烧掉、不可再用于推理的线索（UI 上画成灰色）。
func get_forgotten_clues() -> Array[String]:
	return ClueStore.load_forgotten()


# ---------------------------------------------------------------------------
# 公开 API —— 心灯数值
# ---------------------------------------------------------------------------

## 设置上限（默认 100）。当前值会被同步钳制。
func set_max_value(value: int) -> void:
	_max_value = maxi(1, value)
	if _value > _max_value:
		_value = _max_value
		_persist_value()
		heart_lamp_changed.emit(_value, _max_value)


## 直接设置心灯数值（钳制到 [0, max]）。降到 0 会触发归零流程。
## 主要给测试与调试用；正式流程请走 reset_for_new_loop()/tick()/resolve_case()。
##
## allow_extinguish = false 是给 restore_from_store() 用的【只摆状态、不再吃记忆】模式：
## 上次退出时心灯已经熄了的话，那次熄灯早就吃掉过一条记忆并落盘了，
## 重启时再触发一次归零流程会让玩家每重启一次就白丢一条线索。
func set_value(value: int, allow_extinguish: bool = true) -> void:
	var clamped: int = clampi(value, 0, _max_value)
	if clamped == _value:
		return
	_value = clamped
	_drain_accum = 0.0
	_persist_value()
	if _value <= 0:
		if allow_extinguish:
			_trigger_extinguish()
		else:
			_extinguished = true
			heart_lamp_changed.emit(_value, _max_value)
	else:
		_extinguished = false
		heart_lamp_changed.emit(_value, _max_value)


## 进入余页（心灯开始随时间流逝）。
func set_in_loop(value: bool) -> void:
	_in_loop = value


## ★ 重开一遍余页：扣 DRAIN_PER_LOOP_RESET（8）点。
## 如果这一遍【开始之前】心灯就已经熄着（value <= 0），还要额外再划掉一笔记忆
## （问题 9：故意烧灯不再是纯赚）。本次重开才把灯烧灭的不算"熄灯期间"，不额外扣。
func reset_for_new_loop() -> void:
	var was_extinguished: bool = _extinguished
	drain(DRAIN_PER_LOOP_RESET)
	if was_extinguished:
		_burn_extra_clue()


## 余页之内推进时间：每流逝 1 秒扣 DRAIN_PER_SECOND（0.05）点。
func tick(delta: float) -> void:
	if not _in_loop or delta <= 0.0 or _value <= 0:
		return
	_drain_accum += delta * DRAIN_PER_SECOND
	if _drain_accum < 1.0:
		return
	var steps: int = int(floor(_drain_accum))
	_drain_accum -= float(steps)
	_apply_drain(steps)


## 扣点心灯（不会低于 0；降到 0 会触发归零流程）。
func drain(amount: int) -> void:
	_apply_drain(amount)


## 恢复心灯（不会超过上限；恢复即重新点亮）。
## 点亮之后，被划掉的线索重新查获时才允许解除遗忘（见 add_clue()）。
func restore(amount: int) -> void:
	if amount <= 0:
		return
	var new_value: int = mini(_max_value, _value + amount)
	if new_value == _value:
		return
	_value = new_value
	_extinguished = false
	_persist_value()
	heart_lamp_changed.emit(_value, _max_value)


## ★ 结案：恢复 RESTORE_PER_CASE_RESOLVED（25）点，上限为 max_value。
func resolve_case() -> void:
	restore(RESTORE_PER_CASE_RESOLVED)


# ---------------------------------------------------------------------------
# 公开 API —— 线索（带持久化）
# ---------------------------------------------------------------------------

## 取得一条线索：写入记忆 → 落盘。
##
## 返回值语义（2026-10 验收员问题 7 / 10 收紧）：
##   true  = 这条线索确实进了记忆【并且】成功落盘（set_store_enabled(false) 时只看前半条）；
##   false = 参数非法 / 幂等重复 / 心灯已熄而被黑名单拒绝 / 落盘失败。
## 调用方 scripts/ui/slice_hud.gd 拿到 false 会提示玩家"可以再来看一次"，
## 所以这里绝不能"落盘失败还报 true"—— 否则玩家以为记下了，重启就没了。
##
## 解除遗忘的条件（问题 8）：只有心灯【已经重新点亮】时，重新查获黑名单里的 id
## 才允许 unmark_forgotten()；心灯熄着的时候这段记忆是找不回来的。
func add_clue(clue_id: String, source_loop: int = -1) -> bool:
	if clue_id.is_empty():
		push_warning("[HeartLamp] add_clue() 收到空 clue_id，已忽略。")
		return false

	# 熄灯期间遗忘是永久的：直接拒绝，绝不 unmark_forgotten。
	var blacklisted: bool = ClueStore.is_forgotten(clue_id)
	if blacklisted and _extinguished:
		push_warning("[HeartLamp] 心灯已熄，这段记忆找不回来了：%s" % clue_id)
		return false

	var writable: bool = _has_memory_method("add_clue")
	var added: bool = false
	if writable:
		var result: Variant = _memory_call("add_clue", [clue_id, source_loop])
		added = typeof(result) == TYPE_BOOL and bool(result)
	else:
		# 没有注入记忆管理器（工具脚本、单机调试）：只以落盘为准。
		added = true

	# 无论记忆管理器在不在，线索本身都要落盘（线索 = 记忆，绝不能只活在内存里）。
	var persisted: bool = true
	if _store_enabled:
		persisted = ClueStore.save([clue_id])

	# 到这里 blacklisted 为真只可能是"心灯已经重新点亮"（熄灯那支上面就返回了）。
	if not (added or blacklisted):
		# 幂等重复：记忆里本来就有，这不是"这次记下了"，也不该动黑名单。
		return false
	if not persisted:
		push_error("[HeartLamp] 线索 %s 落盘失败：重启后会丢，本次按失败返回（调用方可以重新查获）。" % clue_id)
		return false
	if blacklisted:
		# 重新点亮【之后】重新查获 → 记忆被找回来。
		if not ClueStore.unmark_forgotten(clue_id):
			push_warning("[HeartLamp] 线索 %s 已重新记起，但解除遗忘记录失败：UI 可能仍把它画成灰色。" % clue_id)
	return true


## 把存档里的线索重新灌进记忆（引导层在开档时调用），返回实际恢复的条数。
## 心灯数值也在这一步恢复（问题 7），而且是"只摆状态、不再吃记忆"：
## 上次退出时已经熄灯的话，那次熄灯早就吃过一条并落盘了，重启不该再吃一条。
func restore_from_store(source_loop: int = -1) -> int:
	# 顺序很重要：先抓住"上次活跃时间戳"，再恢复数值 —— set_value() 会立刻落盘并把时间戳刷成"现在"，
	# 抓晚了离线时长就永远是 0（apply_offline_recovery() 见下）。
	var state: Dictionary = ClueStore.load_lamp_state()
	_offline_seen_unix = _as_int(state.get("seen_unix", 0), 0)
	set_value(_as_int(state.get("value", DEFAULT_MAX_VALUE), DEFAULT_MAX_VALUE), false)

	var stored: Array[String] = ClueStore.load_clues()
	var restored: int = 0
	for clue_id in stored:
		var result: Variant = _memory_call("add_clue", [clue_id, source_loop])
		if typeof(result) == TYPE_BOOL and bool(result):
			restored += 1
	return restored


## ★ 现实时间恢复（docs/story/09:175）：离开游戏（余页之外）每过 1 分钟回 RECOVER_PER_REAL_MINUTE 点。
##
## 为什么必须有这一条：余页之内每遍固定烧 8 + 秒数×0.05 点，案一要走到第 8 遍才允许结案
## ⇒ 需要 8×26 = 208 点 > 满值 100；而熄灯之后唯一重新点亮的途径是结案 ⇒ 不打这个补丁案一在数值上
## 根本通不了关。恢复会走 restore() 的语义（封顶 max_value、自动重新点亮、立刻按新时间戳落盘）。
##
## now_unix <= 0 时取系统时间；seen_unix <= 0（从没存过）或时间倒流时返回 0 且不改数值。
## 返回值 = 本次实际补回来的点数；同一进程里连续调用只会补一次（时间戳已被刷新）。
func apply_offline_recovery(now_unix: int = -1) -> int:
	_last_offline_recovery = 0
	if not _store_enabled:
		return 0

	var now: int = now_unix if now_unix > 0 else int(Time.get_unix_time_from_system())
	# 起点优先用开档时抓住的那个（restore_from_store() 里读到的），否则现场读盘。
	var seen: int = _offline_seen_unix
	if seen <= 0:
		seen = _as_int(ClueStore.load_lamp_state().get("seen_unix", 0), 0)
	_offline_seen_unix = 0
	if seen <= 0 or now <= seen:
		return 0

	var minutes: int = int((now - seen) / 60)
	var points: int = minutes * RECOVER_PER_REAL_MINUTE
	if points <= 0:
		return 0

	var before: int = _value
	restore(points)                    # 内部会 _persist_value()（写新的 seen_unix = now）并广播信号
	_last_offline_recovery = _value - before
	return _last_offline_recovery


## 上一次 apply_offline_recovery() 实际补回来的点数（0 = 没补、或补了但灯已经满）。
func get_last_offline_recovery() -> int:
	return _last_offline_recovery


# ---------------------------------------------------------------------------
# 内部实现 —— 数值
# ---------------------------------------------------------------------------

func _apply_drain(amount: int) -> void:
	if amount <= 0:
		return
	var new_value: int = maxi(0, _value - amount)
	if new_value == _value:
		return
	_value = new_value
	# 每一次真实扣点都落盘（tick 里浮点攒满 1 点的那一瞬也走这里）。
	_persist_value()
	if _value <= 0:
		_trigger_extinguish()
	else:
		heart_lamp_changed.emit(_value, _max_value)


## 把当前心灯数值落盘（问题 7：数值从不落盘 → 退出重进白回 100）。
## set_store_enabled(false) 之后只在内存里走，返回 true（"没打算写盘"不等于"写失败"）。
func _persist_value() -> bool:
	if not _store_enabled:
		return true
	# 数值与时间戳一起写：时间戳是"离线多久"的唯一依据（apply_offline_recovery()）。
	return ClueStore.save_lamp_state(_value, int(Time.get_unix_time_from_system()))


## 归零：熄灯 + 永久丢失一条线索的记忆 + 广播信号。重复归零（已经是 0）会被忽略。
func _trigger_extinguish() -> void:
	if _extinguished:
		return
	_extinguished = true
	_extinguish_count += 1
	var lost_clue_id: String = _forget_one_clue()
	heart_lamp_changed.emit(_value, _max_value)
	heart_lamp_extinguished.emit(lost_clue_id)


## 熄灯期间每重开一遍，额外划掉一笔（问题 9：故意烧灯不再是纯赚）。
## 还有可失的线索才广播 heart_lamp_extinguished；已经没得可失时只 push_warning，不报错。
func _burn_extra_clue() -> void:
	var lost_clue_id: String = _forget_one_clue("心灯已熄，本遍重开还得再划一笔")
	if lost_clue_id.is_empty():
		return
	heart_lamp_extinguished.emit(lost_clue_id)


## 永久丢失一条线索：优先丢"最后一次获得的线索"。返回被丢掉的 clue_id。
func _forget_one_clue(reason: String = "心灯归零") -> String:
	var lost_clue_id: String = _pick_lost_clue()
	if lost_clue_id.is_empty():
		push_warning("[HeartLamp] %s，但记忆里已无线索可失：本次只熄灯，不划掉任何一笔。" % reason)
		return ""

	# 1) 黑名单：这是"遗忘"唯一能跨启动保留的记录（核心层没有删除接口，不许改核心）。
	ClueStore.mark_forgotten(lost_clue_id)
	# 2) 从记忆里移除（只用 PersistentMemoryManager 的公开存档往返 API）。
	_remove_clue_from_memory(lost_clue_id)
	return lost_clue_id


## 选一条要划掉的线索：记忆里"最后一次获得"的那条（order 最大，退化时取列表末位）。
func _pick_lost_clue() -> String:
	var available: Array[String] = get_available_clues()
	if available.is_empty():
		return ""

	var last_clue_id: String = available[available.size() - 1]
	var best_order: int = -1
	for clue_id in available:
		var order: int = _clue_order(clue_id)
		if order >= best_order:
			best_order = order
			last_clue_id = clue_id
	return last_clue_id


## 查某条线索的解锁序号（PersistentMemoryManager.get_clue_record()["order"]）。
func _clue_order(clue_id: String) -> int:
	var record: Variant = _memory_call("get_clue_record", [clue_id])
	if typeof(record) != TYPE_DICTIONARY:
		return -1
	var record_dict: Dictionary = record
	if not record_dict.has("order"):
		return -1
	return int(record_dict["order"])


## 用公开的 get_save_data()/apply_save_data() 往返一次，把线索从记忆里摘掉。
func _remove_clue_from_memory(clue_id: String) -> bool:
	var data: Variant = _memory_call("get_save_data")
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var save_data: Dictionary = data

	var raw_clues: Variant = save_data.get("clues")
	if typeof(raw_clues) != TYPE_ARRAY:
		return false
	var clues: Array = raw_clues
	if not clues.has(clue_id):
		return false
	clues.erase(clue_id)

	var raw_records: Variant = save_data.get("records")
	if typeof(raw_records) == TYPE_DICTIONARY:
		var records: Dictionary = raw_records
		records.erase(clue_id)

	var applied: Variant = _memory_call("apply_save_data", [save_data])
	return typeof(applied) == TYPE_BOOL and bool(applied)


# ---------------------------------------------------------------------------
# 内部实现 —— 记忆管理器 / 时间循环
# ---------------------------------------------------------------------------

## 记忆里的线索快照（管理器不存在时返回空数组）。
func _memory_clues() -> Array[String]:
	var clues: Array[String] = []
	var raw: Variant = _memory_call("get_clues")
	if typeof(raw) != TYPE_ARRAY:
		return clues
	var list: Array = raw
	for clue_id in list:
		if typeof(clue_id) == TYPE_STRING and not clues.has(clue_id):
			clues.append(clue_id)
	return clues


## 通过方法名动态调用注入的记忆管理器（Node 类型上做静态调用会编译不过，这里统一走 callv）。
func _memory_call(method: String, args: Array = []) -> Variant:
	if not _has_memory_method(method):
		return null
	return _memory.callv(method, args)


## 把存档里读出来的数字安全转成 int（JSON.parse 把 0 与 25 都读成 float）。
func _as_int(value: Variant, fallback: int) -> int:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return int(value)
	return fallback


## 注入的记忆管理器是否可用、是否实现了某个公开 API。
func _has_memory_method(method: String) -> bool:
	if _memory == null or not is_instance_valid(_memory):
		return false
	return _memory.has_method(method)


## 订阅 TimeLoopManager.loop_started：loop_index > 0 的每一遍重开都扣 8 点。
func _subscribe_time_loop_manager() -> void:
	var loop: Node = get_node_or_null(LOOP_MANAGER_PATH)
	if loop == null:
		return
	if not loop.has_signal("loop_started"):
		return
	if loop.is_connected("loop_started", _on_loop_started):
		return
	loop.connect("loop_started", _on_loop_started)


func _on_loop_started(loop_index: int) -> void:
	if loop_index > 0:
		reset_for_new_loop()
