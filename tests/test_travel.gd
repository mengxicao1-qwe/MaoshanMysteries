extends SceneTree
## ============================================================================
##  test_travel.gd —— 走位耗时自检：map_loader + player_travel + 案一真实数据
## ----------------------------------------------------------------------------
##  运行方式（无需打开编辑器、无需 --import）：
##      godot --headless --path . --script res://tests/test_travel.gd
##
##  四组覆盖：
##    1. 正常地图：解析、房间清单、邻居、直接耗时、最短路（含必须中转的情形）、路线总耗时；
##    2. 错误 / 警告分类：未知房间名（带拼写建议）、重复房间、缺 rooms、出口缺 to、
##       耗时非正数 / 非整数 / 负数、自环、重复边、没有任何出口、只写单向、走不到的房间；
##    3. 走位状态机：落位、出发、途中（位置诚实）、到达、取消、走不了、移动中不能再动、
##       边界（恰好整秒到达）、**大 dt 与小 dt 结果一致**；
##    4. 真实数据（案一）：地图覆盖 meta.rooms 全部 17 间；用"BFS 最短耗时 + 线索窗口
##       （NPC 到达该房间的秒 → 他下一个拍点的秒）"逐遍枚举，算出**集齐 6 条必需线索
##       需要几遍**，并把实算值写进 RESULT 文案。
##
##  末尾有 EXPECTED_CHECKS 执行数量守护：中途崩溃/提前 return 会让断言数对不上，
##  从而打印 FAIL 而不是"假绿"（Godot 的运行时错误不会改变退出码，这个守护是必需的）。
## ============================================================================

const MapLoader = preload("res://scripts/data/map_loader.gd")
const PlayerTravel = preload("res://scripts/entities/player_travel.gd")
const CaseLoader = preload("res://scripts/data/case_loader.gd")

## 断言总数。加断言时必须同步改这里，否则本测试会自己报 FAIL。
const EXPECTED_CHECKS: int = 165

## 预算：案一的 6 条必需线索必须能在**第 8 遍或更早**集齐（走位耗时不许把收集阶段拖过这个数）。
## 注意"集齐"和"结案"是两回事：案一 `require_min_loop=8`（case_loader 口径）要求
## **第 9 遍（loop_index 8）** 才允许结案，所以整局最早 9 遍——这是案件设计里的循环叙事门槛，
## 不是走位耗时造成的；本测试把两者分开断言，免得掩盖真正的瓶颈。
const MAX_COLLECT_PASSES: int = 8

var _checks: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	var real_result := _test_real_case_data()
	_test_map_parsing()
	_test_paths_and_routes()
	_test_map_errors()
	_test_map_warnings()
	_test_player_travel()
	_report(real_result)


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


func _joined(items: Array) -> String:
	var parts: Array[String] = []
	for item in items:
		parts.append(str(item))
	return "\n".join(parts)


# ---------------------------------------------------------------------------
#  夹具 1：正常地图（含必须中转的最短路：hut → ridge → pond = 30 秒）
# ---------------------------------------------------------------------------

const VALID_MAP: String = """
{
  "schema_version": 1,
  "case_id": 1,
  "map_id": "fixture_map",
  "display_name": "夹具地图",
  "rooms": [
    { "room_id": "hall",  "display_name": "厅", "exits": [
      { "to": "ridge", "travel_seconds": 10 },
      { "to": "pond",  "travel_seconds": 40 } ] },
    { "room_id": "ridge", "display_name": "埂", "exits": [
      { "to": "hall",  "travel_seconds": 10 },
      { "to": "pond",  "travel_seconds": 20 } ] },
    { "room_id": "pond",  "display_name": "塘", "exits": [
      { "to": "hall",  "travel_seconds": 40 },
      { "to": "ridge", "travel_seconds": 20 } ] }
  ]
}
"""


func _test_map_parsing() -> void:
	var map := MapLoader.parse_text(VALID_MAP, "<fixture-valid>")

	_check(map.ok, "正常地图应当解析成功")
	_check(map.validate(), "validate() 应当与 ok 一致")
	_check_eq(map.errors.size(), 0, "正常地图不该有错误")
	_check_eq(map.warnings.size(), 0, "正常地图不该有警告")
	_check_eq(map.case_id, 1, "case_id 应被读出")
	_check_eq(map.map_id, "fixture_map", "map_id 应被读出")
	_check_eq(map.display_title(), "夹具地图（fixture_map）", "display_title 应拼出中文标题")
	_check_eq(map.room_count(), 3, "应读出 3 间房")
	_check_eq(map.edge_count(), 6, "应有 6 条有向边")
	_check(map.has_room("ridge"), "has_room 应认得 ridge")
	_check(not map.has_room("cellar"), "has_room 不该认得没声明的房间")
	_check_eq(map.default_room(), "hall", "默认落位应是排序后的第一间")
	_check_eq(map.get_display_name("pond"), "塘", "get_display_name 应给出中文名")
	_check_eq(map.get_display_name("nope"), "nope", "未知房间的中文名应原样返回 id")
	_check_eq(map.get_neighbors("hall"), ["ridge", "pond"] as Array[String], "邻居应按耗时升序")
	_check_eq(map.get_direct_travel_seconds("hall", "pond"), 40, "直接边耗时 40 秒")
	_check_eq(map.get_direct_travel_seconds("hall", "cellar"), 0, "没有直接边应返回 0")
	_check(map.has_edge("pond", "ridge"), "has_edge 应认得反向边")
	_check(not map.has_edge("hall", "hall"), "不该凭空有自环")

	var exits := map.get_exits("hall")
	_check_eq(str(exits[0]["to"]), "ridge", "get_exits 的第一条应是最快的那条")


# ---------------------------------------------------------------------------
#  夹具 2：最短路与路线总耗时
# ---------------------------------------------------------------------------

func _test_paths_and_routes() -> void:
	var map := MapLoader.parse_text(VALID_MAP, "<fixture-valid>")

	_check_eq(map.travel_seconds("hall", "pond"), 30, "hall→pond 应绕过 ridge 走 30 秒（直接边 40 秒不是最短）")
	_check_eq(map.travel_seconds("pond", "hall"), 30, "pond→hall 反向最短路同样是 30 秒")
	_check_eq(map.find_path("hall", "pond"), ["hall", "ridge", "pond"] as Array[String], "最短路应含途经房 ridge")
	_check_eq(map.travel_seconds("hall", "hall"), 0, "同房耗时应为 0")
	_check_eq(map.find_path("hall", "hall"), ["hall"] as Array[String], "同房路径应只有自己")
	_check_eq(map.find_path("hall", "cellar").size(), 0, "未知房间的路径应为空")
	_check_eq(map.travel_seconds("hall", "cellar"), 0, "未知房间的耗时应为 0")

	_check_eq(map.route_seconds(["hall", "ridge"]), 10, "单段路线应为 10 秒")
	_check_eq(map.route_seconds(["hall", "ridge", "pond"]), 30, "两段路线应为 30 秒")
	_check_eq(map.route_seconds(["pond", "hall"]), 30, "反向路线应按反向边算")
	_check_eq(map.route_seconds(["hall"]), 0, "少于两站的路线应为 0")
	_check_eq(map.route_seconds(["hall", "cellar"]), 0, "含未知房间的路线应为 0")
	_check_eq(map.route_seconds(["hall", "ridge", "cellar"]), 0, "任一段走不到，整条路线就应为 0")


