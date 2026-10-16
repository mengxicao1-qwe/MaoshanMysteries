extends SceneTree
## tests/test_deduction.gd —— M1 第 ④ 步：推演板与矛盾高亮
##
## 跑法：godot --headless --path D:\DeepLoopGame --script res://tests/test_deduction.gd
## 约定（AGENTS.md §2）：extends SceneTree + _initialize() + quit(code)，末行唯一一行 RESULT:，
## 并带"断言执行数不足即 FAIL"的守护常量 EXPECTED_CHECKS（脚本中途挂掉时进程照样可能退 0）。
##
## 覆盖：真数据装载 / 卡面中文名 / 单卡到多卡的推进 / 结案六卡 / 矛盾点亮与排序 / 卡关提示 /
##       板面文本与截断 / 夹具错误分类 / 记忆注入（含"注入对象被 free 之后"）/ 快照可序列化 / 节点卫生。
##
## 注意：本测试**不写 user://**，所以不实例化 PersistentMemoryManager / HeartLamp（它们会落盘），
## 改用文件内的假记忆体（FakeMemory / FakeLamp）—— 组件的契约只要求"有那几个方法"，注入即可。

const DeductionBoard = preload("res://scripts/entities/deduction_board.gd")

const DEDUCTION_DATA: String = "res://data/deduction/case_01_deduction.json"

## 断言条数下限：实际执行数低于它 = FAIL（防"脚本中途出错退出 0"被当成通过）。
const EXPECTED_CHECKS: int = 263

## 案一结案六环各取一条（data/scenarios/case_01_baihu.json 的 resolve_conditions.require_clues）。
const CLOSING_CLUES: Array[String] = [
	"clue_01_four_in_three",
	"clue_01_half_stroke_cun",
	"clue_01_rubbing_fragment",
	"clue_01_stone_dust",
	"clue_01_three_sources_conflict",
	"clue_01_bowl_bottom",
]

## 案一全部 14 条线索（data/clues/case_01_clues.json）。
const ALL_CLUES: Array[String] = [
	"clue_01_four_in_three",
	"clue_01_two_hands",
	"clue_01_hole_chipped",
	"clue_01_half_stroke_cun",
	"clue_01_rubbing_fragment",
	"clue_01_grey_bag",
	"clue_01_stone_dust",
	"clue_01_double_knot",
	"clue_01_three_sources_conflict",
	"clue_01_keep_stele_motive",
	"clue_01_bowl_bottom",
	"clue_01_date_untouched",
	"note_01_first_edit",
	"sealed_01_gan_shoupu",
]

var _passed: int = 0
var _failed: int = 0
var _executed: int = 0
var _failures: Array[String] = []
var _instances: Array[Node] = []

## board_changed 的探针：广播次数 + 最后一次的两个计数（-1 = 从没广播过）。
var _signal_count: int = 0
var _last_unlocked: int = -1
var _last_ready: int = -1


## 假记忆体：PersistentMemoryManager 的"有没有记得"那一半（不落盘）。
class FakeMemory extends Node:
	var clues: Array[String] = []

	func remember(clue_id: String) -> void:
		if not clues.has(clue_id):
			clues.append(clue_id)

	func has_clue(clue_id: String) -> bool:
		return clues.has(clue_id)

	func get_clues() -> Array[String]:
		return clues.duplicate()


## 假心灯：只有 get_available_clues() 的对象（表现层实际注入的就是 HeartLamp）。
## has_clue() 故意说谎（永远 false）：板子若用错接口，下面的断言立刻红。
class FakeLamp extends Node:
	var available: Array[String] = []

	func get_available_clues() -> Array[String]:
		return available.duplicate()

	func has_clue(_clue_id: String) -> bool:
		return false


func _initialize() -> void:
	_case_real_data()
	_case_progression()
	_case_closing_clues()
	_case_conflicts()
	_case_stuck_hints()
	_case_board_lines()
	_case_memory_injection()
	_case_fixtures()
	_case_state_and_hygiene()
	_finish()


# ============================================================================
#  1. 真数据装载 + 卡面中文名
# ============================================================================

