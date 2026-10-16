extends SceneTree
## ============================================================================
##  tools/gen_index.gd —— 符号索引生成器（工具链第 1 步）
## ----------------------------------------------------------------------------
##  它做两件事，而且是"一次扫描同时完成"：
##    1. 【解析检查】把 scripts/ tools/ tests/ 下每个 .gd 都 load() 一遍，
##       任何一个脚本有语法/编译错误都会被捕获并列进 RESULT 行；
##    2. 【生成索引】用引擎自己的反射 API（而不是正则去猜）导出每个脚本的
##       类名、基类、信号、公开方法签名、常量、内部类、依赖的 Autoload，
##       再叠加数据表 / 场景 / 测试的摘要，输出：
##          docs/INDEX.md    —— 给人（和 AI）读的唯一入口文件
##          docs/index.json  —— 给工具链读的机器可读版本
##
##  用法：
##      godot --headless --path . --script res://tools/gen_index.gd
##      godot --headless --path . --script res://tools/gen_index.gd -- --check
##
##  退出码：0 = 生成成功 / 索引是最新的；1 = 有脚本解析失败 或 索引已过期。
##  `--check` 供 CI 与 check 闸门使用：谁手改了脚本却忘了重新生成索引，就会红。
##
##  为什么用引擎反射而不是正则？
##      正则解析 GDScript 会在多行签名、默认值、内部类、类型化数组上翻车，
##      而 load() + get_script_method_list() 拿到的是编译器眼里的真值。
##      副作用是顺带完成了全项目的语法检查 —— 一份扫描，两份收益。
##
##  为什么索引里【没有】生成时间和引擎版本？
##      因为 --check 要按内容比对，任何随时间/机器变化的信息都会造成"假漂移"。
##      引擎版本只在 stdout 打印，不进文件。
## ============================================================================

## 扫描根目录（相对项目根）。
const SCAN_ROOTS: Array[String] = ["res://scripts", "res://tools", "res://tests"]

const MD_PATH: String = "res://docs/INDEX.md"
const JSON_PATH: String = "res://docs/index.json"

## 数据表与场景目录（只做摘要，不深入解析语义）。
const DATA_DIR: String = "res://data"
const SCENE_DIR: String = "res://scenes"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var check_only := args.has("--check")

	var data := _collect()
	var markdown := _render_markdown(data)
	var json_text := JSON.stringify(data, "  ") + "\n"
	var parse_errors: Array = data["parse_errors"]

	print("引擎：%s   模块：%d   解析失败：%d" % [
		Engine.get_version_info()["string"], (data["modules"] as Array).size(), parse_errors.size(),
	])

	if check_only:
		if not parse_errors.is_empty():
			print("RESULT: FAIL 解析失败的脚本 %d 个：%s" % [
				parse_errors.size(), ", ".join(PackedStringArray(parse_errors)),
			])
			quit(1)
			return
		var drifted: Array[String] = []
		if _read_text(MD_PATH) != markdown:
			drifted.append(MD_PATH)
		if _read_text(JSON_PATH) != json_text:
			drifted.append(JSON_PATH)
		if drifted.is_empty():
			print("RESULT: CLEAN modules=%d" % (data["modules"] as Array).size())
			quit(0)
			return
		print("RESULT: DRIFT %s（请重新运行不带 --check 的 gen_index.gd）" % ", ".join(PackedStringArray(drifted)))
		quit(1)
		return

	# 普通模式：若存在解析失败，索引仍会生成（并在文件里标红），但退出码为 1。
	var write_err := _write_text(MD_PATH, markdown)
	write_err = maxi(write_err, _write_text(JSON_PATH, json_text))
	if write_err != OK:
		print("RESULT: FAIL 写入索引失败（错误码 %d）" % write_err)
		quit(1)
		return
	if not parse_errors.is_empty():
		print("RESULT: FAIL 解析失败的脚本 %d 个：%s" % [
			parse_errors.size(), ", ".join(PackedStringArray(parse_errors)),
		])
		quit(1)
		return
	print("RESULT: OK %s + %s modules=%d" % [MD_PATH, JSON_PATH, (data["modules"] as Array).size()])
	quit(0)