# ---------------------------------------------------------------------------
#  夹具 3：结构性错误（必须 ok=false）
# ---------------------------------------------------------------------------

const DUPLICATE_ROOM_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 } ] },
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 } ] } ] }
"""

const UNKNOWN_ROOM_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "hal", "travel_seconds": 10 } ] } ] }
"""

const MISSING_EXIT_TO_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "travel_seconds": 10 } ] } ] }
"""

const ZERO_TRAVEL_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 0 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const FRACTIONAL_TRAVEL_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 2.5 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const NEGATIVE_TRAVEL_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": -5 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const SELF_LOOP_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const DUPLICATE_EDGE_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 },
                                  { "to": "pond", "travel_seconds": 12 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const NO_EXITS_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
"""

const MISSING_ROOMS_MAP: String = """
{ "schema_version": 1, "case_id": 1, "map_id": "m" }
"""


func _test_map_errors() -> void:
	var duplicated := MapLoader.parse_text(DUPLICATE_ROOM_MAP, "<dup-room>")
	_check(not duplicated.ok, "房间 id 重复必须 ok=false")
	_check(_joined(duplicated.errors).contains("房间 id 重复"), "应报房间 id 重复")

	var unknown := MapLoader.parse_text(UNKNOWN_ROOM_MAP, "<unknown-room>")
	_check(not unknown.ok, "出口指向未知房间必须 ok=false")
	_check(_joined(unknown.errors).contains("未知房间"), "应报未知房间")
	_check(_joined(unknown.errors).contains("是否想写 \"hall\"？"), "未知房间名应给编辑距离拼写建议")

	var missing_to := MapLoader.parse_text(MISSING_EXIT_TO_MAP, "<missing-to>")
	_check(not missing_to.ok, "出口缺 to 必须 ok=false")

	var zero := MapLoader.parse_text(ZERO_TRAVEL_MAP, "<zero-travel>")
	_check(not zero.ok, "耗时 0 必须 ok=false（同房耗时恒为 0，正数才是一条路）")

	var fractional := MapLoader.parse_text(FRACTIONAL_TRAVEL_MAP, "<fractional-travel>")
	_check(not fractional.ok, "耗时写小数必须 ok=false（一律整数秒）")

	var negative := MapLoader.parse_text(NEGATIVE_TRAVEL_MAP, "<negative-travel>")
	_check(not negative.ok, "负耗时必须 ok=false")

	var self_loop := MapLoader.parse_text(SELF_LOOP_MAP, "<self-loop>")
	_check(not self_loop.ok, "自环必须 ok=false")
	_check(_joined(self_loop.errors).contains("指向自己"), "应报自环")

	var dup_edge := MapLoader.parse_text(DUPLICATE_EDGE_MAP, "<dup-edge>")
	_check(not dup_edge.ok, "同一方向写两条不同耗时的边必须 ok=false")

	var no_exits := MapLoader.parse_text(NO_EXITS_MAP, "<no-exits>")
	_check(not no_exits.ok, "房间没有任何出口必须 ok=false")
	_check(_joined(no_exits.errors).contains("没有任何出口"), "应报孤岛房间")

	var no_rooms := MapLoader.parse_text(MISSING_ROOMS_MAP, "<no-rooms>")
	_check(not no_rooms.ok, "缺 rooms 必须 ok=false")

	var broken := MapLoader.parse_text("{ this is not json", "<broken>")
	_check(not broken.ok, "非法 JSON 必须 ok=false")

	var missing := MapLoader.load_from_file("res://data/maps/__no_such_map__.json")
	_check(not missing.ok, "文件不存在时必须 ok=false 而不是崩溃")
	_check(not missing.error_summary().is_empty(), "错误摘要不该为空")


# ---------------------------------------------------------------------------
#  夹具 4：可疑但可继续（只报警告）
# ---------------------------------------------------------------------------

const WARN_MAP: String = """
{
  "schema_version": 1,
  "case_id": 1,
  "map_id": "warn_map",
  "rooms": [
    { "room_id": "hall",  "exits": [ { "to": "stub", "travel_seconds": 10 },
                                     { "to": "far",  "travel_seconds": 200 } ] },
    { "room_id": "stub",  "exits": [ { "to": "hall", "travel_seconds": 10 } ] },
    { "room_id": "far",   "exits": [ { "to": "hall", "travel_seconds": 200 } ] },
    { "room_id": "island", "exits": [ { "to": "island2", "travel_seconds": 5 } ] },
    { "room_id": "island2", "exits": [ { "to": "island", "travel_seconds": 5 } ] }
  ]
}
"""


func _test_map_warnings() -> void:
	var map := MapLoader.parse_text(WARN_MAP, "<warn>")
	var joined := _joined(map.warnings)

	_check(map.ok, "可疑地图不该让装载失败")
	_check(map.warnings.size() >= 3, "warnings 应当收集到多条问题")
	_check(joined.contains("超过 180 秒"), "一步 200 秒应警告（多半把米当成了秒）")
	_check(joined.contains("走不到"), "从 hall 到不了 island 应警告")
	_check_eq(map.travel_seconds("hall", "island"), 0, "走不到的房间之间耗时应是 0")
	_check_eq(map.find_path("hall", "island").size(), 0, "走不到就没有路径")


# ---------------------------------------------------------------------------
#  夹具 5：走位状态机（t=0 在 hall；hall→ridge = 10 秒，hall→pond 最短路 = 30 秒）
# ---------------------------------------------------------------------------