func _case_real_data() -> void:
	var board: DeductionBoard = _new_board()
	_check(board.configure(1), "configure(1) 返回 true")
	_check(board.is_configured(), "is_configured() 为真")
	_check(board.is_ok(), "is_ok() 为真（真数据没有 error）")
	_check(board.get_errors().is_empty(), "get_errors() 为空")
	_check(board.error_summary() == "", "error_summary() 在无错时是空串")
	_check(board.get_warnings().is_empty(), "get_warnings() 为空（真数据连警告都没有）")

	var raw: Dictionary = _read_json_file(DEDUCTION_DATA)
	var raw_deductions: Array = raw.get("deductions", [])
	var raw_conflicts: Array = raw.get("conflicts", [])
	var raw_hints: Array = raw.get("stuck_hints", [])
	_check(raw_deductions.size() == 10, "数据文件里有 10 条推论（独立于组件的口径核对）")
	_check(raw_conflicts.size() == 6, "数据文件里有 6 条矛盾")
	_check(raw_hints.size() == 6, "数据文件里有 6 条卡关提示")

	_check(board.total_deduction_count() == 10, "total_deduction_count() == 10")
	_check(board.total_conflict_count() == 6, "total_conflict_count() == 6")
	_check(board.total_stuck_hint_count() == 6, "total_stuck_hint_count() == 6")
	_check(board.deduction_ids().size() == 10, "deduction_ids() 有 10 条")
	_check(board.conflict_ids().size() == 6, "conflict_ids() 有 6 条")
	_check(board.total_clue_count() == 14, "线索台账读了 14 条（card_name 的来源）")
	_check(board.get_case_id() == 1, "get_case_id() == 1")
	_check(board.get_source().ends_with("case_01_deduction.json"), "get_source() 指向案一的推演板数据")

	_check(board.has_deduction("ded_01_last_row_edited"), "has_deduction(ded_01) 为真")
	_check(board.has_deduction("ded_99_nope") == false, "has_deduction() 对不存在的 id 为假")
	_check(board.get_deduction("ded_99_nope").is_empty(), "get_deduction() 对不存在的 id 返回空字典")
	_check(board.get_deduction("ded_01_last_row_edited")["title"] == "碑阴末行被改过", "get_deduction() 取到标题")
	_check(board.get_deduction("ded_01_last_row_edited")["core"] == true, "ded_01 是核心推论（core = true）")
	_check(board.has_conflict("cf_01_stone_versus_paper"), "has_conflict(cf_01) 为真")
	_check(board.has_conflict("cf_99_nope") == false, "has_conflict() 对不存在的 id 为假")
	_check(board.get_conflict("cf_99_nope").is_empty(), "get_conflict() 对不存在的 id 返回空字典")
	_check(board.get_conflict("cf_05_visitor_bag")["severity"] == "次要", "cf_05 是次要矛盾")

	# 卡面中文名：来自 data/clues/case_01_clues.json 的 clues[].name
	_check(board.card_name("clue_01_four_in_three") == "三字位上的四字", "card_name() 取到台账里的中文名")
	_check(board.card_name("clue_01_hole_chipped") == "系线石孔的新崩石屑", "card_name() 第二例")
	_check(board.card_name("clue_01_half_stroke_cun") == "半笔'寸'", "card_name() 第三例（含引号）")
	_check(board.card_name("clue_01_two_hands") == "碑上两只手", "card_name() 第四例")
	_check(board.card_name("clue_01_bowl_bottom") == "陶碗底的'甘氏领雨'四字", "card_name() 第五例")
	_check(board.card_name("clue_01_date_untouched") == "日子没被改：三月十八还在", "card_name() 第六例（含全角冒号）")
	_check(board.card_name("note_01_first_edit") == "自注：此处曾改，不止一次", "card_name() 认 note_ 前缀的自注")
	_check(board.card_name("clue_99_unknown") == "clue_99_unknown", "台账里没有的 id 退回 id 本身（不返回空串）")
	_check(board.card_chain("clue_01_four_in_three").begins_with("环一"), "card_chain() 取到环节")

	# 没配置过 / 案号不存在：明确失败，而不是静默半死
	var blank: DeductionBoard = _new_board()
	_check(blank.is_configured() == false, "还没 configure 时 is_configured() 为假")
	_check(blank.is_ok() == false, "还没 configure 时 is_ok() 为假")
	_check(blank.unlocked_deductions().is_empty(), "还没 configure 时没有推论")
	_check(blank.stuck_hint(5).is_empty(), "还没 configure 时 stuck_hint() 返回空")
	_check(blank.configure(99) == false, "configure(99)（没有这个案）返回 false")
	_check(blank.is_ok() == false, "案号不存在时 is_ok() 为假")
	_check(_has_error_like(blank, "读不到推演板数据"), "案号不存在时给出'读不到数据'的 error")


# ============================================================================
#  2. 单条线索到"差一步"
# ============================================================================

func _case_progression() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)

	# 空集：板上什么都没有 —— 但这不是 error
	board.set_owned_clues([])
	_check(board.owned_cards().is_empty(), "set_owned_clues([]) 后 owned_cards() 为空")
	_check(board.unlocked_deductions().is_empty(), "空集下 0 条推论成立")
	_check(board.locked_deductions().size() == 10, "空集下 10 条推论都没成立")
	_check(board.nearly_locked().is_empty(), "空集下没有'差一步'（都差两张以上）")
	_check(board.ready_conflicts().is_empty(), "空集下没有点亮的矛盾")
	_check(board.pending_conflicts().size() == 6, "空集下 6 条矛盾都没点亮")
	_check(board.board_lines().is_empty(), "空集下 board_lines() 是空数组")
	_check(board.describe().begins_with("推演板："), "describe() 以'推演板：'开头")
	_check(board.describe() == "推演板：0 条推论成立 / 0 条对不上（其中 0 条未收束）｜线索卡 0/14",
		"空集下 describe() 的完整一行")
	_check(_signal_count == 0, "空板不广播 board_changed")

	var pending_cf01: Dictionary = _row_by(board.pending_conflicts(), "conflict_id", "cf_01_stone_versus_paper")
	_check(_same_list(pending_cf01["missing_cards"], ["clue_01_four_in_three", "clue_01_rubbing_fragment"]),
		"未点亮的矛盾给出 missing_cards（按表内顺序）")
	_check(_same_list(pending_cf01["missing_names"], ["三字位上的四字", "民国拓本残纸"]),
		"未点亮的矛盾给出 missing_names（中文卡名）")

	# 只加一张：还不够（ded_01 要两张卡），但已经"差一步"
	board.set_owned_clues(["clue_01_four_in_three"])
	_check(_same_list(board.owned_cards(), ["clue_01_four_in_three"]), "owned_cards() 只收已入录的卡")
	_check(board.unlocked_deductions().is_empty(), "只有四字卡时 0 条推论成立（ded_01 要两张卡）")
	_check(_same_list(_ids_of(board.nearly_locked(), "deduction_id"),
		["ded_01_last_row_edited", "ded_02_two_hands"]), "差一步的两条：ded_01 / ded_02")
	_check(_signal_count == 0, "只差一步还不算板上内容变化：不广播")
	var locked_ded01: Dictionary = _row_by(board.locked_deductions(), "deduction_id", "ded_01_last_row_edited")
	_check(_same_list(locked_ded01["missing_cards"], ["clue_01_hole_chipped"]), "ded_01 还缺哪张卡")
	_check(_same_list(locked_ded01["missing_names"], ["系线石孔的新崩石屑"]), "ded_01 缺的卡叫什么")

	# 再加第二张：ded_01 成立，cf_04 点亮（hole_chipped 一条就能点亮它）
	var before: int = _signal_count
	board.set_owned_clues(["clue_01_four_in_three", "clue_01_hole_chipped"])
	_check(board.unlocked_deductions().size() == 1, "两张卡后 1 条推论成立")
	_check(board.unlocked_deductions()[0]["deduction_id"] == "ded_01_last_row_edited", "成立的是 ded_01")
	_check(board.is_deduction_unlocked("ded_01_last_row_edited"), "is_deduction_unlocked(ded_01) 为真")
	_check(board.is_deduction_unlocked("ded_02_two_hands") == false, "is_deduction_unlocked(ded_02) 为假")
	_check(board.locked_deductions().size() == 9, "还剩 9 条推论没成立")
	_check(_same_list(board.owned_cards(), ["clue_01_four_in_three", "clue_01_hole_chipped"]),
		"owned_cards() 保持表内顺序")
	_check(_signal_count == before + 1, "板上多了内容：广播一次 board_changed")
	_check(_last_unlocked == 1, "广播带的 unlocked_count == 1")
	_check(_last_ready == 1, "广播带的 ready_conflict_count == 1")
	_check(board.ready_conflicts().size() == 1, "点亮的矛盾有 1 条")
	_check(board.ready_conflicts()[0]["conflict_id"] == "cf_04_old_face_new_chip", "点亮的是 cf_04（只看孔口崩口）")
	_check(board.ready_conflicts()[0]["resolved"] == false, "cf_04 的 resolve_cards 为空 ⇒ 未收束（悬案）")
	_check(board.is_conflict_ready("cf_04_old_face_new_chip"), "is_conflict_ready(cf_04) 为真")
	_check(board.is_conflict_ready("cf_01_stone_versus_paper") == false, "cf_01 还没点亮")
	_check(board.describe() == "推演板：1 条推论成立 / 1 条对不上（其中 1 条未收束）｜线索卡 2/14",
		"两张卡下 describe() 的完整一行")

	# 同一集合重复设置 / 显式 refresh：板上内容没变就不重复广播
	var after: int = _signal_count
	board.set_owned_clues(["clue_01_four_in_three", "clue_01_hole_chipped"])
	board.refresh()
	_check(_signal_count == after, "同一集合重复 set/refresh 不再广播（HUD 不会被空刷）")

	# 深拷贝：调用方改坏了返回的行，板子的缓存不受影响
	var unlocked: Array[Dictionary] = board.unlocked_deductions()
	unlocked[0]["title"] = "被改坏的标题"
	_check(board.unlocked_deductions()[0]["title"] == "碑阴末行被改过", "返回的行是深拷贝，改不坏板内缓存")

	# reset()：清掉运行期状态与显式集合
	board.reset()
	_check(board.owned_cards().is_empty(), "reset() 后 owned_cards() 为空")
	_check(board.unlocked_deductions().is_empty(), "reset() 后没有成立中的推论")
	_check(board.describe().contains("线索卡 0/14"), "reset() 后线索卡计数归零")


