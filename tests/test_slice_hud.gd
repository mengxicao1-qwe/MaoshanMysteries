extends SceneTree
## ============================================================================
##  test_slice_hud.gd —— M0 可玩纵切片的无头试玩
## ----------------------------------------------------------------------------
##  跑法：
##      godot --headless --path . --script res://tests/test_slice_hud.gd
##
##  它把"能玩"变成可验证的断言：真的实例化 scenes/main.tscn，用合成按键
##  （Input.parse_input_event）换房间、快进、暂停，用手动 tick 推进时钟，
##  然后检查玩法闭环的每一环都真的发生了：
##      装案件 → 蹲对房间拿到线索 → 线索落盘 → 重开一遍心灯 -8 且线索不丢
##      → 心灯归零永久遗忘一条（灯灭期间找不回来）→ 结案门槛（线索 + 最少遍数）
##      → 快进到下一处拍点 → 对话追问（F）→ 世界递进与 NPC 跨轮记忆
##      → 推演板与矛盾高亮（B）→ 卡关预警 → 一键重演上一遍路线（H）
##      → 画符结案（G）：三笔照回原文、错笔有交代、仪式做完案子才结
##
##  为什么必须"真跑场景"而不是只测脚本函数：
##      表现层引用了 Autoload（TimeLoopManager / PersistentMemoryManager），
##      而 `--check-only --script` 模式下 Autoload 没有注册，会误报
##      "Identifier not found"（实测踩过）。所以这类脚本只能靠真跑场景验证。
##
##  防假绿：GDScript 运行时报错不会改变退出码，因此末尾用 EXPECTED_CHECKS
##  守护"实际执行的断言数 < 期望值 ⇒ 直接判 FAIL"（同 test_case_loader.gd）。
## ============================================================================

const CaseLoader = preload("res://scripts/data/case_loader.gd")
const ClueStore = preload("res://scripts/data/clue_store.gd")
const UIPrefs = preload("res://scripts/data/ui_prefs.gd")
const HeartLamp = preload("res://scripts/entities/heart_lamp.gd")

const SCENE_PATH: String = "res://scenes/main.tscn"
const STORE_PATH: String = "user://clue_store.json"
const TMP_PATH: String = "user://clue_store.json.tmp"

## 存档相关的全部文件：测试前后的字节快照必须逐字节还原（见 _check_hygiene）。
## ui_prefs.json（引导开关）也算"玩家目录里的东西"—— 测试要把它一起备份/还原，
## 而且**开局要删掉它**，否则"首次进入弹引导"这条就测不到（见 _check_overlay_tutorial）。
const STORE_PATHS: Array[String] = [
	"user://clue_store.json",
	"user://clue_store.json.tmp",
	"user://clue_store.json.bak",
	"user://clue_store.json.corrupt",
	"user://ui_prefs.json",
]

## 期望执行的断言数（跑一次后按实际值填写；少执行 = 中途崩了 = 假绿）。
const EXPECTED_CHECKS: int = 215

# ------------------------------- 测试状态 -------------------------------

var _checks: int = 0
var _failures: Array[String] = []
var _scene: Node = null
var _hud: Node = null
var _label: Label = null
var _case: CaseLoader.CaseData = null

## 用户目录里的存档在测试前后的字节快照（测试必须不留痕）。
var _saved_existed: Array[bool] = []
var _saved_bytes: Array[PackedByteArray] = []


func _initialize() -> void:
	_backup_user_files()
	_clear_user_files()                    # 从干净的一档开始跑（结束时原样还回去）
	_playtest()


## 测试必须从"新档"起跑：玩家自己玩过的存档（心灯被烧过、线索拿过）会让断言漂移。
## 文件已由 _backup_user_files() 逐字节备份，_restore_user_files() 会还回去。
func _clear_user_files() -> void:
	for path in STORE_PATHS:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


# ============================================================================
#  试玩主流程（await 帧 ⇒ 由引擎按帧回调续跑）
# ============================================================================

func _playtest() -> void:
	var packed: Variant = load(SCENE_PATH)
	_check(packed is PackedScene, "主场景可以加载：%s" % SCENE_PATH)
	if not (packed is PackedScene):
		_finish()
		return

	_scene = (packed as PackedScene).instantiate()
	_check(_scene != null, "主场景可以实例化")
	if _scene == null:
		_finish()
		return
	root.add_child(_scene)
	await process_frame

	_hud = _scene.get_node_or_null("SliceHUD")
	_check(_hud != null, "场景里有 SliceHUD 节点（表现层已接线）")
	_label = _scene.find_child("InfoLabel", true, false) as Label
	_check(_label != null, "场景里有 InfoLabel（HUD 文本载体）")
	_check(_hud != null and _hud.get_node_or_null("HeartLamp") != null, "HUD 自己挂上了心灯子节点")

	var loop := root.get_node_or_null("TimeLoopManager")
	var memory := root.get_node_or_null("PersistentMemoryManager")
	_check(loop != null and memory != null, "两个 Autoload 都在（TimeLoopManager / PersistentMemoryManager）")
	if _hud == null or _label == null or loop == null or memory == null:
		_finish()
		return

	_case = CaseLoader.load_case()
	_check(_case.ok, "案件数据可装载：%s" % _case.error_summary())
	if not _case.ok:
		_finish()
		return

	await _check_overlay_tutorial()
	await _check_case_wiring()
	await _check_room_switching()
	await _check_clue_pickup()
	await _check_loop_reset_keeps_clues()
	await _check_loop_gate()
	await _check_extinguish_forgets()
	await _check_fast_forward_and_keys()
	await _check_resolution_gate()
	await _check_dialogue_clue()
	await _check_world_and_memory()
	await _check_deduction_board()
	await _check_rune_ritual()
	await _check_play_view()
	await _check_overlay_settlement_and_restart()
	_restore_user_files()                  # 先还原存档，再断言"没留痕"
	_check_hygiene()
	_finish()


# ---------------------------------------------------------------------------
#  1) 装载：余页长度来自数据、时钟真的在跑、HUD 文本已刷新
# ---------------------------------------------------------------------------
func _check_case_wiring() -> void:
	var loop := root.get_node("TimeLoopManager")
	_check(is_equal_approx(loop.get_loop_duration(), float(_case.loop_duration_seconds)),
		"余页长度来自案件数据（%d 秒）" % _case.loop_duration_seconds)
	_check(loop.is_running(), "场景一加载，余页就开始跑了")
	_check(loop.get_loop_index() == 0, "第一遍是第 0 遍余页")
	_check(_label.text.contains(_case.case_title), "HUD 显示案名《%s》" % _case.case_title)
	_check(_label.text.contains("第 1 遍余页"), "HUD 显示遍数（玩家口径 1 基：核心 0 基 +1）")
	_check(_label.text.contains("心灯"), "HUD 显示心灯")
	var events := _case.clue_events()
	_check(_label.text.contains("可观测线索 %d 处" % events.size()),
		"HUD 报出可观测线索数（%d 处）" % events.size())
	await process_frame


