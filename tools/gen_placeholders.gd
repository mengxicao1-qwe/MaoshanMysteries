extends SceneTree
## ============================================================================
##  gen_placeholders.gd —— 占位图生成器：assets_src/placeholder_manifest.json → PNG
## ----------------------------------------------------------------------------
##  为什么要有这个工具？
##    美术资源还没到位时，场景里需要一批"尺寸正确、方向可辨"的临时贴图，否则布局
##    和碰撞体都没法验证。手工切这些图既费时又容易尺寸对不上，所以统一由清单生成。
##    每张图都是：纯色填充 + 1px 深色描边 + 一个**非对称**标记。
##    标记为什么非对称？因为这样一眼就能看出贴图有没有被翻转/旋转 —— 左上角是深色
##    3x3 方块，右下角是亮色 2x2 方块，左右上下都不对称，任何翻转都会立刻露馅。
##
##  运行方式（在项目根目录执行）：
##    godot --headless --path . --script res://tools/gen_placeholders.gd -- [--spec <路径>] [--check]
##
##  参数：
##    --spec  <res:// 或绝对路径>  占位图清单 JSON；缺省 = res://assets_src/placeholder_manifest.json
##    --out-dir <res:// 目录>      输出目录；缺省 = res://assets/placeholder/
##    --check                      只校验：重新生成到 user:// 临时目录并与磁盘上的 PNG
##                                 逐字节比较，**不覆盖**真实文件；有差异时退出码 1
##
##  退出码：0 = 成功 / 无漂移；1 = 任何错误（缺清单、字段非法、保存失败、漂移）
##  最后一行固定输出机器可读结果（前面的过程日志不超过约 20 行）：
##    RESULT: OK <out_dir> images=<N> bytes=<B>
##    RESULT: CLEAN <out_dir> images=<N> bytes=<B>
##    RESULT: DRIFT <out_dir> images=<N> drifted=<D>
##    RESULT: FAIL <reason>
##
##  ★ 清单 JSON 的约定（契约，新增字段请同步此注释与清单里的 _comment）：
##    {
##      "_comment": "...",                  // 可选，纯备注，工具忽略
##      "placeholders": [
##        {
##          "name":  "npc_butler_idle",     // 必填，输出文件名（小写字母/数字/下划线）
##          "size":  [32, 48],              // 必填，[宽, 高]，必须是正整数
##          "color": "Color(0.62, ...)",    // 必填，主色；接受 "Color(r,g,b,a)" 字面量串
##          "kind":  "npc"                  // 可选，仅作备注（npc/prop/ui/fx），不影响像素
##        }
##      ]
##    }
##
##  ★ 本脚本刻意不写 class_name：工具脚本要在"刚 clone、没有全局类缓存"的环境直接跑。
## ============================================================================


## 缺省清单路径
const SPEC_DEFAULT: String = "res://assets_src/placeholder_manifest.json"
## 缺省输出目录
const OUT_DIR_DEFAULT: String = "res://assets/placeholder/"
## --check 模式的临时目录（user:// 在无头模式下也可写）
const TMP_DIR: String = "user://gen_placeholders_check/"
## 顺带生成的说明文件（与图片同目录）
const README_NAME: String = "README.md"
## 人类可读日志的行数上限（结果行不计入）
const LOG_LIMIT: int = 18
## 漂移时最多列出几个文件名
const DRIFT_LIMIT: int = 10
## 尺寸上限（挡住手滑写出 99999 的图，避免无头环境下爆内存）
const SIZE_MAX: int = 2048
## 描边/标记的取色系数。
## 这几个数不是随便定的：占位图经常被缩略图/预览按 1/2 甚至 1/4 分辨率显示，
## 标记与底色的对比度不够就会糊成一片、失去"辨方向"的意义。所以深色侧压到 0.30
## 以下、亮色侧拉到 1.0 以上（在 0..1 处 clamp），保证缩略图上也一眼能看出不对称。
const BORDER_FACTOR: float = 0.55   # 描边 = 主色压暗
const MARKER_DARK_FACTOR: float = 0.18
const MARKER_LIGHT_FACTOR: float = 1.35