# ============================================================================
#  3. 案一结案六条线索
# ============================================================================

func _case_closing_clues() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)
	board.set_owned_clues(CLOSING_CLUES)
	_check(board.owned_cards().size() == 6, "六条结案线索都在板上（6 张卡）")

	# 数据裁定：require_cards 必须**全部**入录才成立，所以六条线索单靠自己只撑得起 ded_04 / ded_08
	# （详见最终报告——规格里"六条全入录 ⇒ ded_01/03/05/07 也成立"与 data/deduction 的 require_cards
	#  不符：这四条各自还缺一张卡，而缺的都在案一另外 14 条线索里）。
	_check(_same_list(_ids_of(board.unlocked_deductions(), "deduction_id"),
		["ded_04_name_is_gan_shoupu", "ded_08_family_remembers"]),
		"六条结案线索单靠自己成立的是 ded_04 / ded_08（require_cards 全部入录才算）")
	_check(board.describe().contains("2 条推论成立"), "describe() 报出 2 条推论成立")
	_check(board.describe().contains("6/14"), "describe() 报出线索卡 6/14")
	_check(board.describe().contains("3 条对不上"), "describe() 报出 3 条矛盾已点亮")
	_check(board.describe().contains("其中 2 条未收束"), "describe() 报出其中 2 条未收束")

	# 这四条各"差一步"，缺的正好是那四张卡（这就是"结案六卡还需补哪四张"的答案）
	var want: Dictionary = {
		"ded_01_last_row_edited": "clue_01_hole_chipped",
		"ded_03_a_real_name": "clue_01_two_hands",
		"ded_05_dust_is_fresh": "clue_01_grey_bag",
		"ded_07_the_other_side_was_right": "clue_01_keep_stele_motive",
	}
	for deduction_id in want.keys():
		var row: Dictionary = _row_by(board.locked_deductions(), "deduction_id", deduction_id)
		_check(_same_list(row["missing_cards"], [want[deduction_id]]), "六卡下 %s 还缺一张卡" % deduction_id)
	_check(_same_list(_ids_of(board.nearly_locked(), "deduction_id"), [
		"ded_01_last_row_edited", "ded_02_two_hands", "ded_03_a_real_name", "ded_05_dust_is_fresh",
		"ded_06_insider_knot", "ded_07_the_other_side_was_right", "ded_09_the_seam", "ded_10_edited_before",
	]), "六卡下'差一步'的推论共 8 条（按表内顺序）")

	# 补上那四张卡：规格要求的那一组核心推论全部成立（"至少"口径）
	board.set_owned_clues([
		"clue_01_four_in_three", "clue_01_half_stroke_cun", "clue_01_rubbing_fragment", "clue_01_stone_dust",
		"clue_01_three_sources_conflict", "clue_01_bowl_bottom",
		"clue_01_hole_chipped", "clue_01_two_hands", "clue_01_grey_bag", "clue_01_keep_stele_motive",
	])
	_check(board.unlocked_deductions().size() == 7, "补四张后 7 条推论成立（ded_06 还要双回结，补的四张里没有）")
	for deduction_id in [
		"ded_01_last_row_edited", "ded_02_two_hands", "ded_03_a_real_name", "ded_04_name_is_gan_shoupu",
		"ded_05_dust_is_fresh", "ded_07_the_other_side_was_right", "ded_08_family_remembers",
	]:
		_check(board.is_deduction_unlocked(deduction_id), "补四张后 %s 成立" % deduction_id)
	_check(_same_list(_row_by(board.locked_deductions(), "deduction_id", "ded_06_insider_knot")["missing_cards"],
		["clue_01_double_knot"]), "ded_06 仍缺双回结（它不在结案六卡那一路）")
	_check(_same_list(_ids_of(board.nearly_locked(), "deduction_id"),
		["ded_06_insider_knot", "ded_09_the_seam", "ded_10_edited_before"]),
		"补四张后'差一步'的只剩三条：ded_06 / ded_09 / ded_10")
	_check(board.is_deduction_unlocked("ded_09_the_seam") == false, "ded_09 仍缺'日子没被改'")
	_check(board.is_deduction_unlocked("ded_10_edited_before") == false, "ded_10 仍缺自注卡")
	_check(_same_list(_ids_of(board.ready_conflicts(), "conflict_id"),
		["cf_03_papers_say_nobody", "cf_04_old_face_new_chip", "cf_05_visitor_bag",
		"cf_01_stone_versus_paper", "cf_02_three_sources_fight"]),
		"补四张后点亮的 5 条矛盾：未收束在前、核心在次要之前、同档按表内顺序")
	_check(board.ready_conflicts()[4]["severity"] == "核心", "已收束组里核心在前")
	_check(board.ready_conflicts()[2]["severity"] == "次要", "未收束组里的次要排在核心之后")