# ---------------------------------------------------------------------------
#  2) 换房间：走位要花余页里的秒数 —— 按键只是"动身"，秒数走完才真的到
# ---------------------------------------------------------------------------
func _check_room_switching() -> void:
	var loop := root.get_node("TimeLoopManager")
	var start_room: String = _current_room()
	_check(start_room == String(_case.rooms[0]), "开局站在第 1 个房间（%s）" % start_room)

	var travel: Variant = _hud.get("_travel")
	_check(travel != null, "HUD 读入了地图（走位按秒算，不再瞬移）")
	if travel == null:
		return

	await _press(KEY_TAB)
	var walking: bool = bool(travel.call("is_moving"))
	_check(walking, "按 TAB 只是动身去下一间（路上要花时间）")
	_check(_label.text.contains("正在去"), "HUD 报出正在去哪个房间、还剩几秒")
	if walking:
		var target: String = String(travel.call("get_target_room"))
		var left: int = int(travel.call("get_remaining_seconds"))
		await _tick_to(int(loop.get_elapsed_seconds()) + left + 1)
		_check(_current_room() == target, "秒数走完了才真的到 [%s]" % target)

	await _press(KEY_Q)
	var back: String = String(travel.call("get_target_room"))
	await _tick_to(int(loop.get_elapsed_seconds()) + int(travel.call("get_remaining_seconds")) + 1)
	_check(_current_room() == back, "Q 走回上一间（%s）" % back)

	await _press(KEY_1 + 2)
	await _tick_to(int(loop.get_elapsed_seconds()) + int(travel.call("get_travel_seconds_to", String(_case.rooms[2]))) + 1)
	_check(_current_room() == String(_case.rooms[2]), "数字键 3 走去第 3 个房间（%s）" % _current_room())


# ---------------------------------------------------------------------------
#  3) 核心玩法：站对房间、到点就拿到线索，并且立刻落盘
# ---------------------------------------------------------------------------
func _check_clue_pickup() -> void:
	var loop := root.get_node("TimeLoopManager")
	var memory := root.get_node("PersistentMemoryManager")
	var travel: Variant = _hud.get("_travel")

	# 走位要花秒数，所以挑一条"还没发生、而且来得及走过去"的拍点
	# （第一条线索的窗口可能在你走过去的路上就开了 —— 那是正常玩法，不是漏测）。
	var event: Dictionary = {}
	for candidate in _case.clue_events():
		var room_id: String = String(candidate["room"])
		var walk: int = int(travel.call("get_travel_seconds_to", room_id)) if travel != null else 0
		if memory.has_clue(String(candidate["clue_id"])):
			continue                       # 前面几节可能已经顺手看见了，换一条没见过的
		if int(candidate.get("loop_min", 0)) > int(loop.get_loop_index()):
			continue                       # 带遍数锁的拍点：这一遍就算蹲到了也看不见（第 14 节专门测它）
		if int(candidate["second"]) > int(loop.get_elapsed_seconds()) + walk + 3:
			event = candidate
			break
	_check(not event.is_empty(), "找到一条还没发生、又来得及走过去的线索拍点")
	if event.is_empty():
		return
	var clue_id: String = String(event["clue_id"])
	var room: String = String(event["room"])

	await _goto_room(room)
	_check(_current_room() == room, "蹲到了线索发生的房间（%s）" % room)

	var before: int = memory.get_clue_count()
	await _tick_to(int(event["second"]))
	_check(memory.get_clue_count() == before + 1, "到点后线索进记忆（%d → %d）" % [before, memory.get_clue_count()])
	_check(memory.has_clue(clue_id), "拿到的正是拍点上的那条线索（%s）" % clue_id)
	_check(_label.text.contains("看见"), "HUD 播报了这次观测")

	# 幂等：同一遍里再推 5 秒，不会重复获得
	var after_first: int = memory.get_clue_count()
	await _tick_to(int(event["second"]) + 5)
	_check(memory.get_clue_count() == after_first, "同一遍里不会重复获得同一条线索")

	# 持久化：内存 → 磁盘（关掉游戏再开还在，这是"线索即记忆"的地基）
	_check(FileAccess.file_exists(STORE_PATH), "线索已原子落盘（%s 存在）" % STORE_PATH)
	var saved: Array[String] = ClueStore.load_clues()
	_check(saved.has(clue_id), "落盘的存档里能找到这条线索（%d 条）" % saved.size())


# ---------------------------------------------------------------------------
#  4) 重开一遍：心灯 -8（读常量，别再写死），线索一条不丢（本作的核心体验）
# ---------------------------------------------------------------------------
func _check_loop_reset_keeps_clues() -> void:
	var loop := root.get_node("TimeLoopManager")
	var memory := root.get_node("PersistentMemoryManager")
	var lamp := _hud.get_node("HeartLamp")

	var value_before: int = lamp.call("get_value")
	var clues_before: int = memory.get_clue_count()
	# 重开一遍扣多少，直接读常量（M2 平衡调整过 8 → 5，别再把它写死在测试里）。
	var per_loop: int = lamp.DRAIN_PER_LOOP_RESET

	await _press(KEY_R)          # 强制重开本遍
	await process_frame

	_check(loop.get_loop_index() == 1, "按 R 后进入第 1 遍余页（核心 0 基）")
	_check(lamp.call("get_value") == value_before - per_loop,
		"重开一遍心灯 -%d（%d → %d）" % [per_loop, value_before, lamp.call("get_value")])
	_check(memory.get_clue_count() == clues_before, "线索跨遍不丢（仍是 %d 条）" % memory.get_clue_count())
	_check(_label.text.contains("第 2 遍余页"), "HUD 跟上第 2 遍的计数（玩家口径）")
	_check(_label.text.contains("余页重开：心灯 -%d" % per_loop), "HUD 记录了这次重开的代价")


# ---------------------------------------------------------------------------
#  4b) 遍数锁：站在对的地方、时辰也对，但遍数不到就是看不见（M2 加的门槛）
# ---------------------------------------------------------------------------
func _check_loop_gate() -> void:
	var loop := root.get_node("TimeLoopManager")
	var memory := root.get_node("PersistentMemoryManager")

	var gated_id := "clue_01_four_in_three"       # docs/story/04：四字位"获得方式：余页第二遍"
	var gated_room := "baihutai_west"
	var gated_second := 70

	# 数据 → HUD 的接线：窗口表里带着 loop_min。
	var found_loop_min: int = -1
	for window in _hud.get("_windows"):
		if String(window["clue_id"]) == gated_id:
			found_loop_min = int(window.get("loop_min", 0))
	_check(found_loop_min == 2, "%s 的遍数锁是 2（数据里写的 loop_min=%d）" % [gated_id, found_loop_min])

	# 此刻是第 1 遍（上一节刚按过 R）：站在台西、等到第 70 秒，也拿不到。
	_check(loop.get_loop_index() < 2, "此刻的 loop_index=%d < 2（还没到第 3 遍）" % loop.get_loop_index())
	_check(not memory.has_clue(gated_id), "遍数不到之前，这条线索不在记忆里（前置）")

	await _goto_room(gated_room)
	await _tick_to(gated_second)
	_check(not memory.has_clue(gated_id), "第 %d 遍的第 %d 秒站在台西，四字位那条还是拿不到（遍数锁真的拦住了）"
		% [loop.get_loop_index(), gated_second])
	_check(_label.text.contains("还没到时候"), "HUD 直说'还没到时候'，不装作这里什么都没有")

	# 再重开一遍（→ 第 3 遍），同一个房间、同一个秒数，这次拿得到。
	await _press(KEY_R)
	await process_frame
	_check(loop.get_loop_index() == 2, "重开一遍后到第 3 遍（loop_index=%d）" % loop.get_loop_index())
	await _goto_room(gated_room)
	await _tick_to(gated_second)
	_check(memory.has_clue(gated_id), "第 3 遍的同一拍点，四字位那条拿到了（遍数锁放开）")
	_check(_label.text.contains("看见"), "HUD 播报了这次观测")


