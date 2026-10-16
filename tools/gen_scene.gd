extends SceneTree
## ============================================================================
##  gen_scene.gd —— 场景生成器：场景规格 JSON → .tscn（调用引擎自身的序列化器）
## ----------------------------------------------------------------------------
##  为什么要有这个工具？
##    手写 .tscn 文本极其脆弱（uid 漂移、格式错一处整个场景打不开），而且改一个
##    属性要动多处文本。这里改成：用 Node.new() / ClassDB.instantiate() 真正把节点树
##    搭出来 → 赋值 → 打 owner → PackedScene.pack() → ResourceSaver.save()。
##    序列化交给引擎自己，永远不会写出引擎读不懂的文本。
##
##  运行方式（在项目根目录执行）：
##    godot --headless --path . --script res://tools/gen_scene.gd -- \
##        --spec res://scenes_src/main.json [--out res://scenes/main.tscn] [--check]
##
##  参数：
##    --spec  <res:// 或绝对路径>  场景规格 JSON（必填）
##    --out   <res:// 路径 .tscn>  输出场景；缺省 = res://scenes/<规格文件名>.tscn
##    --check                      只校验：生成到 user:// 临时文件并与现有 .tscn 逐行比较，
##                                 **不覆盖**真实文件；有差异时退出码 1
##
##  ★ 输出是"规范形"：落盘时会删掉 unique_id=NNN（Godot 4.7 每次打包随机生成）
##    与 ext_resource 里的 uid="uid://..."（编辑器补的）。二者都不影响场景语义，
##    但会让 git 反复出现假 diff。删掉之后：同一份规格 ⇒ 同一份字节，
##    因此 --check 可以做到精确到字节的漂移检测。
##
##  退出码：0 = 成功 / 无漂移；1 = 任何错误（缺规格、节点类型非法、属性非法、保存失败、漂移）
##  最后一行固定输出机器可读结果（前面的过程日志不超过约 20 行）：
##    RESULT: OK <out_path> nodes=<N>
##    RESULT: CLEAN <out_path> nodes=<N>
##    RESULT: DRIFT <out_path>          （随后最多 10 行"仅行号"的差异上下文）
##    RESULT: FAIL <reason>
##
##  ★ 规格 JSON 的约定（契约，新增字段请同步此注释）：
##    {
##      "scene_name": "Main",              // 可选，只作日志/记录用
##      "root": <节点对象>                  // 必填，整个场景的根
##    }
##    节点对象：
##    {
##      "type":     "Control",             // 必填，必须是 ClassDB.class_exists() 认可的真实类
##      "name":     "DebugHUD",            // 必填，节点名
##      "script":   "res://xxx.gd",        // 可选，任何节点都能挂脚本（load + set_script）
##      "props":    { ... },               // 可选，属性表
##      "children": [ <节点对象>, ... ]     // 可选，子节点（顺序即 add_child 顺序）
##    }
##    属性取值规则（按顺序判断）：
##      1) JSON 的 bool / int / float / String → 直接 set()（字符串可含中文）；
##      2) 字符串若能被 str_to_var() 解析成"非 String"的 Variant
##         （如 "Color(0.92, 0.94, 1, 1)" / "Vector2(10, 20)" / "NodePath(\"../X\")"）→ 用解析后的值；
##      3) 属性键里的 "/" 是子属性路径（如 "theme_override_font_sizes/font_size"），
##         Node.set() 原生支持，直接透传即可。
##    拼错属性名会被**提前拦下并报错退出**（比引擎默默忽略要好得多）。
##
##  ★ 本脚本刻意不写 class_name：工具脚本要在"刚 clone、没有全局类缓存"的环境直接跑。
## ============================================================================


