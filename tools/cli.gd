extends SceneTree
## ============================================================================
##  tools/cli.gd —— 项目命令行（工具链第 2 步：状态探针）
## ----------------------------------------------------------------------------
##  为什么需要它：
##    以前想知道"项目现在什么状态、数据合不合规、场景跑不跑得起来"，要开编辑器、
##    或者 grep 好几个文件。现在一条命令、一行结论；细节按需再看。
##    这也是"给 AI 用的入口"：一条命令换一行 JSON 式的摘要，比读 800 行日志便宜得多。
##
##  用法（在项目根目录）：
##    godot --headless --path . --script res://tools/cli.gd -- validate
##    godot --headless --path . --script res://tools/cli.gd -- smoke --scene res://scenes/main.tscn --frames 300
##    godot --headless --path . --script res://tools/cli.gd -- cases
##    godot --headless --path . --script res://tools/cli.gd -- index [--check]
##    godot --headless --path . --script res://tools/cli.gd -- dump-state [--start]
##    godot --headless --path . --script res://tools/cli.gd -- simulate --seconds 900 [--clue]
##    godot --headless --path . --script res://tools/cli.gd -- new-npc --id npc_03_x --name 车夫 [--write]
##
##  子命令：
##    validate          数据 schema + 设计不变量校验（读 data/，绝不写入）
##    smoke             实例化场景、空跑若干帧，断言核心系统真的活着
##    cases             一行一个案件：案号/标题/余页长度/NPC/节点/缝的类型
##    index             转发给 tools/gen_index.gd（--check = 只校验过期/语法，不重写）
##    dump-state        打印一行 STATE <json>：圈数/运行中/暂停/已过秒/剩余/流速/线索
##    simulate          不开场景、直接 tick() 空跑 N 游戏秒：验证跨循环线索保留
##    new-npc           生成一个 NPC 骨架并追加到时间轴数据表（默认 dry-run，--write 才落盘）
##    help              用法
##
##  注意：与其它工具脚本一致 —— extends SceneTree + _initialize() + quit(code)，
##        并且**不写 class_name**（避免污染全局类名缓存）。
## ============================================================================

const ValidateData = preload("res://tools/validate_data.gd")
const Parser = preload("res://scripts/data/npc_timeline_parser.gd")

const SCENARIO_DIR := "res://data/scenarios"
const DEFAULT_SCENE := "res://scenes/main.tscn"
## new-npc 的默认写入目标（阶段一的旧数据表；正式案件数据在 data/scenarios/）
const LEGACY_TIMELINE := "res://data/npc_timelines.json"
const GEN_INDEX_SCRIPT := "res://tools/gen_index.gd"
## simulate 默认空跑的游戏内秒数（≈2.14 轮 420 秒循环）
const DEFAULT_SIM_SECONDS := 900.0
## 冒烟测试要跑到的"游戏内秒数"：足够跨越至少 2 个 time_updated 信号与一次 UI 刷新
const SMOKE_TARGET_SECONDS := 3.0
## 打印问题时最多显示多少行（剩下的折叠成一行计数）
const MAX_PROBLEM_LINES := 10


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var command := "help"
	if args.size() > 0:
		command = args[0]
	match command:
		"validate":
			quit(_cmd_validate())
		"smoke":
			_cmd_smoke(args)      # 内部 await 帧，结束后自己 quit
		"cases":
			quit(_cmd_cases())
		"index":
			quit(_cmd_index(args))
		"dump-state":
			quit(_cmd_dump_state(args))
		"simulate":
			quit(_cmd_simulate(args))
		"new-npc":
			quit(_cmd_new_npc(args))
		"help", "-h", "--help":
			_print_usage()
			quit(0)
		_:
			print("RESULT: FAIL 未知子命令 \"%s\"" % command)
			_print_usage()
			quit(2)


# ---------------------------------------------------------------------------
#  validate
# ---------------------------------------------------------------------------
func _cmd_validate() -> int:
	var validator = ValidateData.new()
	var report: Dictionary = validator.run()
	var stats: Dictionary = report["stats"]

	print("数据规模: 场景文件 %d / 案件 %d / NPC %d / 节点 %d / 线索引用 %d / 已登记线索 %d / 已登记对话 %d / 符 %d（%d 步 / %d 笔）" % [
		stats["scenario_files"], stats["cases"], stats["npcs"], stats["timeline_nodes"],
		stats["clue_refs"], stats["clues_declared"], stats["dialogues_declared"],
		int(stats.get("runes_declared", 0)), int(stats.get("rune_steps_declared", 0)),
		int(stats.get("rune_strokes_declared", 0)),
	])
	_print_problems("错误", report["errors"])
	_print_problems("警告", report["warnings"])

	if report["ok"]:
		print("RESULT: OK 数据 schema 与设计不变量通过（0 错误, %d 警告）" % report["warnings"].size())
		return 0
	print("RESULT: FAIL 数据校验不通过：%d 个错误（详见上方或 logs\\check\\数据表校验.log）" % report["errors"].size())
	return 1


