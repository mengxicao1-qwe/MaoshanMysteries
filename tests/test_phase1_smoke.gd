extends SceneTree
## ============================================================================
##  test_phase1_smoke.gd —— 阶段一冒烟测试（不需要打开编辑器）
## ----------------------------------------------------------------------------
##  运行方式（在项目根目录执行）：
##      godot --headless --path . --script res://tests/test_phase1_smoke.gd
##
##  退出码：0 = 全部通过；1 = 存在失败项（可直接接入 CI）。
##  首次运行若提示找不到全局类名，先执行一次 `godot --headless --path . --import`。
##
##  覆盖范围：
##    1. JSON 数据表能否解析成结构化数据（含非法输入的错误处理）；
##    2. 时间循环：启动 / 倒计时 / 流速缩放 / 强制重置 / 自然超时 / 暂停；
##    3. 记忆管理器：解锁、去重、只读快照、存档数据往返；
##    4. ★ 核心验收点：循环重置（含多次重置）之后线索依然保留；
##    5. 重置流程的重入保护。
##
##  说明：这里直接 load() 脚本并 new() 出实例来测试，不依赖 Autoload，
##        因此可以确定性地手动推进时间，也不会受项目设置影响。
## ============================================================================

const TIME_LOOP_SCRIPT: String = "res://scripts/core/time_loop_manager.gd"
const MEMORY_SCRIPT: String = "res://scripts/core/persistent_memory_manager.gd"

## 用 preload 拿到解析器，而不是直接用它的全局类名 NPCTimelineParser：
## 全局类名依赖编辑器导入时生成的 .godot/global_script_class_cache.cfg，
## 而本测试要能在"刚 clone 下来、还没打开过编辑器"的环境里直接跑通（CI 友好）。
const TimelineParser = preload("res://scripts/data/npc_timeline_parser.gd")

## 本文件里 _check() 的调用点总数（新增断言时请同步更新）。
## 用于防止"测试中途因运行时错误中断，却因为没人断言失败而报绿"的假通过：
## GDScript 的运行时错误不会让退出码变红，只能靠执行数量来兜底。
const EXPECTED_CHECKS: int = 84

var _passed: int = 0
var _failed: int = 0

## 测试过程中 new() 出来的 Node 实例，结束时统一 free()，避免退出时泄漏告警。
var _instances: Array = []

# 供信号回调探针使用的测试状态（GDScript 的 lambda 按值捕获局部变量，
# 所以"需要被回调写回"的状态一律放在成员变量里）。
var _probe_manager = null
var _probe: Dictionary = {}
var _reentry_depth: int = 0


func _initialize() -> void:
	print("==========================================================")
	print(" 《茅山秘录·诡异录》阶段一冒烟测试（Headless）")
	print("==========================================================")
	_test_timeline_parser()
	_test_time_loop_manager()
	_test_persistent_memory()
	_test_cross_loop_persistence()
	_test_reset_reentrancy_guard()

	var executed: int = _passed + _failed
	if executed < EXPECTED_CHECKS:
		_failed += 1
		printerr("  [FAIL] 只执行了 %d 项断言，少于预期的 %d 项 —— 测试很可能在中途被运行时错误中断了！"
			% [executed, EXPECTED_CHECKS])

	print("----------------------------------------------------------")
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_passed, _failed, executed])
	_cleanup()
	quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# 1. 数据层
# ---------------------------------------------------------------------------

