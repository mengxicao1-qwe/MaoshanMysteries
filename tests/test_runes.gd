extends SceneTree
## tests/test_runes.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的自带断言测试
##
## 覆盖（真数据 = `data/runes/case_01_runes.json`，只读不改）：
##   ① 装载：1 道符 / 5 步 / 3 笔 / 3 条近似笔 / **0 error 0 warning**（真数据硬要求）；
##   ② 交叉引用：`require_clues` 6 条全部能在 `data/clues/case_01_clues.json`（14 条）里找到；
##      案件 `meta.secret.resolve_conditions.require_ritual` 点得到本表的 rune_id；
##   ③ 门槛三维：线索不全 / 遍数不够 / 房间不对 ⇒ `is_available()` false、`can_start()` false；
##   ④ 真路径：三条门槛都满足 ⇒ `start_rune()` true、状态 step、逐步推进；
##   ⑤ 三笔按数据画对（`feed_token` 逐 token）⇒ status="ok"、drawn_strokes 增长、三笔完 step_done；
##   ⑥ 三条 near_miss 各命中一次，hint **原文**逐字比对；一条纯错笔 ⇒ 兜底文案；
##   ⑦ `undo_token()` / `undo_stroke()`；
##   ⑧ `choice` 选错不推进、选对推进 + `advance()` 在 choice 步返回 false；
##   ⑨ 整套仪式走到 `is_completed() == true`，且 `rune_completed` 信号真的发过；
##   ⑩ `reset()` 与 `loop_reset`（订阅 `/root/TimeLoopManager` 的相对解析）清状态；
##   ⑪ `get_state_snapshot()` 能 `JSON.stringify()`、`prompt_lines()` 行数 ≤ 参数且非空；
##   ⑫ 5 组错误夹具（repeat rune_id / 未知 kind / draw 无 strokes / choice 两个 correct / 未知 clue_id）
##      都要进 `errors`；1 组 warning 夹具（案件 require_ritual 对不上）只进 `warnings`。
##
## 约定（AGENTS.md §4）：`extends SceneTree` + `_initialize()` + `quit(code)`；
## 不写 `class_name`；末行唯一一行 `RESULT:`；**不落盘**（本测试绝不碰 `user://`）；
## `EXPECTED_CHECKS` 守护：实际执行数 < 期望 ⇒ FAIL（防止脚本中途出错却"全过"）。

const Loader = preload("res://scripts/data/rune_loader.gd")
const RuneInput = preload("res://scripts/entities/rune_input.gd")

const EXPECTED_CHECKS: int = 455

const RUNE_ID: String = "huizhao_songbei"
const SIX_CLUES: Array[String] = [
	"clue_01_four_in_three",
	"clue_01_half_stroke_cun",
	"clue_01_rubbing_fragment",
	"clue_01_stone_dust",
	"clue_01_three_sources_conflict",
	"clue_01_bowl_bottom",
]
const DRAW_STEP: String = "draw_the_reflection"
const CHOICE_STEP: String = "no_re_carving"
const ROOM: String = "baihutai_bei"
const MIN_LOOP: int = 8
## 时钟挂载点的名字（与 `rune_input.gd` 的 `LOOP_MANAGER_NAME` 一致；不写 Autoload 标识符）。
const LOOP_MANAGER_NAME: String = "TimeLoopManager"

var _passed: int = 0
var _failed: int = 0
var _executed: int = 0
var _failures: Array[String] = []
## 需要 free() 的 Node（末尾统一释放；本测试只造节点，不写盘）。
var _nodes: Array[Node] = []
## 被假时钟顶开的真 Autoload（`_finish()` 里原样放回）。
var _displaced_manager: Node = null


func _initialize() -> void:
	_test_load_real_data()
	_test_cross_reference()
	_test_availability_gates()
	_test_start_gates()
	_test_draw_three_strokes()
	_test_near_miss()
	_test_wrong_and_undo()
	_test_choice_step()
	_test_full_ritual()
	_test_reset_and_loop_reset()
	_test_snapshot_and_prompts()
	_test_memory_injection()
	_test_error_fixtures()
	_test_warning_fixtures()
	_finish()


# ============================================================================
#  ① 真数据装载
# ============================================================================

func _test_load_real_data() -> void:
	var table: Variant = Loader.load_for_case(1)
	_check(table != null, "load_for_case(1) 返回非空")
	_check_eq(table.schema_version, 1, "schema_version")
	_check_eq(table.case_id, 1, "case_id")
	_check_eq(table.case_title, "白鹄不举", "case_title")
	_check(table.purpose != "", "meta.purpose 非空")
	_check_str(table.path, "res://data/runes/case_01_runes.json", "path")
	_check_eq(table.count(), 1, "只 1 道符")
	_check(table.has_rune(RUNE_ID), "has_rune(huizhao_songbei)")
	_check(not table.has_rune("meiyou_zhe_dao"), "has_rune(不存在的符) = false")
	_check(table.get_rune("meiyou_zhe_dao") == null, "get_rune(不存在) = null")
	_check_same(table.rune_ids(), [RUNE_ID] as Array[String], "rune_order")
	_check_eq(table.total_steps(), 5, "5 步")
	_check_eq(table.total_strokes(), 3, "3 笔")
	_check_eq(table.total_near_miss(), 3, "3 条近似笔")
	_check_eq(table.errors.size(), 0, "真数据 0 error")
	_check_eq(table.warnings.size(), 0, "真数据 0 warning")
	_check(table.ok, "ok = true")
	_check_str(table.error, "", "error 空串")
	_check_str(table.error_summary(), "", "error_summary 空串")
	_check(table.describe().contains("1 道符"), "describe() 带符数")
	_check_eq(table.input_tokens.size(), 8, "八个方向 token")
	_check(table.input_tokens.has("down_right"), "token 含 down_right")
	_check_str(table.backspace_key, "KEY_BACKSPACE", "backspace_key")
	_check_str(table.commit_key, "KEY_ENTER", "commit_key")
	_check_eq(table.key_map.size(), 8, "key_map 八个方向")
	_check_eq(table.key_map_alt.size(), 4, "key_map_alt 四个斜向")
	_check_eq(table.clue_registry_size, 14, "线索台账 14 条")
	_check(table.case_ritual_checked, "做过 require_ritual 交叉引用")
	_check_str(table.case_require_ritual, RUNE_ID, "案件 require_ritual")
	_check(Loader.find_rune_path(1).ends_with("case_01_runes.json"), "find_rune_path(1)")
	_check_str(Loader.find_rune_path(99), "", "find_rune_path(99) = 空")
	_check(Loader.find_scenario_path(1).ends_with("case_01_baihu.json"), "find_scenario_path(1)")
	_check_eq(Loader.list_rune_files().size(), 1, "list_rune_files 1 个")
	_check_eq(Loader.load_known_clue_ids().size(), 14, "load_known_clue_ids 14 条")

	var rune: Variant = table.get_rune(RUNE_ID)
	_check_eq(rune.display_name, "回照诵碑（把阙文照回原样）", "display_name")
	_check_eq(rune.require_min_loop, MIN_LOOP, "require_min_loop = 8（整数没有被 float 化）")
	_check_str(rune.room, ROOM, "room")
	_check_str(rune.npc_id, "npc_01_gan_fengyi", "npc_id")
	_check_eq(rune.require_clues.size(), 6, "6 条 require_clues")
	_check_eq(rune.step_count(), 5, "rune.step_count = 5")
	_check_eq(rune.total_strokes(), 3, "rune.total_strokes = 3")
	_check_eq(rune.total_near_miss(), 3, "rune.total_near_miss = 3")
	_check_same(rune.step_ids(), [
		"spread_the_rubbing", DRAW_STEP, "let_her_read_it", CHOICE_STEP, "chant_to_the_end",
	] as Array[String], "五个 step_id")
	_check(rune.gate_note != "", "gate_note 非空")
	_check(rune.success_text != "", "success_text 非空")
	_check(rune.fail_text != "", "fail_text 非空")
	_check(rune.get_step("meiyou") == null, "get_step(不存在) = null")
	_check_eq(rune.get_step("let_her_read_it").kind, "npc", "第 3 步是 npc")
	_check(rune.get_step("let_her_read_it").is_npc(), "is_npc()")
	_check(rune.get_step("spread_the_rubbing").is_gate(), "is_gate()")
	_check(rune.get_step(DRAW_STEP).is_draw(), "is_draw()")
	_check(rune.get_step(CHOICE_STEP).is_choice(), "is_choice()")

	var draw: Variant = rune.get_step(DRAW_STEP)
	_check_eq(draw.stroke_count(), 3, "draw 步 3 笔")
	_check_eq(draw.near_miss.size(), 3, "draw 步 3 条近似笔")
	_check_eq(draw.index, 1, "draw 步是第 2 步（index 0 基）")
	_check_same(draw.strokes[0].pattern, ["right", "down", "left", "up"] as Array[String], "回")
	_check_same(draw.strokes[1].pattern, ["down", "down_right", "right", "down"] as Array[String], "照")
	_check_same(draw.strokes[2].pattern, ["right", "down", "right", "down"] as Array[String], "录")
	_check_eq(draw.strokes[0].name, "回", "第 1 笔名")
	_check_eq(draw.strokes[1].name, "照", "第 2 笔名")
	_check_eq(draw.strokes[2].name, "录", "第 3 笔名")
	_check_eq(draw.strokes[0].index, 0, "笔画 index 0 基")
	_check_eq(draw.strokes[2].index, 2, "第 3 笔 index = 2")
	_check_eq(draw.strokes[0].token_count(), 4, "每笔 4 画")
	_check(draw.strokes[0].note != "", "笔画有 note")
	_check(draw.describe().contains("3 笔"), "draw.describe()")
	_check(rune.describe().contains(RUNE_ID), "rune.describe()")


