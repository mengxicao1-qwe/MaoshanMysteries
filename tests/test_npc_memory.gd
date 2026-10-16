extends SceneTree
## 测试：NPC 跨轮记忆（npc_memory.gd）+ 世界状态递进（loop_mutation.gd）—— M1 第③步的唯一空白差异位。
##
## 运行：godot --headless --path . --script res://tests/test_npc_memory.gd
##
## 覆盖：
##  1) loop_mutation：吃 CaseData / 原始 Dictionary 两种形状；grow 逐遍递增且每遍重算不累积
##  2) loop_mutation：shrink 逐遍递减，硬性下限 0（绝不出现负数）
##  3) loop_mutation：坏数据给 error（含房间 id 拼写建议）；未配置时无任何残留
##  4) npc_memory：内联规则 —— 无线索 stage=0 / 线索到手立刻抬阶 + describe 变 / 遍数不到下限不抬阶 /
##     退回上一遍时阶跟着降（不累积）/ reset 只清遍数不清线索 / 坏数据给 error、缺对话只给 warning
##  5) npc_memory：案一真实数据 —— 能解析、0 error、≥4 名 NPC 有台阶、一条线索就能抬阶、第 9 遍的察觉阶
##  6) 不订阅（无头测试环境）也能全绿：手动 set_loop_index / on_loop_reset 与订阅入口互不干扰
##
## 本测试【不依赖 Autoload】【不写 user://】；两个组件都用注入（SceneTree 里没有 /root/TimeLoopManager）。

const LoopMutation = preload("res://scripts/entities/loop_mutation.gd")
const NpcMemory = preload("res://scripts/entities/npc_memory.gd")
const CaseLoader = preload("res://scripts/data/case_loader.gd")
const PersistentMemoryManagerScript = preload("res://scripts/core/persistent_memory_manager.gd")

const CASE_PATH: String = "res://data/scenarios/case_01_baihu.json"
const MEMORY_PATH: String = "res://data/npc_memory/case_01_memory.json"

## 期待执行的断言总数（漏执行即判 FAIL）—— 改动测试后必须同步这个数。
const EXPECTED_CHECKS: int = 130

var _passed: int = 0
var _failed: int = 0
var _executed: int = 0
var _instances: Array = []
var _json_error: String = ""


func _initialize() -> void:
	print("=== NPC 跨轮记忆 / 世界状态递进 测试 ===")
	print("--- 1. loop_mutation：grow（案一真实数据，两种输入形状）---")
	_test_mutation_grow_real_data()
	print("--- 2. loop_mutation：shrink（内联，下限 0）---")
	_test_mutation_shrink()
	print("--- 3. loop_mutation：坏数据 / 未配置无残留 ---")
	_test_mutation_bad_data()
	print("--- 4. npc_memory：内联规则（单元断言）---")
	_test_memory_inline()
	print("--- 5. npc_memory：案一真实数据（集成断言）---")
	_test_memory_real_data()
	print("--- 6. 不订阅也能全绿 / loop_reset 契约 ---")
	_test_no_subscription()

	var ok: bool = _failed == 0 and _executed >= EXPECTED_CHECKS
	if _executed < EXPECTED_CHECKS:
		_failed += 1
		printerr("  [FAIL] 只执行了 %d 项断言（EXPECTED_CHECKS = %d）" % [_executed, EXPECTED_CHECKS])
	_cleanup()
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_passed, _failed, _executed])
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


# ---------------------------------------------------------------------------
# 1. loop_mutation：grow（真实数据）
# ---------------------------------------------------------------------------

