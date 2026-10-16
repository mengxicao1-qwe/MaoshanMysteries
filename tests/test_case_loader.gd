extends SceneTree
## ============================================================================
##  test_case_loader.gd —— case_loader.gd 的离线自检（不依赖 data/scenarios 里有没有真文件）
## ----------------------------------------------------------------------------
##  运行方式（无需打开编辑器、无需 --import）：
##      godot --headless --path . --script res://tests/test_case_loader.gd
##
##  它用一段内联 JSON 夹具覆盖三类行为：
##    1. 正常案件：解析、排序、查询（node_at / rooms_at / clue_events / next_interesting_second）；
##    2. 可疑数据：乱序自动重排、缺 second:0、房间名打错 —— 只报警告，ok 仍为 true；
##    3. 结构性错误：非法 JSON、npcs 写成阶段一的字典、同秒重复、节点越界 —— ok 必须为 false。
##
##  末尾有 EXPECTED_CHECKS 执行数量守护：中途崩溃/提前 return 会让断言数对不上，
##  从而打印 FAIL 而不是"假绿"（Godot 的运行时错误不会改变退出码，这个守护是必需的）。
## ============================================================================

const CaseLoader = preload("res://scripts/data/case_loader.gd")

## 断言总数。加断言时必须同步改这里，否则本测试会自己报 FAIL。
const EXPECTED_CHECKS: int = 35

var _checks: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	_test_valid_case()
	_test_suspicious_data()
	_test_structural_errors()
	_report()


# ---------------------------------------------------------------------------
#  断言助手
# ---------------------------------------------------------------------------

func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)


func _check_eq(actual: Variant, expected: Variant, label: String) -> void:
	_checks += 1
	if actual != expected:
		_failures.append("%s（实际 %s，期望 %s）" % [label, str(actual), str(expected)])


# ---------------------------------------------------------------------------
#  1. 正常案件
# ---------------------------------------------------------------------------

const VALID_FIXTURE: String = """
{
  "meta": {
    "schema_version": 1,
    "map_id": "test_map",
    "case_id": 1,
    "case_title": "白鹄不举",
    "loop_duration_seconds": 360,
    "rooms": ["hall", "cellar"],
    "description": "夹具案件",
    "secret": { "kind": "test", "per_loop_mutation": { "mode": "shrink" } }
  },
  "npcs": [
    {
      "npc_id": "npc_01_a",
      "display_name": "甲",
      "default_room": "hall",
      "timeline": [
        { "second": 0,   "room": "hall",   "action": "wait",  "clue_id": "" },
        { "second": 120, "room": "cellar", "action": "dig",   "clue_id": "clue_01_shovel" }
      ]
    },
    {
      "npc_id": "npc_01_b",
      "display_name": "乙",
      "default_room": "cellar",
      "timeline": [
        { "second": 0,  "room": "cellar", "action": "hide", "clue_id": "" },
        { "second": 60, "room": "hall",   "action": "talk", "clue_id": "clue_01_letter" }
      ]
    }
  ]
}
"""

func _test_valid_case() -> void:
	var case := CaseLoader.parse_text(VALID_FIXTURE, "<fixture-valid>")

	_check(case.ok, "正常夹具应当解析成功")
	_check_eq(case.case_id, 1, "case_id 应被读出")
	_check_eq(case.case_title, "白鹄不举", "case_title 应被读出")
	_check_eq(case.display_title(), "案 01《白鹄不举》", "display_title 应拼出中文标题")
	_check_eq(case.loop_duration_seconds, 360, "余页长度应为 360")
	_check_eq(case.rooms.size(), 2, "应读出 2 个房间")
	_check_eq(case.npc_count(), 2, "应有 2 名 NPC")
	_check_eq(case.total_nodes(), 4, "应有 4 个时间节点")
	_check(case.warnings.is_empty(), "正常夹具不该产生任何警告")

	var schedule := case.npcs["npc_01_a"] as CaseLoader.NPCSchedule
	_check(schedule.node_at(-1) == null, "早于首个节点时应返回 null")
	_check_eq(schedule.room_at(0), "hall", "第 0 秒甲应在 hall")
	_check_eq(schedule.room_at(119), "hall", "第 119 秒甲仍应在 hall")
	_check_eq(schedule.room_at(120), "cellar", "第 120 秒甲应到 cellar")
	_check_eq(schedule.room_at(999), "cellar", "末节点之后应停在末节点")

	_check_eq(case.next_interesting_second(0), 60, "第 0 秒之后的下一处动向应是 60 秒")
	_check_eq(case.next_interesting_second(60), 120, "第 60 秒之后的下一处动向应是 120 秒")
	_check_eq(case.next_interesting_second(120), -1, "最后一处动线之后再无动向")

	var events := case.clue_events()
	_check_eq(events.size(), 2, "应有 2 个线索事件")
	_check_eq(int(events[0]["second"]), 60, "线索事件应按秒升序（第一条在 60 秒）")
	_check_eq(str(events[1]["clue_id"]), "clue_01_shovel", "第二条线索应是 clue_01_shovel")
	_check_eq(case.total_clues(), 2, "全案应有 2 条线索")
	_check_eq(case.observable_clues(60).size(), 1, "第 60 秒只有 1 条线索可观测")

	var rooms := case.rooms_at(0)
	_check(rooms.has("hall") and rooms.has("cellar"), "第 0 秒两个房间都有人")


