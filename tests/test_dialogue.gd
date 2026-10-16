extends SceneTree
## ============================================================================
##  test_dialogue.gd —— dialogue_loader.gd 的离线自检（M1 对话层）
## ----------------------------------------------------------------------------
##  运行方式（无需打开编辑器、无需 --import）：
##      godot --headless --path . --script res://tests/test_dialogue.gd
##
##  四组覆盖：
##    1. 正常夹具：解析（meta / 条目 / 行 / 选项）、排序、查询
##       （get_dialogue / dialogue_ids / speakers / npc_id_of / say_for /
##        current_line / active_dialogues / available_options / reward_clue_ids /
##        dialogues_giving / all_reward_clue_ids）；
##    2. 可疑数据：缺 speaker、空台词、顺序乱、goto 悬空、无锚点 —— 只进 warnings，ok 仍为 true；
##    3. 结构性错误：非法 JSON、缺 meta、dialogues 写成数组、重复 dialogue_id、
##       缺 lines、秒数越界、引用不存在的 npc、clue_id 不在登记表 —— 必须 ok=false；
##    4. **真实数据断言**：data/dialogues/case_01_dialogues.json 的 38 条对话能被装载，
##       且原先不可达的两条线索 clue_01_double_knot / clue_01_keep_stele_motive 现在可达
##       （这是本次对话层要修掉的那个背景问题，只有这一组读真文件）。
##
##  末尾有 EXPECTED_CHECKS 执行数量守护：中途崩溃/提前 return 会让断言数对不上，
##  从而打印 FAIL 而不是"假绿"（Godot 的运行时错误不会改变退出码，这个守护是必需的）。
## ============================================================================

const DialogueLoader = preload("res://scripts/data/dialogue_loader.gd")

## 断言总数。加断言时必须同步改这里，否则本测试会自己报 FAIL。
const EXPECTED_CHECKS: int = 114

## 夹具里用到的 NPC 映射（正常夹具的 npc_id ↔ 显示名，与真实案件同形状）。
const FIXTURE_NPCS: Dictionary = {
	"npc_01_a": "甲先生",
	"甲先生": "npc_01_a",
	"npc_01_b": "乙姑娘",
	"乙姑娘": "npc_01_b",
}

## 夹具里登记在册的线索 id（模拟 data/clues/*.json 的登记表）。
const FIXTURE_CLUES: Array[String] = ["clue_01_knot", "clue_01_letter"]

var _passed: int = 0
var _failed: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	_test_valid_fixture()
	_test_suspicious_fixture()
	_test_structural_errors()
	_test_real_data()
	_report()


# ---------------------------------------------------------------------------
#  断言助手
# ---------------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		_failures.append(label)


func _check_eq(actual: Variant, expected: Variant, label: String) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failed += 1
		_failures.append("%s（实际 %s，期望 %s）" % [label, str(actual), str(expected)])


## 把内联夹具解析成表，并注入"已知 NPC + 已知线索"上下文（模拟 load_for_case 的做法）。
## 注意：解析本身不读任何真实文件；上下文只用常量，保证夹具结果不被磁盘数据污染。
## 名册必须在 parse_text() **之前**灌进去：speaker→npc_id 的解析发生在解析当拍。
## with_clues=false 用来把"线索登记表为空"这一档单独测出来（此时 clue_id 只查命名规范）。
func _parse_fixture(text: String, path: String, with_clues: bool = true) -> DialogueLoader.DialogueTable:
	DialogueLoader.reset_context()
	DialogueLoader.set_context_npcs(FIXTURE_NPCS)
	if with_clues:
		DialogueLoader.set_context_clue_ids(FIXTURE_CLUES)
	return DialogueLoader.parse_text(text, path)


func _joined_warnings(table: DialogueLoader.DialogueTable) -> String:
	return "\n".join(table.warnings)


func _joined_errors(table: DialogueLoader.DialogueTable) -> String:
	return "\n".join(table.errors)