func _print_problems(label: String, items: Array) -> void:
	if items.is_empty():
		return
	var shown := 0
	for item in items:
		if shown >= MAX_PROBLEM_LINES:
			print("  …还有 %d 条%s未显示" % [items.size() - shown, label])
			break
		print("  %s %s" % ["✗" if label == "错误" else "!", item])
		shown += 1


# ---------------------------------------------------------------------------
#  smoke：真实跑帧，验证"装配是否真的活着"
# ---------------------------------------------------------------------------
func _cmd_smoke(args: PackedStringArray) -> void:
	var scene_path := _arg(args, "--scene", DEFAULT_SCENE)
	var max_frames := int(_arg(args, "--frames", "300"))
	var time_scale := float(_arg(args, "--scale", "60"))
	# 标题页这类"没有余页钟"的场景：时钟断言本来就不适用（它不该引 Autoload 去启动时钟），
	# 只验"装得起来、跑得住、没报错"。主场景那种玩法场景不要加这个开关 —— 时钟断言是抓假绿的关键。
	var no_clock: bool = args.has("--no-clock")

	var packed = load(scene_path)
	if packed == null or not (packed is PackedScene):
		print("RESULT: FAIL 场景无法加载：%s" % scene_path)
		quit(1)
		return

	var instance: Node = (packed as PackedScene).instantiate()
	if instance == null:
		print("RESULT: FAIL 场景实例化失败：%s" % scene_path)
		quit(1)
		return
	root.add_child(instance)

	# 核心系统必须由 Autoload 提供 —— 这正是 project.godot 的装配是否有效的关键断言
	var loop := root.get_node_or_null("TimeLoopManager")
	var memory := root.get_node_or_null("PersistentMemoryManager")
	if loop == null or memory == null:
		print("RESULT: FAIL Autoload 缺失（TimeLoopManager=%s, PersistentMemoryManager=%s）" % [loop != null, memory != null])
		_cleanup(instance)
		quit(1)
		return

	var label := _find_label(instance)
	var label_before := label.text if label != null else ""

	# 加速时间，让 3 个游戏内秒在几十帧内跑完；不改 Engine.time_scale（核心层约定）
	if loop.has_method("set_time_scale"):
		loop.set_time_scale(time_scale)

	var frames := 0
	var elapsed: float = 0.0
	var problems: Array[String] = []
	if no_clock:
		for i in 4:
			await process_frame
			frames += 1
		elapsed = loop.get_elapsed_seconds()
	else:
		while frames < max_frames and loop.get_elapsed_seconds() < SMOKE_TARGET_SECONDS:
			await process_frame
			frames += 1

		elapsed = loop.get_elapsed_seconds()
		if not loop.is_running():
			problems.append("循环未启动（HUD 的 _ready 装配可能失败）")
		if loop.get_loop_index() != 0:
			problems.append("第 0 遍未跑完就重置了（loop_index=%d）" % loop.get_loop_index())
		if elapsed <= 0.0:
			problems.append("时钟没有走动（elapsed=0）")
		if elapsed < SMOKE_TARGET_SECONDS:
			problems.append("帧预算 %d 帧内只推进了 %.2f 游戏秒" % [max_frames, elapsed])
		# 这一条能抓住"脚本报错但不崩溃"的假绿：UI 若从未刷新，说明信号链断了
		if label != null and label.text == label_before and elapsed >= 1.0:
			problems.append("HUD 文本在 %.1f 游戏秒后仍未刷新（信号链或访问器出错）" % elapsed)

	var node_count := _count_nodes(instance)
	if problems.is_empty():
		print("RESULT: OK scene=%s frames=%d 游戏内=%.2fs 节点=%d HUD=\"%s\"%s" % [
			scene_path, frames, elapsed, node_count, label.text if label != null else "(无)",
			"（无余页钟场景：只验装配）" if no_clock else "",
		])
	else:
		for p in problems:
			print("  ✗ %s" % p)
		print("RESULT: FAIL 场景冒烟 %d 项不通过" % problems.size())

	_cleanup(instance)
	quit(0 if problems.is_empty() else 1)