# ---------------------------------------------------------------------------
#  5) 归零不是死亡：永久遗忘一条记忆，并且跨启动生效
# ---------------------------------------------------------------------------
func _check_extinguish_forgets() -> void:
	var memory := root.get_node("PersistentMemoryManager")
	var lamp := _hud.get_node("HeartLamp")
	var clue_id: String = memory.get_clues()[memory.get_clue_count() - 1]

	lamp.call("set_value", 1)          # 把灯压到只剩 1 点
	var count_before: int = memory.get_clue_count()
	lamp.call("drain", 1)              # 再扣 1 → 归零

	_check(lamp.call("is_extinguished"), "心灯归零（但主角没死）")
	_check(lamp.call("get_extinguish_count") == 1, "记下被划掉 1 笔")
	_check((lamp.call("get_forgotten_clues") as Array).has(clue_id), "被遗忘的线索进了黑名单：%s" % clue_id)
	_check(memory.get_clue_count() == count_before - 1,
		"记忆里真的少了一条（%d → %d）" % [count_before, memory.get_clue_count()])
	_check(not memory.has_clue(clue_id), "那条线索不再可用于推理")
	_check(ClueStore.is_forgotten(clue_id), "遗忘跨启动生效（存档里记着 blacklist）")
	_check(_label.text.contains("已遗忘"), "HUD 把遗忘的线索画出来")

	# 灯灭期间这段记忆是**永久**划掉的：重新查获也拒绝（验收员 2026-10 的发现 3 ——
	# 旧行为允许原地捡回，等于"故意烧灯纯赚"，与 09 文档"永久丢失"矛盾）。
	_check(not bool(lamp.call("add_clue", clue_id, 1)), "灯灭着时重新查获会被拒绝")
	_check(ClueStore.is_forgotten(clue_id), "灯灭着时黑名单不会被解除")
	_check(not memory.has_clue(clue_id), "那条线索依旧不可用于推理")

	# 重新点亮（结案/恢复）之后，记忆才可以被重新找回。
	lamp.call("restore", 50)
	_check(not lamp.call("is_extinguished"), "结案或恢复可以重新点亮心灯")
	_check(bool(lamp.call("add_clue", clue_id, 1)), "点亮之后重新查获成功")
	_check(not ClueStore.is_forgotten(clue_id), "点亮之后解除遗忘（记忆可以重新找回）")
	_check(memory.has_clue(clue_id), "那条线索重新可用于推理")


# ---------------------------------------------------------------------------
#  6) 秒级重演雏形 + 倍速 / 暂停
# ---------------------------------------------------------------------------
func _check_fast_forward_and_keys() -> void:
	var loop := root.get_node("TimeLoopManager")

	await _press(KEY_SPACE)
	_check(is_equal_approx(loop.get_time_scale(), 60.0), "空格快进用 60x（当前 %.0fx）" % loop.get_time_scale())
	_check(_label.text.contains("快进到"), "HUD 报出快进目标")

	# 走到 HUD 记下的那个拍点 → 它应该自己降回 1x（"到点就停"是秒级重演的关键）
	loop.set_time_scale(1.0)             # 手动降速避免真实帧把时间带飞（HUD 内部档位仍是 60x）
	var guard: int = 0
	while not _label.text.contains("快进结束") and guard < 400:
		loop.tick(1.0)
		guard += 1
	_check(is_equal_approx(loop.get_time_scale(), 1.0), "快进到点自动回到 1x（当前 %.0fx）" % loop.get_time_scale())
	_check(_label.text.contains("快进结束"), "HUD 记录了快进结束")

	# T 键在档位之间循环（此处档位下标已被快进结束复位到 1x）
	await _press(KEY_T)
	_check(is_equal_approx(loop.get_time_scale(), 10.0), "T 键切到下一档倍速（10x）")
	loop.set_time_scale(1.0)

	await _press(KEY_P)
	_check(loop.is_paused(), "P 键暂停")
	await _press(KEY_P)
	_check(not loop.is_paused(), "再按 P 继续")


# ---------------------------------------------------------------------------
#  7) 结案门槛：数据写明的 require_clues + require_min_loop 必须真的拦得住
#     （验收员 2026-10 的发现 2：旧版只查线索，第 0 遍就能一键结案）
# ---------------------------------------------------------------------------
func _check_resolution_gate() -> void:
	var loop := root.get_node("TimeLoopManager")
	var lamp := _hud.get_node("HeartLamp")
	var memory := root.get_node("PersistentMemoryManager")
	var conditions: Variant = _case.secret.get("resolve_conditions", {})
	_check(typeof(conditions) == TYPE_DICTIONARY, "案一写明了 resolve_conditions")
	if typeof(conditions) != TYPE_DICTIONARY:
		return
	var required: Array = (conditions as Dictionary).get("require_clues", [])
	var min_loop: int = int((conditions as Dictionary).get("require_min_loop", 0))
	_check(required.size() > 0, "结案所需线索非空（%d 条）" % required.size())
	_check(min_loop > 0, "结案写明最少遍数（require_min_loop = %d）" % min_loop)
	_check(loop.get_loop_index() < min_loop, "此刻还没到那一遍（第 %d 遍）" % loop.get_loop_index())

	# 集齐线索（本节验证的是"门槛"，不是"怎么拿到线索"）。
	lamp.call("set_value", 100)
	for clue_id in required:
		lamp.call("add_clue", String(clue_id), 0)
	_check(memory.has_all_clues(required), "%d 条结案线索已齐" % required.size())
	_hud.call("_refresh")                  # 直接调 API 入账不会自动刷屏，手动刷一次再看 HUD 文本
	_check(_label.text.contains("线索 %d/%d" % [required.size(), required.size()]),
		"HUD 显示线索已齐")
	_check(not _label.text.contains("已结案"), "线索齐了但遍数不够 ⇒ 不结案（旧版会在这里就 +25）")
	_check(_label.text.contains("须第 %d 遍之后" % (min_loop + 1)), "HUD 告诉玩家还差遍数（1 基：数据写 8 = 第 9 遍）")

	# 推到期满前一遍：每 tick 满一遍，核心会自动重开（本节排除"灯烧干"这个变量）。
	var guard: int = 0
	while loop.get_loop_index() < min_loop - 1 and guard < min_loop * 2 + 4:
		lamp.call("set_value", 100)
		loop.tick(float(_case.loop_duration_seconds))
		guard += 1
	await process_frame
	_check(loop.get_loop_index() == min_loop - 1, "推进到门槛前一遍（第 %d 遍）" % (min_loop - 1))
	_check(not _label.text.contains("已结案"), "差一遍也不结案（门槛真的在拦）")

	# 跨过门槛：这一遍开始时就该结案，心灯 +25 要到账。
	lamp.call("set_value", 40)
	loop.tick(float(_case.loop_duration_seconds))
	await process_frame
	_check(loop.get_loop_index() == min_loop, "跨过第 %d 遍" % min_loop)
	_check(not _label.text.contains("已结案"),
		"线索齐、遍数够，但仪式还没做 ⇒ 不结案（M1 第五步起仪式是硬门槛）")
	_check(_label.text.contains("还没做"), "HUD 直说还差哪一步（第 12 节把这一步做完）")