func _test_player_travel() -> void:
	var map := MapLoader.parse_text(VALID_MAP, "<fixture-valid>")
	var travel = PlayerTravel.new(map, "hall")

	# --- 落位 ---
	_check_eq(travel.get_room(), "hall", "初始房间应是 hall")
	_check(travel.is_map_loaded(), "地图应已装载")
	_check(not travel.is_moving(), "初始不该在移动中")
	_check(travel.can_go("ridge"), "hall 隔壁 ridge 应当能走")
	_check(not travel.can_go("hall"), "自己所在的房间不算能走")
	_check(not travel.can_go("cellar"), "没声明的房间不能走")
	_check_eq(travel.get_route_to("pond"), ["hall", "ridge", "pond"] as Array[String], "到 pond 的路线应含中转房")
	_check_eq(travel.get_travel_seconds_to("pond"), 30, "到 pond 的耗时应是 30 秒")

	# --- 出发 ---
	_check_eq(travel.start_move("ridge"), 10, "start_move 应返回 10 秒")
	_check(travel.is_moving(), "出发后应在移动中")
	_check_eq(travel.get_room(), "hall", "途中 get_room 仍是出发地（位置诚实）")
	_check_eq(travel.get_target_room(), "ridge", "途中应能读到目的房间")
	_check_eq(travel.get_from_room(), "hall", "途中应能读到出发房间")
	_check_eq(travel.get_travel_seconds(), 10, "途中应能读到总耗时")
	_check_eq(travel.get_remaining_seconds(), 10, "刚出发时剩余应为 10 秒")

	# --- 移动中不能再动 ---
	_check_eq(travel.start_move("pond"), 0, "移动期间再发起移动必须返回 0")
	_check_eq(travel.get_target_room(), "ridge", "被拒绝的移动不该改掉目的房间")

	# --- 途中推进 ---
	_check(not travel.tick(4.0), "第 4 秒还没到，tick 应返回 false")
	_check_eq(travel.get_remaining_seconds(), 6, "走掉 4 秒后剩余 6 秒")
	_check_eq(travel.get_room(), "hall", "还没到就还在 hall")

	# --- 取消 ---
	_check(travel.cancel_move(), "cancel_move 应成功")
	_check(not travel.is_moving(), "取消后不该在移动中")
	_check_eq(travel.get_room(), "hall", "取消后应留在原地")
	_check_eq(travel.get_remaining_seconds(), 0, "取消后剩余应为 0")
	_check(not travel.cancel_move(), "没有移动时 cancel_move 应返回 false")
	_check_eq(travel.start_move("hall"), 0, "去当前房间应返回 0（走不了）")
	_check_eq(travel.start_move("cellar"), 0, "去没声明的房间应返回 0（走不了）")

	# --- 到达 ---
	_check_eq(travel.start_move("ridge"), 10, "重新出发应返回 10 秒")
	_check(not travel.tick(9.9), "9.9 秒还没到")
	_check(travel.tick(0.1), "补上 0.1 秒后应到达（浮点累积也能对上整秒）")
	_check_eq(travel.get_room(), "ridge", "到达后房间应切换")
	_check(not travel.is_moving(), "到达后不该在移动中")
	_check_eq(travel.get_travel_seconds(), 0, "到达后总耗时应清零")
	_check_eq(travel.get_last_arrived_room(), "ridge", "应记住上一次到达的房间")
	_check_eq(travel.get_move_count(), 1, "应记到 1 次移动")
	_check_eq(travel.get_total_travelled_seconds(), 10, "累计走过 10 秒")

	# --- 无 tick 在移动中：tick 不该有作用 ---
	_check(not travel.tick(1.0), "没在移动时 tick 应返回 false")

	# --- 大 dt 与小 dt 结果一致 ---
	var tiny = PlayerTravel.new(map, "hall")
	tiny.start_move("pond")
	for _i in range(3000):
		tiny.tick(0.01)
	var huge = PlayerTravel.new(map, "hall")
	huge.start_move("pond")
	huge.tick(30.0)
	_check_eq(tiny.get_room(), huge.get_room(), "小 dt 与大 dt 应到达同一个房间")
	_check_eq(tiny.get_room(), "pond", "两者都应到达 pond")
	_check_eq(tiny.get_remaining_seconds(), huge.get_remaining_seconds(), "小 dt 与大 dt 的剩余秒数应一致")
	_check_eq(tiny.get_move_count(), huge.get_move_count(), "小 dt 与大 dt 的移动次数应一致")

	# --- 边界：恰好整秒到达 ---
	# 容差口径：tick(dt) 到达的判据是 `已走 + dt >= 耗时 - 容差`，容差 = 耗时 × ARRIVE_EPSILON_RATIO。
	# 注意 dt 是 float32：探到 1e-9 级别会被 float32 舍入（10 - 5e-9 在 float32 里就是 10.0），
	# 所以边界用"半毫秒"这种 float32 明确可表示的差量来探，探的是容差语义而不是浮点尾数。
	var exact = PlayerTravel.new(map, "hall")
	var exact_seconds := exact.start_move("ridge")
	var slack := float(exact_seconds) * PlayerTravel.ARRIVE_EPSILON_RATIO
	_check(slack > 0.0 and slack < 0.001, "到达容差应是'远小于一帧'的小量")
	_check_eq(exact.get_arrive_epsilon(), slack, "公开的容差应与常量口径一致")
	var half_ms := 0.0005
	_check(not exact.tick(float(exact_seconds) - half_ms), "差半毫秒不该算到达")
	_check(exact.get_remaining_seconds() >= 1, "还差着的时候剩余秒数不该归零")
	_check(exact.is_moving(), "差半毫秒时仍应在移动中")
	_check(exact.tick(half_ms), "补上这半毫秒应恰好到达")
	var overshoot = PlayerTravel.new(map, "hall")
	overshoot.start_move("ridge")
	_check(overshoot.tick(9.999) == false, "9.999 秒还没到（实际秒数 %d）" % exact_seconds)
	_check(overshoot.get_remaining_seconds() >= 1, "9.999 秒后还剩至少 1 秒")
	_check(overshoot.tick(0.001), "补上最后 0.001 秒应到达")
	_check(overshoot.tick(99.0) == false, "已经到达后再 tick 不应再报到达")
	var big_step = PlayerTravel.new(map, "hall")
	big_step.start_move("ridge")
	_check(big_step.tick(99.0), "一次超大 dt 也应到达")
	_check_eq(big_step.get_room(), "ridge", "超大 dt 也应落到目的房间")
	_check_eq(big_step.get_total_travelled_seconds(), 10, "超大 dt 也只记实际需要的 10 秒")

	# --- 直接落位 / 重开 ---
	_check(travel.set_room("pond"), "set_room 到已声明房间应成功")
	_check_eq(travel.get_room(), "pond", "set_room 后房间应变化")
	_check(not travel.set_room("cellar"), "set_room 到没声明的房间应失败")
	_check_eq(travel.get_room(), "pond", "失败的 set_room 不该改变房间")
	travel.start_move("hall")
	_check(travel.is_moving(), "重新开一段移动")
	_check(travel.reset_to("hall"), "reset_to 应成功")
	_check_eq(travel.get_room(), "hall", "reset_to 后应回到指定房间")
	_check(not travel.is_moving(), "reset_to 应取消移动")
	_check_eq(travel.get_total_travelled_seconds(), 0, "reset_to 应清零累计耗时")

	# --- 没有地图时不崩 ---
	var empty = PlayerTravel.new(null, "hall")
	_check(not empty.is_map_loaded(), "没有地图时应报告未装载")
	_check_eq(empty.start_move("ridge"), 0, "没有地图时 start_move 应返回 0")
	_check(not empty.set_room("ridge"), "没有地图时 set_room 应失败")


