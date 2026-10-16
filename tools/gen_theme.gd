extends SceneTree
## ============================================================================
##  gen_theme.gd —— 主题生成器：assets_src/theme.json → theme/default_theme.tres
## ----------------------------------------------------------------------------
##  为什么要有这个工具？
##    .tres 主题文件是二进制式的外部资源引用重灾区：手写容易把条目名拼错，而
##    Godot 对拼错的**主题条目名是完全静默的**（Theme.set_color("Lable", ...)
##    照样存进去，运行时只是"没生效"）。所以这里不仅生成，还会拿**引擎自带的
##    默认主题**逐条核对：类存不存在、这个类到底有没有这个条目名。拼错 ⇒ 直接退出 1。
##
##  运行方式（在项目根目录执行）：
##    godot --headless --path . --script res://tools/gen_theme.gd -- [--spec <路径>] [--check]
##    godot --headless --path . --script res://tools/gen_theme.gd -- --check      # 只校验
##
##  参数：
##    --spec  <res:// 或绝对路径>  主题清单 JSON；缺省 = res://assets_src/theme.json
##    --out   <res:// 路径 .tres>  输出主题；缺省 = res://theme/default_theme.tres
##    --check                      只校验：生成到 user:// 临时文件并与现有 .tres 比较，
##                                 **不覆盖**真实文件；有差异时退出码 1
##
##  退出码：0 = 成功 / 无漂移；1 = 任何错误（缺清单、条目名非法、保存失败、漂移）
##  最后一行固定输出机器可读结果（前面的过程日志不超过约 20 行）：
##    RESULT: OK <out_path> colors=<C> font_sizes=<F> constants=<K>
##    RESULT: CLEAN <out_path> colors=<C> font_sizes=<F> constants=<K>
##    RESULT: DRIFT <out_path>            （随后最多 10 行"仅行号"的差异上下文）
##    RESULT: FAIL <reason>
##
##  ★ 清单 JSON 的约定（契约，新增字段请同步此注释与 assets_src/theme.json 的 _comment）：
##    {
##      "_comment": "...",                  // 可选，纯备注，工具忽略
##      "default_font_size": 17,            // 可选，主题兜底字号 Theme.default_font_size
##      "colors":     { "<类名>": { "<条目名>": "Color(r, g, b, a)" } },
##      "font_sizes": { "<类名>": { "<条目名>": 17 } },      // 也接受 "font_sizes": {"Label": 17}
##      "constants":  { "<类名>": { "<条目名>": 6 } },       // 值可为 int / float / bool / "true"
##    }
##    条目名必须是引擎真实存在的主题条目名（如 Label 的 font_color / font_size / line_spacing，
##    Button 的 h_separation；注意 Panel **没有** colors/constants，它只有 panel 这个 StyleBox 条目）。
##    拼错的类名或条目名会被提前拦下并退出 1。
##
##  ★ 本脚本刻意不写 class_name：工具脚本要在"刚 clone、没有全局类缓存"的环境直接跑。
## ============================================================================


## 缺省清单路径
const SPEC_DEFAULT: String = "res://assets_src/theme.json"
## 缺省输出路径
const OUT_PATH_DEFAULT: String = "res://theme/default_theme.tres"
## --check 模式的临时产物（user:// 在无头模式下也可写）
const TMP_PATH: String = "user://gen_theme_check.tres"
## 人类可读日志的行数上限（结果行不计入）
const LOG_LIMIT: int = 18
## 漂移时最多打印几行差异上下文
const DRIFT_LIMIT: int = 10
## 字号合法区间（挡住明显手滑，比如写成 1700）
const FONT_SIZE_MIN: int = 1
const FONT_SIZE_MAX: int = 512