# ---------------------------------------------------------------------------
#  9) 对话层（M1 第一步）：有两条线索只能靠追问拿到，必须真的拿得到
#     案一 14 条线索里，clue_01_double_knot / clue_01_keep_stele_motive
#     的来源是对话选项的 add_clue —— M0 没有对话层，这两条拿不到。
# ---------------------------------------------------------------------------
func _check_dialogue_clue() -> void:
	var loop := root.get_node("TimeLoopManager")
	var memory := root.get_node("PersistentMemoryManager")
	var lamp := _hud.get_node_or_null("HeartLamp")
	if lamp == null:
		_check(false, "找得到 HUD 挂的心灯")
		return

	var table: Variant = _hud.get("_dialogue")
	_check(table != null and int(table.call("count")) == 38, "HUD 读入了对话表（38 条）")
	if table == null:
		return

	# qdm_02_bag 的前提：手里有 clue_01_grey_bag、第 4 遍以后、邱德茂在石阶上。
	lamp.call("set_value", 100)
	lamp.call("add_clue", "clue_01_grey_bag", loop.get_loop_index())
	await _goto_room("stone_steps_7")
	await _tick_to(180)                     # 锚点是 t=170，窗口 [170, 300)
	_hud.call("_refresh")
	_check(_label.text.contains("F 交谈"), "HUD 提示玩家可以交谈")

	var owned: Array = lamp.call("get_available_clues")
	var npc_id: String = "npc_01_qiu_demao"
	var entry: Variant = table.call("get_dialogue", "qdm_02_bag")
	_check(entry != null and not bool(entry.call("is_active_at", 180)),
		"loader 的严格窗口只认锚点那一秒（t=180 已经过期）")
	var wide: Array = _hud.call("_entries_to_say", npc_id, 180, loop.get_loop_index(), owned)
	var wide_ids: Array = []
	for item in wide:
		wide_ids.append(String(item.dialogue_id))
	_check(wide_ids.has("qdm_02_bag"), "宽窗口口径：NPC 还停在这个房间时照旧能对话（Lead 裁定）")

	# 追问链：qdm_02_bag —（选项带 goto）→ …；多按几次 F 把这条链走完。
	var presses: int = 0
	while not memory.has_clue("clue_01_double_knot") and presses < 4:
		await _press(KEY_F)
		presses += 1
	_check(memory.has_clue("clue_01_double_knot"),
		"按 F 追问 %d 次后拿到只有对话才给的线索（双回结）" % presses)
	_check(_label.text.contains("入录"), "HUD 日志记下了入录")
	_check((lamp.call("get_available_clues") as Array).has("clue_01_double_knot"),
		"这条线索进了「还能记起」的清单")

	await _press(KEY_F)
	_check(_label.text.contains("已经问完"), "再按一次 F 不会重复刷同一段对话")

	# 表现层（鼠标）那条路：对话框里点一条没问过的选项 = 按 F 追问同一个结算。
	# 先清掉"问过"记录，让同一条对话重新出选项。
	(_hud.get("_talked") as Dictionary).clear()
	await _press(KEY_F)
	var view: Dictionary = _hud.get("_dialogue_view")
	_check(bool(view.get("active", false)), "按 F 之后表现层拿得到对话框状态（M2 表现层接口）")
	_check(not String(view.get("speaker", "")).is_empty() and not String(view.get("line", "")).is_empty(),
		"对话框带着说话人与这一句台词")
	var options: Array = view.get("options", [])
	_check(options.size() >= 1, "对话框里有可点的选项（%d 条）" % options.size())
	var option_index: int = -1
	for index in range(options.size()):
		if not bool((options[index] as Dictionary).get("asked", false)):
			option_index = index
			break
	_check(option_index >= 0, "至少有一条还没问过的选项可以点")
	if option_index >= 0:
		var log_before: String = String((_hud.get("_log") as Array)[0])
		_hud.call("request_option", option_index)
		var log_after: String = String((_hud.get("_log") as Array)[0])
		_check(log_after != log_before, "点选项之后 HUD 记了一笔（request_option 生效）")


# ---------------------------------------------------------------------------
#  10) 世界状态递进 + NPC 跨轮记忆（M1 第三步）：接在 HUD 上真的会随遍数变
# ---------------------------------------------------------------------------

func _check_world_and_memory() -> void:
	var loop := root.get_node("TimeLoopManager")
	var lamp := _hud.get_node_or_null("HeartLamp")
	lamp.call("set_value", 100)

	var mutation: Variant = _hud.get("_mutation")
	var memory_component: Variant = _hud.get("_memory")
	if mutation == null or memory_component == null:
		_check(false, "HUD 挂上了世界状态与记忆两个组件")
		return

	_check(bool(mutation.call("is_configured")) and String(mutation.call("get_mode")) == "grow",
		"HUD 的世界状态组件读到了 per_loop_mutation（案一 = grow）")
	_check(String(mutation.call("describe")).contains("余页杂讯"),
		"世界状态行是给人看的中文整句")

	var level_before: int = int(mutation.call("get_level"))
	var traces_before: int = int(mutation.call("entity_count", "baihutai_bei"))
	await _press(KEY_R)
	await _press(KEY_R)
	_check(int(mutation.call("get_level")) > level_before,
		"重开两遍后世界状态确实递进（%d → %d）" % [level_before, int(mutation.call("get_level"))])
	_check(int(mutation.call("entity_count", "baihutai_bei")) > traces_before,
		"同一间房里的痕迹跟着变多（%d → %d，不是累积的残留）" % [
			traces_before, int(mutation.call("entity_count", "baihutai_bei")),
		])

	_check(bool(memory_component.call("is_configured"))
			and (memory_component.call("get_npc_ids") as Array).size() == 6,
		"HUD 的记忆组件读到了 6 名 NPC 的跨轮记忆规则")
	_check(int(memory_component.call("total_rule_count")) == 11, "一共 11 条记忆规则")

	# 穆青的第 1 阶只要求 clue_01_four_in_three（min_loop 0）：线索一到手，阶立刻就变。
	lamp.call("add_clue", "clue_01_four_in_three", loop.get_loop_index())
	_check(int(memory_component.call("get_stage", "npc_01_muqing")) >= 1,
		"线索到手后穆青的记忆阶立刻抬起来（现算，不落盘）")
	var effects: Dictionary = memory_component.call("get_effects", "npc_01_muqing")
	_check(String(effects.get("extra_dialogue_id", "")).begins_with("mq_"),
		"阶数带出了一句原本没有的台词（%s）" % String(effects.get("extra_dialogue_id", "")))

	_hud.call("_refresh")
	_check(_label.text.contains("世界状态") and _label.text.contains("NPC 记忆"),
		"HUD 上真的显示了这两行")

	var owned: Array = lamp.call("get_available_clues")
	_check(_hud.call("_memory_extra_entry", "npc_01_muqing", loop.get_loop_index(), owned) != null,
		"按 F 时这句额外台词会被说出来（接进了 _talk）")