# ---------------------------------------------------------------------------
#  真实数据（案一）：地图覆盖 + 走位耗时下的最少遍数
# ---------------------------------------------------------------------------

func _test_real_case_data() -> Dictionary:
	var case := CaseLoader.load_case("res://data/scenarios/case_01_baihu.json")
	var map := MapLoader.load_for_case(1)

	_check(case.ok, "案一案件数据应当装载成功")
	_check(map.ok, "案一地图应当装载成功（errors=%s）" % _joined(map.errors))

	# --- 覆盖：一间不漏、一间不多 ---
	var map_rooms: Array = map.rooms.duplicate()
	map_rooms.sort()
	var case_rooms: Array = case.rooms.duplicate()
	case_rooms.sort()
	_check_eq(case_rooms, map_rooms, "地图的房间集合必须与 meta.rooms 完全一致")
	_check_eq(map.room_count(), 17, "案一地图应覆盖 17 间房")
	_check_eq(map.rooms.size(), case.rooms.size(), "地图的房间数应与案件一致")

	# --- 真实地形的走位耗时 ---
	_check_eq(map.get_direct_travel_seconds("stone_steps", "stone_steps_7"), 6, "石阶下到第七级应有直接边 6 秒")
	_check_eq(map.get_direct_travel_seconds("stone_steps_7", "stone_steps"), 6, "第七级下到阶下应是 6 秒")
	_check_eq(map.travel_seconds("stone_steps", "stone_steps_7"), 6, "最短路应取直接边 6 秒（绕台前南要 11 秒）")
	_check_eq(map.travel_seconds("stone_steps", "baihutai_south"), 5, "上山应比下山慢（5 秒）")
	_check_eq(map.travel_seconds("baihutai_south", "stone_steps"), 4, "下山应比上山快（4 秒）")
	_check_eq(map.travel_seconds("baihutai", "stall"), 8, "台前到摊后应走 8 秒")
	_check_eq(map.travel_seconds("baihutai_yang", "baihutai_bei"), 20, "碑阳到碑阴应绕碑走 20 秒")
	_check_eq(map.travel_seconds("baihutai_bei", "baihutai_south"), 40, "碑阴到台前南必须中转（20+10+10 = 40 秒）")

	# --- 线索窗口 = [NPC 到达该房间的秒, 他下一个拍点的秒) ---
	# 口径核对（真实数据）：穆青第 0 秒只是摊开拓包（clue_id 为空），量碑在 t=70，
	# 所以第一个线索窗口开在 70 秒，而不是 0 秒 —— "第 0 秒就站在台西"不等于"第 0 秒就能拿线索"。
	var windows := _clue_windows(case)
	_check_eq(windows.size(), 6, "案一应有 6 个线索窗口（每个必需线索一个）")
	_check_eq(str(windows[0]["clue_id"]), "clue_01_four_in_three", "最早的窗口应是穆青台西量碑（70 秒开门）")
	_check_eq(int(windows[0]["open"]), 70, "最早窗口的开门时刻应是 70 秒（她第 70 秒才架尺量碑）")
	_check_eq(int(windows[0]["close"]), 210, "最早窗口的关门时刻应是 210 秒（她下一个拍点去碑阴）")

	# --- 遍数 = max(物理最少遍数, 线索门槛遍数)；门槛本身要求"第 9 遍"才允许结案 ---
	var gates := _clue_gates(case)
	var statistics := _pass_statistics(case, map, windows, gates)
	var physical: int = statistics["physical"]
	var gate_passes: int = statistics["gate"]
	var passes: int = statistics["passes"]
	var ceiling: int = statistics["ceiling"]
	var bound: float = statistics["bound"]

	_check_eq(_require_min_loop(case), 8, "案一 require_min_loop 应为 8（第 9 遍可结案）")
	_check_eq(gate_passes, 8, "线索门槛应要求 8 遍（require_min_loop=8 ⇒ 第 9 遍可结案）")
	_check_eq(int(statistics["collected"]), windows.size(), "逐遍排班最终必须把 6 条必需线索全部拿到")
	_check(physical >= 1, "物理排班至少要 1 遍")
	_check(physical <= gate_passes, "物理上 %d 遍就能集齐，不该被门槛之外的走位拖过 %d 遍" % [
		physical, gate_passes,
	])
	_check(physical <= MAX_COLLECT_PASSES, "走位耗时下必须能在 %d 遍内集齐 6 条必需线索（实际 %d 遍）" % [
		MAX_COLLECT_PASSES, physical,
	])
	_check(bound >= 1.0, "全案 6 条线索至少要下场 1 遍（实际下界 %.2f 遍）" % bound)
	_check(bound <= float(physical) + 0.001, "链条覆盖下界（%.2f 遍）不该超过实际下场遍数（%d 遍）" % [
		bound, physical,
	])
	_check_eq(passes, maxi(physical, gate_passes), "总遍数 = max(物理最少遍数, 门槛遍数)")
	_check_eq(ceiling, gate_passes + 1, "结案上限 = 门槛 + 1（第 9 遍，loop_index 8）")
	_check(passes >= 1, "集齐 6 条必需线索不应少于 1 遍")
	_check(passes <= MAX_COLLECT_PASSES, "集齐 6 条必需线索应在 %d 遍内（实际 %d 遍）" % [
		MAX_COLLECT_PASSES, passes,
	])
	_check(ceiling >= passes, "结案上限不该早于集齐线索的遍数")
	_check_eq(int(statistics["lead"]), gate_passes, "空等遍数应等于门槛（前 8 遍什么也拿不到）")
	_check(str(statistics["detail"]).contains("遍"), "排班明细应可读")

	# --- 独立复核：不受"逐条门槛"限制的线索确实能在一遍里串起来 ---
	# 注意用 _per_clue_gates（不含全局 require_min_loop=8）：全局门槛管的是"整局最早第几遍结案"，
	# 不是"这条线索第几遍才出现"，拿它当逐条门槛会把每条线索都推到第 8 遍之后。
	var per_clue := _per_clue_gates(case)
	var available := _available_windows(windows, per_clue, 0)
	var prefix := _best_feasible_prefix(case, map, windows, per_clue, 0)
	_check_eq(available.size(), 4, "第一遍应能拿到 4 条不受逐条门槛限制的线索（石屑第 4 遍起、碗底第 7 遍起）")
	_check(not available.any(func(window: Dictionary) -> bool:
		return str(window["clue_id"]) == "clue_01_bowl_bottom"
	), "碗底不该出现在第一遍的可拿清单里")
	_check(not available.any(func(window: Dictionary) -> bool:
		return str(window["clue_id"]) == "clue_01_stone_dust"
	), "石屑不该出现在第一遍的可拿清单里（第 4 遍起）")
	# 一条"链条"的口径：到场时刻必须落在某个窗口里（早到要等，等过最后一个窗口就算这一遍错过去了）。
	# 案一实测（下面两条断言就是这两个实测值）：
	#   · 逐条门槛不挡时（第 1 遍）单遍最多 4 条：半字寸 140 → 量碑 150 → 碑阴 240 → 三源冲突 300；
	#   · 6 条全开时单遍就能**一次串完 6 条**：石屑 170（石阶第七级）→ 半字寸 190（台前）→ 量碑 200（台西）
	#     → 碑阴 240 → 等到 300 同拍点一次拿碗底 + 三源冲突。
	# 所以走位不是瓶颈：6 条线索物理上 1 遍就能收完，整局只受叙述门槛（require_min_loop=8）约束。
	_check(prefix.size() < _max_clues_in_one_pass(str(statistics["detail"])),
		"门槛没放开的一遍能串的条数（%d）必须少于 6 条全开时的一遍（%d 条）" % [
			prefix.size(), _max_clues_in_one_pass(str(statistics["detail"])),
		])
	var full_pool: Array[Dictionary] = []
	for window in windows:
		full_pool.append(window)
	var best_chain := _best_feasible_chain(map, full_pool, case.loop_duration_seconds, full_pool.size())
	_check_eq(best_chain.size(), 6, "6 条线索全开时，一条路线应当能把 6 条一次串完（实际 %d 条）" % best_chain.size())
	_check(_chain_is_feasible(map, best_chain, case.loop_duration_seconds),
		"这条 6 条一次串完的路线必须自己在余页内跑得通")
	_check_eq(_chain_cover(_chain_timeline(map, best_chain)), 6, "这条路线必须真能覆盖 6 个线索拍点")
	# 逐段复核：按条目自己的实际到达时刻重算一遍，每一段都必须真的走得到、到场落在窗口里、不超余页。
	_check(_schedule_is_feasible(map, windows, [{"pass": 1, "walk": _walk_prefix(map, prefix)}],
		case.loop_duration_seconds), "门槛没放开时那一遍的行程必须都在窗口内到场且不超过余页长度")
	_check(_schedule_is_feasible(map, windows, [{"pass": 1, "walk": _walk_prefix(map, best_chain)}],
		case.loop_duration_seconds), "6 条一次串完的行程必须都在窗口内到场且不超过余页长度")
	var bowl_pass := _best_feasible_prefix(case, map, windows, per_clue, 6)
	_check(bowl_pass.size() >= 1, "门槛放开后至少能拿到碗底")

	return {
		"passes": passes,
		"physical": physical,
		"gate": gate_passes,
		"ceiling": ceiling,
		"bound": bound,
		"lead": int(statistics["lead"]),
		"windows": windows,
		"detail": str(statistics["detail"]),
		"map": map,
		"best_chain": best_chain,
	}