# ============================================================================
#  ② 交叉引用
# ============================================================================

func _test_cross_reference() -> void:
	var table: Variant = Loader.load_for_case(1)
	var known: Array[String] = Loader.load_known_clue_ids()
	var rune: Variant = table.get_rune(RUNE_ID)
	for clue_id in rune.require_clues:
		_check(known.has(clue_id), "require_clues 里的 %s 在台账里" % clue_id)
	_check_eq(rune.missing_clues(SIX_CLUES).size(), 0, "六条齐了 missing 为空")
	_check_eq(rune.missing_clues([]).size(), 6, "一条没有 missing 6 条")
	_check_eq(rune.missing_clues(["clue_01_stone_dust"]).size(), 5, "只给一条 missing 5 条")
	_check(rune.is_available(MIN_LOOP, SIX_CLUES), "is_available(8, 六条) = true")
	_check(not rune.is_available(MIN_LOOP, []), "is_available(8, 空) = false")


# ============================================================================
#  ③ 三种门槛
# ============================================================================

func _test_availability_gates() -> void:
	var table: Variant = Loader.load_for_case(1)
	var rune: Variant = table.get_rune(RUNE_ID)
	_check(not rune.is_available(7, SIX_CLUES), "遍数不够 ⇒ false")
	_check(rune.is_available(8, SIX_CLUES), "刚好第 8 遍 ⇒ true")
	_check(rune.is_available(20, SIX_CLUES), "超过第 8 遍 ⇒ true")
	_check(not rune.is_available(20, ["clue_01_stone_dust"]), "线索不全 ⇒ false")


# ============================================================================
#  ④ start_rune 的三条门槛（真数据路径）
# ============================================================================

func _test_start_gates() -> void:
	var table: Variant = Loader.load_for_case(1)

	# (a) 线索不全 + 遍数不够 + 房间不对：三样全错
	var one: Node = _make_input(table, true)
	_check(not one.is_configured() == false, "configure_with_table 成功")
	_check(one.is_ok(), "is_ok()")
	_check_eq(one.get_errors().size(), 0, "组件无 error")
	_check_eq(one.get_warnings().size(), 0, "组件无 warning")
	_check_str(one.get_state(), RuneInput.STATE_IDLE, "初始 idle")
	_check(not one.is_running(), "初始没在跑")
	_check(not one.can_start(RUNE_ID), "线索/遍数/房间全不满足 ⇒ can_start false")
	_check(not one.start_rune(RUNE_ID), "全不满足 ⇒ start_rune false")
	_check(one.get_last_message().contains("线索还差"), "提示线索还差几条")
	_check_eq(one.get_owned_clues().size(), 0, "owned 空")

	# (b) 只差遍数
	var two: Node = _make_input(table, true)
	two.set_owned_clues(SIX_CLUES)
	two.set_room(ROOM)
	two.set_loop_index(7)
	_check_eq(two.get_owned_clues().size(), 6, "六条线索已注入")
	_check(not two.can_start(RUNE_ID), "第 7 遍 ⇒ can_start false")
	_check(not two.start_rune(RUNE_ID), "第 7 遍 ⇒ start_rune false")
	_check(two.get_last_message().contains("第 8 遍"), "提示要第 8 遍")
	_check_eq(two.get_state(), RuneInput.STATE_IDLE, "起符失败仍是 idle")

	# (c) 只差房间
	var three: Node = _make_input(table, true)
	three.set_owned_clues(SIX_CLUES)
	three.set_loop_index(MIN_LOOP)
	three.set_room("baihutai_nan")
	_check(not three.can_start(RUNE_ID), "房间不对 ⇒ can_start false")
	_check(not three.start_rune(RUNE_ID), "房间不对 ⇒ start_rune false")
	_check(three.get_last_message().contains(ROOM), "提示指出正确房间")

	# (d) 三样都对 ⇒ 起符
	var four: Node = _make_input(table, true)
	four.set_owned_clues(SIX_CLUES)
	four.set_loop_index(MIN_LOOP)
	four.set_room(ROOM)
	_check(four.can_start(RUNE_ID), "三样都对 ⇒ can_start true")
	_check(four.start_rune(RUNE_ID), "三样都对 ⇒ start_rune true")
	_check_eq(four.get_state(), RuneInput.STATE_STEP, "起符后 state=step")
	_check(four.is_running(), "起符后 is_running")
	_check_str(four.get_current_rune_id(), RUNE_ID, "current_rune_id")
	_check_eq(four.get_step_index(), 0, "第 0 步")
	_check_eq(four.get_step_count(), 5, "共 5 步")
	_check_eq(four.get_current_step().step_id, "spread_the_rubbing", "当前是摊录步")
	_check_str(four.get_room(), ROOM, "get_room")
	_check_eq(four.get_loop_index(), MIN_LOOP, "get_loop_index")
	_check(four.get_last_message() != "", "起符时把 gate_note 记进 last_message")
	_check(four.describe().contains("第 1/5 步"), "describe() 报步数")
	_check(not four.can_start("meiyou_zhe_dao"), "没有这道符 ⇒ can_start false")
	_check(not four.start_rune("meiyou_zhe_dao"), "没有这道符 ⇒ start_rune false")
	_check(four.get_last_message().contains("meiyou_zhe_dao"), "提示点名缺失的符")

	# (e) 空 rune_id = 表里唯一那道符
	var five: Node = _make_input(table, true)
	five.set_owned_clues(SIX_CLUES)
	five.set_loop_index(MIN_LOOP)
	five.set_room(ROOM)
	_check(five.can_start(), "空 rune_id ⇒ 用表里唯一那道符")
	_check(five.start_rune(), "空 rune_id 起符成功")
	_check_str(five.get_current_rune_id(), RUNE_ID, "空 rune_id 解析成 huizhao_songbei")

	# (f) 房间为空则不校验房间
	var six: Node = _make_input(table, true)
	six.set_owned_clues(SIX_CLUES)
	six.set_loop_index(MIN_LOOP)
	_check(not six.can_start(RUNE_ID), "房间未指定 ≠ 符要求的房间 ⇒ false")
	var plain: Variant = _plain_entry()
	_check(plain.room == "", "内存夹具的符 room 为空")
	_check(plain.is_available(0, [] as Array), "room 为空的符 is_available 只看线索/遍数")


# ============================================================================
#  ⑤ 三笔按数据画对
# ============================================================================