## 结果行（整个进程只会打印这一行 "RESULT: ..."）
var _result: String = ""
var _exit_code: int = 1
## 过程日志
var _log_lines: PackedStringArray = []
## 致命错误信息；非空即失败
var _error: String = ""
## 实际写入的条目计数
var _count_colors: int = 0
var _count_font_sizes: int = 0
var _count_constants: int = 0
## 引擎自带默认主题（用于核对条目名；--script 模式下 Control.get_theme() 是空的，
## 只有 ThemeDB.get_default_theme() 能拿到真正的默认主题）
var _default_theme: Theme = null
## 匹配 .tres 里 ext_resource 的 uid="uid://..."（编辑器补的，首次生成时通常没有）
var _re_uid: RegEx = RegEx.new()


func _initialize() -> void:
	_re_uid.compile(" uid=\"uid://[^\"]*\"")
	_default_theme = ThemeDB.get_default_theme()

	var args: PackedStringArray = OS.get_cmdline_user_args()
	var spec_path: String = _arg_value(args, "--spec")
	var out_path: String = _arg_value(args, "--out")
	var check_mode: bool = args.has("--check")
	if spec_path.is_empty():
		spec_path = SPEC_DEFAULT
	if out_path.is_empty():
		out_path = OUT_PATH_DEFAULT
	out_path = _to_res_path(out_path)

	if _default_theme == null:
		# 没有默认主题就无法核对条目名。宁可失败，也不要生成一份"拼错了也不报错"的主题。
		_fail("拿不到引擎默认主题（ThemeDB.get_default_theme() 返回 null），无法核对主题条目名")
		_finish()
		return

	var spec: Dictionary = _load_json(spec_path)
	if _failed():
		_finish()
		return

	var theme: Theme = _build_theme(spec)
	if _failed():
		_finish()
		return

	_note("清单：%s" % spec_path)
	_note("条目计数：colors=%d font_sizes=%d constants=%d"
		% [_count_colors, _count_font_sizes, _count_constants])
	var counts: String = "colors=%d font_sizes=%d constants=%d" \
		% [_count_colors, _count_font_sizes, _count_constants]

	# ResourceSaver 不会替我们创建目录（"res://theme/" 不存在时直接 Can't open），
	# 所以先确保输出目录存在。
	if not _ensure_dir(out_path.get_base_dir()):
		_finish()
		return

	if check_mode:
		var tmp_err: int = _save_canonical(theme, TMP_PATH)
		if tmp_err != OK:
			_fail("临时保存失败：%s" % error_string(tmp_err))
			_finish()
			return
		var is_clean: bool = _compare_files(TMP_PATH, out_path)
		if _failed():
			_finish()
			return
		if is_clean:
			_ok("RESULT: CLEAN %s %s" % [out_path, counts], 0)
		else:
			_ok("RESULT: DRIFT %s" % out_path, 1)
		_finish()
		return

	var save_err: int = _save_canonical(theme, out_path)
	if save_err != OK:
		_fail("保存失败（%s）：%s" % [out_path, error_string(save_err)])
		_finish()
		return
	_ok("RESULT: OK %s %s" % [out_path, counts], 0)
	_finish()


# ---------------------------------------------------------------------------
# 主题构建 + 条目名校验
# ---------------------------------------------------------------------------