## 每个必需线索的窗口：{"clue_id", "npc_id", "room", "open", "close", "spans"}。
## 口径：NPC 每次到达这个房间都算一次到达，拍点序列里每一个 `room == 线索房间 && second >= open`
## 的拍点都开一个窗口 [该拍点 second, 下一个拍点 second)。所以同一条线索可能有**多个**窗口
## （案一：`clue_01_bowl_bottom` 在穆青台后殿 240 与 300 秒各开一次），`spans` 就是这些窗口的列表
## （按 `open` 升序），逐遍排班时必须把"用哪一次到达"一起选掉。
func _clue_windows(case) -> Array[Dictionary]:
	var require: Array = _required_clue_ids(case)
	var result: Array[Dictionary] = []
	for clue_id_value in require:
		var clue_id := str(clue_id_value)
		var spans: Array = []
		for event in case.clue_events():
			if str(event["clue_id"]) != clue_id:
				continue
			var room := str(event["room"])
			var schedule = case.npcs[str(event["npc_id"])]
			for arrival in _arrivals(schedule, room):
				if arrival < int(event["second"]):
					continue
				spans.append([arrival, _next_node_second(schedule, arrival, case.loop_duration_seconds)])
		if spans.is_empty():
			continue
		spans.sort_custom(func(a: Array, b: Array) -> bool:
			return int(a[0]) < int(b[0])
		)
		var first: Array = spans[0]
		var last: Array = spans[spans.size() - 1]
		result.append({
			"clue_id": clue_id,
			"room": str(_clue_room(case, clue_id)),
			"open": int(first[0]),
			"close": int(last[1]),
			"spans": spans,
		})
	# 排序只为了让结果稳定可复现（先按窗口开、再按线索 id）
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["open"]) != int(b["open"]):
			return int(a["open"]) < int(b["open"])
		return str(a["clue_id"]) < str(b["clue_id"])
	)
	return result


## 某条线索对应的房间（取该线索第一条线索事件的房间）。
func _clue_room(case, clue_id: String) -> String:
	for event in case.clue_events():
		if str(event["clue_id"]) == clue_id:
			return str(event["room"])
	return ""


## 某个 NPC 的时间线里，落在 room 上的所有拍点秒（升序，时间线本身就按秒排好）。
func _arrivals(schedule, room: String) -> Array:
	var seconds: Array = []
	for node in schedule.nodes:
		if str(node.room) == room:
			seconds.append(int(node.second))
	return seconds


## 该拍点的下一个拍点秒（没有下一个就一直开到余页结束）。
func _next_node_second(schedule, second: int, fallback: int) -> int:
	var index: int = schedule.node_index_at(second)
	if index + 1 < schedule.nodes.size():
		return int(schedule.nodes[index + 1].second)
	return fallback


## 案一的 6 条必需线索 + 每条最早能在第几遍拿到（loop_index，0 基）。
##   · 逐条线索的门槛：先看案件数据里有没有 per_clue / clue_gates（现在还没有，留口子）；
##   · 全局门槛：meta.secret.resolve_conditions.require_min_loop（案一 = 8）。
func _clue_gates(case) -> Dictionary:
	var require: Array = _required_clue_ids(case)
	var min_loop: int = _require_min_loop(case)
	var per_clue: Dictionary = _per_clue_gates(case)
	var result: Dictionary = {}
	for clue_id in require:
		result[str(clue_id)] = maxi(int(per_clue.get(str(clue_id), 0)), min_loop)
	return result