func _test_mutation_grow_real_data() -> void:
	var text: String = _read_text(CASE_PATH)
	_check(text.length() > 0, "案一案件 JSON 读得到（%d 字节）" % text.length())
	var parsed: Dictionary = _parse_json(text, CASE_PATH)
	_check(not parsed.is_empty(), "案一 JSON 解析成功")
	var meta: Dictionary = parsed.get("meta", {})
	var secret: Dictionary = meta.get("secret", {})
	var raw: Variant = secret.get("per_loop_mutation", null)
	_check(raw is Dictionary, "meta.secret.per_loop_mutation 是字典")
	var mode_text: String = ""
	var note_text: String = ""
	if raw is Dictionary:
		mode_text = String((raw as Dictionary).get("mode", ""))
		note_text = String((raw as Dictionary).get("note", ""))
	_check(mode_text == "grow", "案一 mode = grow（第③步按这个口径跑）")

	# 形状 ①：原始 Dictionary（meta.secret.per_loop_mutation）
	var m_raw = _new_mutation()
	m_raw.configure(raw)
	_check(m_raw.get_mode() == "grow", "原始 Dictionary 形状：mode = %s" % m_raw.get_mode())
	_check(m_raw.is_ok(), "原始 Dictionary 形状 0 error（%d error / %d warning）"
		% [m_raw.get_errors().size(), m_raw.get_warnings().size()])
	_check(m_raw.get_warnings().is_empty(), "原始 Dictionary 形状 0 warning（房间/实体 id 全是真实数据）")
	_check(m_raw.get_max_level() == -1, "数据没写 max_level ⇒ 不封顶（-1）")
	_check(m_raw.is_affected("baihutai_bei"), "is_affected(baihutai_bei) = true")
	_check(not m_raw.is_affected("village_office"), "is_affected(village_office) = false（没被波及的房间）")
	var rooms_raw: Array = m_raw.get_affected_rooms()
	_check(rooms_raw.size() == 3 and rooms_raw.has("baihutai_bei") and rooms_raw.has("baihutai_yang")
		and rooms_raw.has("phone"), "affected_rooms = 3 间：%s" % str(rooms_raw))
	_check(m_raw.get_note() == note_text and note_text.length() > 0, "note 中文说明原样读出")

	# 形状 ②：case_loader.gd 的 CaseData
	var case_data: Variant = CaseLoader.load_case(CASE_PATH)
	_check(case_data != null and case_data.ok, "case_loader 装载案一成功")
	var m_case = _new_mutation()
	m_case.configure(case_data)
	_check(m_case.is_ok(), "CaseData 形状同样吃下（mode = %s）" % m_case.get_mode())
	_check(m_case.get_state()["rooms"].size() == 3, "CaseData 形状：get_state().rooms 计 3 间")
	_check(m_case.base_count("baihutai_bei") == 2, "baihutai_bei 基础数 2（4 条实体按序轮转归房）")
	_check(m_case.base_count("baihutai_yang") == 1, "baihutai_yang 基础数 1")
	_check(m_case.base_count("phone") == 1, "phone 基础数 1")
	_check(m_case.total_entity_count() == 4, "第 1 遍（level 0）合计 4 处")

	var levels: Array = []
	var monotonic: bool = true
	var counts_ok: bool = true
	var lists_ok: bool = true
	for i in 10:
		m_case.apply_loop(i)
		levels.append(m_case.get_level())
		if m_case.get_level() != i:
			monotonic = false
		if m_case.entity_count("baihutai_bei") != 2 + i:
			counts_ok = false
		if m_case.list_entities("baihutai_bei").size() != m_case.entity_count("baihutai_bei"):
			lists_ok = false
	_check(levels == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], "grow：level 随 loop_index 逐遍 +1：%s" % str(levels))
	_check(monotonic, "grow：level 单调递增（10 遍全对）")
	_check(counts_ok, "grow：entity_count = 基础数 + level（baihutai_bei 2→11）")
	_check(lists_ok, "list_entities().size() 恒等于 entity_count()")
	_check(m_case.total_entity_count() == 31, "第 10 遍合计 4 + 9×3 = 31 处（level 是每间房各加一遍），实际 %d" % m_case.total_entity_count())
	_check(m_case.describe().find("第 10 遍") >= 0, "describe() 给出当前遍：%s" % m_case.describe())

	m_case.apply_loop(0)
	_check(m_case.total_entity_count() == 4, "回到第 1 遍 ⇒ 每遍重算、不累积（4 处，不是 22）")
	_check(m_case.get_state()["level"] == 0, "get_state().level 跟着回到 0")

	# 无残留：新实例吃同一份数据、同一个遍数 ⇒ 快照逐字相同
	var fresh = _new_mutation()
	fresh.configure(case_data)
	_check(str(fresh.get_state()) == str(m_case.get_state()),
		"同一份数据 + 同一个遍数 ⇒ 两个实例的 get_state() 逐字相同（没有任何上一遍残留）")