# ---------------------------------------------------------------------------
#  11) ④ 推演板：线索拼成推论、"对不上"置顶、卡关预警、一键重演上一遍路线
#      （对应 docs/market/01 §2.5 的死法 1「循环内重复劳动」与死法 3「引导缺失卡关」）
# ---------------------------------------------------------------------------
func _check_deduction_board() -> void:
	var loop := root.get_node("TimeLoopManager")
	var lamp := _hud.get_node_or_null("HeartLamp")
	var board: Variant = _hud.get("_board")
	_check(board != null, "HUD 挂上了推演板组件")
	if board == null:
		return

	# 上一节把心灯烧到了零（那是它的目的）；这一节点亮线索要真的入录，先把灯扶回满值。
	lamp.call("set_value", 100)

	_check(bool(board.call("is_configured")) and bool(board.call("is_ok")),
		"推演板读到了 data/deduction/case_01_deduction.json")
	_check(int(board.call("total_deduction_count")) == 10, "板上有 10 条推论")
	_check(int(board.call("total_conflict_count")) == 6, "板上登记了 6 处对不上")
	_check(int(board.call("total_stuck_hint_count")) == 6, "板上有 6 条卡关提示")
	_check(String(board.call("describe")).contains("推演板："), "板子的总述是给人看的中文整句")

	# 一张卡就能点亮的矛盾：clue_01_hole_chipped → cf_04_old_face_new_chip。
	lamp.call("add_clue", "clue_01_hole_chipped", loop.get_loop_index())
	board.call("refresh")
	var ready: Array = board.call("ready_conflicts")
	_check(not ready.is_empty(), "线索一到手，对不上的地方就点亮了（%d 处）" % ready.size())
	var lit_ids: PackedStringArray = PackedStringArray()
	var lit_title: String = ""
	for entry in ready:
		if entry is Dictionary:
			lit_ids.append(String((entry as Dictionary).get("conflict_id", "")))
	if not ready.is_empty() and ready[0] is Dictionary:
		lit_title = String((ready[0] as Dictionary).get("title", ""))
	_check(lit_ids.has("cf_04_old_face_new_chip"),
		"数据里写的那一处确实在点亮集合里（%s）" % ", ".join(lit_ids))

	_hud.call("_refresh")
	_check(_label.text.contains("对不上"), "主视图顶部把最该注意的矛盾顶到眼前")
	_check(not lit_title.is_empty() and _label.text.contains(lit_title),
		"顶上来的是给人看的标题（%s），不是 id" % lit_title)

	await _press(KEY_B)
	_check(_label.text.contains("推演板（B 收起）"), "B 键摊开推演板")
	_check(_label.text.contains("⚠ 对不上："), "板子上点亮的矛盾排在最前面")
	await _press(KEY_B)
	_check(not _label.text.contains("推演板（B 收起）"), "再按一次 B 收起推演板")

	# 卡关预警：连着几遍没有新线索 → 主动把落点点出来（死法 3 的正面做法）。
	_hud.call("_refresh")                                   # 先把线索基线同步进去
	_hud.set("_last_progress_loop", loop.get_loop_index() - 7)
	_hud.call("_refresh")
	_check(_label.text.contains("提示（连着"), "连着几遍没有新线索时，HUD 主动给提示")
	_check(_label.text.contains("穆青") or _label.text.contains("刘桂英")
			or _label.text.contains("吴敬堂") or _label.text.contains("邱德茂")
			or _label.text.contains("甘凤仪"),
		"提示里带具体的人和落点，不是一句空话")

	# 一键重演上一遍路线（死法 1）：任何已经解锁过的动作都不该让玩家再手动点一遍。
	var travel: Variant = _hud.get("_travel")
	var start: String = _current_room()
	var best: String = ""
	var best_seconds: int = 99999
	var second: String = ""
	var second_seconds: int = 99999
	for room_id in _case.rooms:
		if room_id == start or not bool(_hud.call("_is_reachable", room_id)):
			continue
		var seconds: int = int(travel.call("get_travel_seconds_to", room_id))
		if seconds > 0 and seconds < best_seconds:
			best_seconds = seconds
			best = room_id
	for room_id in _case.rooms:
		if room_id == start or room_id == best or not bool(_hud.call("_is_reachable", room_id)):
			continue
		var seconds: int = int(travel.call("get_travel_seconds_to", room_id))
		if seconds > 0 and seconds < second_seconds:
			second_seconds = seconds
			second = room_id
	_check(not best.is_empty() and not second.is_empty(),
		"至少有两间走得到的房间可以做重演目标（%s %d 秒 / %s %d 秒）" % [
			best, best_seconds, second, second_seconds,
		])
	if best.is_empty() or second.is_empty():
		return

	# 上一遍的路线是"真走出来的"：先走这两站，再 R 重开（R 会把这一遍的路线存成上一遍的）。
	await _goto_room(best)
	await _goto_room(second)
	await _press(KEY_R)
	var recorded: Variant = _hud.get("_last_loop_route")
	var recorded_count: int = 0 if recorded == null else (recorded as Array).size()
	_check(recorded_count >= 3,
		"重开时把上一遍走过的路线记下来了（%d 站：起点 + 两站）" % recorded_count)

	await _press(KEY_H)
	_check(_label.text.contains("重演上一遍路线：2 站"), "H 键把上一遍路线排进重演队列")
	_check(bool(travel.call("is_moving")) and String(travel.call("get_target_room")) == best,
		"按下 H 就自己动身去第一站（%s），不用再手点" % best)

	var guard: int = 0
	while guard < 600 and _current_room() != best:
		await _tick_to(int(loop.get_elapsed_seconds()) + 1)
		guard += 1
	_check(_current_room() == best, "重演的第一站走到了")
	_check(bool(travel.call("is_moving")) and String(travel.call("get_target_room")) == second,
		"到站后自动接上第二站（%s），玩家一次都不用按键" % second)


# ---------------------------------------------------------------------------
#  12) ⑤ 画符（M1 第五步）：结案的仪式 —— 三笔照回原文、错笔有交代、结案要它
#     对应 docs/story/04 的「回照诵碑」与 docs/story/09 的 resolve_conditions.require_ritual
# ---------------------------------------------------------------------------