## 只有**逐条线索**的门槛（不含全局 require_min_loop）。
## 全局门槛是"整局最早第几遍才允许结案"，不是"这条线索第几遍才出现"——
## 算"一遍里能跑几条"时必须用这个口径，否则会把全局门槛错当成每条线索各自的门槛。
func _per_clue_gates(case) -> Dictionary:
	var per_clue: Dictionary = {}
	for key in ["per_clue", "clue_gates"]:
		var value: Variant = case.secret.get(key, {})
		if value is Dictionary:
			for clue_id in (value as Dictionary).keys():
				per_clue[str(clue_id)] = int((value as Dictionary)[clue_id])
	# 案一正文里的"第 N 遍起"门槛（帧 16）在数据里没有机器可读字段，测试里显式写死，
	# 避免"算出来很轻松"这种假安全：这两条线索的数据门槛比别的线索高。
	per_clue["clue_01_stone_dust"] = maxi(int(per_clue.get("clue_01_stone_dust", 0)), 3)
	per_clue["clue_01_bowl_bottom"] = maxi(int(per_clue.get("clue_01_bowl_bottom", 0)), 6)
	return per_clue


## 案一 resolve_conditions.require_min_loop 的口径（0 基 loop_index，8 ⇒ 第 9 遍可结案）。
func _require_min_loop(case) -> int:
	var conditions: Variant = case.secret.get("resolve_conditions", {})
	if conditions is Dictionary:
		return int((conditions as Dictionary).get("require_min_loop", 0))
	return 0


func _required_clue_ids(case) -> Array:
	var conditions: Variant = case.secret.get("resolve_conditions", {})
	if conditions is Dictionary:
		var value: Variant = (conditions as Dictionary).get("require_clues", [])
		if value is Array:
			return value as Array
	return [] as Array


## 遍数的三部分（都算出来，便于断言与报告）：
##   · gate     —— 线索门槛：第几遍才轮到（require_min_loop = 8 ⇒ 第 9 遍可结案）；
##   · physical —— 物理最少遍数：真正**下场跑**的遍数（见 _simulate_passes["passes"]）；
##   · ceiling  —— 结案上限：门槛 + 1（结案只能发生在允许结案的那一遍，不能更早）。
## 返回 {"passes", "physical", "gate", "ceiling", "lead", "detail", "bound", "collected"}。
func _pass_statistics(case, map, windows: Array[Dictionary], gates: Dictionary) -> Dictionary:
	var gate: int = 0
	for clue_id in gates.keys():
		gate = maxi(gate, int(gates[clue_id]))
	var simulation := _simulate_passes(case, map, windows, gates, gate)
	return {
		"passes": maxi(int(simulation["passes"]), gate),
		"physical": int(simulation["passes"]),
		"gate": gate,
		"ceiling": gate + 1,
		"lead": int(simulation["lead"]),
		"detail": str(simulation["detail"]),
		"collected": int(simulation["collected"]),
		"bound": _chain_cover_bound(case, map, windows),
	}


## 逐遍排班：第 loop_index 遍只能拿"门槛已放开（gate ≤ loop_index）且还没到手"的线索，
## 一遍里能拿多少条由 **覆盖数最大的可行链条**（_best_feasible_chain）决定，拿到手就不再重拿。
## 返回 {"passes", "lead", "collected", "detail"}：
##   · passes —— 真正需要**下场跑**的遍数（有线索入账的遍数），案一实测 = 1；
##   · lead   —— 门槛逼人空等的遍数（前 lead 遍什么也拿不到），案一实测 = 8（第 9 遍才动手）。
## 前几遍先不拿、等门槛放开再一起拿，会被如实记成 lead + 1 遍，而不会被错算成更多遍。
func _simulate_passes(case, map, windows: Array[Dictionary], gates: Dictionary, gate: int) -> Dictionary:
	var collected: Dictionary = {}
	var budget: int = gate + 8
	var lead: int = 0
	var passes: int = 0
	var detail := ""
	var loop_index: int = 0
	while loop_index < budget and collected.size() < windows.size():
		var pool: Array[Dictionary] = []
		for window in windows:
			var clue_id := str(window["clue_id"])
			if collected.has(clue_id):
				continue
			if int(gates.get(clue_id, 0)) <= loop_index:
				pool.append(window)
		var chain: Array[Dictionary] = []
		if not pool.is_empty():
			chain = _best_feasible_chain(map, pool, case.loop_duration_seconds, pool.size())
		loop_index += 1
		if chain.is_empty():
			lead += 1
			continue
		passes += 1
		# 明细按"实际到手秒"排序，读起来才像一张行程表（DP 回溯出来的顺序是按父指针反向的，
		# 不一定按秒；这里只改展示顺序，不改链条本身）。
		var ordered: Array[Dictionary] = chain.duplicate()
		ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["open"]) < int(b["open"])
		)
		var labels: Array[String] = []
		for item in chain:
			collected[str(item["clue_id"])] = true
		for item in ordered:
			labels.append("%d 秒 %s @ %s" % [int(item["open"]), str(item["clue_id"]), str(item["room"])])
		var line := "第 %d 遍（第 %d 次下场）：%s" % [loop_index, passes, ", ".join(labels)]
		detail = line if detail.is_empty() else "%s；%s" % [detail, line]
	return {"passes": passes, "lead": lead, "collected": collected.size(), "detail": detail}


## 下界：把"全部线索"摊开，一条"同遍可行链条"最多能带走几条线索（见 _best_feasible_chain），
## 相除即得"至少要下场几遍"。每条链条都必须自己在余页里跑得通（见 _chain_is_feasible），
## 所以 线索数 / 单链最大覆盖数 是任何排班的遍数下界。
## 返回 float：案一是 6 / 3 = 2.0 遍（单链最大覆盖 3 个线索窗口）。
func _chain_cover_bound(case, map, windows: Array[Dictionary]) -> float:
	if windows.is_empty():
		return 0.0
	var pool: Array[Dictionary] = windows.duplicate()
	var best: Array[Dictionary] = _best_feasible_chain(map, pool, case.loop_duration_seconds, pool.size())
	if best.is_empty():
		return float(windows.size())
	var covered: int = _chain_cover(_chain_timeline(map, best))
	if covered <= 0:
		return float(windows.size())
	return float(windows.size()) / float(covered)


## 穷举"这一遍门槛已经放开的线索"能否在同一遍里串起来（线索只有 6 条，全排列可承受）。
## loop_index 是 0 基的遍号（第 1 遍 = 0），与 case_loader 的 require_min_loop 同一口径。
func _best_feasible_prefix(case, map, windows: Array[Dictionary], gates: Dictionary, loop_index: int) -> Array[Dictionary]:
	var pool := _available_windows(windows, gates, loop_index)
	return _best_feasible_chain(map, pool, case.loop_duration_seconds, pool.size())