# ============================================================================
#  4. 矛盾：点亮、收束、排序
# ============================================================================

func _case_conflicts() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)

	# cf_01 三步走：只有四字卡时没点亮 → 加拓本后点亮（未收束）→ 加半笔'寸'后已收束
	board.set_owned_clues(["clue_01_four_in_three"])
	_check(board.is_conflict_ready("cf_01_stone_versus_paper") == false, "只有四字卡时 cf_01 未点亮")
	_check(_same_list(_row_by(board.pending_conflicts(), "conflict_id", "cf_01_stone_versus_paper")["missing_cards"],
		["clue_01_rubbing_fragment"]), "cf_01 还缺拓本残纸")

	board.set_owned_clues(["clue_01_four_in_three", "clue_01_rubbing_fragment"])
	_check(board.is_conflict_ready("cf_01_stone_versus_paper"), "加上拓本残纸后 cf_01 点亮")
	var lit: Dictionary = _row_by(board.ready_conflicts(), "conflict_id", "cf_01_stone_versus_paper")
	_check(lit["resolved"] == false, "cf_01 点亮但还没收束")
	_check(_same_list(lit["resolve_cards"], ["clue_01_half_stroke_cun"]), "cf_01 的收束卡是半笔'寸'")
	_check(board.describe_conflict("cf_01_stone_versus_paper").contains("未收束"), "describe_conflict() 写'未收束'")
	_check(board.describe_conflict("cf_01_stone_versus_paper").contains("核心"), "describe_conflict() 带严重度")

	board.set_owned_clues(["clue_01_four_in_three", "clue_01_rubbing_fragment", "clue_01_half_stroke_cun"])
	var resolved_row: Dictionary = _row_by(board.ready_conflicts(), "conflict_id", "cf_01_stone_versus_paper")
	_check(resolved_row["resolved"] == true, "再加半笔'寸'后 cf_01 resolved == true")
	_check(board.ready_conflicts().size() == 1, "已收束的矛盾仍留在板上（不消失）")
	_check(board.describe_conflict("cf_01_stone_versus_paper").contains("已收束"), "describe_conflict() 写'已收束'")
	_check(board.describe_conflict("cf_01_stone_versus_paper").contains("石头说"), "describe_conflict() 含标题")
	_check(board.describe_conflict("cf_99_nope") == "", "describe_conflict() 对不存在的 id 返回空串")

	# 全部 14 条线索：6 条矛盾全点亮，排序 = 未收束在前 → 核心在前 → 表内原顺序
	board.set_owned_clues(ALL_CLUES)
	_check(board.owned_cards().size() == 13, "板上出现过的卡是 13 张（sealed_01 不在板上）")
	_check(board.unlocked_deductions().size() == 10, "全线索下 10 条推论全部成立")
	_check(board.locked_deductions().is_empty(), "全线索下没有未成立的推论")
	_check(board.nearly_locked().is_empty(), "全线索下没有'差一步'")
	_check(board.ready_conflicts().size() == 6, "全线索下 6 条矛盾全部点亮")
	_check(board.pending_conflicts().is_empty(), "全线索下没有未点亮的矛盾")
	_check(_same_list(_ids_of(board.ready_conflicts(), "conflict_id"), [
		"cf_03_papers_say_nobody", "cf_04_old_face_new_chip", "cf_06_date_without_name",
		"cf_01_stone_versus_paper", "cf_02_three_sources_fight", "cf_05_visitor_bag",
	]), "全线索下的排序：未收束在前、核心在次要之前、同档按表内顺序")
	var ready: Array[Dictionary] = board.ready_conflicts()
	var seen_resolved: bool = false
	var order_ok: bool = true
	for row in ready:
		if bool(row["resolved"]):
			seen_resolved = true
		elif seen_resolved:
			order_ok = false
	_check(order_ok, "未收束的确实都排在已收束之前")
	_check(ready[0]["resolved"] == false and ready[1]["resolved"] == false and ready[2]["resolved"] == false,
		"前三条是未收束的 cf_03 / cf_04 / cf_06")
	_check(ready[3]["resolved"] == true and ready[4]["resolved"] == true and ready[5]["resolved"] == true,
		"后三条是已收束的 cf_01 / cf_02 / cf_05")
	_check(ready[5]["severity"] == "次要", "已收束组里的次要矛盾（cf_05）排在核心之后")
	_check(ready[0]["severity"] == "核心", "未收束组里都是核心")
	_check(_same_list(ready[3]["resolve_cards"], ["clue_01_half_stroke_cun"]), "cf_01 的收束卡随行返回")
	_check(board.describe() == "推演板：10 条推论成立 / 6 条对不上（其中 3 条未收束）｜线索卡 14/14",
		"全线索下 describe() 的完整一行")
	_check(board.get_state()["unresolved_conflict_count"] == 3, "get_state() 里未收束数 == 3")