# ---------------------------------------------------------------------------
#  1. 正常夹具
# ---------------------------------------------------------------------------

const VALID_FIXTURE: String = """
{
  "meta": {
    "schema_version": 1,
    "case_id": 7,
    "map_id": "test_map",
    "description": "夹具对话表"
  },
  "dialogues": {
    "a_00_hello": {
      "speaker": "甲先生",
      "unlock_if": { "has_clues": [], "loop_min": 0 },
      "lines": ["（他把手收进袖子里）你昨天也在这儿。", "我数了十九年台阶。"],
      "options": [
        { "text": "（先记住他站的是哪一级）", "reply": "（第七级。他一秒不差。）", "goto": "" },
        { "text": "再往上走一步？", "require_loop_min": 3, "goto": "a_01_up" }
      ],
      "note": "夹具：第一拍"
    },
    "a_01_up": {
      "speaker": "甲先生",
      "unlock_if": { "has_clues": ["clue_01_knot"], "loop_min": 3 },
      "lines": ["上面那级是空的。", "他数过的地方比别处亮一点。"],
      "options": [
        { "text": "（把那道结原样描在本子上）", "reply": "（双回结：先反手一圈，再回扣一道。）", "add_clue": "clue_01_knot", "goto": "" }
      ],
      "note": "夹具：第二拍"
    },
    "b_00_hide": {
      "speaker": "乙姑娘",
      "unlock_if": { "has_clues": [], "loop_min": 0 },
      "lines": ["（她把信压在碗底）", "（碗是空的，信也没有署名。）"],
      "options": [
        { "text": "（记下碗底压着什么）", "goto": "" }
      ],
      "note": "夹具：另一名 NPC"
    }
  }
}
"""

## 夹具锚点：把秒数喂进表里（真实数据里这些秒数来自 data/scenarios 的节点引用）。
const VALID_ANCHORS: Dictionary = {
	"a_00_hello": [35],
	"a_01_up": [140],
	"b_00_hide": [70],
}