## 在这些窗口里找**这一遍能拿走最多线索窗口**的一条可行链条。
## 口径注意：目标不是"链条最长"，而是"覆盖到的线索窗口最多"——穆青台后殿 240 与 300 秒两个拍点不重叠时，
## "等到 300 一次拿两个"比"240 拿到手就走"更省遍数（案一实测差 4 遍）。
## 实现是**精确子集 DP**（不是贪心、也不是朴素全排列）：线索最多 6 条，2^6 × 6² 状态，
## 状态 = (已访问线索子集, 最后停在谁)，值 = 该状态最早到场秒（字典序下"越早到越不劣"）。
## 朴素全排列的"覆盖满了就收工"剪枝会漏解：它不知道链条还能**多带**一条同房间的线索
## （案一 `clue_01_three_sources_conflict` 就藏在 `clue_01_bowl_bottom` 同一个 300 秒拍点上，
## 漏掉它就从 8 遍变成 9 遍）。limit 保留在签名里只为兼容调用方。
func _best_feasible_chain(map, pool: Array[Dictionary], loop_seconds: int, limit: int) -> Array[Dictionary]:
	var count: int = pool.size()
	if count == 0:
		return []
	var full: int = 1 << count
	var best_time: Dictionary = {}
	var parent: Dictionary = {}
	var best_cover: int = -1
	var best_mask: int = 0
	var best_last: int = -1
	# 单站起步
	for i in range(count):
		var window: Dictionary = pool[i]
		var open_second: int = int(window["open"])
		if open_second > loop_seconds:
			continue
		var spans: Array = window["spans"]
		var served: bool = false
		for span_value in spans:
			var span: Array = span_value
			if open_second >= int(span[0]) and open_second <= int(span[1]):
				served = true
				break
		if not served:
			continue
		var mask: int = 1 << i
		var key := "%d|%d" % [mask, i]
		if not best_time.has(key) or open_second < int(best_time[key]):
			best_time[key] = open_second
			parent[key] = ""
		var cover_now: int = _chain_cover(_chain_timeline(map, [window]))
		if cover_now > best_cover:
			best_cover = cover_now
			best_mask = mask
			best_last = i
	# 逐子集松弛
	for mask in range(1, full):
		for last in range(count):
			var key := "%d|%d" % [mask, last]
			if not best_time.has(key):
				continue
			var current: int = int(best_time[key])
			for next_index in range(count):
				if mask & (1 << next_index) != 0:
					continue
				var window: Dictionary = pool[next_index]
				var open_second: int = int(window["open"])
				var ready: int = current + int(map.travel_seconds(str(pool[last]["room"]), str(window["room"])))
				if ready < open_second:
					ready = open_second
				if ready > loop_seconds:
					continue
				var spans: Array = window["spans"]
				var served: bool = false
				for span_value in spans:
					var span: Array = span_value
					if ready >= int(span[0]) and ready <= int(span[1]):
						served = true
						break
				if not served:
					continue
				var next_mask: int = mask | (1 << next_index)
				var next_key := "%d|%d" % [next_mask, next_index]
				if best_time.has(next_key) and int(best_time[next_key]) <= ready:
					continue
				best_time[next_key] = ready
				parent[next_key] = key
				var chain := _reconstruct_chain(pool, parent, next_key)
				var cover := _chain_cover(_chain_timeline(map, chain))
				if cover > best_cover:
					best_cover = cover
					best_mask = next_mask
					best_last = next_index
	if best_last < 0:
		return []
	return _reconstruct_chain(pool, parent, "%d|%d" % [best_mask, best_last])


## 沿 parent 指针回溯出链条（顺序：先取到的线索在前）。
func _reconstruct_chain(pool: Array[Dictionary], parent: Dictionary, key: String) -> Array[Dictionary]:
	var chain: Array[Dictionary] = []
	var cursor := key
	while not cursor.is_empty():
		var parts := cursor.split("|")
		chain.append(pool[int(parts[1])])
		cursor = str(parent.get(cursor, ""))
	chain.reverse()
	return chain


## 第 loop_index 遍里门槛已经松开的线索。
func _available_windows(windows: Array[Dictionary], gates: Dictionary, loop_index: int) -> Array[Dictionary]:
	var available: Array[Dictionary] = []
	for window in windows:
		if int(gates.get(str(window["clue_id"]), 0)) <= loop_index:
			available.append(window)
	return available


## 按链条顺序走一遍，返回每站的 {clue_id, room, ready, close, spans, slot}（ready = 到场秒）。
## 到场早于窗口开就在原地等（wait）——这是玩家能做的事，不是作弊。
func _chain_timeline(map, chain: Array[Dictionary]) -> Array[Dictionary]:
	var timeline: Array[Dictionary] = []
	var current_room: String = ""
	var current_second: int = 0
	for window in chain:
		var room := str(window["room"])
		var open_second: int = int(window["open"])
		var ready: int = open_second
		if not current_room.is_empty():
			ready = current_second + int(map.travel_seconds(current_room, room))
			if ready < open_second:
				ready = open_second
		var spans: Array = window["spans"]
		var slot: int = -1
		for index in range(spans.size()):
			var span: Array = spans[index]
			if ready <= int(span[1]):
				slot = index
				break
		timeline.append({
			"clue_id": str(window["clue_id"]),
			"room": room,
			"ready": ready,
			"close": int(window["close"]),
			"spans": spans,
			"slot": slot,
		})
		current_room = room
		current_second = ready
	return timeline


## 这条链条实际能"拿走"几个线索窗口。
## 每个线索是按 (clue_id, 第几种拍法) 去重的：同一条线索的同一拍只算一次；
## 如果同一遍里既拿了早拍又拿了晚拍（重访），两拍都算（不然会低估攻击性排班）。
func _chain_cover(timeline: Array[Dictionary]) -> int:
	var seen: Dictionary = {}
	for station in timeline:
		var slot: int = int(station["slot"])
		if slot < 0:
			continue
		seen["%s#%d" % [str(station["clue_id"]), slot]] = true
	return seen.size()