# ---------------------------------------------------------------------------
# 2. loop_mutation：shrink
# ---------------------------------------------------------------------------

func _test_mutation_shrink() -> void:
	var rules: Dictionary = {
		"mode": "shrink",
		"affected_rooms": ["stele_base", "stone_steps"],
		"affected_entities": [
			{"id": "incense_ash", "room": "stele_base", "base": 3},
			{"id": "loose_stone", "room": "stele_base"},
			{"id": "grey_bag", "room": "stone_steps"},
			{"id": "joss_paper", "room": "stone_steps", "base": 2},
		],
		"max_level": 5,
		"note": "被翻回去的页越翻越薄：每多走一遍，碑座上就少一样东西",
	}
	var m = _new_mutation()
	m.configure(rules)
	_check(m.get_mode() == "shrink", "内联 shrink：mode = shrink")
	_check(m.is_ok(), "内联 shrink：0 error（%d error）" % m.get_errors().size())
	_check(m.get_max_level() == 5, "max_level 取数据里的 5")
	_check(m.base_count("stele_base") == 4, "stele_base 基础数 = 3 + 1 = 4")
	_check(m.base_count("stone_steps") == 3, "stone_steps 基础数 = 1 + 2 = 3")
	_check(m.total_entity_count() == 7, "第 1 遍合计 7 项")

	var counts: Array = []
	var floors_ok: bool = true
	for i in 8:
		m.apply_loop(i)
		counts.append(m.entity_count("stele_base"))
		if m.entity_count("stele_base") < 0 or m.entity_count("stone_steps") < 0:
			floors_ok = false
	_check(counts == [4, 3, 2, 1, 0, 0, 0, 0], "shrink：基础数 − level，到 0 就停住：%s" % str(counts))
	_check(floors_ok, "shrink 的 entity_count 绝不为负（含越界遍数）")
	_check(m.get_level() == 5, "遍数超过 max_level ⇒ level 封顶在 5")
	_check(m.total_entity_count() == 0, "第 8 遍两间房都空了：%d 项" % m.total_entity_count())
	_check(m.list_entities("stele_base").is_empty(), "空房间的 list_entities() 是空数组")
	m.apply_loop(0)
	_check(m.list_entities("stele_base").size() == 4, "回到第 1 遍 ⇒ 4 项全在（每遍重算，不是单向消耗）")
	_check(m.describe().find("余页缺损") >= 0, "shrink 的 describe() 用'余页缺损'口径：%s" % m.describe())


# ---------------------------------------------------------------------------
# 3. loop_mutation：坏数据
# ---------------------------------------------------------------------------