# ============================================================================
#  5. 卡关提示（死法 3 的兜底）
# ============================================================================

func _case_stuck_hints() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)
	board.set_owned_clues([])

	_check(board.stuck_hint(0).is_empty(), "0 遍没进展 = 不给提示（阈值最早是 2）")
	_check(board.stuck_hint(1).is_empty(), "1 遍没进展 = 不给提示")
	var hint: Dictionary = board.stuck_hint(2)
	_check(not hint.is_empty(), "2 遍没进展 = 给第一条提示")
	_check(hint["after_loops_without_progress"] == 2, "提示带阈值 2")
	_check(hint["lead_clue"] == "clue_01_four_in_three", "第一条提示指向四字卡")
	_check(hint["lead_name"] == "三字位上的四字", "提示带卡面中文名")
	_check(hint["room"] == "baihutai_west", "提示带房间 baihutai_west")
	_check(hint["second"] == 70, "提示带拍点第 70 秒")
	_check(hint["npc_id"] == "npc_01_muqing", "提示带 npc_01_muqing")
	_check(hint["npc_name"] == "穆青", "提示带 NPC 中文名（从案件场景读）")
	_check(String(hint["text"]).contains("卯时二刻"), "提示文本来自数据表")
	_check(hint.size() == 8, "提示字典恰好 8 个键（HUD 照这个接线）")
	_check(hint.has("lead_name") and hint.has("npc_name"), "提示字典带 lead_name / npc_name")
	_check(board.stuck_hint(9, 3)["lead_clue"] == "clue_01_four_in_three",
		"阈值早就到了也只给'第一条还没入录的'（meta.stuck_semantics），不剧透后面的落点")
	_check(board.stuck_hint(2, 5)["lead_clue"] == "clue_01_four_in_three", "loop_index 参数不影响落点")

	# 第一条的线索到手了：给下一条可用的（不是什么都不给）
	board.set_owned_clues(["clue_01_four_in_three"])
	var next_hint: Dictionary = board.stuck_hint(2)
	_check(next_hint["lead_clue"] == "clue_01_hole_chipped", "四字卡到手后 2 遍没进展 = 指向新崩石屑")
	_check(next_hint["after_loops_without_progress"] == 3, "第二次提示的阈值是 3")
	_check(next_hint["room"] == "stall", "第二条提示的房间是 stall")
	_check(next_hint["npc_name"] == "刘桂英", "第二条提示的 NPC 名")

	board.set_owned_clues(["clue_01_four_in_three", "clue_01_hole_chipped"])
	_check(board.stuck_hint(2)["lead_clue"] == "clue_01_grey_bag", "前两条都到手后 = 指向灰布袋")
	_check(board.stuck_hint(5)["lead_clue"] == "clue_01_grey_bag", "阈值更高时仍取第一条未入录的")

	# 所有 lead 都已入录：没有可指的了 ⇒ 空
	board.set_owned_clues([
		"clue_01_four_in_three", "clue_01_hole_chipped", "clue_01_grey_bag", "clue_01_stone_dust",
		"clue_01_bowl_bottom", "clue_01_date_untouched",
	])
	_check(board.stuck_hint(7).is_empty(), "所有 lead 都已入录 ⇒ 返回空字典")
	_check(board.stuck_hint(99).is_empty(), "所有 lead 都已入录时阈值再高也是空")

	# 只入录了后面的 lead（前面的还缺）：仍然先给前面那条
	board.set_owned_clues(["clue_01_date_untouched"])
	_check(board.stuck_hint(7)["lead_clue"] == "clue_01_four_in_three", "从最早达阈值那条起找第一条未入录的")
	_check(board.total_stuck_hint_count() == 6, "卡关提示总数仍是 6")


# ============================================================================
#  6. 板面文本与截断
# ============================================================================

func _case_board_lines() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)
	board.set_owned_clues(["clue_01_four_in_three", "clue_01_hole_chipped"])

	var lines: Array[String] = board.board_lines()
	_check(lines.size() == 3, "两张卡下 board_lines() 三行：1 条矛盾 + 1 条推论 + 1 条差一步")
	_check(lines[0] == "⚠ 对不上：凿平面发黑（旧），孔口却崩了新口", "点亮矛盾的行带 '⚠ 对不上：' 前缀")
	_check(lines[1] == "★ 碑阴末行被改过", "核心推论带 '★' 前缀")
	_check(lines[2] == "…差 碑上两只手：末行不是同一只手写的", "'差一步'的行写出缺哪张卡的中文名（ded_02 缺碑上两只手）")

	board.set_owned_clues(ALL_CLUES)
	var full: Array[String] = board.board_lines(100)
	_check(full.size() == 16, "全线索下共 16 行：6 条矛盾 + 10 条推论（max_lines 够大就不截断）")
	_check(full[0] == "⚠ 对不上：文书里没有这个人，活人家里有一只碗", "排头的是未收束的核心矛盾 cf_03")
	_check(full[3].begins_with("✓ 已收束："), "已收束的矛盾写 '✓ 已收束：'")
	_check(full[5] == "✓ 已收束：看山人当它是游客丢的，袋里却是凿下的石屑", "已收束的次要矛盾也在矛盾段里")
	var last_conflict_index: int = -1
	var first_deduction_index: int = -1
	for index in range(full.size()):
		if full[index].begins_with("⚠ ") or full[index].begins_with("✓ "):
			last_conflict_index = index
		elif first_deduction_index < 0 and (full[index].begins_with("★ ") or full[index].begins_with("· ")):
			first_deduction_index = index
	_check(last_conflict_index == 5, "矛盾占了最前 6 行")
	_check(first_deduction_index == 6, "推论从第 7 行开始（矛盾确实在推论之前）")
	_check(full[6] == "★ 碑阴末行被改过", "推论按表内顺序")
	_check(full[11] == "· 改字的人是行内人", "非核心推论带 '·' 前缀（ded_06 core = false）")
	_check(full[15] == "· 此处曾改，不止一次", "最后一条也是非核心推论（ded_10）")

	var truncated: Array[String] = board.board_lines(12)
	_check(truncated.size() == 12, "board_lines(12) 恰好 12 行（截断后不再超）")
	_check(truncated[11] == "（还有 5 条未列）", "截断时末行写'（还有 5 条未列）'")
	_check(truncated[10] == "★ 改字是成心做的，做得很干净", "截断保留前面的行、按顺序")

	var three: Array[String] = board.board_lines(3)
	_check(three.size() == 3, "board_lines(3) 恰好 3 行")
	_check(three[2] == "（还有 14 条未列）", "board_lines(3) 的末行计数正确（16 - 2）")

	var one: Array[String] = board.board_lines(1)
	_check(one.size() == 1 and one[0] == "（还有 16 条未列）", "max_lines = 1 时只剩汇总行")
	_check(board.board_lines(0).is_empty(), "max_lines = 0 时返回空数组")
	_check(board.board_lines(-3).is_empty(), "max_lines 为负也返回空数组")
	_check(board.board_lines(7)[6] == "（还有 10 条未列）", "board_lines(7) = 6 条矛盾 + 汇总行")

	var six: Array[String] = board.board_lines(7)
	_check(six[0].begins_with("⚠ 对不上：") and six[1].begins_with("⚠ 对不上："), "矛盾段的前两行都是未收束的")