# ---------------------------------------------------------------------------
# 采集
# ---------------------------------------------------------------------------

func _collect() -> Dictionary:
	var autoloads := _get_autoloads()
	var modules: Array = []
	var parse_errors: Array = []

	for root in SCAN_ROOTS:
		for path in _find_gd_files(root):
			var module := _describe_script(path, autoloads)
			if module.is_empty():
				parse_errors.append(path)
			else:
				modules.append(module)

	modules.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))

	return {
		"main_scene": str(ProjectSettings.get_setting("application/run/main_scene", "")),
		"autoloads": autoloads,
		"modules": modules,
		"parse_errors": parse_errors,
		"data_files": _summarize_data_files(),
		"scenes": _summarize_scenes(),
	}


## 自动加载表：{名称: 脚本路径}
func _get_autoloads() -> Dictionary:
	var result: Dictionary = {}
	for prop in ProjectSettings.get_property_list():
		var name := str(prop.name)
		if not name.begins_with("autoload/"):
			continue
		var value := str(ProjectSettings.get_setting(name)).trim_prefix("*")
		result[name.trim_prefix("autoload/")] = value
	return result


## 递归收集 .gd（跳过隐藏目录；.uid 之类的旁挂文件不是脚本）。
func _find_gd_files(root: String) -> Array[String]:
	var found: Array[String] = []
	if not DirAccess.dir_exists_absolute(root):
		return found
	for file in DirAccess.get_files_at(root):
		if file.ends_with(".gd"):
			found.append(root.path_join(file))
	for dir in DirAccess.get_directories_at(root):
		if dir.begins_with("."):
			continue
		found.append_array(_find_gd_files(root.path_join(dir)))
	return found


## 用引擎反射描述一个脚本；返回空字典表示该脚本 load() 失败（语法错误）。
func _describe_script(path: String, autoloads: Dictionary) -> Dictionary:
	var script = load(path)
	if script == null:
		return {}

	var source: String = str(script.get_source_code()) if script.has_method("get_source_code") else ""
	var global_name := ""
	if script.has_method("get_global_name"):
		global_name = str(script.get_global_name())
	if global_name.is_empty():
		global_name = _scan_class_name(source)

	var signals: Array = []
	for sig in script.get_script_signal_list():
		signals.append({
			"name": str(sig["name"]),
			"args": _format_args(sig.get("args", [])),
		})

	var methods: Array = []
	var lifecycle: int = 0
	for method in script.get_script_method_list():
		var method_name := str(method["name"])
		if method_name.begins_with("_"):
			lifecycle += 1
			continue
		methods.append({
			"name": method_name,
			"signature": _format_method(method, source),
		})

	var inner_classes: Array = []
	var constants: Array = []
	var constant_map: Dictionary = script.get_script_constant_map()
	for constant_name in constant_map.keys():
		var value = constant_map[constant_name]
		if value is Script:
			# 区分两种"值是脚本"的常量：
			#   内部类（class X:）没有 resource_path；preload 别名有路径。
			var script_path := str((value as Script).resource_path)
			if script_path.is_empty():
				inner_classes.append(str(constant_name))
			else:
				constants.append("%s = preload(%s)" % [str(constant_name), script_path])
		elif typeof(value) in [TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME]:
			constants.append("%s = %s" % [str(constant_name), str(value)])
		elif typeof(value) in [TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY,
				TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_STRING_ARRAY]:
			constants.append("%s = %s" % [str(constant_name), _compact(value)])
		else:
			constants.append("%s（复合值）" % str(constant_name))

	# 依赖了哪些 Autoload（跨系统耦合一眼可见，避免"偷偷全局耦合"）。
	# 两条规则保证这个列表有意义：
	#   1) 先剥掉注释 —— 文档里提到某个 Autoload 不算依赖；
	#   2) 排除自己 —— 自己的 Autoload 名出现在自己的代码里很正常（日志前缀等）。
	# 局限：字符串里的名字仍会被算作依赖（例如 push_warning("[TimeLoopManager] …")）。
	# 这是刻意保留的保守策略：宁可多报一个可疑项，也不漏掉真耦合。
	var code_only := _strip_comments(source)
	var self_autoload := _autoload_name_for(path, autoloads)
	var deps: Array[String] = []
	for autoload_name in autoloads.keys():
		if str(autoload_name) == self_autoload:
			continue
		if code_only.contains(str(autoload_name)):
			deps.append(str(autoload_name))
	deps.sort()

	var role := "autoload" if autoloads.values().has(path) else "module"
	if path.begins_with("res://tools/"):
		role = "tool"
	elif path.begins_with("res://tests/"):
		role = "test"

	return {
		"path": path,
		"role": role,
		"autoload_name": _autoload_name_for(path, autoloads),
		"class_name": global_name,
		"base": str(script.get_instance_base_type()),
		"doc": _extract_doc(source),
		"signals": signals,
		"methods": methods,
		"private_methods": lifecycle,
		"constants": constants,
		"inner_classes": inner_classes,
		"depends_on_autoloads": deps,
		"expected_checks": int(constant_map.get("EXPECTED_CHECKS", 0)),
		"lines": source.split("\n").size() if not source.is_empty() else 0,
	}