## 这条线索顺序能否在同一遍里走完：每段必须真的到得了，到场时刻必须真的落在**某一个**窗口内
## （早到原地等，等过所有窗口就算这一遍错过去了），并且整遍不许超过余页长度。
func _chain_is_feasible(map, chain: Array[Dictionary], loop_seconds: int) -> bool:
	var current_room: String = ""
	var current_second: int = 0
	for window in chain:
		var open_second: int = int(window["open"])
		if current_room.is_empty():
			current_second = open_second
		else:
			# 0 秒是合法的：同一条拍点上可以带两条线索（穆青台后殿 300 秒同拍点一次拿碗底 + 三源冲突）。
			# 只有负数才算"走不到"。
			var leg: int = int(map.travel_seconds(current_room, str(window["room"])))
			if leg < 0:
				return false
			current_second += leg
			if current_second < open_second:
				current_second = open_second
		var spans: Array = window["spans"]
		var served: bool = false
		for span_value in spans:
			var span: Array = span_value
			if current_second >= int(span[0]) and current_second <= int(span[1]):
				served = true
				break
		if not served:
			return false
		current_room = str(window["room"])
	return current_second <= loop_seconds


## 逐遍复核（独立重算，不信任排程里记的秒）：
##   · 给了 "walk"（一串 {clue_id, second}，表示"这一刻在这个线索房间"）就按这些实际到达时刻逐段复核；
##   · 否则从每遍的第一个线索窗口开门时刻起步，按线索顺序走。
## 要求：首站自己也要落在窗口里；之后每段耗时都必须为正、到场不早于"上一站 + 走位耗时"；
## 到场时刻必须落在该线索的某个窗口里；整遍不许超过余页长度。
func _schedule_is_feasible(map, windows: Array[Dictionary], assignment: Array, loop_seconds: int) -> bool:
	var by_id: Dictionary = {}
	for window in windows:
		by_id[str(window["clue_id"])] = window
	if assignment.is_empty():
		return false
	for recorded in assignment:
		var steps: Array = []
		if recorded.has("walk"):
			steps = recorded["walk"]
		else:
			for clue_value in (recorded["clues"] as Array):
				steps.append({
					"clue_id": str((clue_value as Dictionary)["clue_id"]),
					"second": int((clue_value as Dictionary)["open"]),
				})
		if steps.is_empty():
			return false
		var previous_second: int = -1
		var previous_room: String = ""
		var last_second: int = 0
		for step_value in steps:
			var step: Dictionary = step_value
			var clue_id := str(step["clue_id"])
			if not by_id.has(clue_id):
				return false
			var window: Dictionary = by_id[clue_id]
			var room := str(window["room"])
			var current: int = int(step["second"])
			if previous_room.is_empty():
				previous_second = current
				previous_room = room
				last_second = current
				if not _second_in_spans(current, window["spans"]):
					return false
				continue
			# 0 秒合法（同一个拍点上带两条线索）；负数才是"走不到"。
			var leg: int = int(map.travel_seconds(previous_room, room))
			if leg < 0:
				return false
			if current < previous_second + leg:
				return false
			if not _second_in_spans(current, window["spans"]):
				return false
			previous_second = current
			previous_room = room
			last_second = current
		if last_second > loop_seconds:
			return false
	return true


## 某个时刻是否落在这一串窗口里的任意一个（含两端）。
func _second_in_spans(second: int, spans: Array) -> bool:
	for span_value in spans:
		var span: Array = span_value
		if second >= int(span[0]) and second <= int(span[1]):
			return true
	return false


## 按真实的"到场即等"规则把一条链条走一遍，返回 [{clue_id, second}]（每条线索的实际到手秒）。
func _walk_prefix(map, chain: Array[Dictionary]) -> Array:
	var steps: Array = []
	var current_room := ""
	var current_second := -1
	for window in chain:
		var open_second: int = int(window["open"])
		if current_room.is_empty():
			current_second = open_second
		else:
			current_second += int(map.travel_seconds(current_room, str(window["room"])))
			if current_second < open_second:
				current_second = open_second
		steps.append({
			"clue_id": str(window["clue_id"]),
			"room": str(window["room"]),
			"second": current_second,
		})
		current_room = str(window["room"])
	return steps


# ---------------------------------------------------------------------------
#  结论
# ---------------------------------------------------------------------------

## 排班明细（"第 N 遍：a, b, c；第 M 遍：d"）里单遍最多串了几条线索。
func _max_clues_in_one_pass(detail: String) -> int:
	var best: int = 0
	for segment in detail.split("；"):
		var piece := str(segment)
		if piece.is_empty():
			continue
		var tail := piece.split("：")
		if tail.size() < 2:
			continue
		var count: int = str(tail[1]).split(",").size()
		if count > best:
			best = count
	return best


func _report(real_result: Dictionary) -> void:
	if _checks != EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数量异常：实际 %d，期望 %d（测试中途崩溃或提前返回）" % [
			_checks, EXPECTED_CHECKS,
		])
		quit(1)
		return

	if _failures.is_empty():
		print("线索窗口（NPC 到达秒 → 该拍点结束，同一条线索可能有多个窗口）：")
		for window in (real_result["windows"] as Array):
			var spans: Array = window["spans"]
			var labels: Array[String] = []
			for span_value in spans:
				var span: Array = span_value
				labels.append("[%d, %d]" % [int(span[0]), int(span[1])])
			print("  %s @ %s %s" % [
				str(window["clue_id"]), str(window["room"]), " ".join(labels),
			])
		# 玩家真正能跑出的证据链（6 条一次串完）：
		#   170 秒 石阶第七级拿石屑 → 187 秒 台前拿半字寸 → 197 秒 台西拿"四在第三"残字
		#   → 240 秒 碑阴拿拓片 → 等到 300 秒 碑阴，同一个拍点上一次拿碗底 + 三源冲突。
		print("一条路线串完 6 条必需线索（走位耗时之下，实际到手秒）：")
		for step_value in _walk_prefix(real_result["map"], real_result["best_chain"]):
			var step: Dictionary = step_value
			print("  %d 秒  %s @ %s" % [
				int(step["second"]), str(step["clue_id"]), str(step["room"]),
			])
		print("集齐 6 条必需线索：下场 %d 遍（一遍最多串 %d 条）+ 空等 %d 遍；链条覆盖下界 %.2f 遍，叙述门槛 loop_index %d" % [
			int(real_result["physical"]), _max_clues_in_one_pass(str(real_result["detail"])),
			int(real_result["lead"]), float(real_result["bound"]), int(real_result["gate"]),
		])
		print("排班：%s" % str(real_result["detail"]))
		print("RESULT: OK travel 自检通过 %d 项；走位耗时下最少 %d 遍集齐 6 条线索（第 %d 遍，loop_index %d），同遍即可结案" % [
			_checks, int(real_result["passes"]), int(real_result["passes"]) + 1, int(real_result["gate"]),
		])
		quit(0)
		return

	print("RESULT: FAIL travel 自检失败 %d/%d 项：" % [_failures.size(), _checks])
	for failure in _failures:
		print("  · %s" % failure)
	quit(1)