## 结果行（整个进程只会打印这一行 "RESULT: ..."）
var _result: String = ""
var _exit_code: int = 1
## 过程日志
var _log_lines: PackedStringArray = []
## 致命错误信息；非空即失败
var _error: String = ""
## 统计
var _count_images: int = 0
var _count_bytes: int = 0
var _drifted: PackedStringArray = PackedStringArray()
## 已见过的名字（查重）
var _seen_names: Dictionary = {}
## 合法文件名：小写字母开头，只含小写字母/数字/下划线
var _re_name: RegEx = RegEx.new()


func _initialize() -> void:
	_re_name.compile("^[a-z][a-z0-9_]*$")

	var args: PackedStringArray = OS.get_cmdline_user_args()
	var spec_path: String = _arg_value(args, "--spec")
	var out_dir: String = _arg_value(args, "--out-dir")
	var check_mode: bool = args.has("--check")
	if spec_path.is_empty():
		spec_path = SPEC_DEFAULT
	if out_dir.is_empty():
		out_dir = OUT_DIR_DEFAULT
	out_dir = _to_res_path(out_dir)
	if not out_dir.ends_with("/"):
		out_dir += "/"

	var spec: Dictionary = _load_json(spec_path)
	if _failed():
		_finish()
		return

	var entries: Variant = spec.get("placeholders", [])
	if typeof(entries) != TYPE_ARRAY:
		_fail("清单里的 placeholders 必须是数组：%s" % spec_path)
		_finish()
		return
	var list: Array = entries
	if list.is_empty():
		_fail("清单里没有任何占位图条目：%s" % spec_path)
		_finish()
		return
	_note("清单：%s（%d 个条目）" % [spec_path, list.size()])

	# --check 时不碰真实目录，全部生成到 user:// 临时目录再比字节。
	var target_dir: String = TMP_DIR if check_mode else out_dir
	if not _fresh_dir(target_dir):
		_finish()
		return

	if not _generate_all(list, target_dir):
		_finish()
		return

	if not _write_readme(target_dir):
		_finish()
		return

	var summary: String = "images=%d bytes=%d" % [_count_images, _count_bytes]

	if not check_mode:
		_ok("RESULT: OK %s %s" % [out_dir, summary], 0)
		_finish()
		return

	# 校验：逐个 PNG 与磁盘上的同名文件逐字节比较。
	for name in _seen_names.keys():
		var file_name: String = "%s.png" % name
		if not FileAccess.file_exists(out_dir + file_name):
			_drifted.append("%s（磁盘上不存在）" % file_name)
			continue
		if not _same_bytes(target_dir + file_name, out_dir + file_name):
			_drifted.append(file_name)
	if not _readme_matches(target_dir, out_dir):
		_drifted.append(README_NAME)

	if _drifted.is_empty():
		_ok("RESULT: CLEAN %s %s" % [out_dir, summary], 0)
	else:
		_note("以下文件与磁盘内容不一致：")
		var shown: int = 0
		for d in _drifted:
			if shown >= DRIFT_LIMIT:
				_note("  ...（其余 %d 项已省略）" % (_drifted.size() - shown))
				break
			_note("  %s" % d)
			shown += 1
		_ok("RESULT: DRIFT %s images=%d drifted=%d" % [out_dir, _count_images, _drifted.size()], 1)
	_finish()


# ---------------------------------------------------------------------------
# 图片生成
# ---------------------------------------------------------------------------

func _generate_all(list: Array, target_dir: String) -> bool:
	for entry_v in list:
		if typeof(entry_v) != TYPE_DICTIONARY:
			_fail("placeholders 里出现了非对象元素（第 %d 项）" % (_count_images + 1))
			return false
		var entry: Dictionary = entry_v
		var name: String = str(entry.get("name", ""))
		if name.is_empty():
			_fail("第 %d 个条目缺少 name 字段" % (_count_images + 1))
			return false
		if _re_name.search(name) == null:
			_fail("条目名非法：%s（只允许小写字母开头、小写字母/数字/下划线）" % name)
			return false
		if _seen_names.has(name):
			_fail("条目名重复：%s" % name)
			return false
		_seen_names[name] = true

		var size: Vector2i = _parse_size(entry.get("size", null), name)
		if _failed():
			return false
		var color: Color = _parse_color(entry.get("color", null), name)
		if _failed():
			return false

		var image: Image = _make_image(size, color)
		var path: String = target_dir + name + ".png"
		var err: int = image.save_png(path)
		if err != OK:
			_fail("保存 PNG 失败（%s）：%s" % [path, error_string(err)])
			return false

		var bytes: int = _file_size(path)
		_count_images += 1
		_count_bytes += bytes
		var kind: String = str(entry.get("kind", ""))
		_note("  %s.png  %dx%d  %s  color=%s" % [
			name, size.x, size.y, ("[%s]" % kind) if not kind.is_empty() else "", color])
	return true