func _cleanup(instance: Node) -> void:
	root.remove_child(instance)
	instance.free()


func _find_label(node: Node) -> Label:
	if node is Label:
		return node
	for child in node.get_children():
		var found := _find_label(child)
		if found != null:
			return found
	return null


func _count_nodes(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count_nodes(child)
	return total


# ---------------------------------------------------------------------------
#  cases：一行一个案件（比读 JSON 便宜得多的"现状"入口）
# ---------------------------------------------------------------------------
func _cmd_cases() -> int:
	var dir := DirAccess.open(SCENARIO_DIR)
	if dir == null:
		print("RESULT: SKIP %s 不存在：尚无案件数据（docs/story/09 §2 定了每案一个文件）" % SCENARIO_DIR)
		return 0
	var names: Array[String] = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".json"):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	if names.is_empty():
		print("RESULT: SKIP %s 为空：尚无案件数据" % SCENARIO_DIR)
		return 0
	names.sort()

	var rows := 0
	for file_name in names:
		var path := SCENARIO_DIR.path_join(file_name)
		var data = _read_json(path)
		if typeof(data) != TYPE_DICTIONARY:
			print("%-28s <JSON 解析失败>" % file_name)
			continue
		var meta: Dictionary = data.get("meta", {}) if typeof(data.get("meta", {})) == TYPE_DICTIONARY else {}
		var secret: Dictionary = meta.get("secret", {}) if typeof(meta.get("secret", {})) == TYPE_DICTIONARY else {}
		var npcs: Array = data.get("npcs", []) if typeof(data.get("npcs", [])) == TYPE_ARRAY else []
		var nodes := 0
		var clues := 0
		for npc in npcs:
			if typeof(npc) != TYPE_DICTIONARY:
				continue
			for node in (npc.get("timeline", []) if typeof(npc.get("timeline", [])) == TYPE_ARRAY else []):
				nodes += 1
				if typeof(node) == TYPE_DICTIONARY and not str(node.get("clue_id", "")).is_empty():
					clues += 1
		print("%-26s 案%s《%s》 余页%ss 房间%d NPC%d 节点%d 线索%d 缝=%s" % [
			file_name, str(meta.get("case_id", "?")), str(meta.get("case_title", "?")),
			str(meta.get("loop_duration_seconds", "?")), (meta.get("rooms", []) as Array).size(),
			npcs.size(), nodes, clues, str(secret.get("kind", "-")),
		])
		rows += 1
	print("RESULT: OK 案件 %d 个" % rows)
	return 0


# ---------------------------------------------------------------------------
#  index：转发给 gen_index.gd（不重复实现，避免两份真相）
# ---------------------------------------------------------------------------
## 为什么用子进程而不是直接调用：gen_index.gd 是 `extends SceneTree` 的独立工具脚本，
## 没法当普通类 new() 出来。与其把 546 行扫描逻辑复制一份，不如再起一个引擎进程调它，
## 只把它的那一行 RESULT 转发出来 —— 同一条命令，同一个实现。
func _cmd_index(args: PackedStringArray) -> int:
	var cmd_args: PackedStringArray = [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--script", GEN_INDEX_SCRIPT,
	]
	if args.has("--check"):
		cmd_args.append("--check")
	var output: Array = []
	var code := OS.execute(OS.get_executable_path(), cmd_args, output, true)
	var text := ""
	for chunk in output:
		text += str(chunk)
	var result_line := ""
	for raw_line in text.split("\n"):
		var line := raw_line.strip_edges()
		var at := line.find("RESULT:")
		if at >= 0:
			result_line = line.substr(at)
	if result_line.is_empty():
		print("RESULT: FAIL gen_index.gd 未输出 RESULT 行（子进程退出码 %d）" % code)
		return 1
	print(result_line)
	return code