# ============================================================================
#  7. 记忆注入（表现层实际走的那条路）
# ============================================================================

func _case_memory_injection() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)
	var memory: FakeMemory = FakeMemory.new()
	_instances.append(memory)
	memory.remember("clue_01_four_in_three")
	memory.remember("clue_01_hole_chipped")
	var before: int = _signal_count
	board.set_memory_manager(memory)
	_check(board.get_memory_manager() == memory, "get_memory_manager() 取回注入的对象")
	_check(board.owned_cards().size() == 2, "注入记忆体后按它的线索算")
	_check(board.unlocked_deductions().size() == 1, "注入后 ded_01 成立")
	_check(_signal_count == before + 1, "注入后板上有内容：广播一次")
	_check(_same_list(board.get_owned_clues(), ["clue_01_four_in_three", "clue_01_hole_chipped"]),
		"get_owned_clues() 反映注入的记忆")

	# 记忆在组件外面变了：查询时自己跟上（不必显式 refresh）
	memory.remember("clue_01_rubbing_fragment")
	_check(board.is_conflict_ready("cf_01_stone_versus_paper"), "记忆里多一张卡，查询时自动跟上（无需 refresh）")
	_check(_signal_count == before + 2, "记忆变化引起的板上变化也会广播")
	_check(board.get_state()["memory_connected"] == true, "get_state() 标出记忆已连上")

	# 显式集合优先于注入的记忆（夹具要能钉住一个确定集合）
	board.set_owned_clues([])
	_check(board.owned_cards().is_empty(), "显式 set_owned_clues([]) 覆盖注入的记忆")
	board.reset()
	_check(board.owned_cards().size() == 3, "reset() 只清显式集合，不碰注入的记忆")

	# 只有 get_available_clues() 的对象（心灯）优先于 has_clue()
	var lamp: FakeLamp = FakeLamp.new()
	_instances.append(lamp)
	lamp.available = ["clue_01_four_in_three", "clue_01_hole_chipped", "clue_01_two_hands"]
	board.set_memory_manager(lamp)
	_check(board.owned_cards().size() == 3, "有 get_available_clues() 就用它（说真话的 has_clue 被忽略）")
	_check(board.unlocked_deductions().size() == 2, "心灯口径下 ded_01 / ded_02 都成立")

	# 注入的对象先被 free 掉：查询不崩，按空集处理（HUD 的 free 顺序不该成为陷阱）
	var doomed: FakeMemory = FakeMemory.new()
	_instances.append(doomed)
	doomed.remember("clue_01_four_in_three")
	board.set_memory_manager(doomed)
	_check(board.owned_cards().size() == 1, "换一个记忆体后重新算")
	doomed.free()
	_check(board.owned_cards().is_empty(), "记忆体被 free 之后按空集处理，不崩（is_instance_valid 守住了）")


# ============================================================================
#  8. 夹具与错误分类
# ============================================================================