func _test_draw_three_strokes() -> void:
	var input: Node = _running_input()
	_check_eq(input.get_current_step().kind, "gate", "先过 gate 步")
	_check(input.advance(), "gate 步 advance() 成功")
	_check_eq(input.get_current_step().step_id, DRAW_STEP, "进到 draw 步")
	_check_eq(input.current_stroke_index(), 0, "从第 0 笔起")
	_check_eq(input.current_tokens().size(), 0, "还没落笔 tokens 为空")
	_check_eq(input.drawn_strokes().size(), 0, "还没提交过笔")

	# 不在 drawing 就提交 = wrong
	var early: Dictionary = input.commit_stroke()
	_check(not early["ok"], "没起笔就提交 ⇒ ok false")
	_check_str(early["status"], RuneInput.STATUS_WRONG, "没起笔 ⇒ status wrong")
	_check(early["hint"] != "", "没起笔也给原因")
	_check(not input.feed_token("right"), "没起笔喂 token ⇒ false")

	input.begin_stroke()
	_check_eq(input.get_state(), RuneInput.STATE_DRAWING, "begin_stroke ⇒ drawing")
	_check(input.feed_token("right"), "喂 right 成功")
	_check(input.feed_token("down"), "喂 down 成功")
	_check(input.feed_token("left"), "喂 left 成功")
	_check(input.feed_token("up"), "喂 up 成功")
	_check(not input.feed_token("侧卧"), "未登记 token ⇒ false")
	_check_eq(input.current_tokens().size(), 4, "攒了 4 个 token")
	_check_same(input.current_tokens(), ["right", "down", "left", "up"] as Array[String], "第 1 笔 token 串")

	var first: Dictionary = input.commit_stroke()
	_check(first["ok"], "第 1 笔「回」提交成功")
	_check_str(first["status"], RuneInput.STATUS_OK, "第 1 笔 status=ok")
	_check_eq(first["stroke_index"], 0, "第 1 笔 stroke_index=0")
	_check_str(first["stroke_name"], "回", "第 1 笔名=回")
	_check_same(first["expected"], ["right", "down", "left", "up"] as Array[String], "expected 回填")
	_check_same(first["got"], ["right", "down", "left", "up"] as Array[String], "got 回填")
	_check_str(first["attempt_id"], "", "命中时 attempt_id 为空")
	_check(not first["step_done"], "第 1 笔完 step_done=false（还没到三笔）")
	_check_eq(input.current_stroke_index(), 1, "笔下标前进到 1")
	_check_eq(input.current_tokens().size(), 0, "提交后 token 串清空")
	_check_eq(input.drawn_strokes().size(), 1, "已提交 1 笔")
	_check_eq(input.get_state(), RuneInput.STATE_STEP, "一笔完回 step（不自动推进）")
	_check_eq(input.get_step_index(), 1, "仍停在第 2 步（draw）")

	# 第 2 笔「照」
	input.begin_stroke()
	for token in ["down", "down_right", "right", "down"]:
		_check(input.feed_token(token), "喂 %s 成功" % token)
	var second: Dictionary = input.commit_stroke()
	_check(second["ok"], "第 2 笔「照」提交成功")
	_check_str(second["stroke_name"], "照", "第 2 笔名=照")
	_check_eq(second["stroke_index"], 1, "第 2 笔 stroke_index=1")
	_check(not second["step_done"], "第 2 笔完 step_done=false")
	_check_eq(input.drawn_strokes().size(), 2, "已提交 2 笔")

	# 第 3 笔「录」
	input.begin_stroke()
	for token in ["right", "down", "right", "down"]:
		_check(input.feed_token(token), "喂 %s 成功" % token)
	var third: Dictionary = input.commit_stroke()
	_check(third["ok"], "第 3 笔「录」提交成功")
	_check_str(third["stroke_name"], "录", "第 3 笔名=录")
	_check_eq(third["stroke_index"], 2, "第 3 笔 stroke_index=2")
	_check(third["step_done"], "三笔都提交完 ⇒ step_done=true")
	_check_eq(input.current_stroke_index(), 3, "笔下标 = 3")
	_check_eq(input.drawn_strokes().size(), 3, "已提交 3 笔")
	_check_eq(input.get_step_index(), 1, "三笔完仍不自动推进")
	_check_same(input.drawn_strokes()[0], ["right", "down", "left", "up"] as Array[String], "drawn[0] = 回")
	_check_same(input.drawn_strokes()[2], ["right", "down", "right", "down"] as Array[String], "drawn[2] = 录")
	_check_eq(input.get_state(), RuneInput.STATE_STEP, "三笔完 state=step")
	_check(input.advance(), "三笔全对 ⇒ advance() 成功")
	_check_eq(input.get_step_index(), 2, "推进到第 3 步")
	_check_eq(input.get_current_step().step_id, "let_her_read_it", "第 3 步是 npc")
	_check_eq(input.drawn_strokes().size(), 0, "推进后本步绘制状态清零")


# ============================================================================
#  ⑥ 三条 near_miss + 一条纯错笔
# ============================================================================

func _test_near_miss() -> void:
	var input: Node = _draw_step_input()
	_check_eq(input.get_step_index(), 1, "已停在 draw 步")

	# nm_missing_dot：少一笔
	input.begin_stroke()
	for token in ["down", "down_right", "right"]:
		input.feed_token(token)
	var miss_one: Dictionary = input.commit_stroke()
	_check(not miss_one["ok"], "少一笔 ⇒ ok false")
	_check_str(miss_one["status"], RuneInput.STATUS_NEAR_MISS, "少一笔 ⇒ near_miss")
	_check_str(miss_one["attempt_id"], "nm_missing_dot", "attempt_id = nm_missing_dot")
	_check_str(miss_one["hint"], "少一笔——这正是那道半笔：石头上的'寸'就是缺了最后这一点，所以录上认不出这一手。",
		"nm_missing_dot 的 hint 原文照抄")
	_check_eq(input.drawn_strokes().size(), 0, "near_miss 不记入")
	_check_eq(input.current_stroke_index(), 0, "near_miss 不前进")
	_check_eq(input.current_tokens().size(), 3, "near_miss 后 token 串还在（可退可改）")

	# 退掉重来 → nm_extra_stroke：多一笔
	input.begin_stroke()
	for token in ["right", "down", "left", "up", "down"]:
		input.feed_token(token)
	var miss_two: Dictionary = input.commit_stroke()
	_check(not miss_two["ok"], "多一笔 ⇒ ok false")
	_check_str(miss_two["status"], RuneInput.STATUS_NEAR_MISS, "多一笔 ⇒ near_miss")
	_check_str(miss_two["attempt_id"], "nm_extra_stroke", "attempt_id = nm_extra_stroke")
	_check_str(miss_two["hint"], "多一笔——石头已经被凿过一次；再刻一次也是新的一手，是第二次篡改。",
		"nm_extra_stroke 的 hint 原文照抄")

	# nm_reversed：方向反了
	input.begin_stroke()
	for token in ["left", "up", "right", "down"]:
		input.feed_token(token)
	var miss_three: Dictionary = input.commit_stroke()
	_check(not miss_three["ok"], "反着画 ⇒ ok false")
	_check_str(miss_three["status"], RuneInput.STATUS_NEAR_MISS, "反着画 ⇒ near_miss")
	_check_str(miss_three["attempt_id"], "nm_reversed", "attempt_id = nm_reversed")
	_check_str(miss_three["hint"], "方向反了——你画的是别人那一手。辨笔先认手，再认字。",
		"nm_reversed 的 hint 原文照抄")
	_check_eq(input.drawn_strokes().size(), 0, "三次 near_miss 后一笔都没记入")


# ============================================================================
#  ⑦ 纯错笔 + 退 token / 退笔
# ============================================================================