# ---------------------------------------------------------------------------
#  dump-state：一行 JSON 的"现在什么状态"
# ---------------------------------------------------------------------------
func _cmd_dump_state(args: PackedStringArray) -> int:
	var loop := root.get_node_or_null("TimeLoopManager")
	var memory := root.get_node_or_null("PersistentMemoryManager")
	if loop == null or memory == null:
		print("RESULT: FAIL Autoload 缺失（TimeLoopManager/PersistentMemoryManager）")
		return 1

	# 默认只报告"冷启动状态"；加 --start 才真的开跑（避免探针改变被测对象而不自知）
	if args.has("--start") and not loop.is_running():
		loop.start_loop()

	var clues: Array = memory.get_clues()
	var state := {
		"loop_index": loop.get_loop_index(),
		"running": loop.is_running(),
		"paused": loop.is_paused(),
		"elapsed": snappedf(loop.get_elapsed_seconds(), 0.01),
		"remaining": snappedf(loop.get_remaining_seconds(), 0.01),
		"duration": loop.get_loop_duration(),
		"time_scale": loop.get_time_scale(),
		"clues": clues.size(),
		"clue_ids": clues,
	}
	print("STATE %s" % JSON.stringify(state, "", false))
	print("RESULT: OK state loop=%d running=%s paused=%s elapsed=%.2f clues=%d" % [
		state["loop_index"], state["running"], state["paused"], state["elapsed"], clues.size(),
	])
	return 0


# ---------------------------------------------------------------------------
#  simulate：不开场景，直接 tick() 空跑，验证"跨循环线索保留"这条核心不变量
# ---------------------------------------------------------------------------
func _cmd_simulate(args: PackedStringArray) -> int:
	var loop := root.get_node_or_null("TimeLoopManager")
	var memory := root.get_node_or_null("PersistentMemoryManager")
	if loop == null or memory == null:
		print("RESULT: FAIL Autoload 缺失（TimeLoopManager/PersistentMemoryManager）")
		return 1

	var target := float(_arg(args, "--seconds", str(DEFAULT_SIM_SECONDS)))
	var scale := float(_arg(args, "--scale", "1"))
	var dt := float(_arg(args, "--dt", "0.05"))
	if target <= 0.0 or scale <= 0.0 or dt <= 0.0:
		print("RESULT: FAIL 参数非法：--seconds/--scale/--dt 必须为正数")
		return 2

	if args.has("--clue"):
		memory.add_clue("clue_sim_probe")

	loop.set_time_scale(scale)
	loop.start_loop()

	# 注意：memory 是 Node，方法返回值是 Variant —— 这里必须写显式类型，
	# 用 := 会触发 "Cannot infer the type ... because the value doesn't have a set type."
	var clues_before: int = memory.get_clues().size()
	var resets := 0
	var simulated := 0.0
	var ticks := 0
	var safety := int(ceil(target / (dt * scale))) + 100
	while simulated < target and ticks < safety:
		loop.tick(dt)
		simulated += dt * scale
		ticks += 1
		if loop.get_loop_index() != resets:
			resets = loop.get_loop_index()
			print("  第 %d 轮开始：已空跑 %.1fs，线索 %d 条" % [resets, simulated, memory.get_clues().size()])

	var clues_after: int = memory.get_clues().size()
	var state := {
		"simulated_seconds": snappedf(simulated, 0.1),
		"ticks": ticks,
		"time_scale": scale,
		"loop_index": loop.get_loop_index(),
		"loops_completed": resets,
		"clues_before": clues_before,
		"clues_after": clues_after,
	}
	print("SIM %s" % JSON.stringify(state, "", false))

	# 核心不变量：线索跨循环只增不减（阶段一的"记忆永不清空"）
	if resets == 0:
		print("RESULT: FAIL %.1fs 内没有跑完任何一轮循环（余页 %.0fs）" % [simulated, loop.get_loop_duration()])
		return 1
	if args.has("--clue") and clues_after < 1:
		print("RESULT: FAIL 线索在 %d 次重置后丢失（clues_after=0）" % resets)
		return 1
	print("RESULT: OK simulated=%.1fs ticks=%d loops_completed=%d clues=%d（跨循环未丢失）" % [
		simulated, ticks, resets, clues_after,
	])
	return 0