func _test_mutation_bad_data() -> void:
	var empty = _new_mutation()
	empty.configure({})
	_check(not empty.is_configured(), "configure({}) ⇒ 未配置")
	_check(not empty.is_ok(), "configure({}) ⇒ 报 error：%s" % empty.error_summary())
	_check(empty.get_state()["rooms"].is_empty(), "坏数据下 get_state().rooms 为空（无残留）")
	_check(empty.get_mode() == "" and empty.get_level() == 0, "未配置时 mode 空、level 0（不瞎猜）")

	var no_mutation = _new_mutation()
	no_mutation.configure({"meta": {"secret": {"kind": "inscribed_name"}}})
	_check(no_mutation.is_configured() and not no_mutation.is_ok(), "secret 在、缺 per_loop_mutation ⇒ 已配置但报 error")
	_check(no_mutation.describe().find("无异变") >= 0, "缺 per_loop_mutation 的 describe()：%s" % no_mutation.describe())

	var bad_mode = _new_mutation()
	bad_mode.configure({"mode": "sideways", "affected_rooms": ["stele_base"], "affected_entities": ["x"]})
	_check(bad_mode.get_errors().size() > 0, "未知 mode 报 error")
	_check(bad_mode.error_summary().find("sideways") >= 0, "error 文本带上写错的 mode：%s" % bad_mode.error_summary())

	# 真实案件的 meta.rooms 表 + 一个拼错的房间 id ⇒ 编辑距离拼写建议（照 tools/validate_data.gd 的做法）
	var parsed: Dictionary = _parse_json(_read_text(CASE_PATH), CASE_PATH)
	var typo: Dictionary = parsed.duplicate(true)
	var mutation: Dictionary = typo["meta"]["secret"]["per_loop_mutation"]
	mutation["affected_rooms"] = ["baihutai_bie"]
	var m_typo = _new_mutation()
	m_typo.configure(typo)
	_check(not m_typo.is_ok(), "affected_rooms 写错 ⇒ error")
	_check(m_typo.error_summary().find("不在案件 meta.rooms 里") >= 0, "error 说明错在哪：%s" % m_typo.error_summary())
	_check(m_typo.error_summary().find("baihutai_bei") >= 0, "error 给出拼写建议（baihutai_bie → baihutai_bei）")


# ---------------------------------------------------------------------------
# 4. npc_memory：内联规则（单元断言）
# ---------------------------------------------------------------------------