func _test_timeline_parser() -> void:
	print("[1] scripts/data/npc_timeline_parser.gd")

	var result = TimelineParser.load_from_file()
	_check(result != null, "解析器返回了结果对象")
	if result == null:
		return

	_check(result.ok, "data/npc_timelines.json 解析成功（errors: %s）" % result.error_summary())
	_check(result.errors.is_empty() and result.warnings.is_empty(),
		"数据表没有错误也没有警告（warnings: %s）" % result.warning_summary())
	_check(result.loop_duration_seconds == 420, "meta.loop_duration_seconds 解析为 420")
	_check(result.npc_count() == 2, "解析出 2 名 NPC，实际 %d" % result.npc_count())
	_check(result.npcs.has("npc_01_butler") and result.npcs.has("npc_02_lady"),
		"包含 npc_01_butler 与 npc_02_lady")

	var butler = result.get_schedule("npc_01_butler")
	_check(butler != null, "能按 ID 取到执事的动线")
	if butler == null:
		return
	_check(butler.nodes.size() == 3, "执事有 3 个时间节点，实际 %d" % butler.nodes.size())
	_check(butler.room_at(0) == "kitchen", "第 0 秒：执事在厨房（kitchen）")
	_check(butler.room_at(24) == "kitchen", "第 24 秒：仍沿用第 0 秒的状态")
	_check(butler.room_at(25) == "hall", "第 25 秒：执事移动到门厅（hall）")
	_check(butler.room_at(50) == "dining_room", "第 50 秒：执事在宴会厅（dining_room）")

	var node = butler.node_at(30)
	_check(node != null and node.second == 25, "node_at(30) 命中第 25 秒的节点")
	_check(node != null and node.action == "greet_guests", "第 25 秒的行为是 greet_guests")
	_check(butler.node_index_at(59) == 2, "node_index_at(59) == 2（最后一个节点）")
	_check(butler.nodes[2].clue_id == "clue_butler_counts_chairs",
		"第 50 秒节点带出了 clue_id 字段")

	var lady = result.get_schedule("npc_02_lady")
	_check(lady != null and lady.nodes.size() == 3, "夫人有 3 个时间节点")
	_check(lady.room_at(55) == "library", "第 55 秒：夫人在书房（library）")
	_check(lady.last_second() == 55, "夫人动线的最后一个节点在第 55 秒")
	_check(lady.nodes[0].second < 60 and lady.nodes[2].second < 60, "示例数据全部落在前 60 秒内")

	# --- 非法输入的错误处理（★ 必须返回 ParseResult，绝不能返回 null）---
	var broken = TimelineParser.parse_text("{ 这不是 JSON ", "unit_test")
	_check(broken != null and not broken.ok,
		"JSON 语法错误：返回结果对象且判定为失败（不是 null）")
	_check(broken != null and not broken.errors.is_empty(),
		"JSON 语法错误被写进 errors：%s" % (broken.error_summary() if broken != null else "<null>"))

	var wrong_root = TimelineParser.parse_text("[1, 2, 3]", "unit_test")
	_check(not wrong_root.ok, "根节点不是对象时判定为失败")

	var no_npcs = TimelineParser.parse_dictionary({"meta": {}}, "unit_test")
	_check(not no_npcs.ok, "缺少 npcs 数组时判定为失败")

	var out_of_range = TimelineParser.parse_dictionary({
		"meta": {"loop_duration_seconds": 420, "rooms": ["hall"]},
		"npcs": [{"npc_id": "x", "timeline": [{"second": 500, "room": "hall"}]}],
	}, "unit_test")
	_check(not out_of_range.ok, "second 超出循环时长时判定为失败")

	var unordered = TimelineParser.parse_dictionary({
		"meta": {"loop_duration_seconds": 420, "rooms": ["hall", "kitchen"]},
		"npcs": [{"npc_id": "x", "timeline": [
			{"second": 40, "room": "kitchen"},
			{"second": 0, "room": "hall"},
		]}],
	}, "unit_test")
	_check(unordered.ok and not unordered.warnings.is_empty(),
		"节点顺序写错时仍可用，但必须给出警告")
	_check(unordered.get_schedule("x").nodes[0].second == 0, "乱序节点已在内存中重新排序")

	var missing_file = TimelineParser.load_from_file("res://data/__no_such_file__.json")
	_check(missing_file != null and not missing_file.ok, "文件不存在时判定为失败")


# ---------------------------------------------------------------------------
# 2. 时间循环
# ---------------------------------------------------------------------------