## 画一张占位图：纯色底 + 1px 深色描边 + 非对称方向标记。
func _make_image(size: Vector2i, color: Color) -> Image:
	var image: Image = Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)

	var border: Color = _scale_rgb(color, BORDER_FACTOR)
	var dark: Color = _scale_rgb(color, MARKER_DARK_FACTOR)
	var light: Color = _scale_rgb(color, MARKER_LIGHT_FACTOR)

	# 1px 描边
	for x in size.x:
		image.set_pixel(x, 0, border)
		image.set_pixel(x, size.y - 1, border)
	for y in size.y:
		image.set_pixel(0, y, border)
		image.set_pixel(size.x - 1, y, border)

	# 方向标记 1：左上角 3x3 深色块
	var tl_w: int = mini(3, size.x)
	var tl_h: int = mini(3, size.y)
	for y in tl_h:
		for x in tl_w:
			image.set_pixel(x, y, dark)

	# 方向标记 2：右下角 2x2 亮色块（与左上不同色、不同大小，任何翻转都能看出来）
	var br_w: int = mini(2, size.x)
	var br_h: int = mini(2, size.y)
	for y in br_h:
		for x in br_w:
			image.set_pixel(size.x - 1 - x, size.y - 1 - y, light)

	return image


## 按系数缩放 RGB，保留原 alpha（描边/标记都不改变透明度）。
func _scale_rgb(color: Color, factor: float) -> Color:
	return Color(
		clampf(color.r * factor, 0.0, 1.0),
		clampf(color.g * factor, 0.0, 1.0),
		clampf(color.b * factor, 0.0, 1.0),
		color.a)


## 解析 "size": [w, h]。
func _parse_size(raw: Variant, name: String) -> Vector2i:
	if typeof(raw) != TYPE_ARRAY:
		_fail("条目 %s 的 size 必须是 [宽, 高] 数组" % name)
		return Vector2i.ZERO
	var arr: Array = raw
	if arr.size() != 2:
		_fail("条目 %s 的 size 必须是两个数字，得到 %d 个" % [name, arr.size()])
		return Vector2i.ZERO
	var w: int = _as_int(arr[0])
	var h: int = _as_int(arr[1])
	if w <= 0 or h <= 0 or w > SIZE_MAX or h > SIZE_MAX:
		_fail("条目 %s 的尺寸非法：%dx%d（允许 1..%d）" % [name, w, h, SIZE_MAX])
		return Vector2i.ZERO
	return Vector2i(w, h)


## 解析颜色值：接受 "Color(r, g, b, a)" 字符串。
func _parse_color(raw: Variant, name: String) -> Color:
	if typeof(raw) == TYPE_STRING:
		var parsed: Variant = str_to_var(raw)
		if typeof(parsed) == TYPE_COLOR:
			return parsed
		_fail("条目 %s 的 color 不是合法颜色：%s（期望形如 \"Color(0.62, 0.56, 0.78, 1)\"）"
			% [name, raw])
		return Color.WHITE
	if typeof(raw) == TYPE_COLOR:
		return raw
	_fail("条目 %s 缺少合法 color：%s" % [name, str(raw)])
	return Color.WHITE


func _as_int(raw: Variant) -> int:
	match typeof(raw):
		TYPE_INT:
			return raw
		TYPE_FLOAT:
			return int(round(raw))
		TYPE_STRING:
			var parsed: Variant = str_to_var(raw)
			if typeof(parsed) == TYPE_INT or typeof(parsed) == TYPE_FLOAT:
				return _as_int(parsed)
	return -1


# ---------------------------------------------------------------------------
# README 与文件比较
# ---------------------------------------------------------------------------