## 去掉行注释（保留字符串字面量里的 # ），用于依赖扫描。
func _strip_comments(source: String) -> String:
	var out := PackedStringArray()
	for line in source.split("\n"):
		var in_string := false
		var quote := ""
		var cut := line.length()
		for i in line.length():
			var ch := line[i]
			if in_string:
				if ch == quote:
					in_string = false
				continue
			if ch == "\"" or ch == "'":
				in_string = true
				quote = ch
			elif ch == "#":
				cut = i
				break
		out.append(line.substr(0, cut))
	return "\n".join(out)


## 常量值的紧凑显示（索引要短）。
func _compact(value) -> String:
	var text := str(value)
	return text if text.length() <= 60 else text.substr(0, 57) + "…"


## 把 1.0 这种"其实是整数"的数值显示成 1。
func _num(value) -> String:
	if typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), roundf(float(value))):
		return str(int(value))
	return str(value)


func _autoload_name_for(path: String, autoloads: Dictionary) -> String:
	for autoload_name in autoloads.keys():
		if str(autoloads[autoload_name]) == path:
			return str(autoload_name)
	return ""


## 从源码里找 `class_name X`（双保险：不依赖编辑器生成的类缓存）。
func _scan_class_name(source: String) -> String:
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("class_name "):
			return trimmed.trim_prefix("class_name ").split(" ")[0].strip_edges()
		if trimmed.begins_with("func ") or trimmed.begins_with("var "):
			break
	return ""


## 取文件头部第一行有意义的 `##` 文档注释作为职责摘要。
func _extract_doc(source: String) -> String:
	var seen_header := false
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if not trimmed.begins_with("##"):
			if seen_header:
				break
			continue
		var text := trimmed.trim_prefix("##").strip_edges()
		if text.is_empty():
			continue
		# 跳过 ==== / ---- 这类分隔线
		var only_decoration := true
		for ch in text:
			if ch != "=" and ch != "-" and ch != " ":
				only_decoration = false
				break
		if only_decoration:
			seen_header = true
			continue
		return text
	return ""


func _format_args(args: Array) -> String:
	var parts: Array[String] = []
	for arg in args:
		parts.append(_format_arg(arg))
	return ", ".join(PackedStringArray(parts))


func _format_arg(arg: Dictionary) -> String:
	var arg_name := str(arg.get("name", "?"))
	var type_id: int = int(arg.get("type", TYPE_NIL))
	if type_id == TYPE_NIL:
		return arg_name
	# 注意：class_name 是 GDScript 保留字，不能当变量名，所以叫 type_class。
	var type_class := str(arg.get("class_name", ""))
	if type_id == TYPE_OBJECT and not type_class.is_empty():
		return "%s: %s" % [arg_name, type_class]
	if type_id == TYPE_ARRAY and not type_class.is_empty():
		return "%s: Array[%s]" % [arg_name, type_class]
	return "%s: %s" % [arg_name, type_string(type_id)]