func _test_valid_fixture() -> void:
	var table := _parse_fixture(VALID_FIXTURE, "<fixture-valid>")

	_check(table.ok, "正常夹具应当解析成功")
	_check_eq(table.errors.size(), 0, "正常夹具不该有结构性错误")
	_check_eq(table.warnings.size(), 0, "正常夹具不该有任何警告")
	_check_eq(table.case_id, 7, "case_id 应被读出")
	_check_eq(table.map_id, "test_map", "map_id 应被读出")
	_check_eq(table.schema_version, 1, "schema_version 应被读出")

	_check_eq(table.count(), 3, "应有 3 条对话")
	_check_eq(table.total_lines(), 6, "应有 6 句台词")
	_check_eq(table.total_options(), 4, "应有 4 个选项")
	_check_eq(table.dialogue_ids(), ["a_00_hello", "a_01_up", "b_00_hide"], "对话 id 应按文件顺序列出")
	_check(table.has_dialogue("a_00_hello"), "has_dialogue 应认得登记过的 id")
	_check(not table.has_dialogue("no_such_dialogue"), "has_dialogue 对未登记的 id 应返回 false")

	# —— 表级信息
	_check_eq(table.speakers(), ["甲先生", "乙姑娘"], "speakers 应去重且保持出现顺序")
	_check_eq(table.npc_ids(), ["npc_01_a", "npc_01_b"], "speaker 显示名应解析成 npc_id")
	_check_eq(table.npc_id_of("乙姑娘"), "npc_01_b", "npc_id_of 应把显示名解析成 npc_id")
	_check_eq(table.npc_id_of("查无此人"), "查无此人", "npc_id_of 解析不出来时应原样返回")

	# —— 条目级查询
	var hello: DialogueLoader.DialogueEntry = table.get_dialogue("a_00_hello")
	_check(hello != null, "get_dialogue 应取得到已登记的条目")
	_check(table.get_dialogue("no_such_dialogue") == null, "get_dialogue 取不到时应返回 null（不是崩溃）")
	_check_eq(hello.speaker, "甲先生", "条目 speaker 应被读出")
	_check_eq(hello.npc_id, "npc_01_a", "条目 npc_id 应由 speaker 解析而来")
	_check_eq(hello.line_count(), 2, "条目应有 2 句台词")
	_check_eq(hello.option_count(), 2, "条目应有 2 个选项")
	_check_eq(hello.loop_min, 0, "unlock_if.loop_min 应被读出")
	_check(hello.has_clues.is_empty(), "unlock_if.has_clues 为空时应无门槛")
	_check_eq(hello.text(), "（他把手收进袖子里）你昨天也在这儿。\n我数了十九年台阶。", "text() 应用换行拼起全部台词")
	_check_eq(hello.first_line(), "（他把手收进袖子里）你昨天也在这儿。", "first_line() 应给第一句")

	# —— 秒级锚定（真实数据里秒数不在对话文件里，靠场景节点引用补进来）
	_check(not hello.is_anchored(), "未喂锚点时条目不应声称有秒级锚点")
	var anchored := _parse_fixture(VALID_FIXTURE, "<fixture-valid>")
	anchored.apply_anchors(VALID_ANCHORS)
	var hello2: DialogueLoader.DialogueEntry = anchored.get_dialogue("a_00_hello")
	_check(hello2.is_anchored(), "喂过锚点后条目应被标记为已锚定")
	_check_eq(hello2.start_second, 35, "起拍秒应取锚点里最小的那个")
	_check_eq(hello2.anchored_seconds, [35], "anchored_seconds 应原样保留")
	_check_eq(anchored.last_anchor_second(), 140, "last_anchor_second 应给全表最大拍点")
	_check(hello2.is_active_at(35), "起拍那一秒条目应当可用")
	_check(not hello2.is_active_at(36), "默认窗口只有 1 秒，第 36 秒应当不可用")

	# —— 解锁门槛
	var up: DialogueLoader.DialogueEntry = anchored.get_dialogue("a_01_up")
	_check(not up.is_unlocked(0, []), "loop_min=3 时第 0 遍不该解锁")
	_check(not up.is_unlocked(3, []), "还缺 has_clues 时第 3 遍仍不该解锁")
	_check(up.is_unlocked(3, ["clue_01_knot"]), "门槛齐了才该解锁")
	_check(not anchored.is_available("a_01_up", 140, 2, ["clue_01_knot"]), "遍数不够时 is_available 应为 false")
	_check(anchored.is_available("a_01_up", 140, 3, ["clue_01_knot"]), "遍数与线索都够时应为 true")
	_check_eq(anchored.available_options("a_01_up", 3, ["clue_01_knot"]).size(), 1, "解锁后应有 1 个可选选项")

	# —— ★ "同处一室该说什么"入口
	var said := anchored.say_for("npc_01_a", 35, 0, [])
	_check_eq(said.size(), 1, "第 35 秒甲先生应当只说 1 条")
	if said.size() == 1:
		_check_eq(said[0].dialogue_id, "a_00_hello", "该条应是 a_00_hello")
	_check_eq(anchored.say_for("npc_01_a", 36, 0, []).size(), 0, "拍点过了之后不该再有话说")
	_check_eq(anchored.say_for("npc_01_b", 35, 0, []).size(), 0, "这一秒乙姑娘不该说话（她锚在 70）")
	var line: DialogueLoader.DialogueEntry = anchored.current_line("npc_01_b", 70, 0, [])
	_check(line != null and line.dialogue_id == "b_00_hide", "current_line 应给这一拍唯一那条")
	_check(anchored.current_line("npc_01_b", 999, 0, []) == null, "没有可说的时 current_line 应返回 null")
	_check_eq(anchored.active_dialogues(70, 0, []).size(), 1, "第 70 秒全表应有 1 条可触发")

	# —— 线索奖励
	_check_eq(anchored.reward_clue_ids("a_01_up"), ["clue_01_knot"], "应取到该条对话奖励的线索")
	_check(anchored.reward_clue_ids("a_00_hello").is_empty(), "不给线索的条目应返回空数组")
	_check_eq(anchored.dialogues_giving("clue_01_knot"), ["a_01_up"], "应能反查给这条线索的对话")
	_check_eq(anchored.all_reward_clue_ids(), ["clue_01_knot"], "全表奖励线索应去重")
	_check(anchored.is_known_clue("clue_01_knot"), "登记表里的线索应被认得")
	_check(not anchored.is_known_clue("clue_09_ghost"), "没登记的线索不该被认得")

	# —— 选项级门槛（per-option，不只看条目级 unlock_if）
	var hello_options := anchored.available_options("a_00_hello", 0, [])
	_check_eq(hello_options.size(), 1, "第 0 遍时只有 1 个选项可选（另一个要第 3 遍）")
	_check_eq(anchored.available_options("a_00_hello", 3, []).size(), 2, "第 3 遍两个选项都应可选")
	_check(anchored.option_available(anchored.get_dialogue("a_01_up").options[0], 3, ["clue_01_knot"]),
		"option_available 对门槛已满足的选项应返回 true")