func _test_memory_inline() -> void:
	var rules: Dictionary = {
		"meta": {"case_id": 1},
		"npcs": [
			{
				"npc_id": "npc_test_muqing",
				"display_name": "测试穆青",
				"rules": [
					{
						"require_clues": ["clue_a"],
						"require_min_loop": 0,
						"extra_dialogue_id": "dlg_a",
						"note": "第一阶：认得你手里刚拿到的东西",
					},
					{
						"require_clues": ["clue_a", "clue_b"],
						"require_min_loop": 2,
						"extra_dialogue_id": "dlg_b",
						"reveal_clue_id": "clue_c",
						"note": "第二阶：第三遍起主动摊开拓本",
					},
				],
			},
			{
				"npc_id": "npc_test_keeper",
				"display_name": "测试守碑人",
				"rules": [
					{
						"require_clues": [],
						"require_min_loop": 5,
						"extra_dialogue_id": "dlg_loop",
						"note": "只靠遍数：第六遍起他先开口",
					},
				],
			},
		],
	}
	var options: Dictionary = {
		"clue_ids": ["clue_a", "clue_b", "clue_c"],
		"dialogue_ids": ["dlg_a", "dlg_b", "dlg_loop"],
		"known_npcs": ["npc_test_muqing", "npc_test_keeper"],
	}
	var memory = _new_memory()
	var memo = _new_npc_memory()
	memo.configure_with_rules(rules, options)
	memo.set_memory_manager(memory)
	_check(memo.is_ok(), "内联规则 0 error（%d error / %d warning）"
		% [memo.get_errors().size(), memo.get_warnings().size()])
	_check(memo.get_warnings().is_empty(), "内联规则 0 warning（clue/dialogue 登记表都给了）")
	_check(memo.get_npc_ids().size() == 2 and memo.total_rule_count() == 3, "覆盖 2 个 NPC / 3 条规则")
	_check(memo.get_max_stage("npc_test_muqing") == 2, "穆青的阶上限 = 2（两条台阶）")

	# --- 无线索：全员 0 阶 ---
	_check(memo.get_stage("npc_test_muqing") == 0, "无线索时 stage = 0（这一遍他仍是第一次见你）")
	_check(memo.get_stage("npc_test_keeper") == 0, "只有遍数条件的 NPC 在第 1 遍也是 0")
	_check(memo.list_changed_npcs().is_empty(), "list_changed_npcs() 为空")
	var d0: String = memo.describe("npc_test_muqing")
	_check(d0.find("记忆阶 0/2") >= 0, "describe() 无线索时：%s" % d0)

	# --- 线索到手 ⇒ 立刻抬阶（只读 memory，不落盘、不新增持久状态）---
	memory.add_clue("clue_a", 0)
	_check(memo.get_stage("npc_test_muqing") == 1, "add_clue 后 stage 立刻 = 1（无需手动 refresh）")
	var d1: String = memo.describe("npc_test_muqing")
	_check(d1 != d0 and d1.find("记忆阶 1/2") >= 0, "describe() 跟着变：%s" % d1)
	_check(memo.list_changed_npcs().has("npc_test_muqing"), "list_changed_npcs() 收录穆青")
	var effects1: Dictionary = memo.get_effects("npc_test_muqing")
	_check(String(effects1.get("extra_dialogue_id", "")) == "dlg_a", "第 1 阶效果 extra_dialogue_id = dlg_a")
	_check(String(effects1.get("reveal_clue_id", "")) == "", "第 1 阶 reveal_clue_id 为空")
	_check(String(effects1.get("note", "")).length() > 0, "第 1 阶 note 是中文说明")
	_check(memo.get_effects("npc_test_muqing").size() == 3, "get_effects() 恒返回三个键")

	# --- 线索齐了但遍数不到下限 ⇒ 停在第 1 阶 ---
	memory.add_clue("clue_b", 0)
	_check(memo.get_stage("npc_test_muqing") == 1,
		"线索齐了但 loop 0 < require_min_loop 2 ⇒ 仍停在第 1 阶（%d）" % memo.get_stage("npc_test_muqing"))
	var changed: int = memo.apply_loop(2)
	_check(memo.get_stage("npc_test_muqing") == 2, "loop = 2 ⇒ 上到第 2 阶")
	_check(changed == 1, "apply_loop(2) 返回本次变化的 NPC 数 = 1（实际 %d）" % changed)
	_check(String(memo.get_effects("npc_test_muqing").get("reveal_clue_id", "")) == "clue_c",
		"第 2 阶声明可交出 clue_c")
	var reveals: Array = memo.get_reveal_clue_ids()
	_check(reveals.size() == 1 and reveals.has("clue_c"), "get_reveal_clue_ids() = %s" % str(reveals))
	_check(memo.get_state()["stages"]["npc_test_muqing"] == 2, "get_state().stages 同步")

	# --- 只靠遍数的台阶 ---
	_check(memo.get_stage("npc_test_keeper") == 0, "loop 2 < 5 ⇒ 守碑人仍是 0")
	memo.apply_loop(5)
	_check(memo.get_stage("npc_test_keeper") == 1, "loop 5 ⇒ 守碑人上到第 1 阶（无需任何线索）")

	# --- 退回上一遍：阶必须跟着降（只反映当下，不累积"曾经到过第几阶"）---
	memo.apply_loop(0)
	_check(memo.get_stage("npc_test_muqing") == 1, "回到 loop 0 ⇒ 阶退回 1")
	_check(memo.get_stage("npc_test_keeper") == 0, "回到 loop 0 ⇒ 守碑人退回 0")

	# --- reset()：清遍数缓存，但绝不动 PersistentMemoryManager ---
	memo.reset()
	_check(memo.get_loop_index() == 0 and memo.get_stage("npc_test_muqing") == 1,
		"reset() 回第 1 遍后按当前线索重算 = 1（%d）" % memo.get_stage("npc_test_muqing"))
	_check(memory.has_clue("clue_a") and memory.has_clue("clue_b"), "reset() 没碰 PersistentMemoryManager（线索还在）")
	_check(memo.get_state()["memory_connected"] == true, "get_state().memory_connected = true")
	_check(memo.refresh() == 0, "状态没变时 refresh() 返回 0")

	# --- 坏数据：error（含拼写建议）；缺对话文件只给 warning ---
	var bad: Dictionary = {
		"npcs": [
			{
				"npc_id": "npc_bad",
				"rules": [
					{
						"require_clues": ["clue_ab"],
						"require_min_loop": 0,
						"extra_dialogue_id": "dlg_missing",
						"note": "引用了不存在的线索",
					},
					{
						"require_clues": "clue_a",
						"require_min_loop": -3,
						"extra_dialogue_id": 123,
						"note": "字段类型全写错",
					},
					{"require_clues": [], "require_min_loop": 0, "note": "没有任何效果"},
				],
			},
			{
				"npc_id": "npc_bad",
				"rules": [{"require_clues": [], "require_min_loop": 1, "extra_dialogue_id": "dlg_a", "note": "重复定义"}],
			},
		],
	}
	var m_bad = _new_npc_memory()
	m_bad.configure_with_rules(bad, {
		"clue_ids": ["clue_a", "clue_b", "clue_c"],
		"dialogue_ids": ["dlg_a"],
		"known_npcs": ["npc_test_muqing"],
	})
	_check(not m_bad.is_ok(), "坏数据 ⇒ 有 error（%d 条）" % m_bad.get_errors().size())
	_check(m_bad.error_summary().find("clue_ab") >= 0, "未知 clue_id 报 error")
	_check(m_bad.error_summary().find("是否想写") >= 0, "未知 clue_id 带编辑距离拼写建议：%s" % m_bad.error_summary())
	_check(m_bad.error_summary().find("extra_dialogue_id 必须是字符串") >= 0, "数字 extra_dialogue_id ⇒ error（必须字符串）")
	_check(m_bad.error_summary().find("没有任何效果") >= 0, "没有任何效果的规则 ⇒ error")
	_check(m_bad.error_summary().find("重复定义") >= 0, "同一 NPC 重复登记 ⇒ error")
	_check(m_bad.get_stage("npc_bad") == 0, "坏规则不计入阶数（%d）" % m_bad.get_stage("npc_bad"))
	_check(m_bad.get_max_stage("npc_bad") == 0, "坏规则全被丢掉后阶上限 = 0（%d）" % m_bad.get_max_stage("npc_bad"))
	_check(m_bad.get_state()["rule_count"] == 0, "get_state().rule_count 只算留下来的规则")
	_check(m_bad.get_warnings().size() > 0, "同类软问题只给 warning（%d 条）：%s"
		% [m_bad.get_warnings().size(), str(m_bad.get_warnings())])