func _check_rune_ritual() -> void:
	var loop := root.get_node("TimeLoopManager")
	var lamp := _hud.get_node_or_null("HeartLamp")
	lamp.call("set_value", 100)

	var table: Variant = _hud.get("_runes")
	var rune: Variant = _hud.get("_rune")
	_check(table != null and int(table.call("count")) == 1, "HUD 读入了仪式表（1 个仪式）")
	_check(rune != null, "HUD 挂上了画符输入层")
	if table == null or rune == null:
		return
	_check(int(table.call("total_steps")) == 5 and int(table.call("total_strokes")) == 3,
		"仪式 5 步 / 3 笔（数据说话）")
	_check(bool(rune.call("is_configured")) and bool(rune.call("is_ok")), "输入层读到了仪式数据")

	# 仪式开在碑前：先真的走过去（走位耗时口径）。
	await _goto_room("baihutai_bei")
	_check(_current_room() == "baihutai_bei", "走到了仪式所在的房间（%s）" % _current_room())
	_hud.call("_refresh")
	_check(bool(rune.call("can_start", "")), "六环齐 + 遍数够 + 人在碑前 ⇒ 可以起手")
	_check(_label.text.contains("G 画符"), "HUD 主动告诉玩家可以画符了")

	await _press(KEY_G)
	_check(_label.text.contains("画符（G 收起）"), "G 键摊开画符面板")
	_check(bool(rune.call("is_running")), "G 键直接把仪式起手，不用再点一次")
	_check(_label.text.contains("回照诵碑") or _label.text.contains("回照"), "面板上写着仪式的名字")

	# 第一步是 gate（把拓片摊开）：回车确认往下。
	await _press(KEY_ENTER)
	var step_after_gate: Variant = rune.call("get_current_step")
	_check(step_after_gate != null and bool(step_after_gate.call("is_draw")),
		"确认第一步后进到画符步（%s）" % ("" if step_after_gate == null else String(step_after_gate.get("name"))))

	# 先画错一笔：数据里预置的 near_miss（多一笔）要有自己的交代，而且不许糊弄过去。
	for token in ["right", "down", "left", "up", "down"]:
		await _press(_token_key(token))
	await _press(KEY_ENTER)
	_check(_label.text.contains("多一笔"), "画错的那一笔拿到的是数据里预置的说法（多一笔——第二次篡改）")
	_check(int(rune.call("current_stroke_index")) == 0, "画错的笔不算数，还停在第 1 笔")

	# 错笔的 token 还留在笔尖上（数据里的提示就是"退一笔重描"）⇒ 退干净再照原文画。
	for drop in range(5):
		await _press(KEY_BACKSPACE)
	_check((rune.call("current_tokens") as Array).is_empty(), "退格把画错的那一笔退干净了")
	_check(int(rune.call("current_stroke_index")) == 0, "退格不会把没落笔的东西算成画过")

	# 三笔按数据照回来：回、照、录。
	var strokes: Array = [
		["right", "down", "left", "up"],
		["down", "down_right", "right", "down"],
		["right", "down", "right", "down"],
	]
	for index in range(strokes.size()):
		for token in strokes[index]:
			await _press(_token_key(String(token)))
		await _press(KEY_ENTER)
		_check(_label.text.contains("落笔对了"),
			"第 %d 笔（%s）落笔对了" % [index + 1, "回照录"[index]])
	_check(_label.text.contains("三笔齐"), "三笔齐了 —— 阙文照回来了")

	# 往后走：甘阿婆自己念 → 选"不补刻" → 念到底。
	await _press(KEY_ENTER)
	await _press(KEY_ENTER)
	var choice: Variant = rune.call("get_current_step")
	_check(choice != null and bool(choice.call("is_choice")), "进到要玩家拿主意的那一步")
	await _press(KEY_1)                     # carve_it_back：把名字补刻回去（错的）
	_check(not bool(rune.call("is_completed")), "选了补刻就不算完 —— 错的选择不推进")
	await _press(KEY_2)                     # keep_the_gap：留着那道缺口（对的）
	await _press(KEY_ENTER)
	await _press(KEY_ENTER)
	_check(bool(rune.call("is_completed")), "整套仪式做完（第 5 步念到底）")

	# 结案：仪式做完 ⇒ 才轮到"线索齐 + 遍数够"生效。
	_hud.call("_refresh")
	_check(_label.text.contains("仪式完成"), "日志里记下了仪式完成")
	_check(_label.text.contains("已结案"), "仪式做完之后案子才结")
	_check(_label.text.contains("结案：心灯 +25"), "结案把心灯 +25 记进日志")
	_check(lamp.get_value() > 25, "心灯数值确实回升（现在 %d）" % lamp.get_value())

	await _press(KEY_G)
	_check(not _label.text.contains("画符（G 收起）"), "再按一次 G 收起画符面板")


# ---------------------------------------------------------------------------
#  13) 表现层（M2 第一版）：PlayView 真的读到了数据、画了帧、收起了文字 HUD
# ---------------------------------------------------------------------------

func _check_play_view() -> void:
	var view: Node = _scene.get_node_or_null("PlayView")
	_check(view != null, "场景里有 PlayView 节点（M2 表现层已接线）")
	if view == null:
		return
	var info: Dictionary = view.call("debug_info")
	_check(int(info.get("rooms", 0)) == 17, "表现层读到了 17 间房的坐标（%d）" % int(info.get("rooms", 0)))
	_check(int(info.get("edges", 0)) >= 50, "表现层读到了地图的路（%d 条有向边）" % int(info.get("edges", 0)))
	_check(bool(info.get("has_state", false)), "表现层每帧从 SliceHUD.present_state() 取状态")
	_check(int(info.get("drawn", 0)) > 0, "这一层真的在画（画过 %d 帧）" % int(info.get("drawn", 0)))
	var lamp_warning: String = String((_hud.call("present_state") as Dictionary).get("lamp_warning", ""))
	_check(not lamp_warning.is_empty(), "心灯代价预告（诚实交代，别让玩家一头撞上永久遗忘）：%s" % lamp_warning)

	# v2 布局不变量：节点不许挤在一起（用户报的就是这个）
	var min_gap: float = float(info.get("min_gap", 0.0))
	_check(min_gap >= 120.0, "房间牌子之间的最小间距 >= 120px（实测 %.0fpx，%dx%d 格）" % [
		min_gap, int(info.get("cols", 0)), int(info.get("rows", 0))])
	_check(int(info.get("overlaps", -1)) == 0, "没有任何两块牌子互相重叠（重叠 %d 对）" % int(info.get("overlaps", -1)))
	_check(int(info.get("cols", 0)) >= 3 and int(info.get("rows", 0)) >= 3, "网格成型（%dx%d 格，每间房独占一格）" % [
		int(info.get("cols", 0)), int(info.get("rows", 0))])
	_check(int(info.get("chips", 0)) > 0, "NPC 棋子挂在自己的格子里（%d 个）" % int(info.get("chips", 0)))
	_check(bool(info.get("side_panel", false)) and int(info.get("side_rows", 0)) > 0,
		"右侧面板是真容器（PanelContainer/VBoxContainer，%d 个子控件）" % int(info.get("side_rows", 0)))

	# 文字 HUD 默认收起（开局就是"看画面"），` 键随时叫回来
	_check(not _label.visible, "开局文字 HUD 自动收起（画面优先）")
	await _press(KEY_QUOTELEFT)
	_check(_label.visible and _label.text.contains("文字 HUD：开"), "按 ` 叫回文字 HUD（调试与老切片口径）")
	await _press(KEY_QUOTELEFT)
	_check(not _label.visible, "再按一次 ` 收起文字 HUD")

	# 表现层那一整包状态：字段齐、和 HUD 内部一致
	var state: Dictionary = _hud.call("present_state")
	var required_keys: Array[String] = [
		"ok", "title", "loop_index", "second", "duration", "remaining", "paused",
		"room", "room_name", "rooms", "reachable", "lamp", "lamp_max", "extinguished",
		"clues", "clue_names", "clue_total", "required", "resolved", "ritual_required",
		"min_loop", "npcs", "conflicts", "stuck", "next_beat", "occupants", "log",
		"travel", "dialogue", "rune", "text_hud", "elapsed_total",
	]
	var missing: Array[String] = []
	for key in required_keys:
		if not state.has(key):
			missing.append(key)
	_check(missing.is_empty(), "present_state() 的字段齐（缺：%s）" % ("无" if missing.is_empty() else "、".join(missing)))
	_check(String(state.get("room", "")) == _current_room(), "present_state 报的房间和 HUD 一致（%s）" % String(state.get("room", "")))
	var npc_list: Array = state.get("npcs", [])
	_check(npc_list.size() >= 8, "表现层拿得到案一全部 NPC 的位置（棋子 %d 个）" % npc_list.size())
	var reachable: Dictionary = state.get("reachable", {})
	_check(reachable.size() >= 15, "表现层拿得到可达房间表（%d 间）" % reachable.size())

	# 鼠标点房间 → 表现层转发 request_travel（和 TAB 走同一套走位）
	var loop := root.get_node("TimeLoopManager")
	await _goto_room("baihutai")
	var target: String = "baihutai_west"
	_hud.call("request_travel", target)
	var moving_state: Dictionary = _hud.call("present_state")
	var travel: Dictionary = moving_state.get("travel", {})
	_check(bool(travel.get("moving", false)), "request_travel 让人动身了（鼠标点房间那条路）")
	_check(String(travel.get("to", "")) == target or String(moving_state.get("room", "")) == target,
		"动身的方向是点的那间房（%s）" % target)
	var seconds: int = int(reachable.get(target, 0))
	await _tick_to(int(loop.get_elapsed_seconds()) + maxi(1, seconds) + 2)
	_check(_current_room() == target, "走到了点的那间房（%s）" % target)