# ---------------------------------------------------------------------------
#  2. 可疑但可继续的数据（只报警告）
# ---------------------------------------------------------------------------

const SUSPICIOUS_FIXTURE: String = """
{
  "meta": { "schema_version": 1, "case_id": 8, "map_id": "test_map" },
  "dialogues": {
    "c_00_late": {
      "speaker": "甲先生",
      "lines": ["这一条排在前面，但锚点在后。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 100"
    },
    "c_01_early": {
      "speaker": "甲先生",
      "lines": ["这一条锚点在前，却排在后面。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 50"
    },
    "c_02_nospeaker": {
      "lines": ["谁在说这句？"],
      "options": [ { "text": "（不知道是谁说的）", "goto": "" } ],
      "note": "夹具：缺 speaker"
    },
    "c_03_emptylines": {
      "speaker": "甲先生",
      "lines": ["", "   "],
      "options": [ { "text": "（空白台词）", "goto": "" } ],
      "note": "夹具：空文本"
    },
    "c_04_dangling": {
      "speaker": "甲先生",
      "lines": ["这一条跳向一个不存在的条目。"],
      "options": [ { "text": "跟过去", "goto": "no_such_dialogue" } ],
      "note": "夹具：悬空 goto"
    },
    "c_05_outsider": {
      "speaker": "路人甲乙丙",
      "lines": ["台词没问题，但说话的人不在本页名册上。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：speaker 不在名册"
    },
    "c_06_badclue": {
      "speaker": "甲先生",
      "lines": ["这一条给一条没登记的线索。"],
      "options": [ { "text": "（收下）", "add_clue": "clue-09-ghost", "goto": "" } ],
      "note": "夹具：clue_id 不合规范"
    },
    "c_07_shuffled": {
      "speaker": "乙姑娘",
      "lines": ["这一条按锚点应该在中间。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 70"
    }
  }
}
"""

const SUSPICIOUS_ANCHORS: Dictionary = {
	"c_00_late": [100],
	"c_01_early": [50],
	"c_07_shuffled": [70],
}