## 缺省输出目录：--out 省略时 = OUT_DIR_DEFAULT + <规格文件名>.tscn
const OUT_DIR_DEFAULT: String = "res://scenes/"
## --check 模式的临时产物（user:// 在无头模式下也可写）
const TMP_PATH: String = "user://gen_scene_check.tscn"
## 人类可读日志的行数上限（结果行不计入）
const LOG_LIMIT: int = 18
## 漂移时最多打印几行差异上下文
const DRIFT_LIMIT: int = 10

## 结果行（整个进程只会打印这一行 "RESULT: ..."）
var _result: String = ""
var _exit_code: int = 1
## 过程日志
var _log_lines: PackedStringArray = []
## 致命错误信息；非空即失败
var _error: String = ""
## 匹配节点头里的 unique_id=NNN（Godot 4.7 新增，每次打包都是随机数）
var _re_unique_id: RegEx = RegEx.new()
## 匹配 ext_resource 里的 uid="uid://..."（编辑器自动补的，首次生成时通常没有）
var _re_uid: RegEx = RegEx.new()
## 匹配任意 id="..."（用于收集 ext_resource 的随机 id）
var _re_any_id: RegEx = RegEx.new()
## 匹配 ExtResource("...") / SubResource("...") 引用
var _re_ext_ref: RegEx = RegEx.new()


func _initialize() -> void:
	_re_unique_id.compile(" unique_id=[0-9]+")
	_re_uid.compile(" uid=\"uid://[^\"]*\"")
	_re_any_id.compile("\\bid=\"([^\"]+)\"")
	_re_ext_ref.compile("(Ext|Sub)Resource\\(\"([^\"]+)\"\\)")

	var args: PackedStringArray = OS.get_cmdline_user_args()
	var spec_path: String = _arg_value(args, "--spec")
	var out_path: String = _arg_value(args, "--out")
	var check_mode: bool = args.has("--check")

	if spec_path.is_empty():
		_fail("缺少 --spec 参数")
		_finish()
		return

	var spec: Dictionary = _load_json(spec_path)
	if _failed():
		_finish()
		return

	var scene_name: String = str(spec.get("scene_name", ""))
	if not scene_name.is_empty():
		_note("场景名：%s" % scene_name)

	var root_spec: Variant = spec.get("root")
	if typeof(root_spec) != TYPE_DICTIONARY:
		_fail("规格缺少 root 对象（%s）" % spec_path)
		_finish()
		return

	if out_path.is_empty():
		out_path = OUT_DIR_DEFAULT + _basename(spec_path).get_basename() + ".tscn"
	out_path = _to_res_path(out_path)

	var root: Node = _build_node(root_spec)
	if _failed():
		_finish()
		return

	# 关键一步：子节点只有把 owner 指回根节点，才会被 PackedScene.pack() 序列化进去。
	_set_owners(root, root)
	var total: int = _count_nodes(root)
	_note("节点总数：%d（除根外全部已设置 owner=root）" % total)

	# 注意：pack() 是实例方法，不能写成 PackedScene.pack(root)。
	var packed: PackedScene = PackedScene.new()
	var pack_err: int = packed.pack(root)
	if pack_err != OK:
		root.free()
		_fail("PackedScene.pack() 失败：%s" % error_string(pack_err))
		_finish()
		return

	if check_mode:
		# 只校验：写进 user:// 临时文件，绝不碰真实文件
		var tmp_err: int = _save_canonical(packed, TMP_PATH)
		if tmp_err != OK:
			root.free()
			_fail("临时保存失败：%s" % error_string(tmp_err))
			_finish()
			return
		var is_clean: bool = _compare_files(TMP_PATH, out_path)
		root.free()
		if _failed():
			_finish()
			return
		if is_clean:
			_ok("RESULT: CLEAN %s nodes=%d" % [out_path, total], 0)
		else:
			_ok("RESULT: DRIFT %s" % out_path, 1)
		_finish()
		return

	# 输出目录可能还不存在（新克隆的仓库里 scenes/ 之外的目录尤其如此），
	# 先递归建目录，否则 ResourceSaver 会以 ERR_FILE_CANT_OPEN 失败。
	if not _ensure_dir(out_path.get_base_dir()):
		root.free()
		_fail("无法创建输出目录：%s" % out_path.get_base_dir())
		_finish()
		return

	var save_err: int = _save_canonical(packed, out_path)
	if save_err != OK:
		root.free()
		_fail("保存失败（%s）：%s" % [out_path, error_string(save_err)])
		_finish()
		return

	root.free()
	_ok("RESULT: OK %s nodes=%d" % [out_path, total], 0)
	_finish()