# ---------------------------------------------------------------------------
# 5. npc_memory：案一真实数据
# ---------------------------------------------------------------------------

func _test_memory_real_data() -> void:
	var text: String = _read_text(MEMORY_PATH)
	_check(text.length() > 0, "案一记忆规则文件存在（%d 字节）" % text.length())
	var parsed: Dictionary = _parse_json(text, MEMORY_PATH)
	_check(not parsed.is_empty(), "记忆规则 JSON 解析成功")
	_check(int(float(parsed.get("meta", {}).get("case_id", -1))) == 1, "meta.case_id = 1（1 基）")

	var memory = _new_memory()
	var memo = _new_npc_memory()
	memo.set_memory_manager(memory)
	memo.configure(1)
	_check(memo.is_configured(), "configure(1) 装载成功：%s" % memo.get_source())
	_check(memo.is_ok(), "真实规则 0 error（%d error）" % memo.get_errors().size())
	_check(memo.get_warnings().is_empty(), "真实规则 0 warning（clue_id / extra_dialogue_id 全部真实存在）")
	_check(memo.get_clue_registry_size() >= 10, "线索登记表读到 %d 条 id" % memo.get_clue_registry_size())

	var npc_ids: Array = memo.get_npc_ids()
	_check(npc_ids.size() >= 4, "覆盖 %d 名 NPC（要求 ≥ 4）" % npc_ids.size())
	for required_id in ["npc_01_muqing", "npc_01_gan_fengyi", "npc_01_zheng_shoulu"]:
		_check(npc_ids.has(required_id), "含 %s（%s）" % [required_id, memo.get_display_name(required_id)])
	_check(memo.total_rule_count() >= npc_ids.size(), "规则条数 %d ≥ NPC 数 %d" % [memo.total_rule_count(), npc_ids.size()])

	var all_zero: bool = true
	for npc_id in npc_ids:
		if memo.get_stage(npc_id) != 0:
			all_zero = false
	_check(all_zero, "开局（0 线索 + 第 1 遍）⇒ 所有 NPC 的记忆阶都是 0")
	_check(memo.list_changed_npcs().is_empty(), "开局 list_changed_npcs() 为空")

	# 一条线索就能立刻抬阶（差异位的核心行为；线索顺序按登记表真实顺序）
	var clue_ids: Array = _clue_ids_from_registry(1)
	_check(clue_ids.size() >= 10, "data/clues/case_01_clues.json 读到 %d 条线索 id" % clue_ids.size())
	var raised_npc: String = ""
	var raised_clue: String = ""
	for clue_id in clue_ids:
		memory.add_clue(String(clue_id), 0)
		var changed_npcs: Array = memo.list_changed_npcs()
		if not changed_npcs.is_empty():
			raised_npc = String(changed_npcs[0])
			raised_clue = String(clue_id)
			break
	_check(raised_npc != "", "真实数据：持有某条线索后立刻有 NPC 抬阶（%s ← %s）" % [raised_npc, raised_clue])
	_check(int(memo.get_state()["stages"].get(raised_npc, 0)) > 0, "%s 抬阶后：%s" % [raised_npc, memo.describe(raised_npc)])
	_check(String(memo.get_effects(raised_npc).get("extra_dialogue_id", "")) != "",
		"抬阶的 NPC 给出了额外台词 id：%s" % str(memo.get_effects(raised_npc).get("extra_dialogue_id", "")))

	# 遍数下限：周长庚的察觉台阶只认遍数（第 9 遍起）
	_check(memo.get_stage("npc_01_zhou_changgeng") == 0, "周长庚在第 1 遍 stage = 0（遍数没到）")
	memo.apply_loop(8)
	_check(memo.get_stage("npc_01_zhou_changgeng") >= 1,
		"走到第 9 遍 ⇒ 周长庚抬阶：%s" % memo.describe("npc_01_zhou_changgeng"))

	# 无残留：两个独立实例（同一份线索 + 同一个遍数）算出逐字相同的快照
	var memo_b = _new_npc_memory()
	memo_b.set_memory_manager(memory)
	memo_b.configure(1)
	memo_b.apply_loop(8)
	var state_a: Dictionary = memo.get_state()
	var state_b: Dictionary = memo_b.get_state()
	_check(str(state_a["stages"]) == str(state_b["stages"]),
		"两个独立实例算出同一份 stages ⇒ 没有隐藏的历史状态")
	_check(str(state_a["effects"]) == str(state_b["effects"]), "两个独立实例的各项效果逐字相同（无上一遍残留）")

	memo_b.reset()
	_check(memo_b.get_loop_index() == 0 and memo_b.get_stage("npc_01_zhou_changgeng") == 0,
		"reset() 回第 1 遍 ⇒ 恰在遍数门槛上的那一阶立刻退回 0")

	_check(memo.is_clue_known("clue_01_bowl_bottom"), "规则里 reveal 的 clue_01_bowl_bottom 在登记表里")
	_check(int(memo.get_state()["dialogue_registry_size"]) >= 4,
		"对话登记表读到 %d 条 id" % int(memo.get_state()["dialogue_registry_size"]))
	_check(memo.get_state()["npc_count"] == npc_ids.size(), "get_state().npc_count 与 get_npc_ids() 一致")
	_check(memo.describe("npc_01_muqing").find("穆青") >= 0, "describe() 用中文名：%s" % memo.describe("npc_01_muqing"))