func _test_suspicious_fixture() -> void:
	# 这一组故意**不带线索登记表**解析：登记表为空时，clue_id 只按命名规范查（警告）；
	# "线索没登记"是结构性错误，归第 3 组测。
	var table := _parse_fixture(SUSPICIOUS_FIXTURE, "<fixture-suspicious>", false)
	table.apply_anchors(SUSPICIOUS_ANCHORS)

	_check(table.ok, "可疑数据不应让装载失败")
	_check_eq(table.errors.size(), 0, "可疑数据不该产生结构性错误（那是 error 的活）")
	_check_eq(table.count(), 8, "8 条对话都应被读出来")

	var joined := _joined_warnings(table)
	_check(joined.contains("没有 speaker"), "应警告缺 speaker")
	_check(joined.contains("台词是空的"), "应警告空台词")
	_check(joined.contains("no_such_dialogue"), "应警告 goto 指向不存在的对话")
	_check(joined.contains("不在案件 NPC 名单里"), "应警告 speaker 不在 NPC 名册上")
	_check(joined.contains("clue-09-ghost"), "应警告 clue_id 不符合命名规范")
	_check(joined.contains("不符合命名规范"), "命名规范的警告应说清是哪条规范")
	_check(joined.contains("不是按秒升序"), "应警告同一人的条目顺序与拍点矛盾（乱序自动重排）")
	_check(not table.get_dialogue("c_03_emptylines").is_anchored(), "没喂到锚点的条目不该被当成已锚定")

	# 乱序自动重排：list 顺序应改成按首拍秒升序，且不影响 id 查找
	_check_eq(table.dialogue_ids()[0], "c_01_early", "乱序应被自动重排（50 秒那条排到最前）")
	_check(table.get_dialogue("c_00_late") != null, "重排后仍应按 id 查得到条目")
	_check_eq(table.option_clue_ids(table.get_dialogue("c_06_badclue").options[0]), "clue-09-ghost",
		"option_clue_ids 应能取出选项上的 add_clue")


# ---------------------------------------------------------------------------
#  3. 结构性错误（必须 ok=false）
# ---------------------------------------------------------------------------

const NO_META_FIXTURE: String = """
{ "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["缺 meta。"], "options": [] } } }
"""

const DIALOGUES_AS_ARRAY_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": [ { "dialogue_id": "d_00", "lines": ["写成了数组。"] } ] }
"""

const EMPTY_ID_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "": { "speaker": "甲先生", "lines": ["id 是空的。"], "options": [] } } }
"""

const DUPLICATE_ID_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": {
    "d_00": { "speaker": "甲先生", "lines": ["第一份。"], "options": [] },
    "d_00": { "speaker": "甲先生", "lines": ["第二份，同 id。"], "options": [] }
  } }
"""

const NO_LINES_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "options": [] } } }
"""

const BAD_ENTRY_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "d_00": "这一条写成了字符串", "d_01": null } }
"""

## 越界夹具：case_id=10 无场景文件 ⇒ 余页长度取工程默认（全局夹具里会显式喂 300）。
const OUT_OF_RANGE_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["这一条锚在 999 秒。"], "options": [] } } }
"""

const UNKNOWN_NPC_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "npc_99_ghost", "lines": ["说话的人不在名册上。"], "options": [] } } }
"""

const UNKNOWN_CLUE_FIXTURE: String = """
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["给一条没登记的线索。"],
    "options": [ { "text": "（收下）", "add_clue": "clue_01_knots", "goto": "" } ] } } }