func _format_method(method: Dictionary, source: String) -> String:
	var method_name := str(method["name"])
	var raw_args: Array = method.get("args", [])
	var default_count: int = (method.get("default_args", []) as Array).size()
	# 带默认值的参数 = 末尾的那 default_count 个，标成 "= …"（真实默认值不进索引）。
	var parts: Array[String] = []
	for i in raw_args.size():
		var text := _format_arg(raw_args[i])
		if i >= raw_args.size() - default_count:
			text += " = …"
		parts.append(text)
	var args := ", ".join(PackedStringArray(parts))
	var ret: Dictionary = method.get("return", {})
	var return_type: int = int(ret.get("type", TYPE_NIL))
	var returns := "void"
	if return_type != TYPE_NIL:
		var return_class := str(ret.get("class_name", ""))
		if return_type == TYPE_OBJECT and not return_class.is_empty():
			returns = return_class
		elif return_type == TYPE_ARRAY and not return_class.is_empty():
			returns = "Array[%s]" % return_class
		else:
			returns = type_string(return_type)
	# 反射对内层类返回类型只会报出原生基类（ParseResult → RefCounted），
	# 那是"引擎眼里的类型"而不是"作者写的类型"。源码里写了就优先用源码的写法。
	var declared := _declared_return_type(source, method_name)
	if not declared.is_empty():
		returns = declared
	var keyword := "static func " if source.contains("static func " + method_name + "(") else "func "
	return "%s%s(%s) -> %s" % [keyword, method_name, args, returns]


## 从源码里取 `func 名字(...) -> X` 中作者写的返回类型（拿不到就返回空串）。
func _declared_return_type(source: String, method_name: String) -> String:
	var marker := "func " + method_name + "("
	var index := source.find(marker)
	while index >= 0:
		var tail := source.substr(index)
		# 截到下一个顶层函数声明为止，避免把后一个函数的 `->` 算进来。
		var next_func := tail.find("\nfunc ")
		var next_static := tail.find("\nstatic func ")
		if next_func < 0 or (next_static >= 0 and next_static < next_func):
			next_func = next_static
		if next_func >= 0:
			tail = tail.substr(0, next_func)
		var arrow := tail.find("->")
		if arrow >= 0:
			var declared := tail.substr(arrow + 2)
			var colon := declared.find(":")
			if colon >= 0:
				var text := declared.substr(0, colon).strip_edges()
				if not text.is_empty():
					return text
		index = source.find(marker, index + 1)
	return ""


## 数据表摘要（只读 meta，不解释业务语义）。
func _summarize_data_files() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(DATA_DIR):
		return out
	var names := DirAccess.get_files_at(DATA_DIR)
	names.sort()
	for name in names:
		if not name.ends_with(".json"):
			continue
		var path := DATA_DIR.path_join(name)
		var text := _read_text(path)
		var json := JSON.new()
		var entry := {"path": path, "ok": json.parse(text) == OK, "summary": ""}
		if entry["ok"] and json.data is Dictionary:
			var root: Dictionary = json.data
			var meta: Dictionary = root.get("meta", {}) if root.get("meta") is Dictionary else {}
			var npcs: Array = root.get("npcs", []) if root.get("npcs") is Array else []
			var node_count := 0
			for npc in npcs:
				if npc is Dictionary and npc.get("timeline") is Array:
					node_count += (npc["timeline"] as Array).size()
			entry["summary"] = "schema=%s map=%s 循环=%s秒 NPC=%d 节点=%d" % [
				_num(meta.get("schema_version", "-")), str(meta.get("map_id", "-")),
				_num(meta.get("loop_duration_seconds", "-")), npcs.size(), node_count,
			]
		else:
			entry["summary"] = "⚠️ JSON 解析失败"
		out.append(entry)
	return out