func _test_wrong_and_undo() -> void:
	var input: Node = _draw_step_input()

	# 纯错笔：量对但方向全乱
	input.begin_stroke()
	for token in ["up", "up", "up", "up"]:
		input.feed_token(token)
	var wrong: Dictionary = input.commit_stroke()
	_check(not wrong["ok"], "纯错笔 ⇒ ok false")
	_check_str(wrong["status"], RuneInput.STATUS_WRONG, "纯错笔 ⇒ status wrong")
	_check_str(wrong["hint"], RuneInput.WRONG_HINT, "纯错笔用兜底文案")
	_check_str(wrong["attempt_id"], "", "纯错笔没有 attempt_id")
	_check_eq(input.drawn_strokes().size(), 0, "纯错笔不记入")

	# 量也不对（只有 2 画）
	input.begin_stroke()
	input.feed_token("right")
	input.feed_token("down")
	var short: Dictionary = input.commit_stroke()
	_check_str(short["status"], RuneInput.STATUS_WRONG, "画短了 ⇒ wrong（不匹配任何 near_miss）")
	_check_str(short["hint"], RuneInput.WRONG_HINT, "画短了用兜底文案")

	# 空 token 串提交
	input.begin_stroke()
	var empty: Dictionary = input.commit_stroke()
	_check(not empty["ok"], "空 token 串提交 ⇒ false")
	_check_str(empty["status"], RuneInput.STATUS_WRONG, "空 token 串 ⇒ wrong")
	_check(empty["hint"] != "", "空 token 串也说明原因")

	# 退 token
	input.begin_stroke()
	input.feed_token("right")
	input.feed_token("down")
	input.feed_token("left")
	_check_eq(input.current_tokens().size(), 3, "攒了 3 个")
	_check(not input.feed_token("sideways"), "喂未登记 token ⇒ false（且不改状态）")
	_check_eq(input.current_tokens().size(), 3, "未登记 token 没进串")
	_check(input.undo_token(), "退一个 token 成功")
	_check_eq(input.current_tokens().size(), 2, "剩 2 个")
	_check_same(input.current_tokens(), ["right", "down"] as Array[String], "退掉的是最后一个")
	_check(input.undo_token(), "再退一个成功")
	_check(input.undo_token(), "退到空再退一次成功")
	_check(not input.undo_token(), "空串再退 ⇒ false")
	_check_eq(input.current_tokens().size(), 0, "退干净了")

	# 退整笔
	input.begin_stroke()
	for token in ["right", "down", "left", "up"]:
		input.feed_token(token)
	_check(input.commit_stroke()["ok"], "第 1 笔提交成功")
	_check_eq(input.current_stroke_index(), 1, "前进到第 2 笔")
	_check(input.undo_stroke(), "退整笔成功")
	_check_eq(input.current_stroke_index(), 0, "退笔后下标回到 0")
	_check_eq(input.drawn_strokes().size(), 0, "退笔后已提交为空")
	_check_eq(input.current_tokens().size(), 4, "退笔把 token 装回串里（可改一画再描）")
	_check_eq(input.get_state(), RuneInput.STATE_DRAWING, "退笔后回到 drawing")
	input.undo_token()
	input.feed_token("down")
	_check(input.commit_stroke()["ok"] == false, "把回改成 right,down,left,down ⇒ 不匹配（变成错笔）")
	_check(input.undo_stroke() == false, "没有可退的笔 ⇒ false")

	# 退步推进后不能退
	var idle: Node = _make_input(Loader.load_for_case(1), true)
	_check(idle.undo_stroke() == false, "没起符时退笔 ⇒ false")
	_check(idle.undo_token() == false, "没起符时退 token ⇒ false")
	_check(idle.commit_stroke()["status"] == RuneInput.STATUS_WRONG, "没起符时提交 ⇒ wrong")
	_check(idle.commit_stroke()["hint"] == "还没开始画符。", "没起符时提交的提示原文")
	_check(idle.advance() == false, "没起符时 advance() ⇒ false")
	_check(idle.choose_option("keep_the_gap")["ok"] == false, "没起符时选项 ⇒ false")


# ============================================================================
#  ⑧ choice 步
# ============================================================================

func _test_choice_step() -> void:
	var input: Node = _choice_step_input()
	_check_eq(input.get_current_step().step_id, CHOICE_STEP, "已停在 choice 步")
	_check_eq(input.get_current_step().option_count(), 2, "两个选项")
	_check_str(input.get_current_step().correct_option_id(), "keep_the_gap", "正确选项 id")
	_check(input.get_current_step().get_option("carve_it_back") != null, "get_option 拿得到")
	_check(input.get_current_step().get_option("meiyou") == null, "get_option(不存在) = null")
	_check(not input.advance(), "choice 步 advance() ⇒ false（必须走 choose_option）")
	_check_eq(input.get_step_index(), 3, "advance() 失败不推进")

	# 选不存在
	var missing: Dictionary = input.choose_option("meiyou_zhe_ge")
	_check(not missing["ok"], "选不存在的选项 ⇒ false")
	_check_eq(input.get_step_index(), 3, "选不存在不推进")

	# 选错（carve_it_back：把字补刻回去）
	var bad: Dictionary = input.choose_option("carve_it_back")
	_check(not bad["ok"], "选错 ⇒ ok false")
	_check(not bad["correct"], "选错 ⇒ correct false")
	_check(not bad["step_done"], "选错 ⇒ step_done false")
	_check(bad["reply"] != "", "选错也给 reply（错的那句也念出来）")
	_check_eq(input.get_step_index(), 3, "**选错不推进**")
	_check_eq(input.get_current_step().step_id, CHOICE_STEP, "选错后还停在这一步")
	_check(input.get_last_message() != "", "选错把提示记进 last_message")

	# 选对（keep_the_gap：只把"残"记下来）
	var good: Dictionary = input.choose_option("keep_the_gap")
	_check(good["ok"], "选对 ⇒ ok true")
	_check(good["correct"], "选对 ⇒ correct true")
	_check(good["step_done"], "选对 ⇒ step_done true")
	_check_str(good["reply"], "原石既已残，我能做的只有把'残'这件事记下来。", "选对的 reply 原文")
	_check_eq(input.get_step_index(), 3, "choose_option 自己不推进（由 advance 推）")
	_check(input.advance(), "选对后 advance() 推进")
	_check_eq(input.get_step_index(), 4, "推进到第 5 步")
	_check_eq(input.get_current_step().step_id, "chant_to_the_end", "第 5 步是诵碑")


# ============================================================================
#  ⑨ 整套仪式走完
# ============================================================================

func _test_full_ritual() -> void:
	var input: Node = _running_input()
	var completed: Array[String] = []
	input.rune_completed.connect(func(rune_id: String) -> void: completed.append(rune_id))
	var states: Array[String] = []
	var steps: Array[String] = []
	input.rune_changed.connect(func(state: String) -> void: states.append(state))
	input.rune_step_changed.connect(func(step_id: String, _index: int, _total: int) -> void: steps.append(step_id))
	var strokes: Array = []
	input.rune_stroke_drawn.connect(func(index: int, tokens: Array) -> void: strokes.append([index, tokens]))

	# 1. gate：摊开原件
	_check_eq(input.get_current_step().step_id, "spread_the_rubbing", "第 1 步")
	_check(input.advance(), "gate 步推进")
	# 2. draw：三笔
	for pattern in [
		["right", "down", "left", "up"],
		["down", "down_right", "right", "down"],
		["right", "down", "right", "down"],
	]:
		input.begin_stroke()
		for token in pattern:
			input.feed_token(token)
		_check(input.commit_stroke()["ok"], "第 %d 笔对上" % (input.current_stroke_index() + 1))
	_check(input.advance(), "draw 步推进")
	# 3. npc：让她自己念
	_check_eq(input.get_current_step().step_id, "let_her_read_it", "第 3 步")
	_check(input.get_current_step().cost_text != "", "npc 步有 cost_text")
	_check(input.advance(), "npc 步推进")
	# 4. choice
	_check(input.choose_option("keep_the_gap")["ok"], "选对")
	_check(input.advance(), "choice 推进")
	# 5. npc：诵碑到底 ⇒ 完成
	_check_eq(input.get_current_step().step_id, "chant_to_the_end", "第 5 步")
	_check(not input.is_completed(), "还没完成")
	_check(input.advance(), "最后一步推进 ⇒ 完成")
	_check(input.is_completed(), "is_completed() = true")
	_check_str(input.get_state(), RuneInput.STATE_DONE, "state = done")
	_check_str(input.completed_rune_id(), RUNE_ID, "completed_rune_id")
	_check(not input.is_running(), "完成后 is_running() = false")
	_check_eq(completed.size(), 1, "rune_completed 信号发过 1 次")
	_check_str(completed[0], RUNE_ID, "rune_completed 带对 rune_id")
	_check(states.has(RuneInput.STATE_DRAWING), "rune_changed 广播过 drawing")
	_check(states.has(RuneInput.STATE_DONE), "rune_changed 广播过 done")
	# 起符时广播给"当时已连上"的人；本实例的 rune_step_changed 是起符之后才连的，
	# 所以只断言起符之后的两次广播（起符那一下由 rune_changed("step") 覆盖）。
	_check(states.has(RuneInput.STATE_STEP), "rune_changed 广播过 step（起符）")
	_check(steps.has("chant_to_the_end"), "rune_step_changed 广播过第 5 步")
	_check_eq(strokes.size(), 3, "rune_stroke_drawn 发过 3 次")
	_check_eq(int(strokes[0][0]), 0, "第 1 次笔画信号 index=0")
	_check_same(strokes[2][1], ["right", "down", "right", "down"] as Array[String], "第 3 次笔画信号带对 token")
	_check(not input.advance(), "完成后 advance() ⇒ false")
	_check_eq(input.get_state(), RuneInput.STATE_DONE, "完成后 state 不被 advance 改掉")