# ---------------------------------------------------------------------------
#  13b) 覆盖层（Phase 2）：新手引导首次进入弹一次、30 秒倒计时、关掉记一笔
# ---------------------------------------------------------------------------

func _check_overlay_tutorial() -> void:
	var overlay: Node = _scene.get_node_or_null("OverlayUI")
	_check(overlay != null, "场景里有 OverlayUI 节点（弹窗层已接线）")
	if overlay == null:
		return

	# Phase 3 清屏：开发向信息（读入 / 警告）只准进 stdout，不许混进玩家的「最近发生」
	var leaks: Array[String] = []
	for fragment in ["地图读入", "地图警告", "读入 ", "数据警告", "对话表读入", "对话警告",
			"推演板：", "推演板警告", "NPC 记忆规则", "记忆警告", "世界状态警告",
			"仪式：", "仪式警告", "仪式输入警告"]:
		if _log_has(fragment):
			leaks.append(fragment)
	_check(leaks.is_empty(), "玩家日志里没有开发痕迹（漏了：%s）" % ("无" if leaks.is_empty() else "、".join(leaks)))
	var beat: String = String((_hud.call("present_state") as Dictionary).get("next_beat", ""))
	_check(not beat.contains("|") and not beat.contains("off_page"),
		"底栏拍点提示说的是人话（%s）" % beat)

	var info: Dictionary = overlay.call("debug_info")
	_check(bool(info.get("tutorial_open", false)), "首次进入自动弹新手引导（ui_prefs 里没有记录）")
	_check(float(info.get("tutorial_left", 0.0)) > 25.0,
		"引导按 30 秒倒计时（还剩 %.1f 秒）" % float(info.get("tutorial_left", 0.0)))
	var body: Label = overlay.get("_tutorial_body") as Label
	var keys: Label = overlay.get("_tutorial_keys") as Label
	var body_text: String = body.text if body != null else ""
	var keys_text: String = keys.text if keys != null else ""
	_check(body_text.contains("心灯") and body_text.contains("线索") and body_text.contains("结案"),
		"引导讲了核心规则（余页/线索来源/心灯代价/结案）")
	_check(body_text.contains("360"), "引导里的余页秒数从数据现取（含 360）")
	_check(keys_text.contains("TAB") and keys_text.contains("F") and keys_text.contains("G"),
		"引导里有按键表（TAB / F / G …）")
	_check(bool(info.get("blocker_visible", false)), "引导开着时遮罩吃掉底下的点击（不会误点房间）")
	_check(not bool((_hud.call("present_state") as Dictionary).get("paused", true)),
		"引导不暂停余页钟（想上手就点掉，别搅时钟）")

	var button: Button = _find_button(overlay, "知道了")
	_check(button != null, "引导弹窗有关闭按钮「知道了」")
	if button != null:
		button.emit_signal("pressed")
	var after: Dictionary = overlay.call("debug_info")
	_check(not bool(after.get("tutorial_open", true)), "点「知道了」关掉引导")
	_check(not bool(after.get("blocker_visible", true)), "关掉之后遮罩收起（点房间/点人立刻可用）")
	_check(UIPrefs.has_seen_tutorial(), "关掉后记一笔（user://ui_prefs.json）")

	# 第二次进游戏不该再弹（同一份 ui_prefs，不改玩家存档）
	var overlay_script: GDScript = load("res://scripts/ui/overlay_ui.gd")
	var again: Node = overlay_script.new()
	_scene.add_child(again)
	await process_frame
	_check(not bool((again.call("debug_info") as Dictionary).get("tutorial_open", true)),
		"第二遍进游戏不再弹引导（ui_prefs 已经记过）")
	again.queue_free()


# ---------------------------------------------------------------------------
#  13c) 覆盖层（Phase 3）：结案结算 + 重新开始
# ---------------------------------------------------------------------------

func _check_overlay_settlement_and_restart() -> void:
	var overlay: Node = _scene.get_node_or_null("OverlayUI")
	if overlay == null:
		return
	var info: Dictionary = overlay.call("debug_info")
	_check(bool(info.get("settlement_open", false)), "结案那一刻自动弹结算面板（不用玩家按键）")
	_check(bool(info.get("settlement_seen", false)), "结算只弹一次（settlement_seen 记住了）")
	var stats: Label = overlay.get("_settle_stats") as Label
	var sub: Label = overlay.get("_settle_sub") as Label
	var stats_text: String = stats.text if stats != null else ""
	var loop := root.get_node("TimeLoopManager")
	var expected_loop: int = int(loop.get_loop_index()) + 1
	_check(stats_text.contains("用了几遍：第 %d 遍" % expected_loop),
		"结算写出用了几遍（玩家口径：第 %d 遍）" % expected_loop)
	_check(sub != null and sub.text.contains("六环"), "结算标题点了「结案六环」这件事")
	_check(stats_text.contains("心灯：") and stats_text.contains("入案线索："),
		"结算写出心灯与线索两项")
	var clock_at: int = stats_text.find("余页内耗时：")
	var shown_clock: String = stats_text.substr(clock_at + 6, 5) if clock_at >= 0 else ""
	_check(shown_clock.length() == 5 and shown_clock[2] == ":" and shown_clock.substr(0, 2).is_valid_int(),
		"结算是 mm:ss 口径的耗时（%s）" % shown_clock)
	var state: Dictionary = _hud.call("present_state")
	_check(float(state.get("elapsed_total", 0.0)) > 0.0,
		"余页内耗时是真实累计的游戏时钟（%.1f 秒）" % float(state.get("elapsed_total", 0.0)))

	var restart: Button = _find_button(overlay, "重新开始")
	_check(restart != null, "结算面板有「重新开始」按钮")
	_check(_find_button(overlay, "留在此页") != null, "结算面板有「留在此页」按钮（不想重开也能接着看）")

	# 先按「留在此页」：面板收得起，而且不会又自己弹回来
	var stay: Button = _find_button(overlay, "留在此页")
	if stay != null:
		stay.emit_signal("pressed")
	_check(not bool((overlay.call("debug_info") as Dictionary).get("settlement_open", true)),
		"「留在此页」收起结算")
	await process_frame
	await process_frame
	_check(not bool((overlay.call("debug_info") as Dictionary).get("settlement_open", true)),
		"收起后不会又自己弹回来（settlement_seen 兜住）")

	# 「重新开始」= 开新档：记忆清干净、遍数归零、心灯从头记
	if restart != null:
		restart.emit_signal("pressed")
	await process_frame
	var fresh: Dictionary = _hud.call("present_state")
	_check(int(fresh.get("loop_index", -1)) == 0, "「重新开始」把遍数归零（核心 0 基 ⇒ 玩家口径第 1 遍）")
	_check(int(fresh.get("remaining", -1)) >= int(fresh.get("duration", 0)) - 2,
		"「重新开始」后余页钟重新走满（剩 %d / %d 秒）" % [
			int(fresh.get("remaining", -1)), int(fresh.get("duration", 0))])
	_check(int(fresh.get("second", -1)) <= 2,
		"「重新开始」后余页从 0 秒起算（现在第 %d 秒）" % int(fresh.get("second", -1)))
	_check((fresh.get("clues", []) as Array).is_empty(), "「重新开始」清掉入案线索")
	_check(not bool(fresh.get("resolved", true)), "「重新开始」回到未结案状态")
	_check(not bool((overlay.call("debug_info") as Dictionary).get("settlement_open", true)),
		"重开之后结算面板不再挂着")
	_check(_label.text.contains("开新档"), "日志跟玩家交代了这次重开（开新档）")
	_check(_label.text.contains("第 1 遍余页"), "重开之后又从第 1 遍讲起")
	var gone: Array[String] = []
	for path in [STORE_PATH, "user://clue_store.json.tmp", "user://clue_store.json.bak"]:
		if FileAccess.file_exists(path):
			gone.append(path)
	_check(gone.is_empty(), "「重新开始」把记忆档清干净（还在：%s）" % ("无" if gone.is_empty() else "、".join(gone)))
	var probe: Node = HeartLamp.new()
	probe.call("restore_from_store")
	_check(int(probe.call("get_value")) == int(probe.call("get_max_value")),
		"开新档后冷启动读到的心灯是满的（%d）" % int(probe.call("get_value")))
	probe.free()