## 场景摘要（只数节点、取根节点，不做完整场景解析）。
func _summarize_scenes() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(SCENE_DIR):
		return out
	var names := DirAccess.get_files_at(SCENE_DIR)
	names.sort()
	for name in names:
		if not name.ends_with(".tscn"):
			continue
		var path := SCENE_DIR.path_join(name)
		var text := _read_text(path)
		var root_type := "?"
		var root_name := "?"
		var nodes := 0
		var root_resources := 0
		for line in text.split("\n"):
			var trimmed := line.strip_edges()
			if trimmed.begins_with("[ext_resource"):
				root_resources += 1
			if not trimmed.begins_with("[node "):
				continue
			nodes += 1
			if nodes == 1:
				root_name = _attr(trimmed, "name")
				root_type = _attr(trimmed, "type")
		# "是否由规格生成"不看 .tscn 内部标记（塞注释会破坏场景格式），
		# 而是看 scenes_src/ 下有没有同名规格文件 —— 规格在，场景就是它的产物。
		var spec_path := "res://scenes_src/%s.json" % name.get_basename()
		out.append({
			"path": path, "root_name": root_name, "root_type": root_type,
			"nodes": nodes, "ext_resources": root_resources,
			"generated": FileAccess.file_exists(spec_path), "spec": spec_path,
		})
	return out


func _attr(line: String, key: String) -> String:
	var marker := key + "=\""
	var start := line.find(marker)
	if start < 0:
		return "?"
	start += marker.length()
	var end := line.find("\"", start)
	if end < 0:
		return "?"
	return line.substr(start, end - start)


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------