# ============================================================================
#  ⑩ reset() 与 loop_reset
# ============================================================================

func _test_reset_and_loop_reset() -> void:
	var table: Variant = Loader.load_for_case(1)

	# reset()：回到 idle，符表与线索不动
	var input: Node = _running_input()
	input.advance()
	input.begin_stroke()
	input.feed_token("right")
	_check_eq(input.get_state(), RuneInput.STATE_DRAWING, "reset 前在 drawing")
	input.reset()
	_check_eq(input.get_state(), RuneInput.STATE_IDLE, "reset 后 idle")
	_check(not input.is_running(), "reset 后没在跑")
	_check_str(input.get_current_rune_id(), "", "reset 后 rune_id 清空")
	_check_eq(input.get_owned_clues().size(), 6, "reset 不动线索")
	_check(input.is_ok(), "reset 不动符表")
	input.reset()
	_check_eq(input.get_state(), RuneInput.STATE_IDLE, "重复 reset 幂等")

	# loop_reset：挂上 /root/TimeLoopManager 的假时钟，发一次 loop_reset 就清状态
	var clock: Node = _make_loop_manager()
	var driven: Node = RuneInput.new()
	_nodes.append(driven)
	_check_eq(driven.get_state(), RuneInput.STATE_IDLE, "新节点初始 idle")
	root.add_child(driven)
	# 无头 SceneTree 的 root 在 `_initialize()` 期间还没进树，`_ready()` 不会自己跑；
	# 手动补一次"已就绪"通知，走的就是真实挂树时的那条订阅路径。
	driven.notification(Node.NOTIFICATION_READY)
	_check(driven.get_parent() == root, "挂进场景树（root 子节点）")
	driven.set_process(false)
	_check(driven.configure_with_table(table, {
		"auto_subscribe": true,
		"clues": SIX_CLUES,
		"room": ROOM,
		"loop_index": MIN_LOOP,
	}) as bool, "注入真表 + 三样门槛都满足")
	_check(driven.start_rune(RUNE_ID), "起符")
	driven.advance()
	_check_eq(driven.get_step_index(), 1, "推进到 draw 步")
	driven.begin_stroke()
	driven.feed_token("right")
	_check_eq(driven.current_tokens().size(), 1, "跨遍前攒了 1 个 token")
	_check(clock.has_signal("loop_reset"), "假时钟有 loop_reset 信号")
	_check_eq(clock.get_signal_connection_list("loop_reset").size(), 1, "input 订上了 loop_reset")
	clock.emit_signal("loop_reset", 9)
	_check_eq(driven.get_state(), RuneInput.STATE_IDLE, "loop_reset ⇒ 本遍绘制状态清零")
	_check_eq(driven.current_tokens().size(), 0, "loop_reset 清 token")
	_check_eq(driven.drawn_strokes().size(), 0, "loop_reset 清已提交的笔")
	_check(not driven.is_running(), "loop_reset 后没在跑")
	_check(driven.is_ok(), "loop_reset 不动符表")
	_check_eq(driven.get_owned_clues().size(), 6, "loop_reset 不动线索")

	# auto_subscribe=false：不订
	var lonely: Node = RuneInput.new()
	_nodes.append(lonely)
	lonely.auto_subscribe = false
	root.add_child(lonely)
	lonely.notification(Node.NOTIFICATION_READY)
	lonely.set_process(false)
	lonely.configure_with_table(table, {"auto_subscribe": false, "clues": SIX_CLUES, "room": ROOM, "loop_index": MIN_LOOP})
	_check_eq(clock.get_signal_connection_list("loop_reset").size(), 1, "auto_subscribe=false 不再多订一条")
	_check(lonely.start_rune(RUNE_ID), "不订阅的节点照样能起符")
	_check(lonely.advance(), "不订阅的节点照样能推进到 draw 步")
	clock.emit_signal("loop_reset", 10)
	_check_eq(lonely.get_step_index(), 1, "没订的节点不受 loop_reset 影响")
	_check(not (lonely.get_state() == RuneInput.STATE_IDLE), "没订的节点状态没被清零")


# ============================================================================
#  ⑪ 快照 / 提示行
# ============================================================================

func _test_snapshot_and_prompts() -> void:
	var input: Node = _draw_step_input()
	input.begin_stroke()
	input.feed_token("down")
	var snapshot: Dictionary = input.get_state_snapshot()
	_check_eq(String(snapshot["state"]), RuneInput.STATE_DRAWING, "快照 state")
	_check_str(String(snapshot["rune_id"]), RUNE_ID, "快照 rune_id")
	_check_eq(int(snapshot["step_index"]), 1, "快照 step_index")
	_check_eq(int(snapshot["step_count"]), 5, "快照 step_count")
	_check_str(String(snapshot["step_id"]), DRAW_STEP, "快照 step_id")
	_check_eq(int(snapshot["stroke_count"]), 3, "快照 stroke_count")
	_check_eq((snapshot["tokens"] as Array).size(), 1, "快照 tokens")
	_check(snapshot.has("drawn"), "快照带 drawn")
	_check(snapshot.has("owned_clues"), "快照带 owned_clues")
	_check(not snapshot.has("table"), "快照里没有 RuneTable（不可序列化的对象不进快照）")
	var encoded: String = JSON.stringify(snapshot)
	_check(encoded.length() > 2, "快照能 JSON.stringify")
	_check(encoded.contains(RUNE_ID), "序列化结果里有 rune_id")

	_check(prompt_lines_size(input) > 0, "drawing 时提示行非空")
	_check(prompt_lines_size(input) <= 6, "drawing 时提示行 ≤ 6")
	_check_eq(_count_lines(input.prompt_lines(2)), 2, "prompt_lines(2) 恰好 ≤ 2")
	_check_eq(_count_lines(input.prompt_lines(1)), 1, "prompt_lines(1) 恰好 1 行")
	_check_eq(_count_lines(input.prompt_lines(0)), 0, "prompt_lines(0) = 空")
	_check_eq(_count_lines(input.prompt_lines(-3)), 0, "prompt_lines(-3) = 空")
	_check(input.describe_step() != "", "describe_step() 非空")
	_check(input.describe().contains("已描"), "describe() 报已描笔数")

	var idle: Node = _make_input(Loader.load_for_case(1), true)
	_check(prompt_lines_size(idle) > 0, "未起符时提示行非空")
	_check(idle.describe().contains("未起符"), "未起符 describe()")
	var broken: Node = RuneInput.new()
	_nodes.append(broken)
	_check(not broken.is_configured(), "没配置时 is_configured false")
	_check(not broken.is_ok(), "没配置时 is_ok false")
	_check_eq(broken.get_step_count(), 0, "没配置时 step_count 0")
	_check(broken.prompt_lines(3).size() > 0, "没配置时也给一行说明")
	_check(broken.error_summary() != "", "没配置时 error_summary 非空")
	_check(not broken.configure_with_table(null), "注入 null 表 ⇒ false")
	_check(broken.get_errors().size() > 0, "注入 null 表 ⇒ 记了 error")
	_check(not broken.start_rune(""), "没配置时起符 ⇒ false")
	_check(broken.get_last_message() != "", "没配置时起符也留话")

	# 完成态的提示行
	var done_input: Node = _full_ritual_input()
	_check(done_input.is_completed(), "完成态")
	_check(done_input.prompt_lines(3).size() > 0, "完成态提示行非空")
	_check_eq(_count_lines(done_input.prompt_lines(1)), 1, "完成态 prompt_lines(1) = 1 行")


# ============================================================================
#  ⑫ 记忆注入
# ============================================================================