# ---------------------------------------------------------------------------
#  14) 卫生：测试不许留下痕迹
# ---------------------------------------------------------------------------

func _check_hygiene() -> void:
	_check(not FileAccess.file_exists(TMP_PATH), "测试结束后没有残留 .tmp")
	var changed: Array[String] = []
	for index in range(STORE_PATHS.size()):
		var path: String = STORE_PATHS[index]
		var exists: bool = FileAccess.file_exists(path)
		if exists != _saved_existed[index]:
			changed.append(path)
		elif exists and FileAccess.get_file_as_bytes(path) != _saved_bytes[index]:
			changed.append(path)
	_check(changed.is_empty(), "存档 + 引导偏好逐字节还原（%s）" % (
		"不一致：" + "、".join(changed) if not changed.is_empty() else "全部一致"))
	_check(_label.text.length() > 100, "HUD 文本是完整的一屏（%d 字符）" % _label.text.length())


# ============================================================================
#  驱动工具
# ============================================================================

## 按**文本**找按钮（弹窗是纯代码搭的，测试照着玩家看到的那几个字点）。
func _find_button(node: Node, text: String) -> Button:
	for child in node.get_children():
		if child is Button and String((child as Button).text) == text:
			return child
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


## 玩家的「最近发生」里有没有这句话（Phase 3 拿它查"开发痕迹漏没漏"）。
func _log_has(fragment: String) -> bool:
	var lines: Variant = _hud.get("_log")
	if not (lines is Array):
		return false
	for line in (lines as Array):
		if String(line).contains(fragment):
			return true
	return false


## 方向 token → 键位（画符用；四个斜向走小键盘，和 data/runes 的 key_map 口径一致）。
func _token_key(token: String) -> int:
	match token:
		"up":
			return KEY_UP
		"down":
			return KEY_DOWN
		"left":
			return KEY_LEFT
		"right":
			return KEY_RIGHT
		"up_left":
			return KEY_KP_7
		"up_right":
			return KEY_KP_9
		"down_left":
			return KEY_KP_1
		"down_right":
			return KEY_KP_3
	return 0


## 合成一次按键（走真实的输入管线，而不是直接调 _input）。
func _press(keycode: int) -> void:
	var event := InputEventKey.new()
	event.set("keycode", keycode)
	event.set("physical_keycode", keycode)
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame


## 走到指定房间：开真走位（最短路，多跳自动接上），一秒一秒推到走完。
## 顺带证明"走位真的是要花秒数的"——不是直接改 _player_room。
func _goto_room(room: String) -> void:
	var loop := root.get_node("TimeLoopManager")
	var travel: Variant = _hud.get("_travel")
	_hud.call("_travel_to", room)
	var guard: int = 0
	while travel != null and bool(travel.call("is_moving")) and guard < 600:
		await _tick_to(int(loop.get_elapsed_seconds()) + 1)
		guard += 1
	_check(_current_room() == room, "走位到目标房间（%s）" % room)


## 推进时钟直到"已经过去 target 秒"（手动 tick ⇒ 确定性，不依赖真实帧率）。
func _tick_to(target: int) -> void:
	var loop := root.get_node("TimeLoopManager")
	var guard: int = 0
	while loop.get_elapsed_seconds() < float(target) and guard < 2000:
		loop.tick(1.0)
		guard += 1
	await process_frame


## 从 HUD 文本里抠出"你在 [xxx]"里的房间名，再翻回房间 id
## （HUD 显示的是地名，不是 id —— 这是给玩家看的）。
func _current_room() -> String:
	var text: String = _label.text
	var open_at: int = text.find("你在 [")
	if open_at < 0:
		return ""
	var close_at: int = text.find("]", open_at)
	if close_at < 0:
		return ""
	var shown: String = text.substr(open_at + "你在 [".length(), close_at - open_at - "你在 [".length())
	var map: Variant = _hud.get("_map")
	if map == null:
		return shown
	for room_id in _case.rooms:
		if String(map.call("get_display_name", room_id)) == shown:
			return room_id
	return shown


# ============================================================================
#  断言与收尾
# ============================================================================

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  ✓ %s" % message)
	else:
		_failures.append(message)
		print("  ✗ %s" % message)


func _backup_user_files() -> void:
	_saved_existed.clear()
	_saved_bytes.clear()
	for path in STORE_PATHS:
		var exists: bool = FileAccess.file_exists(path)
		_saved_existed.append(exists)
		_saved_bytes.append(FileAccess.get_file_as_bytes(path) if exists else PackedByteArray())


func _restore_user_files() -> void:
	# 测试开始时如果是"干净存档"，结束时就必须还是干净的 —— 否则会污染玩家的真实进度。
	for index in range(STORE_PATHS.size()):
		var path: String = STORE_PATHS[index]
		if _saved_existed[index]:
			_write_bytes(path, _saved_bytes[index])
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _finish() -> void:
	_restore_user_files()
	if _scene != null:
		_scene.free()
	print("")
	if _checks < EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数量异常：实际 %d 项 < 期望 %d 项（中途崩了？）" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if _failures.is_empty():
		print("结果：通过 %d 项 / 失败 0 项（共 %d 项）" % [_checks, _checks])
		print("RESULT: OK slice_hud 试玩 %d 项断言全部通过（装载/走位耗时/取线索/跨遍保留/遗忘/快进/对话追问/世界递进/跨轮记忆/推演板与矛盾高亮/卡关预警/一键重演/画符结案/画面层接线）" % _checks)
		quit(0)
	else:
		print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_checks - _failures.size(), _failures.size(), _checks])
		for failure in _failures:
			print("  ✗ %s" % failure)
		print("RESULT: FAIL slice_hud 试玩 %d 项不通过" % _failures.size())
		quit(1)