func _render_markdown(data: Dictionary) -> String:
	var lines := PackedStringArray()
	var modules: Array = data["modules"]
	var parse_errors: Array = data["parse_errors"]
	var autoloads: Dictionary = data["autoloads"]

	lines.append("# 项目索引 · 《茅山秘录·诡异录》")
	lines.append("")
	lines.append("> 🤖 本文件由 `tools/gen_index.gd` 自动生成，**请勿手改**。")
	lines.append("> 重新生成：`godot --headless --path . --script res://tools/gen_index.gd`")
	lines.append("> 校验是否过期：结尾加 `-- --check`（过期或存在脚本解析失败时退出码 1）")
	lines.append(">")
	lines.append("> **这是进入本项目的唯一入口**：先读这一页确定「该改哪个文件」，再打开具体源文件。")
	lines.append("")

	lines.append("## 0. 骨架")
	lines.append("")
	lines.append("- 主场景：`%s`" % str(data["main_scene"]))
	if autoloads.is_empty():
		lines.append("- Autoload：无")
	else:
		for autoload_name in autoloads.keys():
			lines.append("- Autoload：`%s` → `%s`" % [str(autoload_name), str(autoloads[autoload_name])])
	var role_counts := {}
	for module in modules:
		var role := str(module["role"])
		role_counts[role] = int(role_counts.get(role, 0)) + 1
	# 注意：GDScript 没有 Python 那种列表推导式，这里老老实实循环拼装。
	var role_parts := PackedStringArray()
	for role in role_counts.keys():
		role_parts.append("%s %d" % [str(role), int(role_counts[role])])
	lines.append("- 模块统计：%s（合计 %d 个 .gd）" % [", ".join(role_parts), modules.size()])
	if parse_errors.is_empty():
		lines.append("- 解析检查：✅ 全部脚本可加载")
	else:
		lines.append("- 解析检查：❌ **%d 个脚本解析失败**：%s" % [
			parse_errors.size(), ", ".join(PackedStringArray(parse_errors)),
		])
	lines.append("")

	lines.append("## 1. 模块地图")
	lines.append("")
	lines.append("| 路径 | 类名 / Autoload | 基类 | 行数 | 职责 |")
	lines.append("| --- | --- | --- | --- | --- |")
	for module in modules:
		var identity := ""
		if not str(module["autoload_name"]).is_empty():
			identity = "**Autoload** `%s`" % str(module["autoload_name"])
		elif not str(module["class_name"]).is_empty():
			identity = "`%s`" % str(module["class_name"])
		else:
			identity = "—"
		lines.append("| `%s` | %s | %s | %d | %s |" % [
			str(module["path"]), identity, str(module["base"]), int(module["lines"]), str(module["doc"]),
		])
	lines.append("")

	lines.append("## 2. 接口清单")
	lines.append("")
	for module in modules:
		var title := "### `%s`" % str(module["path"])
		if not str(module["autoload_name"]).is_empty():
			title += " — Autoload `%s`" % str(module["autoload_name"])
		lines.append(title)
		lines.append("")
		if not str(module["doc"]).is_empty():
			lines.append("> %s" % str(module["doc"]))
			lines.append("")
		lines.append("- 基类：`%s`；行数 %d；私有/内部方法 %d 个" % [
			str(module["base"]), int(module["lines"]), int(module["private_methods"]),
		])
		var deps: Array = module["depends_on_autoloads"]
		lines.append("- 依赖 Autoload：%s" % ("无（完全解耦）" if deps.is_empty() else ", ".join(PackedStringArray(deps))))
		var signals: Array = module["signals"]
		if signals.is_empty():
			lines.append("- 信号：无")
		else:
			var sig_parts: Array[String] = []
			for sig in signals:
				sig_parts.append("`%s(%s)`" % [str(sig["name"]), str(sig["args"])])
			lines.append("- 信号：%s" % "；".join(PackedStringArray(sig_parts)))
		var methods: Array = module["methods"]
		if methods.is_empty():
			lines.append("- 公开方法：无")
		else:
			lines.append("- 公开方法：")
			for method in methods:
				lines.append("  - `%s`" % str(method["signature"]))
		var inner: Array = module["inner_classes"]
		if not inner.is_empty():
			lines.append("- 内部类：%s" % ", ".join(PackedStringArray(inner)))
		var constants: Array = module["constants"]
		if not constants.is_empty():
			lines.append("- 常量：%s" % "；".join(PackedStringArray(constants)))
		lines.append("")

	lines.append("## 3. 数据表")
	lines.append("")
	lines.append("| 文件 | 结构摘要 |")
	lines.append("| --- | --- |")
	for entry in data["data_files"]:
		lines.append("| `%s` | %s |" % [str(entry["path"]), str(entry["summary"])])
	lines.append("")

	lines.append("## 4. 场景")
	lines.append("")
	lines.append("| 文件 | 根节点 | 节点数 | ext_resource | 生成方式 |")
	lines.append("| --- | --- | --- | --- | --- |")
	for entry in data["scenes"]:
		lines.append("| `%s` | `%s` (%s) | %d | %d | %s |" % [
			str(entry["path"]), str(entry["root_name"]), str(entry["root_type"]),
			int(entry["nodes"]), int(entry["ext_resources"]),
			"生成（勿手改）" if bool(entry["generated"]) else "手写",
		])
	lines.append("")

	lines.append("## 5. 测试")
	lines.append("")
	lines.append("| 测试文件 | 断言数 | 运行命令 |")
	lines.append("| --- | --- | --- |")
	var test_count := 0
	for module in modules:
		if str(module["role"]) != "test":
			continue
		test_count += 1
		var checks := int(module["expected_checks"])
		lines.append("| `%s` | %s | `godot --headless --path . --script %s` |" % [
			str(module["path"]),
			("%d" % checks) if checks > 0 else "—",
			str(module["path"]),
		])
	if test_count == 0:
		lines.append("| — | — | 暂无测试 |")
	lines.append("")

	lines.append("## 6. 工具链命令")
	lines.append("")
	lines.append("| 命令 | 作用 |")
	lines.append("| --- | --- |")
	lines.append("| `./tools/check.ps1` | 一条命令跑完全部检查（≤20 行输出，全量日志写 `logs/`） |")
	lines.append("| `godot --headless --path . --script res://tools/gen_index.gd` | 重新生成本索引（顺带全项目解析检查） |")
	lines.append("| `godot --headless --path . --script res://tools/cli.gd -- validate` | 校验数据表（含设计不变量） |")
	lines.append("| `godot --headless --path . --script res://tools/cli.gd -- simulate --seconds 420` | 无头模拟整轮循环并输出 JSON |")
	lines.append("| `godot --headless --path . --script res://tools/gen_scene.gd -- --spec <规格>` | 由规格重新生成场景 `.tscn` |")
	lines.append("")
	return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 文件读写
# ---------------------------------------------------------------------------

func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text.replace("\r\n", "\n")


func _write_text(path: String, text: String) -> int:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		var dir_err := DirAccess.make_dir_recursive_absolute(dir)
		if dir_err != OK:
			return dir_err
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(text)
	file.close()
	return OK