## 生成同目录的 README.md（也参与 --check 比较，避免文档与图片脱节）。
func _write_readme(target_dir: String) -> bool:
	var file: FileAccess = FileAccess.open(target_dir + README_NAME, FileAccess.WRITE)
	if file == null:
		_fail("无法写入 %s：%s" % [target_dir + README_NAME, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(_readme_text())
	file.close()
	return true


func _readme_text() -> String:
	return """# 占位素材（自动生成，请勿手工编辑）

本目录下的 PNG 全部由 `tools/gen_placeholders.gd` 依据 `assets_src/placeholder_manifest.json` 生成：
纯色填充 + 1px 深色描边，左上角 3x3 深色块与右下角 2x2 亮色块用于辨认方向（任一翻转或旋转都会立刻看出来）。
需要改动尺寸或配色时请编辑清单 JSON，然后重新执行
`godot --headless --path . --script res://tools/gen_placeholders.gd --`；
只想确认磁盘内容与清单是否一致，加 `--check`（不一致时退出码 1）。
**不要手工编辑这里的 PNG**：下一次生成会直接覆盖，改动会丢失。
"""


## 逐字节比较两个文件。任何一侧读不出来都算不一致。
func _same_bytes(a_path: String, b_path: String) -> bool:
	var a: PackedByteArray = FileAccess.get_file_as_bytes(a_path)
	var b: PackedByteArray = FileAccess.get_file_as_bytes(b_path)
	if a.is_empty() and b.is_empty():
		return FileAccess.file_exists(a_path) and FileAccess.file_exists(b_path)
	return a == b


func _readme_matches(tmp_dir: String, out_dir: String) -> bool:
	if not FileAccess.file_exists(out_dir + README_NAME):
		return false
	return FileAccess.get_file_as_string(tmp_dir + README_NAME) \
		== FileAccess.get_file_as_string(out_dir + README_NAME)


func _file_size(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var n: int = file.get_length()
	file.close()
	return n


# ---------------------------------------------------------------------------
# 通用小工具
# ---------------------------------------------------------------------------

## 准备输出目录：普通模式只确保存在（不删除既有文件，避免误删美术补进来的图）；
## --check 模式用临时目录，先整个删掉保证干净。
func _fresh_dir(dir_path: String) -> bool:
	if dir_path == TMP_DIR and DirAccess.dir_exists_absolute(dir_path):
		if not _remove_dir_recursive(dir_path):
			_fail("无法清理临时目录（%s）" % dir_path)
			return false
	if not DirAccess.dir_exists_absolute(dir_path):
		var mk: int = DirAccess.make_dir_recursive_absolute(dir_path)
		if mk != OK and not DirAccess.dir_exists_absolute(dir_path):
			_fail("无法创建目录（%s）：%s" % [dir_path, error_string(mk)])
			return false
		_note("已创建目录：%s" % dir_path)
	return true


## 递归删除目录及其内容。
## 注意：DirAccess.remove_absolute() 删不掉"非空目录"（会返回 Failed），
## 所以必须先把里面的文件和子目录清空，再删目录本身。
## 这个坑只在"临时目录已经存在"时才会踩到，也就是第二次及以后的 --check。
func _remove_dir_recursive(dir_path: String) -> bool:
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		# 打不开就当作已经不存在
		return not DirAccess.dir_exists_absolute(dir_path)
	for file_name in d.get_files():
		var e: int = d.remove(file_name)
		if e != OK:
			_note("删除文件失败：%s%s（%s）" % [dir_path, file_name, error_string(e)])
			return false
	for sub in d.get_directories():
		if not _remove_dir_recursive(dir_path.path_join(sub)):
			return false
	# 目录已空，此时才能删掉它
	var err: int = DirAccess.remove_absolute(dir_path)
	if err != OK and DirAccess.dir_exists_absolute(dir_path):
		_note("删除目录失败：%s（%s）" % [dir_path, error_string(err)])
		return false
	return true


## 读取命令行参数："--out-dir res://x/" 与 "--out-dir=res://x/" 两种写法都支持。
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
			print("[gen_placeholders] ...（日志已截断）")
			break
		print("[gen_placeholders] %s" % line)
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