# ---------------------------------------------------------------------------
# 节点树构建
# ---------------------------------------------------------------------------

## 递归构建一个节点及其子树。
func _build_node(node_spec: Dictionary) -> Node:
	var type_name: String = str(node_spec.get("type", ""))
	if type_name.is_empty():
		_fail("节点缺少 type 字段（name=%s）" % str(node_spec.get("name", "?")))
		return null
	if not ClassDB.class_exists(type_name):
		_fail("未知节点类型：%s（name=%s）—— 不是 ClassDB 里存在的真实类"
			% [type_name, str(node_spec.get("name", "?"))])
		return null

	var node: Node = ClassDB.instantiate(type_name) as Node
	if node == null:
		_fail("无法实例化节点类型：%s（name=%s）" % [type_name, str(node_spec.get("name", "?"))])
		return null

	node.name = str(node_spec.get("name", type_name))

	if node_spec.has("script"):
		var script_path: String = str(node_spec["script"])
		# 工具脚本不能用 class_name，所以这里用 load() 而不是 preload。
		var scr: Variant = load(script_path)
		if scr == null or not (scr is Script):
			node.free()
			_fail("脚本加载失败：%s（节点 %s）" % [script_path, node.name])
			return null
		node.set_script(scr)

	var props: Variant = node_spec.get("props", {})
	if typeof(props) == TYPE_DICTIONARY:
		for key in (props as Dictionary).keys():
			var prop_key: String = str(key)
			if not _has_property(node, prop_key):
				var owner_desc: String = "%s（%s）" % [node.name, type_name]
				node.free()
				_fail("未知属性：%s —— %s 没有这个属性" % [prop_key, owner_desc])
				return null
			var value: Variant = _decode_value((props as Dictionary)[key])
			node.set(prop_key, value)

	var children: Variant = node_spec.get("children", [])
	if typeof(children) == TYPE_ARRAY:
		for child_spec in (children as Array):
			if typeof(child_spec) != TYPE_DICTIONARY:
				node.free()
				_fail("children 里出现了非对象元素（父节点 %s）" % node.name)
				return null
			var child: Node = _build_node(child_spec)
			if _failed():
				node.free()
				return null
			node.add_child(child)
	return node


## 属性值解码：先试 str_to_var()（支持 "Color(...)" / "Vector2(...)" 这类字面量），
## 解析不出（返回 null，或解析结果就是同一字符串）就按原样使用。
func _decode_value(raw: Variant) -> Variant:
	if typeof(raw) != TYPE_STRING:
		return raw
	var text: String = raw
	var parsed: Variant = str_to_var(text)
	if parsed != null and typeof(parsed) != TYPE_STRING:
		return parsed
	return text