func _test_memory_injection() -> void:
	var table: Variant = Loader.load_for_case(1)
	var memory: Node = FakeMemory.new(SIX_CLUES)
	_nodes.append(memory)
	var input: Node = RuneInput.new()
	_nodes.append(input)
	input.set_process(false)
	_check(input.configure_with_table(table), "注入真表")
	_check(input.get_memory_manager() == null, "初始没有注入对象")
	input.set_memory_manager(memory)
	_check(input.get_memory_manager() == memory, "get_memory_manager 拿回同一个对象")
	_check_eq(input.get_owned_clues().size(), 6, "从对象的 get_available_clues() 读到 6 条")
	input.set_room(ROOM)
	input.set_loop_index(MIN_LOOP)
	_check(input.start_rune(RUNE_ID), "靠注入对象满足线索门槛")

	# 显式集合优先于注入对象
	input.set_owned_clues(["clue_01_stone_dust"])
	_check_eq(input.get_owned_clues().size(), 1, "显式集合覆盖注入对象")
	_check(not input.can_start(RUNE_ID), "显式集合不全 ⇒ false")
	input.set_owned_clues([] as Array)
	_check_eq(input.get_owned_clues().size(), 0, "显式空集合 = 一条都没有（不问注入对象）")

	# 新的一遍：注入对象换了内容，重新读
	var rich: Node = FakeMemory.new(SIX_CLUES)
	_nodes.append(rich)
	var fresh: Node = RuneInput.new()
	_nodes.append(fresh)
	fresh.set_process(false)
	fresh.configure_with_table(table)
	fresh.set_memory_manager(rich)
	_check_eq(fresh.get_owned_clues().size(), 6, "get_available_clues 口径")

	# 只有 has_clue() 的对象（谓词式接口）也能量出来
	var thin: Node = HasOnly.new(SIX_CLUES)
	_nodes.append(thin)
	var probe: Node = RuneInput.new()
	_nodes.append(probe)
	probe.set_process(false)
	probe.configure_with_table(table)
	probe.set_memory_manager(thin)
	_check_eq(probe.get_owned_clues().size(), 6, "has_clue() 兜底逐个问出来 6 条")
	probe.set_room(ROOM)
	probe.set_loop_index(MIN_LOOP)
	_check(probe.can_start(RUNE_ID), "兜底口径也能过线索门槛")

	# 注入 null 不清掉已有集合（防表现层传空）
	probe.set_memory_manager(null)
	_check(probe.get_memory_manager() == null, "可注入 null 解绑")


# ============================================================================
#  ⑬ 错误夹具（5 组）
# ============================================================================

func _test_error_fixtures() -> void:
	var tokens: Array = ["up", "down", "left", "right"]
	var base_steps: Array = [
		{"step_id": "one", "name": "摊", "kind": "gate", "text": "摊开。"},
		{
			"step_id": "two", "name": "照", "kind": "draw",
			"strokes": [{"name": "回", "pattern": ["right", "down", "left", "up"]}],
		},
	]

	# (1) rune_id 重复
	var fixture_one: Dictionary = {
		"meta": {"schema_version": 1, "case_id": 1, "case_title": "夹具"},
		"inputs": {"tokens": tokens, "key_map": {"up": "KEY_UP"}, "backspace_key": "KEY_BACKSPACE", "commit_key": "KEY_ENTER"},
		"runes": [
			{"rune_id": "same_id", "name": "甲", "require_clues": [], "require_min_loop": 0,
				"gate_note": "n", "room": "", "steps": base_steps},
			{"rune_id": "same_id", "name": "乙", "require_clues": [], "require_min_loop": 0,
				"gate_note": "n", "room": "", "steps": base_steps},
		],
	}
	var table_one: Variant = Loader.parse_dictionary(fixture_one, "res://data/runes/case_01_runes.json")
	_check(not table_one.ok, "夹具1：ok false")
	_check(_has_error(table_one, "rune_id 重复"), "夹具1：errors 里有 rune_id 重复")
	_check_eq(table_one.count(), 1, "夹具1：重复的那道不重复登记")

	# (2) 未知 kind
	var fixture_two: Dictionary = fixture_one.duplicate(true)
	fixture_two["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": [], "require_min_loop": 0,
			"gate_note": "n", "room": "",
			"steps": [{"step_id": "one", "name": "摊", "kind": "sing", "text": "唱。"}]},
	]
	var table_two: Variant = Loader.parse_dictionary(fixture_two, "res://data/runes/case_01_runes.json")
	_check(not table_two.ok, "夹具2：ok false")
	_check(_has_error(table_two, "不在 gate, draw, npc, choice"), "夹具2：errors 里有非法 kind")
	_check(_has_error(table_two, "sing"), "夹具2：错误信息点名 'sing'")

	# (3) draw 步没有 strokes
	var fixture_three: Dictionary = fixture_two.duplicate(true)
	fixture_three["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": [], "require_min_loop": 0,
			"gate_note": "n", "room": "",
			"steps": [{"step_id": "two", "name": "照", "kind": "draw", "text": "照。"}]},
	]
	var table_three: Variant = Loader.parse_dictionary(fixture_three, "res://data/runes/case_01_runes.json")
	_check(not table_three.ok, "夹具3：ok false")
	_check(_has_error(table_three, "draw 步没有 strokes"), "夹具3：errors 里有 draw 无 strokes")

	# (4) choice 两个 correct:true
	var fixture_four: Dictionary = fixture_two.duplicate(true)
	fixture_four["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": [], "require_min_loop": 0,
			"gate_note": "n", "room": "",
			"steps": [{"step_id": "four", "name": "择", "kind": "choice", "text": "择。",
				"options": [
					{"option_id": "a", "text": "甲", "correct": true, "reply": "甲"},
					{"option_id": "b", "text": "乙", "correct": true, "reply": "乙"},
				]}]},
	]
	var table_four: Variant = Loader.parse_dictionary(fixture_four, "res://data/runes/case_01_runes.json")
	_check(not table_four.ok, "夹具4：ok false")
	_check(_has_error(table_four, "correct:true 必须是恰好一个"), "夹具4：errors 里有两个 correct")
	var step_four: Variant = table_four.get_rune("r_one").get_step("four")
	_check_str(step_four.correct_option_id(), "", "夹具4：correct_option_id() 返回空")
	_check_eq(step_four.option_count(), 2, "夹具4：两个选项都还读到了")

	# (4b) choice 一个 correct 都没有
	var fixture_four_b: Dictionary = fixture_four.duplicate(true)
	(fixture_four_b["runes"] as Array)[0]["steps"][0]["options"][0]["correct"] = false
	(fixture_four_b["runes"] as Array)[0]["steps"][0]["options"][1]["correct"] = false
	var table_four_b: Variant = Loader.parse_dictionary(fixture_four_b, "res://data/runes/case_01_runes.json")
	_check(not table_four_b.ok, "夹具4b：ok false")
	_check(_has_error(table_four_b, "correct:true 必须是恰好一个"), "夹具4b：errors 里说 correct 个数不对")
	_check_str(table_four_b.get_rune("r_one").get_step("four").correct_option_id(), "", "夹具4b：没有正确选项时返回空")

	# (5) 未知 clue_id（带拼写建议）
	var fixture_five: Dictionary = fixture_two.duplicate(true)
	fixture_five["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": ["clue_01_stone_dust", "clue_01_stoen_dust"],
			"require_min_loop": 0, "gate_note": "n", "room": "", "steps": base_steps},
	]
	var table_five: Variant = Loader.parse_dictionary(fixture_five, "res://data/runes/case_01_runes.json")
	_check(not table_five.ok, "夹具5：ok false")
	_check(_has_error(table_five, "未登记的线索"), "夹具5：errors 里有未登记线索")
	_check(_has_error(table_five, "clue_01_stoen_dust"), "夹具5：点名那个拼错的 id")
	_check(_has_error(table_five, "clue_01_stone_dust"), "夹具5：给了拼写建议")
	_check_eq(_error_count(table_five, "未登记的线索"), 1, "夹具5：只报那一条错的（对的那条不报）")

	# (6) runes 为空 / 根节点类型不对 / JSON 坏
	var fixture_six: Dictionary = fixture_two.duplicate(true)
	fixture_six["runes"] = []
	var table_six: Variant = Loader.parse_dictionary(fixture_six, "res://data/runes/case_01_runes.json")
	_check(not table_six.ok, "夹具6：runes 空 ⇒ ok false")
	_check(_has_error(table_six, "runes 为空"), "夹具6：errors 里有 runes 为空")
	var table_seven: Variant = Loader.parse_text("这不是 JSON", "res://data/runes/case_01_runes.json")
	_check(not table_seven.ok, "夹具7：坏 JSON ⇒ ok false")
	_check(_has_error(table_seven, "JSON 解析失败"), "夹具7：errors 里有 JSON 解析失败")
	_check(table_seven.error.contains("行"), "夹具7：错误信息带行号")
	var table_eight: Variant = Loader.parse_text("[1, 2]", "res://data/runes/case_01_runes.json")
	_check(not table_eight.ok, "夹具8：根节点不是对象 ⇒ ok false")
	_check(_has_error(table_eight, "根节点必须是对象"), "夹具8：errors 里说了根节点类型")
	var table_nine: Variant = Loader.load_from_file("res://data/runes/case_99_runes.json")
	_check(not table_nine.ok, "夹具9：文件不存在 ⇒ ok false")
	_check(_has_error(table_nine, "不存在"), "夹具9：errors 里说文件不存在")
	var table_ten: Variant = Loader.load_for_case(99)
	_check(not table_ten.ok, "夹具10：案 99 没有符表 ⇒ ok false")
	_check(table_ten.error_summary() != "", "夹具10：error_summary 非空")

	# (7) 笔画 token 不在 inputs.tokens 里 + pattern 为空
	var fixture_eleven: Dictionary = fixture_two.duplicate(true)
	fixture_eleven["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": [], "require_min_loop": 0,
			"gate_note": "n", "room": "",
			"steps": [{"step_id": "two", "name": "照", "kind": "draw", "text": "照。",
				"strokes": [
					{"name": "回", "pattern": ["right", "sideways"]},
					{"name": "照", "pattern": []},
				]}]},
	]
	var table_eleven: Variant = Loader.parse_dictionary(fixture_eleven, "res://data/runes/case_01_runes.json")
	_check(not table_eleven.ok, "夹具11：ok false")
	_check(_has_error(table_eleven, "不在 inputs.tokens"), "夹具11：errors 里有非法 token")
	_check(_has_error(table_eleven, "sideways"), "夹具11：点名非法 token")
	_check(_has_error(table_eleven, "pattern 为空"), "夹具11：errors 里有空 pattern")

	# (8) step_id 重复 / 步名重复 / require_min_loop 负
	var fixture_twelve: Dictionary = fixture_two.duplicate(true)
	fixture_twelve["runes"] = [
		{"rune_id": "r_one", "name": "甲", "require_clues": [], "require_min_loop": -3,
			"gate_note": "n", "room": "",
			"steps": [
				{"step_id": "one", "name": "摊", "kind": "gate", "text": "摊开。"},
				{"step_id": "one", "name": "再摊", "kind": "gate", "text": "又摊开。"},
			]},
	]
	var table_twelve: Variant = Loader.parse_dictionary(fixture_twelve, "res://data/runes/case_01_runes.json")
	_check(not table_twelve.ok, "夹具12：ok false")
	_check(_has_error(table_twelve, "step_id 重复"), "夹具12：errors 里有 step_id 重复")
	_check(_has_error(table_twelve, "require_min_loop 不能是负数"), "夹具12：errors 里有负数遍数")
	_check(_has_error(table_twelve, "steps"), "夹具12：错误信息带 steps 定位")

	# (9) 纯内存夹具：没有 meta / 没有 inputs
	var fixture_thirteen: Dictionary = {
		"runes": [{"rune_id": "r_one", "steps": base_steps}],
	}
	var table_thirteen: Variant = Loader.parse_dictionary(fixture_thirteen)
	_check(not table_thirteen.ok, "夹具13：缺 inputs ⇒ ok false")
	_check(_has_error(table_thirteen, "缺 inputs"), "夹具13：errors 里有缺 inputs")
	_check(_has_warning(table_thirteen, "缺 meta"), "夹具13：warnings 里有缺 meta")
	_check(table_thirteen.warnings.size() >= 2, "夹具13：warnings 不止一条")
	_check(table_thirteen.error_summary() != "", "夹具13：error_summary 非空")
	_check_eq(table_thirteen.case_id, 1, "夹具13：没有 path ⇒ case_id 落默认 1")