## 按清单构建 Theme 资源；任何非法类名 / 条目名立即失败。
func _build_theme(spec: Dictionary) -> Theme:
	var theme: Theme = Theme.new()

	if spec.has("default_font_size"):
		var raw_size: Variant = spec["default_font_size"]
		if typeof(raw_size) != TYPE_INT and typeof(raw_size) != TYPE_FLOAT:
			_fail("default_font_size 必须是数字，得到：%s" % _describe(raw_size))
			return null
		var size: int = _check_font_size("default_font_size", int(raw_size))
		if _failed():
			return null
		theme.default_font_size = size
		_note("default_font_size = %d" % size)

	var colors: Variant = spec.get("colors", {})
	if typeof(colors) == TYPE_DICTIONARY:
		for class_name_v in (colors as Dictionary).keys():
			var cls: String = str(class_name_v)
			var items: Variant = (colors as Dictionary)[class_name_v]
			if typeof(items) != TYPE_DICTIONARY:
				_fail("colors/%s 的值必须是对象" % cls)
				return null
			for item_v in (items as Dictionary).keys():
				var item: String = str(item_v)
				if not _check_item(cls, item, "color"):
					return null
				var color: Variant = _parse_color((items as Dictionary)[item_v], "colors/%s/%s" % [cls, item])
				if _failed():
					return null
				theme.set_color(item, cls, color)
				_count_colors += 1

	var font_sizes: Variant = spec.get("font_sizes", {})
	if typeof(font_sizes) == TYPE_DICTIONARY:
		for class_name_v in (font_sizes as Dictionary).keys():
			var cls: String = str(class_name_v)
			var items: Variant = (font_sizes as Dictionary)[class_name_v]
			# 允许两种写法：{"Label": {"font_size": 17}} 与 {"Label": 17}（后者等价于 font_size）
			if typeof(items) != TYPE_DICTIONARY:
				if not _check_item(cls, "font_size", "font_size"):
					return null
				var direct: int = _check_font_size("font_sizes/%s" % cls, _as_int(items))
				if _failed():
					return null
				theme.set_font_size("font_size", cls, direct)
				_count_font_sizes += 1
				continue
			for item_v in (items as Dictionary).keys():
				var item: String = str(item_v)
				if not _check_item(cls, item, "font_size"):
					return null
				var size: int = _check_font_size("font_sizes/%s/%s" % [cls, item],
					_as_int((items as Dictionary)[item_v]))
				if _failed():
					return null
				theme.set_font_size(item, cls, size)
				_count_font_sizes += 1

	var constants: Variant = spec.get("constants", {})
	if typeof(constants) == TYPE_DICTIONARY:
		for class_name_v in (constants as Dictionary).keys():
			var cls: String = str(class_name_v)
			var items: Variant = (constants as Dictionary)[class_name_v]
			if typeof(items) != TYPE_DICTIONARY:
				_fail("constants/%s 的值必须是对象" % cls)
				return null
			for item_v in (items as Dictionary).keys():
				var item: String = str(item_v)
				if not _check_item(cls, item, "constant"):
					return null
				theme.set_constant(item, cls, _as_int((items as Dictionary)[item_v]))
				_count_constants += 1

	return theme


## 核对"类名 + 条目名"是否真实存在。
## 判据是引擎自带的默认主题：Theme.get_color_list(cls) / get_constant_list(cls) /
## get_font_size_list(cls)。这三张表就是该控件类**实际会去查**的条目名集合，
## 因此"不在表里"就等于"写了也不会生效"。
func _check_item(cls: String, item: String, kind: String) -> bool:
	if not ClassDB.class_exists(cls):
		_fail("未知类名：%s（不是 ClassDB 里存在的真实类）—— 条目 %s" % [cls, item])
		return false
	if not ClassDB.is_parent_class(cls, "Control"):
		_fail("类 %s 不是 Control 的子类，主题条目对它没有意义 —— 条目 %s" % [cls, item])
		return false

	var known: PackedStringArray = PackedStringArray()
	match kind:
		"color":
			known = _default_theme.get_color_list(cls)
		"font_size":
			known = _default_theme.get_font_size_list(cls)
		"constant":
			known = _default_theme.get_constant_list(cls)
		_:
			_fail("内部错误：未知条目类别 %s" % kind)
			return false

	if known.is_empty():
		_fail("%s 类没有任何 %s 条目，不能设置 %s（可用条目：无）"
			% [cls, _kind_label(kind), item])
		return false
	if not known.has(item):
		_fail("%s 类没有 %s 条目「%s」—— %s。可用：%s"
			% [cls, _kind_label(kind), item,
				"拼写错误？" if _looks_like_typo(item, known) else "该类的默认主题里不存在此条目",
				", ".join(known)])
		return false
	return true