# ---------------------------------------------------------------------------
#  new-npc：生成 NPC 骨架（默认 dry-run；--write 才落盘，且立刻回读校验）
# ---------------------------------------------------------------------------
func _cmd_new_npc(args: PackedStringArray) -> int:
	var npc_id := _arg(args, "--id", "")
	var display_name := _arg(args, "--name", "")
	var room := _arg(args, "--room", "")
	var target := _arg(args, "--out", LEGACY_TIMELINE)
	if npc_id.is_empty() or display_name.is_empty():
		print("RESULT: FAIL 需要 --id（如 npc_03_footman）与 --name（如 车夫）")
		return 2

	var data = _read_json(target)
	if typeof(data) != TYPE_DICTIONARY:
		print("RESULT: FAIL 目标文件缺失或不是合法 JSON：%s" % target)
		return 1
	var root_dict: Dictionary = data
	var npcs: Array = []
	if typeof(root_dict.get("npcs", [])) == TYPE_ARRAY:
		npcs = root_dict["npcs"]
	var meta: Dictionary = root_dict.get("meta", {}) if typeof(root_dict.get("meta", {})) == TYPE_DICTIONARY else {}
	var rooms: Array = meta.get("rooms", []) if typeof(meta.get("rooms", [])) == TYPE_ARRAY else []

	for npc in npcs:
		if typeof(npc) == TYPE_DICTIONARY and str(npc.get("npc_id", "")) == npc_id:
			print("RESULT: SKIP %s 已存在（不覆盖，保持幂等）" % npc_id)
			return 0
	if room.is_empty():
		room = str(rooms[0]) if rooms.size() > 0 else "hall"
	if rooms.size() > 0 and not rooms.has(room):
		print("RESULT: FAIL 房间 \"%s\" 不在 meta.rooms 内；可用房间：%s" % [room, ", ".join(PackedStringArray(rooms))])
		return 2

	var entry := {
		"npc_id": npc_id,
		"display_name": display_name,
		"default_room": room,
		"timeline": [
			{
				"second": 0, "room": room, "action": "idle", "facing": "",
				"dialogue_id": "", "clue_id": "",
				"note": "由 cli.gd new-npc 生成的骨架：请补全后续时间节点（每 NPC 必须有 second:0）",
			},
		],
	}
	var snippet := JSON.stringify(entry, "  ", false)

	if not args.has("--write"):
		print("预览（加 --write 才写入 %s）：" % target)
		print(snippet)
		print("RESULT: OK dry-run npc=%s nodes=1（未写入任何文件）" % npc_id)
		return 0

	npcs.append(entry)
	root_dict["npcs"] = npcs
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		print("RESULT: FAIL 无法写入 %s（错误码 %d）" % [target, FileAccess.get_open_error()])
		return 1
	file.store_string(JSON.stringify(_ints_back(root_dict), "  ", false) + "\n")
	file.close()

	# 写完立刻用正式的解析器回读：宁可在这里失败，也不要把坏数据留给下一个人
	var result = Parser.load_from_file(target)
	if result == null or not result.ok:
		var reason := "解析器返回 null"
		if result != null:
			reason = result.error_summary()
		print("RESULT: FAIL 写入后回读失败（%s）：%s" % [target, reason])
		return 1
	print("RESULT: OK 已写入 %s：npc=%s 总数=%d 节点=%d" % [
		target, npc_id, result.npc_count(), result.get_schedule(npc_id).nodes.size(),
	])
	return 0


## Godot 的 JSON 解析把**所有数字都当 float**：读进来 `420` 会变成 `420.0`，
## 直接 stringify 回磁盘就把整张表的整数全改成浮点（实测：一个 NPC 的追加操作
## 让整份数据表的 `0/25/50/420/1` 全变成 `0.0/25.0/…`）。语义上无害，
## 但会让 git 出现整文件假 diff，也会让"同一份内容"产生两份字节。
## 所以落盘前把"值为整数的 float"还原成 int（真正的浮点如 0.05 原样保留）。
func _ints_back(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			var f: float = value
			if absf(f) < 1e15 and is_equal_approx(f, roundf(f)):
				return int(roundf(f))
			return f
		TYPE_ARRAY:
			var items: Array = []
			for item in (value as Array):
				items.append(_ints_back(item))
			return items
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for key in (value as Dictionary):
				out[key] = _ints_back((value as Dictionary)[key])
			return out
		_:
			return value


func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


# ---------------------------------------------------------------------------
func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var index := args.find(key)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return fallback


func _print_usage() -> void:
	print("用法: godot --headless --path . --script res://tools/cli.gd -- <子命令> [参数]")
	print("  validate                              数据 schema + 设计不变量校验")
	print("  smoke [--scene <路径>] [--frames N] [--no-clock]   实例化场景空跑 N 帧并断言核心系统存活")
	print("  cases                                 一行一个案件摘要")
	print("  index [--check]                       生成/校验 docs/INDEX.md + index.json（转发 gen_index.gd）")
	print("  dump-state [--start]                  打印一行 STATE <json>（圈数/秒数/流速/线索）")
	print("  simulate [--seconds N] [--scale X] [--clue]  不开场景空跑 N 游戏秒，验证线索跨循环保留")
	print("  new-npc --id <id> --name <名> [--room R] [--write]  NPC 骨架（默认只预览）")
	print("  help                                  本说明")