func _test_time_loop_manager() -> void:
	print("[2] scripts/core/time_loop_manager.gd")

	var manager = _new_time_loop_manager()
	var events: Array[String] = []
	_probe_manager = manager
	_probe = {"remaining_at_reset": -1, "running_at_reset": true}

	manager.time_updated.connect(func(second: int) -> void: events.append("t%d" % second))
	manager.loop_started.connect(func(index: int) -> void: events.append("start%d" % index))
	manager.loop_timeout.connect(func() -> void: events.append("timeout"))
	manager.loop_reset.connect(func() -> void: events.append("reset"))
	manager.loop_reset.connect(_on_probe_loop_reset)

	_check(manager.loop_duration == 420.0, "默认循环长度为 420 秒（7 分钟）")
	_check(manager.get_loop_duration() == 420.0, "get_loop_duration() 与 loop_duration 一致")
	_check(not manager.is_running(), "auto_start=false 时不会自动开始")
	manager.tick(10.0)
	_check(manager.get_remaining_seconds() == 420, "未开始前 tick() 不会消耗时间")

	manager.start_loop()
	_check(manager.is_running(), "start_loop() 后进入运行状态")
	_check(manager.get_loop_index() == 0, "首轮循环编号为 0")
	_check(manager.get_remaining_seconds() == 420, "开始瞬间剩余 420 秒")
	_check(events.size() == 2 and events[0] == "start0" and events[1] == "t420",
		"启动时依次广播 loop_started(0) 与 time_updated(420)，实际 %s" % str(events))

	manager.tick(1.0)
	_check(manager.get_remaining_seconds() == 419, "tick(1.0) 后剩余 419 秒")
	_check(manager.get_elapsed_seconds() == 1, "已流逝 1 秒（NPC 动线按它索引）")

	manager.set_time_scale(10.0)
	_check(manager.get_time_scale() == 10.0, "get_time_scale() 读回流速倍率")
	manager.tick(1.0)
	_check(manager.get_remaining_seconds() == 409, "10 倍速下 tick(1.0) 消耗 10 秒")
	manager.set_time_scale(9999.0)
	_check(manager.get_time_scale() == 200.0, "流速倍率被钳制在上限 200")

	# --- 强制重置 ---
	events.clear()
	manager.trigger_loop_reset()
	_check(events.count("reset") == 1, "trigger_loop_reset() 广播一次 loop_reset")
	_check(events.count("timeout") == 0, "强制重置不应广播 loop_timeout")
	_check(_probe["remaining_at_reset"] == 0,
		"loop_reset 触发时时钟已清零（订阅者可在此时安全清理上一轮世界）")
	_check(_probe["running_at_reset"] == false, "loop_reset 触发时倒计时已停止")
	_check(manager.get_loop_index() == 1, "重置后进入第 1 轮")
	_check(manager.get_remaining_seconds() == 420, "重置后剩余时间回到 420 秒")
	_check(manager.is_running(), "重置后自动开始新一轮")

	# --- 自然超时 ---
	manager.set_time_scale(1.0)
	events.clear()
	manager.tick(420.0)
	_check(events.count("timeout") == 1, "时间耗尽时广播一次 loop_timeout")
	_check(events.count("reset") == 1, "时间耗尽同样广播 loop_reset")
	_check(manager.get_loop_index() == 2, "超时后进入第 2 轮")
	_check(manager.get_remaining_seconds() == 420, "超时后剩余时间回到 420 秒")

	# --- 暂停 ---
	manager.pause_loop()
	manager.tick(30.0)
	_check(manager.get_remaining_seconds() == 420, "暂停期间时间不流逝")
	manager.resume_loop()
	manager.tick(2.0)
	_check(manager.get_remaining_seconds() == 418, "恢复后时间继续流逝")
	_check(manager.get_progress_ratio() > 0.0 and manager.get_progress_ratio() < 1.0,
		"进度比例在 (0, 1) 区间内")

	# --- 高倍速下逐秒补发 ---
	var fast = _new_time_loop_manager()
	var ticks: Array[int] = []
	fast.time_updated.connect(func(second: int) -> void: ticks.append(second))
	fast.start_loop()
	fast.tick(5.0)
	_check(ticks.size() == 6, "start 时 1 次 + tick(5 秒) 补发 5 次，共 6 次（不漏拍），实际 %d 次" % ticks.size())
	_check(ticks[-1] == 415, "最后一次补发的剩余秒数为 415，实际 %d" % ticks[-1])


# ---------------------------------------------------------------------------
# 3. 跨循环记忆
# ---------------------------------------------------------------------------

func _test_persistent_memory() -> void:
	print("[3] scripts/core/persistent_memory_manager.gd")

	var memory = _new_memory_manager()
	var added_events: Array[String] = []
	memory.clue_added.connect(func(clue_id: String, source_loop: int) -> void: added_events.append(clue_id))

	_check(memory.get_clue_count() == 0, "初始没有任何线索")
	_check(memory.add_clue("clue_a", 0) == true, "add_clue() 首次解锁返回 true")
	_check(memory.add_clue("clue_a", 0) == false, "重复 add_clue() 返回 false（幂等）")
	_check(memory.add_clue("") == false, "空 clue_id 被拒绝")
	_check(memory.has_clue("clue_a"), "has_clue('clue_a') 为真")
	_check(not memory.has_clue("clue_b"), "未解锁的线索返回 false")
	_check(memory.get_clue_count() == 1, "线索数量为 1")
	_check(added_events.size() == 1, "clue_added 只在首次解锁时广播一次")

	_check(memory.has_all_clues(["clue_a"]), "has_all_clues 对已集齐的集合返回 true")
	_check(not memory.has_all_clues(["clue_a", "clue_b"]), "has_all_clues 对缺项的集合返回 false")
	_check(memory.add_clues(["clue_b", "clue_c", "clue_b"]) == 2, "批量解锁返回新增数量（自动去重）")
	_check(memory.get_clue_count() == 3, "批量解锁后共 3 条线索")

	var record: Dictionary = memory.get_clue_record("clue_a")
	_check(record.get("source_loop", -99) == 0, "线索元数据记录了来源循环编号")
	_check(memory.get_clue_record("clue_zzz").is_empty(), "查询不存在的线索返回空字典")

	var snapshot: Array[String] = memory.get_clues()
	if snapshot.size() > 0:
		snapshot[0] = "被外部篡改"
	_check(memory.has_clue("clue_a"), "get_clues() 返回副本，外部修改不影响内部数据")

	var saved: Dictionary = memory.get_save_data()
	var restored = _new_memory_manager()
	_check(restored.apply_save_data(saved), "存档数据可被恢复到新实例")
	_check(restored.get_clue_count() == 3 and restored.has_clue("clue_c"), "恢复后的线索内容一致")
	_check(not restored.apply_save_data({}), "非法存档数据被拒绝且返回 false")