func _case_fixtures() -> void:
	var good: Dictionary = {
		"meta": {"case_id": 9},
		"deductions": [
			{"deduction_id": "ded_x", "title": "夹具甲", "text": "甲文", "chain": "环一", "core": true,
				"require_cards": ["clue_ok_a"]},
			{"deduction_id": "ded_y", "title": "夹具乙", "text": "乙文", "chain": "环二", "core": false,
				"require_cards": ["clue_ok_a", "clue_ok_b"]},
		],
		"conflicts": [
			{"conflict_id": "cf_x", "title": "矛盾甲", "text": "甲", "severity": "核心",
				"require_cards": ["clue_ok_a"], "resolve_cards": ["clue_ok_b"]},
		],
		"stuck_hints": [
			{"after_loops_without_progress": 2, "lead_clue": "clue_ok_b", "npc_id": "npc_99",
				"room": "room_a", "second": 100, "text": "去甲处"},
			{"after_loops_without_progress": 3, "lead_clue": "clue_ok_a", "npc_id": "npc_99",
				"room": "room_b", "second": 359, "text": "去乙处"},
		],
	}
	var options: Dictionary = {
		"clue_names": {"clue_ok_a": "甲卡", "clue_ok_b": "乙卡"},
		"card_chains": {"clue_ok_a": "环一"},
	}
	var board: DeductionBoard = _new_board()
	_check(board.configure_with_rules(good, options), "夹具装载返回 true")
	_check(board.is_ok(), "夹具没有 error")
	_check(board.get_errors().is_empty(), "夹具 get_errors() 为空")
	_check(board.get_case_id() == 9, "夹具的 case_id 从 meta 读")
	_check(board.get_source() == "<inline>", "夹具的 source 标成 <inline>")
	_check(board.total_deduction_count() == 2, "夹具 2 条推论")
	_check(board.total_conflict_count() == 1, "夹具 1 条矛盾")
	_check(board.total_stuck_hint_count() == 2, "夹具 2 条提示")
	_check(board.total_clue_count() == 2, "夹具台账来自 options.clue_names")
	_check(board.card_name("clue_ok_a") == "甲卡", "options.clue_names 生效")
	_check(board.card_chain("clue_ok_a") == "环一", "options.card_chains 生效")
	_check(board.card_name("clue_zzz") == "clue_zzz", "夹具里没有的卡退回 id")
	_check(board.stuck_hint(2)["room"] == "room_a", "夹具提示的落点")
	_check(board.stuck_hint(2)["npc_name"] == "", "夹具里查不到的 npc 名给空串（不是 error）")
	board.set_owned_clues(["clue_ok_b"])
	_check(board.stuck_hint(2)["room"] == "room_b", "第一条 lead 到手后往前取到下一条（阈值 3 的那条）")
	_check(board.stuck_hint(3)["second"] == 359, "second = 359 是合法边界（余页 360 秒）")
	_check(board.stuck_hint(3)["lead_name"] == "甲卡", "夹具提示的 lead_name 来自 options.clue_names")

	board.set_owned_clues(["clue_ok_a"])
	_check(_same_list(_ids_of(board.unlocked_deductions(), "deduction_id"), ["ded_x"]), "夹具里成立的是 ded_x")
	_check(_same_list(_ids_of(board.nearly_locked(), "deduction_id"), ["ded_y"]), "夹具里差一步的是 ded_y")
	_check(_same_list(_row_by(board.nearly_locked(), "deduction_id", "ded_y")["missing_names"], ["乙卡"]),
		"夹具里 missing_names 用 options 的中文名")
	_check(board.ready_conflicts().size() == 1, "夹具矛盾已点亮")
	_check(board.ready_conflicts()[0]["resolved"] == false, "夹具矛盾未收束")
	_check(board.describe() == "推演板：1 条推论成立 / 1 条对不上（其中 1 条未收束）｜线索卡 1/2",
		"夹具 describe() 的分母退回板上卡数")
	board.set_owned_clues(["clue_ok_a", "clue_ok_b"])
	_check(board.ready_conflicts()[0]["resolved"] == true, "夹具矛盾收束")
	_check(_same_list(_ids_of(board.unlocked_deductions(), "deduction_id"), ["ded_x", "ded_y"]),
		"两张卡都入录后夹具两条推论都成立")

	# ---- 坏夹具：每一类问题都要被抓到，并且分类正确 ----
	var bad: Dictionary = {
		"meta": {"case_id": 1},
		"deductions": [
			{"deduction_id": "ded_dup", "title": "重复一", "text": "文", "chain": "环一", "core": true,
				"require_cards": ["clue_ok_a"]},
			{"deduction_id": "ded_dup", "title": "重复二", "text": "文", "chain": "环一", "core": false,
				"require_cards": ["clue_ok_a"]},
			{"deduction_id": "ded_unknown", "title": "未知卡", "text": "文", "chain": "环一", "core": true,
				"require_cards": ["clue_zzz_missing"]},
			{"deduction_id": "ded_no_title", "title": "", "text": "文", "chain": "环一", "core": true,
				"require_cards": ["clue_ok_a"]},
			{"deduction_id": "", "title": "没有 id", "text": "文", "chain": "环一", "core": true,
				"require_cards": ["clue_ok_a"]},
			{"deduction_id": "ded_free", "title": "开局就成立", "text": "文", "chain": "环一", "core": false,
				"require_cards": []},
		],
		"conflicts": [
			{"conflict_id": "cf_bad_severity", "title": "坏严重度", "text": "文", "severity": "诡异",
				"require_cards": ["clue_ok_a"], "resolve_cards": ["clue_ok_ab"]},
			{"conflict_id": "cf_no_text", "title": "没有正文", "text": "", "severity": "核心",
				"require_cards": ["clue_ok_a"], "resolve_cards": []},
		],
		"stuck_hints": [
			{"after_loops_without_progress": 0, "lead_clue": "clue_zzz_missing", "npc_id": "npc_1",
				"room": "", "second": 400, "text": "去哪儿"},
			{"after_loops_without_progress": 2, "lead_clue": "clue_ok_a", "npc_id": "npc_1",
				"room": "room_a", "second": 10, "text": ""},
		],
	}
	var broken: DeductionBoard = _new_board()
	_check(broken.configure_with_rules(bad, options) == false, "坏夹具返回 false")
	_check(broken.is_configured(), "坏夹具照样算'读进来了'（is_configured 与 is_ok 分开）")
	_check(broken.is_ok() == false, "坏夹具 is_ok() 为假")
	_check(broken.get_errors().size() >= 10, "坏夹具至少 10 条 error（逐项报）")
	_check(_has_error_like(broken, "clue_zzz_missing"), "报出不存在的 clue_id：clue_zzz_missing")
	_check(_has_error_like(broken, "是否想写"), "写错 id 时给拼写建议（clue_ok_ab → 提示 clue_ok_a）")
	_check(_has_error_like(broken, "deduction_id 重复：ded_dup"), "报出重复的 id")
	_check(_has_error_like(broken, "severity 非法：'诡异'"), "报出非法 severity")
	_check(_has_error_like(broken, "second 不在 0..359：400"), "报出越界的 second")
	_check(_has_error_like(broken, "after_loops_without_progress < 1"), "报出阈值 < 1")
	_check(_has_error_like(broken, "room 为空"), "报出空房间")
	_check(_has_error_like(broken, "的 text 缺失"), "报出缺失的 text")
	_check(_has_error_like(broken, "的 title 缺失"), "报出缺失的 title")
	_check(_has_error_like(broken, "deduction_id 为空"), "报出空的 id")
	_check(broken.error_summary().begins_with("deduction_board："), "error_summary() 带组件名")
	_check(broken.error_summary().contains("个错误"), "error_summary() 带错误数")

	_check(_has_warning_like(broken, "require_cards 为空"), "'require_cards 为空'只给 warning")
	_check(_has_error_like(broken, "require_cards 为空") == false, "'require_cards 为空'不算 error")
	_check(broken.total_deduction_count() == 5, "重复 id 的那一行被丢掉（6 - 1）")
	_check(broken.is_deduction_unlocked("ded_free"), "require_cards 为空的推论开局就成立（warning 的由来）")
	_check(broken.total_stuck_hint_count() == 2, "坏夹具的提示照样装进来")

	# 表可以缺省：没有 stuck_hints / conflicts 时只给 warning，不当结构性错误
	var minimal: Dictionary = {
		"meta": {"case_id": 1},
		"deductions": [
			{"deduction_id": "ded_only", "title": "只有推论", "text": "文", "chain": "", "core": true,
				"require_cards": ["clue_ok_a"]},
		],
	}
	var tiny: DeductionBoard = _new_board()
	_check(tiny.configure_with_rules(minimal, options), "只有 deductions 表也能装载")
	_check(tiny.get_errors().is_empty(), "缺表不算 error")
	_check(tiny.get_warnings().size() == 2, "缺 conflicts / stuck_hints 各给一条 warning")
	_check(tiny.total_conflict_count() == 0, "没有矛盾表时矛盾数为 0")
	_check(tiny.stuck_hint(9).is_empty(), "没有提示表时 stuck_hint() 返回空")