# ---------------------------------------------------------------------------
# 6. 不订阅也能全绿 / loop_reset 契约
# ---------------------------------------------------------------------------

func _test_no_subscription() -> void:
	# ① auto_subscribe 默认 true，但组件不挂树 ⇒ 不订阅、不报错、查询照常
	var lazy = _new_npc_memory(true)
	_check(lazy.auto_subscribe == true, "auto_subscribe 默认 true（挂进场景树才会真的去订阅）")
	_check(not lazy.is_inside_tree(), "本测试不把组件挂进场景树")
	lazy.configure(1)
	lazy.set_memory_manager(_new_memory())
	_check(lazy.is_ok(), "不挂树 / 不订阅：configure(1) 照样 0 error（测试不依赖 Autoload）")
	_check(lazy.get_stage("npc_01_muqing") == 0, "不订阅也能查询 stage")
	lazy.apply_loop(8)
	_check(lazy.get_stage("npc_01_zhou_changgeng") == 1, "不订阅也能手动 apply_loop(8)（%d）"
		% lazy.get_stage("npc_01_zhou_changgeng"))

	# ② 订阅入口：环境里有没有 /root/TimeLoopManager 都不许崩（测试环境通常没有）
	var env_has_manager: bool = root.has_node("TimeLoopManager")
	var probe = _new_npc_memory()
	probe.configure(1)
	var connected: bool = probe.subscribe_loop_manager()
	_check(connected == env_has_manager, "subscribe_loop_manager() 与环境一致（场景树里有 TimeLoopManager = %s）"
		% str(env_has_manager))
	_check(env_has_manager or probe.get_warnings().size() > 0, "订阅失败时留下 warning，不静默（%d 条）"
		% probe.get_warnings().size())
	probe.on_loop_started(3)
	_check(probe.get_loop_index() == 3, "手动 on_loop_started(3) ⇒ 第 4 遍（不依赖订阅）")

	# ③ 09:17 契约：loop_reset 清掉"仅属于上一遍的世界状态"，跨遍保留的线索不清
	var memory2 = _new_memory()
	var memo2 = _new_npc_memory()
	memo2.set_memory_manager(memory2)
	memo2.configure(1)
	memory2.add_clue("clue_01_four_in_three", 0)
	memo2.apply_loop(8)
	_check(memo2.get_stage("npc_01_muqing") >= 1, "第 9 遍时穆青已经抬阶：%s" % memo2.describe("npc_01_muqing"))
	memo2.on_loop_reset()
	_check(memo2.get_loop_index() == 0, "on_loop_reset() ⇒ loop_index 回 0")
	_check(memo2.get_stage("npc_01_zhou_changgeng") == 0, "on_loop_reset() 清掉只靠遍数成立的那一阶")
	_check(memo2.get_stage("npc_01_muqing") == 1, "跨遍保留的是'玩家知道了什么'：reset 后穆青仍是阶 1")


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_executed += 1
	if condition:
		_passed += 1
		print("  [PASS] %s" % label)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % label)