## 判断对象是否真的拥有该属性（支持 "a/b" 子属性路径与 "a:x" 索引写法）。
## 说明：Godot 把主题覆盖项登记成了名字里就带 "/" 的属性
## （如 "theme_override_colors/font_color"），而 "position:x" 这类索引写法则不在属性表里。
## 所以按"整名 → 去掉 theme_override_ 前缀 → 去掉 x:y 后缀 → 取 "/" 前的基名"
## 依次尝试；其中 theme_override_* 一律放行（Object._set() 按前缀路由，拼错也不会崩）。
func _has_property(obj: Object, prop_key: String) -> bool:
	var candidates: PackedStringArray = [prop_key]
	var stripped: String = prop_key
	if stripped.begins_with("theme_override_"):
		var slash: int = stripped.find("/")
		if slash >= 0:
			stripped = stripped.substr(slash + 1)
			candidates.append(stripped)
	var colon: int = stripped.find(":")
	if colon >= 0:
		var no_index: String = stripped.substr(0, colon)
		candidates.append(no_index)
		stripped = no_index
	var sub_slash: int = stripped.find("/")
	if sub_slash >= 0:
		candidates.append(stripped.substr(0, sub_slash))

	for info in obj.get_property_list():
		if candidates.has(str(info.get("name", ""))):
			return true
	return false