# ---------------------------------------------------------------------------
#  2. 可疑但可继续的数据（只报警告）
# ---------------------------------------------------------------------------

const SUSPICIOUS_FIXTURE: String = """
{
  "meta": {
    "schema_version": 1,
    "map_id": "test_map",
    "case_id": 2,
    "case_title": "夹具二",
    "loop_duration_seconds": 300,
    "rooms": ["hall", "cellar"]
  },
  "npcs": [
    {
      "npc_id": "npc_02_a",
      "display_name": "丙",
      "default_room": "hall",
      "timeline": [
        { "second": 100, "room": "cellar", "action": "dig" },
        { "second": 50,  "room": "celar",  "action": "walk" }
      ]
    }
  ]
}
"""

func _test_suspicious_data() -> void:
	var case := CaseLoader.parse_text(SUSPICIOUS_FIXTURE, "<fixture-suspicious>")

	_check(case.ok, "可疑数据不应让装载失败")
	_check_eq(case.npc_count(), 1, "可疑夹具应有 1 名 NPC")

	var schedule := case.npcs["npc_02_a"] as CaseLoader.NPCSchedule
	_check_eq(schedule.nodes[0].second, 50, "乱序的时间线应被自动重排（第一项 50 秒）")
	_check_eq(schedule.nodes[1].second, 100, "乱序的时间线应被自动重排（第二项 100 秒）")

	var joined := "\n".join(case.warnings)
	_check(joined.contains("不是按秒升序"), "应警告时间线乱序")
	_check(joined.contains("第 0 秒没有节点"), "应警告缺少 second:0 节点")
	_check(joined.contains("是想写「cellar」吗"), "房间名打错时应给出拼写建议")


# ---------------------------------------------------------------------------
#  3. 结构性错误（必须 ok=false）
# ---------------------------------------------------------------------------

const LEGACY_SHAPE_FIXTURE: String = """
{ "meta": { "map_id": "m", "case_id": 3, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": { "npc_03_a": { "display_name": "丁" } } }
"""

const DUPLICATE_SECOND_FIXTURE: String = """
{ "meta": { "map_id": "m", "case_id": 4, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": [ { "npc_id": "npc_04_a", "display_name": "戊", "default_room": "hall",
    "timeline": [ { "second": 10, "room": "hall" }, { "second": 10, "room": "hall" } ] } ] }
"""

const OUT_OF_RANGE_FIXTURE: String = """
{ "meta": { "map_id": "m", "case_id": 5, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": [ { "npc_id": "npc_05_a", "display_name": "己", "default_room": "hall",
    "timeline": [ { "second": 90, "room": "hall" } ] } ] }
"""

func _test_structural_errors() -> void:
	var broken := CaseLoader.parse_text("{ this is not json", "<fixture-broken>")
	_check(not broken.ok, "非法 JSON 必须 ok=false")

	var legacy := CaseLoader.parse_text(LEGACY_SHAPE_FIXTURE, "<fixture-legacy>")
	_check(not legacy.ok, "npcs 写成阶段一字典时必须 ok=false")

	var duplicated := CaseLoader.parse_text(DUPLICATE_SECOND_FIXTURE, "<fixture-dup>")
	_check(not duplicated.ok, "同一 NPC 同秒两个节点必须 ok=false")

	var out_of_range := CaseLoader.parse_text(OUT_OF_RANGE_FIXTURE, "<fixture-range>")
	_check(not out_of_range.ok, "节点秒数超过余页长度必须 ok=false")

	var missing := CaseLoader.load_case("res://data/scenarios/__no_such_case__.json")
	_check(not missing.ok, "文件不存在时必须 ok=false 而不是崩溃")


# ---------------------------------------------------------------------------
#  结论
# ---------------------------------------------------------------------------

func _report() -> void:
	if _checks != EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数量异常：实际 %d，期望 %d（测试中途崩溃或提前返回）" % [
			_checks, EXPECTED_CHECKS,
		])
		quit(1)
		return

	if _failures.is_empty():
		print("RESULT: OK case_loader 自检通过 %d 项" % _checks)
		quit(0)
		return

	print("RESULT: FAIL case_loader 自检失败 %d/%d 项：" % [_failures.size(), _checks])
	for failure in _failures:
		print("  · %s" % failure)
	quit(1)