## 给"拼错"与"本来就没有"两种失败原因一点区分，便于快速定位。
func _looks_like_typo(item: String, known: PackedStringArray) -> bool:
	var lowered: String = item.to_lower()
	for k in known:
		var kk: String = str(k).to_lower()
		if kk == lowered or kk.replace("_", "") == lowered.replace("_", ""):
			return true
	# 前缀/后缀高度重合也算疑似拼错（如 font_colour vs font_color）
	for k in known:
		var kk: String = str(k).to_lower()
		if kk.length() >= 4 and lowered.length() >= 4:
			if kk.begins_with(lowered.substr(0, 4)) or lowered.begins_with(kk.substr(0, 4)):
				return true
	return false


func _kind_label(kind: String) -> String:
	match kind:
		"color":
			return "颜色"
		"font_size":
			return "字号"
		"constant":
			return "常量"
	return kind


## 解析颜色值：接受 "Color(r, g, b, a)" 字符串，也接受 str_to_var 的其它字面量。
func _parse_color(raw: Variant, where: String) -> Color:
	if typeof(raw) == TYPE_STRING:
		var parsed: Variant = str_to_var(raw)
		if typeof(parsed) == TYPE_COLOR:
			return parsed
		_fail("%s 不是合法颜色：%s（期望形如 \"Color(0.92, 0.94, 1, 1)\"）" % [where, raw])
		return Color.BLACK
	if typeof(raw) == TYPE_COLOR:
		return raw
	_fail("%s 不是合法颜色：%s" % [where, _describe(raw)])
	return Color.BLACK


## 常量取整：JSON 里写 6 / 6.0 / true 都接受。
func _as_int(raw: Variant) -> int:
	match typeof(raw):
		TYPE_INT:
			return raw
		TYPE_FLOAT:
			return int(round(raw))
		TYPE_BOOL:
			return 1 if raw else 0
		TYPE_STRING:
			var parsed: Variant = str_to_var(raw)
			if typeof(parsed) == TYPE_INT or typeof(parsed) == TYPE_FLOAT or typeof(parsed) == TYPE_BOOL:
				return _as_int(parsed)
	return 0


func _check_font_size(where: String, size: int) -> int:
	if size < FONT_SIZE_MIN or size > FONT_SIZE_MAX:
		_fail("%s 的字号越界：%d（允许 %d..%d）" % [where, size, FONT_SIZE_MIN, FONT_SIZE_MAX])
		return 0
	return size


func _describe(raw: Variant) -> String:
	return "%s（类型 %d）" % [str(raw), typeof(raw)]


# ---------------------------------------------------------------------------
# 落盘：保存 → 归一化文本 → 写回
# ---------------------------------------------------------------------------

## 保存主题，并把引擎写出的文本归一化成"规范形"。
## ★ 为什么要写回一次文本？
##   .tres 里的 uid="uid://..." 是编辑器补的，首次生成时通常没有；留着会让
##   git 出现假 diff、让 --check 永远报漂移。删掉之后"同一份清单 ⇒ 同一份字节"，
##   --check 才能做到**逐字节**的漂移检测。主题内容本身全部由 ResourceSaver 产出。
func _save_canonical(theme: Theme, path: String) -> int:
	var err: int = ResourceSaver.save(theme, path)
	if err != OK:
		return err
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		return FAILED
	text = text.replace("\r\n", "\n")
	text = _re_uid.sub(text, "", true)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FAILED
	file.store_string(text)
	file.close()
	return OK


## 逐行比较两个文件（两边都先归一化：去行尾空白、折叠/去掉末尾空行）。
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
	var shown: int = 0
	for line in _diff_lines(gen_lines, disk_lines):
		if shown >= DRIFT_LIMIT:
			_note("  ...（其余差异已省略）")
			break
		_note("  %s" % line)
		shown += 1
	return false


## 归一化：统一换行、去掉行尾空白、折叠连续空行、去掉末尾空行。
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


## 读取命令行参数："--out res://x.tres" 与 "--out=res://x.tres" 两种写法都支持。
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


func _note(text: String) -> void:
	_log_lines.append(text)


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
			print("[gen_theme] ...（日志已截断）")
			break
		print("[gen_theme] %s" % line)
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