# ---------------------------------------------------------------------------
# 4. ★ 核心验收点：循环重置不清空线索
# ---------------------------------------------------------------------------

func _test_cross_loop_persistence() -> void:
	print("[4] 跨循环保留（本阶段核心验收点）")

	var memory = _new_memory_manager()
	var manager = _new_time_loop_manager()
	manager.start_loop()

	memory.add_clue("clue_letter_under_plate", 0)
	manager.tick(60.0)
	_check(memory.has_clue("clue_letter_under_plate"), "第 0 轮解锁的线索已记录")

	# 连续重置 3 次（其中一次靠自然超时触发）
	manager.trigger_loop_reset()
	manager.trigger_loop_reset()
	manager.tick(420.0)
	_check(manager.get_loop_index() == 3, "累计进入第 3 轮循环，实际 %d" % manager.get_loop_index())
	_check(memory.has_clue("clue_letter_under_plate"), "★ 三次循环重置后线索依然保留")
	_check(memory.get_clue_count() == 1, "线索数量不受重置影响")
	_check(memory.get_clue_record("clue_letter_under_plate").get("source_loop", -99) == 0,
		"线索仍然记得自己来自第 0 轮")

	# 顺便验证：时间循环管理器本身不持有、也不清空任何线索数据
	_check(not manager.has_method("clear_memory"), "核心时间系统没有清空记忆的接口（结构上杜绝误清空）")

	var memory2 = _new_memory_manager()
	memory2.add_clue("clue_keep_me")
	memory2.reset_for_new_game()
	_check(memory2.get_clue_count() == 0, "reset_for_new_game() 是唯一能清空数据的入口")


# ---------------------------------------------------------------------------
# 5. 重置重入保护
# ---------------------------------------------------------------------------

func _test_reset_reentrancy_guard() -> void:
	print("[5] 重置过程的重入保护")

	var manager = _new_time_loop_manager()
	_probe_manager = manager
	_reentry_depth = 0
	manager.loop_reset.connect(_on_reentrant_loop_reset)

	manager.start_loop()
	manager.trigger_loop_reset()
	_check(_reentry_depth == 1, "订阅者回调里再次触发重置会被忽略（未发生递归）")
	_check(manager.get_loop_index() == 1, "重入请求没有额外推进循环编号")


# ---------------------------------------------------------------------------
# 测试基础设施
# ---------------------------------------------------------------------------

func _new_time_loop_manager():
	var script = load(TIME_LOOP_SCRIPT)
	var instance = script.new()
	instance.auto_start = false  # 测试里手动 tick()，不要自动开跑
	instance.name = "TLM_UnderTest"
	_instances.append(instance)
	return instance


func _new_memory_manager():
	var script = load(MEMORY_SCRIPT)
	var instance = script.new()
	instance.name = "PMM_UnderTest"
	_instances.append(instance)
	return instance


## 释放测试期间创建的所有 Node，避免 Godot 退出时报 "ObjectDB instances were leaked"。
func _cleanup() -> void:
	for instance in _instances:
		if instance != null and is_instance_valid(instance):
			instance.free()
	_instances.clear()


## 记录 loop_reset 触发瞬间的时钟状态（验证"先清零、后广播"的契约）。
func _on_probe_loop_reset() -> void:
	_probe["remaining_at_reset"] = _probe_manager.get_remaining_seconds()
	_probe["running_at_reset"] = _probe_manager.is_running()


## 模拟"某个订阅者在重置回调里又触发了一次重置"。
func _on_reentrant_loop_reset() -> void:
	_reentry_depth += 1
	if _reentry_depth < 5:
		_probe_manager.trigger_loop_reset()


func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("  [PASS] %s" % label)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % label)