"""

func _test_structural_errors() -> void:
	var broken := _parse_fixture("{ this is not json", "<fixture-broken>")
	_check(not broken.ok, "非法 JSON 必须 ok=false")
	_check(not broken.error.is_empty(), "非法 JSON 必须给出一句可读的 error")

	var no_meta := _parse_fixture(NO_META_FIXTURE, "<fixture-no-meta>")
	_check(not no_meta.ok, "缺 meta 必须 ok=false")
	_check(_joined_errors(no_meta).contains("meta"), "缺 meta 的错误信息应点名 meta")

	var as_array := _parse_fixture(DIALOGUES_AS_ARRAY_FIXTURE, "<fixture-array>")
	_check(not as_array.ok, "dialogues 写成数组必须 ok=false")
	_check(_joined_errors(as_array).contains("对象"), "dialogues 写成数组时应提示它必须是对象")

	var empty_id := _parse_fixture(EMPTY_ID_FIXTURE, "<fixture-empty-id>")
	_check(not empty_id.ok, "空 dialogue_id 必须 ok=false")

	var duplicated := _parse_fixture(DUPLICATE_ID_FIXTURE, "<fixture-dup>")
	_check(not duplicated.ok, "重复 dialogue_id 必须 ok=false")
	_check(_joined_errors(duplicated).contains("重复"), "重复 id 的错误信息应点名'重复'")

	var no_lines := _parse_fixture(NO_LINES_FIXTURE, "<fixture-no-lines>")
	_check(not no_lines.ok, "缺 lines 必须 ok=false")

	var bad_entry := _parse_fixture(BAD_ENTRY_FIXTURE, "<fixture-bad-entry>")
	_check(not bad_entry.ok, "条目值不是对象必须 ok=false")

	# —— 越界 / 交叉引用：这两类要"有上下文才报"，先无上下文解析、再带上下文复检
	var out_of_range := _parse_fixture(OUT_OF_RANGE_FIXTURE, "<fixture-range>")
	out_of_range.loop_duration_seconds = 300
	out_of_range.apply_anchors({"d_00": [999]})
	var strict_range := out_of_range.validate_strict()
	_check(not strict_range.ok, "秒数超过余页长度必须 ok=false")
	_check(_joined_errors(strict_range).contains("越界") or _joined_errors(strict_range).contains("超过"),
		"越界的错误信息应说清超出了余页长度")

	var unknown_npc := _parse_fixture(UNKNOWN_NPC_FIXTURE, "<fixture-unknown-npc>")
	var strict_npc := unknown_npc.validate_strict()
	_check(not strict_npc.ok, "引用不存在的 npc_id 必须 ok=false")
	_check(_joined_errors(strict_npc).contains("npc_99_ghost"), "应点名那个不存在的 npc_id")

	var unknown_clue := _parse_fixture(UNKNOWN_CLUE_FIXTURE, "<fixture-unknown-clue>")
	var strict_clue := unknown_clue.validate_strict()
	_check(not strict_clue.ok, "clue_id 不在线索登记表里必须 ok=false")
	_check(_joined_errors(strict_clue).contains("clue_01_knots"), "应点名那个没登记的 clue_id")
	_check(_joined_errors(strict_clue).contains("是想写"), "写错 clue_id 时应给编辑距离拼写建议")

	var missing := DialogueLoader.load_from_file("res://data/dialogues/__no_such_file__.json", "")
	_check(not missing.ok, "对话文件不存在时必须 ok=false 而不是崩溃")
	_check(missing.count() == 0, "装载失败时应返回空表（count=0）")


# ---------------------------------------------------------------------------
#  4. 真实数据断言（唯一读真文件的一组）
#     —— 本次对话层要修掉的背景问题：data/clues/case_01_clues.json 里
#        clue_01_double_knot / clue_01_keep_stele_motive 的来源写着"对话 add_clue"，
#        但此前没有任何代码读 data/dialogues ⇒ 14 条登记线索里这 2 条不可达。
# ---------------------------------------------------------------------------

const REAL_DIALOGUE_PATH: String = "res://data/dialogues/case_01_dialogues.json"
const REAL_CLUE_PATH: String = "res://data/clues/case_01_clues.json"
const ORPHAN_CLUES: Array[String] = ["clue_01_double_knot", "clue_01_keep_stele_motive"]

func _test_real_data() -> void:
	DialogueLoader.reset_context()
	var table: DialogueLoader.DialogueTable = DialogueLoader.load_for_case(1)

	_check(table.ok, "真实对话表必须装载成功（errors 为空）")
	_check_eq(table.errors.size(), 0, "真实对话表不该有结构性错误")
	_check_eq(table.warnings.size(), 0, "真实对话表不该刷出警告噪音")
	_check_eq(table.count(), 38, "案一应有 38 条对话")
	_check_eq(table.loop_duration_seconds, 360, "案一余页长度应从场景文件读出 360")
	_check(table.case_path.ends_with("case_01_baihu.json"), "应自动配上案一的场景文件（秒级锚点来源）")
	_check(table.is_known_clue(ORPHAN_CLUES[0]), "线索登记表里应有 clue_01_double_knot")
	_check(table.is_known_clue(ORPHAN_CLUES[1]), "线索登记表里应有 clue_01_keep_stele_motive")

	# ★ 两条孤儿线索现在可达
	for clue_id in ORPHAN_CLUES:
		var givers := table.dialogues_giving(clue_id)
		_check(not givers.is_empty(), "%s 必须有一条对话能给（此前不可达）" % clue_id)
	_check_eq(table.dialogues_giving("clue_01_double_knot"), ["qdm_02_bag"],
		"clue_01_double_knot 应由 qdm_02_bag 给出")
	_check_eq(table.dialogues_giving("clue_01_keep_stele_motive"), ["qdm_04_ningque"],
		"clue_01_keep_stele_motive 应由 qdm_04_ningque 给出")
	_check(table.all_reward_clue_ids().has("clue_01_double_knot"), "全表奖励线索应含 clue_01_double_knot")
	_check(table.all_reward_clue_ids().has("clue_01_keep_stele_motive"), "全表奖励线索应含 clue_01_keep_stele_motive")

	var qdm: DialogueLoader.DialogueEntry = table.get_dialogue("qdm_04_ningque")
	_check(qdm != null, "qdm_04_ningque 应存在")
	if qdm != null:
		var option: DialogueLoader.DialogueOption = qdm.options[0]
		_check(option.gives_clue(), "qdm_04_ningque 的选项应带 add_clue")
		_check_eq(option.add_clue, "clue_01_keep_stele_motive", "该选项应给 clue_01_keep_stele_motive")
		_check_eq(option.require_loop_min, 8, "该选项应要求第 8 遍起")
		_check(option.require_clues.has("clue_01_date_untouched"), "该选项应要求先有 clue_01_date_untouched")

	# 真实数据里的秒级锚点：来自场景节点引用
	var rub: DialogueLoader.DialogueEntry = table.get_dialogue("mq_03_rubbing")
	_check(rub != null and rub.is_anchored(), "mq_03_rubbing 应从场景节点上拿到秒级锚点")
	if rub != null and rub.is_anchored():
		_check_eq(rub.start_second, 240, "mq_03_rubbing 的拍点应是 240 秒")
	# 这一条自己有门槛（第 2 遍 + clue_01_two_hands）：同一秒，门槛没到就不该开口，到点了才说话。
	_check_eq(table.say_for("npc_01_muqing", 240, 0, []).size(), 0, "门槛没到时穆青在第 240 秒不该开口")
	_check_eq(table.say_for("npc_01_muqing", 240, 2, ["clue_01_two_hands"]).size(), 1,
		"门槛齐了（第 2 遍 + clue_01_two_hands）穆青在第 240 秒应说 1 条")
	_check_eq(table.last_anchor_second(), 355, "案一最后一个对话拍点应是 355 秒")

	# 真实数据的 speaker 全部能解析成 npc_id（否则 speaker 就是没对上名册）
	var unresolved: Array[String] = []
	for speaker in table.speakers():
		if table.npc_id_of(speaker) == speaker:
			unresolved.append(speaker)
	_check_eq(unresolved.size(), 0, "真实数据里每个 speaker 都应能解析成 npc_id")


# ---------------------------------------------------------------------------
#  结论
# ---------------------------------------------------------------------------

func _report() -> void:
	var executed: int = _passed + _failed
	if executed != EXPECTED_CHECKS:
		_failed += 1
		_failures.append("断言执行数量异常：实际 %d 项，期望 %d 项（测试中途崩溃/提前 return，或改了断言却忘了同步 EXPECTED_CHECKS）"
			% [executed, EXPECTED_CHECKS])

	print("----------------------------------------------------------")
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_passed, _failed, executed])

	if _failed > 0:
		print("RESULT: FAIL dialogue_loader 自检失败 %d/%d 项：" % [_failed, executed])
		for failure in _failures:
			print("  · %s" % failure)
		quit(1)
		return

	print("RESULT: OK dialogue_loader 对话层 %d 项断言全部通过（解析/查询/错误与警告分类/线索交叉引用/两条孤儿线索可达）"
		% _passed)
	quit(0)