# ============================================================================
#  ⑭ warning 夹具（不影响 ok）
# ============================================================================

func _test_warning_fixtures() -> void:
	# 案件 require_ritual 与本表对不上：只进 warnings，ok 仍为 true
	var table: Variant = Loader.parse_dictionary(_valid_fixture(), "", "res://data/scenarios/case_01_baihu.json")
	_check(table.ok, "warning 夹具：ok 仍为 true")
	_check_eq(table.errors.size(), 0, "warning 夹具：0 error")
	_check(table.warnings.size() >= 1, "warning 夹具：至少一条 warning")
	_check(_has_warning(table, "require_ritual"), "warning 夹具：warnings 里点了 require_ritual")
	_check_str(table.case_require_ritual, RUNE_ID, "warning 夹具：读到了案件的 require_ritual")
	_check(_has_warning(table, "huizhao_songbei"), "warning 夹具：warnings 里列出案件要的那道符")
	_check(table.error_summary() == "", "warning 夹具：error_summary 仍为空")

	# gate/npc 步缺 text：warning，不是 error
	var fixture: Dictionary = _valid_fixture()
	(fixture["runes"] as Array)[0]["steps"] = [
		{"step_id": "one", "name": "摊", "kind": "gate"},
		{"step_id": "two", "name": "念", "kind": "npc", "npc_id": "npc_01", "room": ""},
	]
	var table_two: Variant = Loader.parse_dictionary(fixture, "")
	_check(table_two.ok, "缺 text ⇒ ok 仍为 true")
	_check(_has_warning(table_two, "缺 text"), "缺 text ⇒ warnings 里有提示")
	_check_eq(table_two.errors.size(), 0, "缺 text ⇒ 0 error")

	# 未知字段（typo 的第一道网）
	var fixture_three: Dictionary = _valid_fixture()
	(fixture_three["runes"] as Array)[0]["second"] = 12
	var table_three: Variant = Loader.parse_dictionary(fixture_three, "")
	_check(table_three.ok, "未知字段 ⇒ ok 仍为 true")
	_check(_has_warning(table_three, "未知字段"), "未知字段 ⇒ warnings 里有提示")
	_check(_has_warning(table_three, "'second'"), "未知字段 ⇒ 点名 'second'")

	# step / index 序号与下标对不上
	var fixture_four: Dictionary = _valid_fixture()
	var rune_four: Dictionary = (fixture_four["runes"] as Array)[0]
	rune_four["steps"] = [
		{"step": 9, "step_id": "one", "name": "摊", "kind": "gate", "text": "摊开。"},
		{"step_id": "two", "name": "照", "kind": "draw", "text": "照。",
			"strokes": [{"index": 7, "name": "回", "pattern": ["right", "down", "left", "up"]}]},
	]
	var table_four: Variant = Loader.parse_dictionary(fixture_four, "")
	_check(table_four.ok, "序号错位 ⇒ ok 仍为 true")
	_check(_has_warning(table_four, "与下标"), "序号错位 ⇒ warnings 里有提示")
	_check_eq(table_four.get_rune("r_one").get_step("one").index, 0, "序号错位时按下标走")

	# schema_version 高于 loader
	var fixture_five: Dictionary = _valid_fixture()
	(fixture_five["meta"] as Dictionary)["schema_version"] = 99
	var table_five: Variant = Loader.parse_dictionary(fixture_five, "")
	_check(table_five.ok, "高版本 schema ⇒ ok 仍为 true")
	_check(_has_warning(table_five, "schema_version"), "高版本 schema ⇒ warnings 里有提示")
	_check_eq(table_five.schema_version, 99, "高版本 schema 仍读进来")

	# 拿真表 + 只差 require_ritual 的假案件路径：报 warning；案件文件读不到也报 warning
	var real: Variant = Loader.load_from_file("res://data/runes/case_01_runes.json", "res://data/scenarios/case_99_baihu.json")
	_check(real.ok, "案件文件读不到 ⇒ 符表本身仍 ok")
	_check(_has_warning(real, "案件数据读不到"), "案件文件读不到 ⇒ warning")
	_check(real.case_ritual_checked, "尝试过 require_ritual 交叉引用")


# ============================================================================
#  断言器
# ============================================================================