# ============================================================================
#  9. 快照可序列化 + 节点卫生
# ============================================================================

func _case_state_and_hygiene() -> void:
	var board: DeductionBoard = _new_board()
	board.configure(1)
	board.set_owned_clues(["clue_01_four_in_three", "clue_01_hole_chipped"])
	var state: Dictionary = board.get_state()
	var text: String = JSON.stringify(state)
	_check(not text.is_empty(), "get_state() 能 JSON.stringify（可序列化）")
	_check(text.begins_with("{"), "序列化结果是对象")
	var parsed: Variant = JSON.parse_string(text)
	_check(parsed is Dictionary, "序列化结果能解析回来")
	var back: Dictionary = parsed
	_check(back["unlocked_count"] == board.unlocked_deductions().size(), "快照里的成立数与查询一致")
	_check(back["deduction_count"] == 10, "快照里有推论总数")
	_check(back["conflict_count"] == 6, "快照里有矛盾总数")
	_check(back["stuck_hint_count"] == 6, "快照里有提示总数")
	_check(back["configured"] == true and back["ok"] == true, "快照里有可用性")
	_check(back["errors"] is Array and (back["errors"] as Array).is_empty(), "快照里有错误列表")
	_check(back["ready_conflict_ids"] is Array, "快照里有已点亮矛盾的 id 列表")
	_check(back["owned_card_count"] == 2, "快照里有已入录卡数")

	# 进树 → 用 → free：不留节点泄漏。
	# 注意：--script（SceneTree）模式下 root 里本来就有 Autoload（TimeLoopManager / PersistentMemoryManager），
	# 而且 _initialize() 期间 root.is_inside_tree() 还是 false（树还没走完 enter）——
	# 所以这里只断定"parent 是 root / 用完摘干净"，不断言 is_inside_tree()。
	var node: DeductionBoard = DeductionBoard.new()
	node.name = "DeductionBoardHygiene"
	var children_before: int = root.get_child_count()
	root.add_child(node)
	_check(node.get_parent() == root, "组件能 add_child() 进树（parent 是 root）")
	_check(root.get_child_count() == children_before + 1, "add_child() 之后 root 多了一个孩子")
	node.configure(1)
	node.set_owned_clues(ALL_CLUES)
	node.refresh()
	_check(node.unlocked_deductions().size() == 10, "进树之后照常工作")
	node.free()
	_check(not is_instance_valid(node), "free() 之后实例真的没了（没有 RefCounted 悬空引用）")
	_check(not root.has_node("DeductionBoardHygiene"), "free() 把它从树里摘干净了")
	_check(root.get_child_count() == children_before, "root 的孩子数回到进树之前（不留节点）")


# ============================================================================
#  断言 / 收尾
# ============================================================================

func _new_board() -> DeductionBoard:
	var board: DeductionBoard = DeductionBoard.new()
	board.board_changed.connect(_on_board_changed)
	_instances.append(board)
	return board


func _on_board_changed(unlocked_count: int, ready_conflict_count: int) -> void:
	_signal_count += 1
	_last_unlocked = unlocked_count
	_last_ready = ready_conflict_count


func _check(condition: bool, label: String) -> void:
	_executed += 1
	if condition:
		_passed += 1
		return
	_failed += 1
	_failures.append(label)
	print("  FAIL: %s" % label)


func _ids_of(rows: Array, key: String) -> Array[String]:
	var result: Array[String] = []
	for row in rows:
		result.append(String(row[key]))
	return result


func _row_by(rows: Array, key: String, value: String) -> Dictionary:
	for row in rows:
		if String(row[key]) == value:
			return row
	return {}


func _same_list(left: Variant, right: Variant) -> bool:
	if not (left is Array) or not (right is Array):
		return false
	var a: Array = left
	var b: Array = right
	if a.size() != b.size():
		return false
	for index in range(a.size()):
		if String(a[index]) != String(b[index]):
			return false
	return true


func _has_error_like(board: DeductionBoard, needle: String) -> bool:
	for message in board.get_errors():
		if message.contains(needle):
			return true
	return false


func _has_warning_like(board: DeductionBoard, needle: String) -> bool:
	for message in board.get_warnings():
		if message.contains(needle):
			return true
	return false


func _read_json_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var json: JSON = JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK:
		return {}
	var data: Variant = json.data
	if data is Dictionary:
		return data
	return {}


func _finish() -> void:
	for node in _instances:
		if is_instance_valid(node):
			node.free()
	_instances.clear()
	var total: int = _passed + _failed
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_passed, _failed, total])
	if _executed < EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数不足：%d < %d（脚本可能中途出错退出）" % [_executed, EXPECTED_CHECKS])
		quit(1)
		return
	if _failed > 0:
		print("RESULT: FAIL 推演板测试失败 %d 项" % _failed)
		quit(1)
		return
	print("RESULT: OK 推演板 %d 项断言全过（案一 10 推论 / 6 矛盾 / 6 提示）" % _passed)
	quit(0)