func _new_mutation():
	var node = LoopMutation.new()
	_instances.append(node)
	return node


func _new_npc_memory(auto_subscribe: bool = false):
	var node = NpcMemory.new()
	node.auto_subscribe = auto_subscribe
	_instances.append(node)
	return node


func _new_memory():
	var node = PersistentMemoryManagerScript.new()
	node.name = "TestMemory"
	_instances.append(node)
	return node


func _read_text(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("  [io] 读不到 %s" % path)
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _parse_json(text: String, where: String) -> Dictionary:
	_json_error = ""
	var json := JSON.new()
	var error: int = json.parse(text)
	if error != OK:
		_json_error = "%s 第 %d 行：%s" % [where, json.get_error_line() + 1, json.get_error_message()]
		printerr("  [json] %s" % _json_error)
		return {}
	var data: Variant = json.data
	if not (data is Dictionary):
		_json_error = "%s 顶层不是字典" % where
		printerr("  [json] %s" % _json_error)
		return {}
	return data


## 从 data/clues/case_NN_clues.json 抠出 clue_id（数组 / 字典两种形状都认）。
func _clue_ids_from_registry(case_id: int) -> Array:
	var path: String = "res://data/clues/case_%02d_clues.json" % case_id
	var parsed: Dictionary = _parse_json(_read_text(path), path)
	var result: Array = []
	var rows_value: Variant = parsed.get("clues", null)
	if rows_value is Array:
		for item in (rows_value as Array):
			if item is Dictionary:
				var clue_id: String = String((item as Dictionary).get("clue_id", ""))
				if not clue_id.is_empty():
					result.append(clue_id)
	elif rows_value is Dictionary:
		for key in (rows_value as Dictionary).keys():
			if key is String:
				result.append(key)
	return result


func _cleanup() -> void:
	for node in _instances:
		if is_instance_valid(node):
			node.free()
	_instances.clear()