func _check(condition: bool, label: String) -> void:
	_executed += 1
	if condition:
		_passed += 1
		return
	_failed += 1
	_failures.append(label)
	if _failures.size() <= 12:
		print("  ✗ %s" % label)


func _check_eq(actual: Variant, expected: Variant, label: String) -> void:
	_check(actual == expected, "%s（实际 %s，期望 %s）" % [label, str(actual), str(expected)])


func _check_str(actual: String, expected: String, label: String) -> void:
	_check(actual == expected, "%s（实际 '%s'，期望 '%s'）" % [label, actual, expected])


func _check_same(actual: Array, expected: Array, label: String) -> void:
	var same: bool = actual.size() == expected.size()
	if same:
		for index in range(actual.size()):
			if String(actual[index]) != String(expected[index]):
				same = false
				break
	_check(same, "%s（实际 %s，期望 %s）" % [label, str(actual), str(expected)])


func _has_error(table: Variant, needle: String) -> bool:
	for message in table.errors:
		if String(message).contains(needle):
			return true
	return false


func _has_warning(table: Variant, needle: String) -> bool:
	for message in table.warnings:
		if String(message).contains(needle):
			return true
	return false


func _error_count(table: Variant, needle: String) -> int:
	var hits: int = 0
	for message in table.errors:
		if String(message).contains(needle):
			hits += 1
	return hits


func _count_lines(lines: Array[String]) -> int:
	return lines.size()


func prompt_lines_size(input: Node) -> int:
	return input.prompt_lines(6).size()


# ============================================================================
#  夹具 / 构造器
# ============================================================================

## 起一道符（三样门槛都满足），停在 gate 步。
func _running_input() -> Node:
	var input: Node = _make_input(Loader.load_for_case(1), true)
	input.set_owned_clues(SIX_CLUES)
	input.set_loop_index(MIN_LOOP)
	input.set_room(ROOM)
	_check(input.start_rune(RUNE_ID), "构造：起符成功")
	return input


## 起一道符并推进到 draw 步。
func _draw_step_input() -> Node:
	var input: Node = _running_input()
	_check(input.advance(), "构造：过 gate 步")
	return input


## 起一道符并推进到 choice 步（三笔按数据画对）。
func _choice_step_input() -> Node:
	var input: Node = _draw_step_input()
	for pattern in [
		["right", "down", "left", "up"],
		["down", "down_right", "right", "down"],
		["right", "down", "right", "down"],
	]:
		input.begin_stroke()
		for token in pattern:
			input.feed_token(token)
		input.commit_stroke()
	_check(input.advance(), "构造：过 draw 步")
	_check(input.advance(), "构造：过 npc 步")
	return input


## 整套仪式走完的实例（完成态）。
func _full_ritual_input() -> Node:
	var input: Node = _choice_step_input()
	_check(input.choose_option("keep_the_gap")["ok"], "构造：选对")
	_check(input.advance(), "构造：过 choice 步")
	_check(input.advance(), "构造：过最后一步")
	return input


func _make_input(table: Variant, in_tree: bool) -> Node:
	var input: Node = RuneInput.new()
	_nodes.append(input)
	if in_tree:
		root.add_child(input)
	input.set_process(false)
	input.auto_subscribe = false
	if not in_tree:
		input.auto_subscribe = false
	_check(input.configure_with_table(table, {"auto_subscribe": false}), "构造：注入符表")
	return input


## 带 `loop_reset` 信号的假时钟（代替真 TimeLoopManager，测订阅路径；组件靠相对解析找它）。
## 工程里 `TimeLoopManager` 是 Autoload ⇒ `--script` 跑起来时它已经占了 `/root/TimeLoopManager`
## 这个名字，直接 `add_child` 会被引擎自动改名成 `@Node@N`。所以这里先把真的挪开（记在
## `_displaced_manager`，`_finish()` 里原样放回），让假时钟占住那个路径名与名字。
func _make_loop_manager() -> Node:
	var clock: Node = LoopClock.new()
	_nodes.append(clock)
	if _displaced_manager == null:
		var existing: Node = root.get_node_or_null(LOOP_MANAGER_NAME)
		if existing != null:
			_displaced_manager = existing
			root.remove_child(existing)
	clock.name = LOOP_MANAGER_NAME
	root.add_child(clock)
	return clock


## 内存夹具里的符（room 为空）：用来断言"room 为空不校验房间"。
func _plain_entry() -> Variant:
	var table: Variant = Loader.parse_dictionary(_valid_fixture(), "")
	return table.get_rune("r_one")


## 合法的最小夹具（1 道符 / 2 步 / 1 笔 / 1 选项；用于 warning 组）。
func _valid_fixture() -> Dictionary:
	return {
		"meta": {"schema_version": 1, "case_id": 1, "case_title": "夹具案"},
		"inputs": {
			"tokens": ["up", "down", "left", "right"],
			"key_map": {"up": "KEY_UP", "down": "KEY_DOWN"},
			"backspace_key": "KEY_BACKSPACE",
			"commit_key": "KEY_ENTER",
		},
		"runes": [{
			"rune_id": "r_one",
			"name": "夹具符",
			"display_name": "夹具符（假）",
			"source_note": "夹具",
			"require_clues": [],
			"require_min_loop": 0,
			"gate_note": "夹具门槛",
			"room": "",
			"npc_id": "",
			"success_text": "夹具成功",
			"fail_text": "夹具失败",
			"steps": [
				{"step_id": "one", "name": "摊", "kind": "gate", "text": "摊开。"},
				{"step_id": "two", "name": "照", "kind": "draw", "text": "照。",
					"strokes": [{"name": "回", "pattern": ["right", "down", "left", "up"]}],
					"near_miss": [{"attempt_id": "nm_x", "pattern": ["left"], "hint": "反了。", "clue_note": ""}]},
				{"step_id": "three", "name": "择", "kind": "choice", "text": "择。",
					"options": [
						{"option_id": "a", "text": "补刻", "correct": false, "reply": "错的那句"},
						{"option_id": "b", "text": "留残", "correct": true, "reply": "对的那句"},
					]},
			],
		}],
	}


func _finish() -> void:
	for node in _nodes:
		if is_instance_valid(node):
			node.free()
	_nodes.clear()
	# 把被挪开的真 Autoload 原样放回 `/root/TimeLoopManager`（不多留、不销毁引擎的东西）。
	if _displaced_manager != null and is_instance_valid(_displaced_manager):
		if _displaced_manager.get_parent() == null:
			root.add_child(_displaced_manager)
		if _displaced_manager.name != LOOP_MANAGER_NAME:
			_displaced_manager.name = LOOP_MANAGER_NAME
		_displaced_manager = null
	var total: int = _passed + _failed
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项，期望 ≥ %d）" % [_passed, _failed, total, EXPECTED_CHECKS])
	if _executed < EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数不足：%d < %d（脚本可能中途出错退出）" % [_executed, EXPECTED_CHECKS])
		quit(1)
		return
	if _failed > 0:
		for label in _failures:
			print("  FAIL: %s" % label)
		print("RESULT: FAIL 画符输入测试失败 %d 项" % _failed)
		quit(1)
		return
	print("RESULT: OK 画符输入 %d 项断言全过（案一 1 道符 / 5 步 / 3 笔 / 3 条近似笔）" % _passed)
	quit(0)


# ============================================================================
#  测试替身
# ============================================================================

## 带 `loop_reset` 的假时钟（真 TimeLoopManager 的接口面只需要这一个信号）。
class LoopClock extends Node:
	signal loop_reset(loop_index: int)


## 记忆对象替身：心灯口径（get_available_clues）。
class FakeMemory extends Node:
	var _clues: Array[String] = []

	func _init(clues: Array = []) -> void:
		for clue_id in clues:
			_clues.append(String(clue_id))

	func get_available_clues() -> Array[String]:
		return _clues.duplicate()

	func has_clue(clue_id: String) -> bool:
		return _clues.has(clue_id)

	func get_clues() -> Array[String]:
		return _clues.duplicate()


## 只有 has_clue() 的对象（谓词式接口）：测组件能不能靠候选集兜底。
class HasOnly extends Node:
	var _clues: Array[String] = []

	func _init(clues: Array = []) -> void:
		for clue_id in clues:
			_clues.append(String(clue_id))

	func has_clue(clue_id: String) -> bool:
		return _clues.has(clue_id)