## 给除根节点以外的所有节点设置 owner —— 否则它们不会出现在打包结果里。
func _set_owners(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owners(child, root)


func _count_nodes(node: Node) -> int:
	var n: int = 1
	for child in node.get_children():
		n += _count_nodes(child)
	return n


# ---------------------------------------------------------------------------
# 落盘：保存 → 归一化文本 → 写回
# ---------------------------------------------------------------------------

## 保存场景，并把引擎写出的文本归一化成"规范形"（去掉一切不稳定标识符）。
##
## ★ 为什么要写回一次文本？
##   ResourceSaver 会写出三类"每次都不一样"的内容，让同一份规格产生字节不同的文件：
##     1) 节点头里的 unique_id=NNN —— Godot 4.7 新增，每次 pack() 都是随机数；
##     2) ext_resource 里的 uid="uid://..." —— 编辑器补的，首次生成时通常没有；
##     3) ext_resource 的 id="1_x7k2p" —— 引擎启动时 Math::randomize() 播种的随机短码，
##        同一份规格连跑三次会得到三个不同的 id（已实测）。
##   这三样都不影响场景语义（已实测：处理完之后 load() + instantiate() 一切正常），
##   但会让 git 每次都出现假 diff、让 --check 永远报漂移。
##   所以这里把它们全部规整掉，让"同一份规格 ⇒ 同一份字节"，
##   使 --check 能真正做到**逐字节**的漂移检测，而不是靠"忽略若干行"糊过去。
##   注意：本工具只做减法与改名 —— 节点、属性、引用关系全部由 ResourceSaver 产出，
##   绝不手写场景内容。
func _save_canonical(packed: PackedScene, path: String) -> int:
	var err: int = ResourceSaver.save(packed, path)
	if err != OK:
		return err
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return FAILED
	text = text.replace("\r\n", "\n")
	text = _re_uid.sub(text, "", true)
	text = _re_unique_id.sub(text, "", true)
	text = _renumber_ext_ids(text)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FAILED
	file.store_string(text)
	file.close()
	return OK


## 把 ext_resource 的随机 id 按"出现顺序"改写成稳定的 id="1_0" / "1_1" ...，
## 并同步改写全文所有 ExtResource("...") / SubResource("...") 引用。
## 这样同一份规格永远产出同一份字节。
func _renumber_ext_ids(text: String) -> String:
	var lines: PackedStringArray = text.split("\n")
	var id_map: Dictionary = {}   # 原 id -> 新 id
	var index: int = 0
	var out: PackedStringArray = []
	for line in lines:
		if line.begins_with("[ext_resource "):
			var id_match: RegExMatch = _re_any_id.search(line)
			if id_match != null:
				var old_id: String = id_match.get_string(1)
				var new_id: String = "1_%d" % index
				id_map[old_id] = new_id
				index += 1
				line = line.substr(0, id_match.get_start(0)) + "id=\"%s\"" % new_id \
					+ line.substr(id_match.get_end(0))
		out.append(line)

	if id_map.is_empty():
		return text

	# 改写引用。必须倒着替换，否则前面的替换会让后面的下标全部失效。
	var joined: String = "\n".join(out)
	var matches: Array[RegExMatch] = []
	var m: RegExMatch = _re_ext_ref.search(joined)
	while m != null:
		matches.append(m)
		m = _re_ext_ref.search(joined, m.get_end(0))
	for i in range(matches.size() - 1, -1, -1):
		var match: RegExMatch = matches[i]
		var kind: String = match.get_string(1)
		var old_ref: String = match.get_string(2)
		if not id_map.has(old_ref):
			continue
		var replacement: String = "%sResource(\"%s\")" % [kind, str(id_map[old_ref])]
		joined = joined.substr(0, match.get_start(0)) + replacement + joined.substr(match.get_end(0))
	return joined


## 逐行比较两个文件（两边都先归一化：去行尾空白、折叠/去掉末尾空行）。
## 无漂移返回 true；有漂移返回 false（并打印差异位置）；出错则 _fail()。
func _compare_files(tmp_path: String, target_path: String) -> bool:
	var generated: String = _read_text(tmp_path)
	if _failed():
		return false
	if not FileAccess.file_exists(target_path):
		_fail("目标文件不存在：%s（--check 需要先正常生成一次）" % target_path)
		return false

	var expected: String = _read_text(target_path)
	if _failed():
		return false

	var gen_lines: PackedStringArray = _normalize(generated)
	var disk_lines: PackedStringArray = _normalize(expected)
	if gen_lines == disk_lines:
		return true

	_note("检测到文本漂移，差异位置（仅行号）：")
	var diff_lines: PackedStringArray = _diff_lines(gen_lines, disk_lines)
	var shown: int = 0
	for line in diff_lines:
		if shown >= DRIFT_LIMIT:
			_note("  ...（其余差异已省略）")
			break
		_note("  %s" % line)
		shown += 1
	return false


## 归一化：统一换行、去掉行尾空白、折叠连续空行、去掉末尾空行。
## （uid / unique_id 已在落盘时删掉，这里只做与空白有关的容错，便于诊断真正的漂移。）
func _normalize(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for raw_line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		var line: String = raw_line.strip_edges(false, true)
		if line.is_empty() and out.size() > 0 and out[out.size() - 1].is_empty():
			continue
		out.append(line)
	while out.size() > 0 and out[out.size() - 1].is_empty():
		out.remove_at(out.size() - 1)
	return out


## 朴素 LCS 差异 → 每处变化只输出一行"行号"描述。
func _diff_lines(a: PackedStringArray, b: PackedStringArray) -> PackedStringArray:
	var diff: PackedStringArray = []
	var n: int = a.size()
	var m: int = b.size()
	var dp: Array = []
	dp.resize(n + 1)
	for i in range(n + 1):
		var row: PackedInt32Array = PackedInt32Array()
		row.resize(m + 1)
		dp[i] = row
	for i in range(n - 1, -1, -1):
		for j in range(m - 1, -1, -1):
			if a[i] == b[j]:
				dp[i][j] = dp[i + 1][j + 1] + 1
			else:
				dp[i][j] = maxi(dp[i + 1][j], dp[i][j + 1])

	var i2: int = 0
	var j2: int = 0
	while i2 < n and j2 < m:
		if a[i2] == b[j2]:
			i2 += 1
			j2 += 1
			continue
		var start_a: int = i2
		var start_b: int = j2
		# 成对推进"改动区"，直到重新出现公共子序列
		while i2 < n and j2 < m and a[i2] != b[j2]:
			i2 += 1
			j2 += 1
		var old_count: int = i2 - start_a
		var new_count: int = j2 - start_b
		if old_count > 0 and new_count > 0:
			diff.append("生成第 %d-%d 行  <->  磁盘第 %d-%d 行" % [start_a + 1, i2, start_b + 1, j2])
		elif old_count > 0:
			diff.append("生成独有：第 %d-%d 行" % [start_a + 1, i2])
		else:
			diff.append("磁盘独有：第 %d-%d 行" % [start_b + 1, j2])
	while i2 < n:
		diff.append("生成独有：第 %d 行" % (i2 + 1))
		i2 += 1
	while j2 < m:
		diff.append("磁盘独有：第 %d 行" % (j2 + 1))
		j2 += 1
	return diff


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

## 读取命令行参数："--out res://x.tscn" 与 "--out=res://x.tscn" 两种写法都支持。
func _arg_value(args: PackedStringArray, key: String) -> String:
	for i in args.size():
		var a: String = args[i]
		if a == key:
			if i + 1 < args.size():
				return args[i + 1]
			return ""
		if a.begins_with(key + "="):
			return a.substr(key.length() + 1)
	return ""


## 读取 JSON 文件（res:// 与绝对路径都支持），失败时把原因写进 _error。
func _load_json(path: String) -> Dictionary:
	var text: String = _read_text(path)
	if _failed():
		return {}
	var json: JSON = JSON.new()
	var parse_err: int = json.parse(text)
	if parse_err != OK:
		_fail("JSON 解析失败（%s 第 %d 行）：%s"
			% [path, json.get_error_line(), json.get_error_message()])
		return {}
	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		_fail("JSON 顶层必须是对象：%s" % path)
		return {}
	return data


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		_fail("文件不存在：%s" % path)
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("无法打开文件（%s）：%s" % [path, error_string(FileAccess.get_open_error())])
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


## 绝对路径 → res:// 路径（ProjectSettings.localize_path 只对项目内路径有效）。
func _to_res_path(path: String) -> String:
	var p: String = path.replace("\\", "/")
	if p.begins_with("res://") or p.begins_with("user://"):
		return p
	if p.is_absolute_path():
		var localized: String = ProjectSettings.localize_path(p)
		return localized if localized.begins_with("res://") else p
	return p


func _basename(path: String) -> String:
	var p: String = path.replace("\\", "/")
	var slash: int = p.rfind("/")
	return p.substr(slash + 1) if slash >= 0 else p


func _note(text: String) -> void:
	_log_lines.append(text)


## 确保输出目录存在（ResourceSaver 不建目录）。返回 false 表示失败并已 _fail()。
func _ensure_dir(dir_path: String) -> bool:
	if dir_path.is_empty() or dir_path == "res://" or dir_path == "user://":
		return true
	if DirAccess.dir_exists_absolute(dir_path):
		return true
	var err: int = DirAccess.make_dir_recursive_absolute(dir_path)
	if err != OK and not DirAccess.dir_exists_absolute(dir_path):
		_fail("无法创建目录（%s）：%s" % [dir_path, error_string(err)])
		return false
	_note("已创建目录：%s" % dir_path)
	return true


## 记录一条致命错误（只保留第一条，避免噪声掩盖根因）。
func _fail(reason: String) -> void:
	if _error.is_empty():
		_error = reason


func _failed() -> bool:
	return not _error.is_empty()


func _ok(result_line: String, code: int) -> void:
	_result = result_line
	_exit_code = code


# ---------------------------------------------------------------------------
# 收尾：统一打印人类可读日志（≤ LOG_LIMIT 行）+ 唯一一行 RESULT:
# ---------------------------------------------------------------------------

func _finish() -> void:
	var shown: int = 0
	for line in _log_lines:
		if shown >= LOG_LIMIT:
			print("[gen_scene] ...（日志已截断）")
			break
		print("[gen_scene] %s" % line)
		shown += 1

	if _failed():
		_result = "RESULT: FAIL %s" % _error
		_exit_code = 1
	elif _result.is_empty():
		_result = "RESULT: FAIL 未知错误（未产生结果行）"
		_exit_code = 1

	if _exit_code != 0:
		printerr(_result)
	else:
		print(_result)
	quit(_exit_code)
