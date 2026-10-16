extends SceneTree
## ============================================================================
##  test_title_scene.gd —— 标题界面（scenes/title_scene.tscn）无头测试
## ----------------------------------------------------------------------------
##  运行方式（在项目根目录执行）：
##    godot --headless --path . --script res://tests/test_title_scene.gd
##
##  覆盖：
##    [1] 场景装配与文案（4 个节点、文案逐字、按钮文案含全角方头括号）
##    [2] 字体覆盖 —— 标题页每个汉字/全角标点都在 CJK 子集里（防豆腐块 ▯）
##    [3] 版面自适应 —— 三档窗口下：按钮水平居中、四个元素零重叠、全部在画布内、
##        标题在最上/按钮在最下、整块纵向比例一致、字号随窗口高度缩放
##        （AGENTS.md §4：写死 1280×720 的版面在别的窗口尺寸下会全错位）
##    [4] 源码卫生 —— title_scene.gd 里不出现写死的分辨率，也不引用任何 Autoload
##    [5] 交互 —— 回车 / 小键盘回车 / 空格 / 点按钮都能开始；重复触发只算一次；
##        松键、按键回显（echo）、无关键都不触发
##    [6] 悬停 / 按下反馈 —— 三个 StyleBox 真的不一样，焦点在按钮上
##    [7] 真跳场景 —— 回车真的切到 res://scenes/main.tscn（SceneTree 真加载）
##
##  本测试也是"无头跑得起来"的兜底证据：它真实例化 scenes/title_scene.tscn、
##  真等帧、真读节点尺寸，而不是只做语法检查。
##
##  ★ 存档卫生：本测试会短暂加载 main.tscn（它的 SliceHUD 一动余页就扣心灯），
##    所以先做 user:// 存档字节快照，结束时逐字节还原（与 test_slice_hud.gd 同口径）。
## ============================================================================

const SCENE_PATH: String = "res://scenes/title_scene.tscn"
const SCRIPT_PATH: String = "res://scripts/ui/title_scene.gd"
const MAIN_SCENE_PATH: String = "res://scenes/main.tscn"

## 本文件里 _check() 的调用点总数（新增断言时请同步更新）。
## GDScript 的运行时错误不会让退出码变红，只能靠执行数量兜底。
const EXPECTED_CHECKS: int = 57

const STORE_PATHS: Array[String] = [
	"user://clue_store.json",
	"user://clue_store.json.tmp",
	"user://clue_store.json.bak",
	"user://clue_store.json.corrupt",
]

## 三档窗口尺寸。这里的数字只是"测试输入"——被测脚本自己一个分辨率常量都没有。
const LAYOUT_SIZES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(960, 540),
]

var _checks: int = 0
var _failures: Array[String] = []
var _saved_existed: Array[bool] = []
var _saved_bytes: Array[PackedByteArray] = []

## 当前挂在 root 下的标题页实例
var _node: Control = null
## start_requested 信号被广播了几次（lambda 按值捕获，所以状态放成员变量）
var _start_events: int = 0
## 每档尺寸下按钮中心的 y / 窗口高度（用来证明整块是按比例摆的）
var _center_ratios: Array[float] = []
var _title_font_sizes: Array[int] = []


func _initialize() -> void:
	print("==========================================================")
	print(" 标题界面测试：scenes/title_scene.tscn（Headless）")
	print("==========================================================")
	_backup_user_files()
	_run()


func _run() -> void:
	await _test_wiring()
	await _test_font_coverage()
	await _test_layout_adaptive()
	_test_source_hygiene()
	await _test_interaction()
	await _test_button_feedback()
	await _test_real_scene_switch()
	await _finish()


# ---------------------------------------------------------------------------
# 1. 装配与文案
# ---------------------------------------------------------------------------

func _test_wiring() -> void:
	print("[1] 场景装配与文案")
	await _spawn(Vector2i(1280, 720))

	_check(_node != null, "scenes/title_scene.tscn 可实例化并挂进场景树")
	if _node == null:
		return

	var script: Script = _node.get_script()
	_check(script != null and script.resource_path == SCRIPT_PATH,
		"根节点挂的是 scripts/ui/title_scene.gd（实际 %s）"
			% ("(无)" if script == null else script.resource_path))

	var label_ok: bool = true
	for node_name in ["TitleLabel", "SubtitleLabel", "HintLabel"]:
		var label := _node.get_node_or_null(node_name)
		if label == null or not (label is Label):
			label_ok = false
	var button := _node.get_node_or_null("StartButton")
	_check(label_ok and button is Button,
		"TitleLabel / SubtitleLabel / HintLabel（Label）+ StartButton（Button）都在")

	var title := _node.get_node_or_null("TitleLabel") as Label
	var subtitle := _node.get_node_or_null("SubtitleLabel") as Label
	var hint := _node.get_node_or_null("HintLabel") as Label
	var start := _node.get_node_or_null("StartButton") as Button

	_check(title != null and title.text.contains("茅山秘录") and title.text.contains("诡异录"),
		"游戏名文案：%s" % ("(缺)" if title == null else title.text))
	_check(subtitle != null and subtitle.text.contains("第一案") and subtitle.text.contains("白鹄不举"),
		"副标题文案：%s" % ("(缺)" if subtitle == null else subtitle.text))
	_check(hint != null and hint.text.length() >= 8,
		"小字提示文案：%s" % ("(缺)" if hint == null else hint.text))
	_check(start != null and start.text == "【开始推演】",
		"按钮文案逐字等于【开始推演】（含全角方头括号）：%s" % ("(缺)" if start == null else start.text))

	var info: Dictionary = _node.call("debug_info")
	_check(bool(info.get("laid_out", false)), "首帧之后版面已算过（debug_info.laid_out = true）")


# ---------------------------------------------------------------------------
# 2. 字体覆盖：标题页用到的字必须都在 CJK 子集里
# ---------------------------------------------------------------------------

func _test_font_coverage() -> void:
	print("[2] 字体覆盖（防豆腐块）")
	if _node == null:
		return
	var title := _node.get_node_or_null("TitleLabel") as Label
	var font: Font = null
	if title != null:
		font = title.get_theme_font("font")
	_check(font != null and font.has_char("茅".unicode_at(0)),
		"标题用的字体来自项目主题且含「茅」字（%s）"
			% ("(无字体)" if font == null else font.resource_path))

	var missing: String = ""
	var all_text: String = ""
	for node_name in ["TitleLabel", "SubtitleLabel", "HintLabel", "StartButton"]:
		var control := _node.get_node_or_null(node_name) as Control
		var text: String = ""
		if control is Label:
			text = (control as Label).text
		elif control is Button:
			text = (control as Button).text
		all_text += text
		var node_font: Font = null if control == null else control.get_theme_font("font")
		for index in text.length():
			var code: int = text.unicode_at(index)
			if code > 127 and (node_font == null or not node_font.has_char(code)):
				missing += char(code)
	_check(missing.is_empty(), "标题页全部汉字/全角标点都在字体子集里（缺字：%s）"
		% ("(无)" if missing.is_empty() else missing))
	_check(all_text.length() > 30, "四段文案合计 %d 个字符（非空）" % all_text.length())


# ---------------------------------------------------------------------------
# 3. 版面自适应：三档窗口
# ---------------------------------------------------------------------------

func _test_layout_adaptive() -> void:
	print("[3] 版面自适应（%d 档窗口）" % LAYOUT_SIZES.size())
	for size_px in LAYOUT_SIZES:
		await _spawn(size_px)
		if _node == null:
			return
		var info: Dictionary = _node.call("debug_info")
		var got: Vector2 = info["size"]
		var rects: Array = info["rects"]
		var w: float = float(size_px.x)
		var h: float = float(size_px.y)
		var tag: String = "%dx%d" % [size_px.x, size_px.y]

		_check(got.is_equal_approx(Vector2(w, h)),
			"%s：根 Control 的 size 跟着窗口走（实际 %s）" % [tag, str(got)])
		_check(int(info["overlaps"]) == 0,
			"%s：标题/副标题/提示/按钮 四块零重叠（overlaps=%d）" % [tag, int(info["overlaps"])])

		var center: Vector2 = info["button_center"]
		_check(absf(center.x - w * 0.5) <= 1.0,
			"%s：按钮水平居中（按钮中心 x=%.1f，期望 %.1f）" % [tag, center.x, w * 0.5])

		var inside: bool = true
		var centers_ok: bool = true
		for rect_v in rects:
			var rect: Rect2 = rect_v
			if rect.position.x < -1.0 or rect.position.y < -1.0 \
					or rect.end.x > w + 1.0 or rect.end.y > h + 1.0:
				inside = false
			if absf(rect.position.x + rect.size.x * 0.5 - w * 0.5) > 1.0:
				centers_ok = false
		_check(inside, "%s：四个元素全部落在画布内" % tag)
		_check(centers_ok, "%s：四块文字都以窗口中线居中" % tag)

		# 顺序：标题 → 副标题 → 提示 → 按钮（严格自上而下，且不留叠压）
		var order_ok: bool = rects.size() == 4
		var buttons_below: bool = false
		if rects.size() == 4:
			var title_rect: Rect2 = rects[0]
			var subtitle_rect: Rect2 = rects[1]
			var hint_rect: Rect2 = rects[2]
			var button_rect: Rect2 = rects[3]
			order_ok = title_rect.end.y <= subtitle_rect.position.y + 0.01 \
				and subtitle_rect.end.y <= hint_rect.position.y + 0.01 \
				and hint_rect.end.y <= button_rect.position.y + 0.01
			buttons_below = button_rect.position.y > hint_rect.position.y
		_check(order_ok, "%s：自上而下 标题→副标题→提示→按钮，互不叠压" % tag)
		_check(buttons_below, "%s：按钮在提示文字下方（不是跑到标题上面）" % tag)

		_center_ratios.append(center.y / h)
		_title_font_sizes.append(int(info["title_font_size"]))

	var ratio_spread: float = 0.0
	for ratio in _center_ratios:
		ratio_spread = maxf(ratio_spread, absf(ratio - _center_ratios[0]))
	_check(_center_ratios.size() == LAYOUT_SIZES.size() and ratio_spread <= 0.03,
		"三档窗口下按钮纵向位置比例一致（最大偏差 %.4f ≤ 0.03 ⇒ 不是写死坐标；实测 %s）"
			% [ratio_spread, str(_center_ratios)])
	_check(_title_font_sizes.size() == LAYOUT_SIZES.size() \
			and _title_font_sizes[1] > _title_font_sizes[2],
		"字号随窗口高度缩放（900 高=%d > 540 高=%d）"
			% [_title_font_sizes[1], _title_font_sizes[2]])


# ---------------------------------------------------------------------------
# 4. 源码卫生
# ---------------------------------------------------------------------------

func _test_source_hygiene() -> void:
	print("[4] 源码卫生")
	var source: String = FileAccess.get_file_as_string(SCRIPT_PATH)
	_check(source.length() > 0 and source.contains("NEXT_SCENE"),
		"读到 %s（%d 字节）" % [SCRIPT_PATH, source.length()])

	var hardcoded: Array[String] = []
	for token in ["1280", "720"]:
		if source.contains(token):
			hardcoded.append(token)
	_check(hardcoded.is_empty(),
		"脚本里没有写死的分辨率常量（命中：%s）"
			% ("(无)" if hardcoded.is_empty() else ", ".join(PackedStringArray(hardcoded))))

	var autoloads: Array[String] = []
	for token in ["TimeLoopManager", "PersistentMemoryManager"]:
		if source.contains(token):
			autoloads.append(token)
	_check(autoloads.is_empty(),
		"脚本不引用任何 Autoload（命中：%s）"
			% ("(无)" if autoloads.is_empty() else ", ".join(PackedStringArray(autoloads))))


# ---------------------------------------------------------------------------
# 5. 交互：鼠标点 / 回车 / 小键盘回车 / 空格
# ---------------------------------------------------------------------------

func _test_interaction() -> void:
	print("[5] 交互")
	await _check_start_by_key(KEY_ENTER, "回车")
	await _check_start_by_key(KEY_KP_ENTER, "小键盘回车")
	await _check_start_by_key(KEY_SPACE, "空格")
	await _check_start_by_click()
	await _check_double_press_once()
	await _check_ignored(KEY_A, "无关键 A")
	await _check_echo_ignored()
	await _check_release_ignored()


func _check_start_by_key(keycode: int, label: String) -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	var info: Dictionary = _node.call("debug_info")
	_check(String(info["requested_scene"]) == MAIN_SCENE_PATH,
		"%s → 请求切换到 %s（实际 \"%s\"）"
			% [label, MAIN_SCENE_PATH, String(info["requested_scene"])])
	_check(_start_events == 1, "%s → start_requested 恰好广播 1 次（实际 %d）" % [label, _start_events])


func _check_start_by_click() -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var button := _node.get_node_or_null("StartButton") as Button
	if button != null:
		button.emit_signal("pressed")
	await process_frame
	var info: Dictionary = _node.call("debug_info")
	_check(String(info["requested_scene"]) == MAIN_SCENE_PATH,
		"鼠标点按钮 → 请求切换到 %s" % MAIN_SCENE_PATH)
	_check(_start_events == 1, "鼠标点按钮 → start_requested 恰好 1 次（实际 %d）" % _start_events)


func _check_double_press_once() -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	for i in 2:
		var event := InputEventKey.new()
		event.keycode = KEY_ENTER
		event.physical_keycode = KEY_ENTER
		event.pressed = true
		Input.parse_input_event(event)
		await process_frame
	await process_frame
	_check(_start_events == 1,
		"连按两次回车只会开始一次（防重入，实际 %d 次）" % _start_events)
	_check(bool(_node.call("debug_info")["leaving"]), "开始之后进入 leaving 状态（不再重复响应）")


func _check_ignored(keycode: int, label: String) -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	var info: Dictionary = _node.call("debug_info")
	_check(String(info["requested_scene"]) == "", "%s 不会开始" % label)
	_check(_start_events == 0, "%s 不广播 start_requested" % label)


func _check_echo_ignored() -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.physical_keycode = KEY_ENTER
	event.pressed = true
	event.echo = true
	_node.call("_input", event)
	await process_frame
	_check(_start_events == 0, "按住不放产生的回显事件（echo）不会重复开始")


func _check_release_ignored() -> void:
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.physical_keycode = KEY_ENTER
	event.pressed = false
	_node.call("_input", event)
	await process_frame
	_check(_start_events == 0, "松键（pressed=false）不会开始")


# ---------------------------------------------------------------------------
# 6. 悬停 / 按下 / 焦点反馈
# ---------------------------------------------------------------------------

func _test_button_feedback() -> void:
	print("[6] 悬停 / 按下反馈")
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	var button := _node.get_node_or_null("StartButton") as Button
	if button == null:
		return
	var normal := button.get_theme_stylebox("normal")
	var hover := button.get_theme_stylebox("hover")
	var pressed := button.get_theme_stylebox("pressed")
	_check(normal != null and hover != null and hover.bg_color != normal.bg_color,
		"hover 底色与 normal 不同（%s → %s）" % [str(normal.bg_color), str(hover.bg_color)])
	_check(hover.border_color != normal.border_color,
		"hover 描边比 normal 亮（%s → %s）" % [str(normal.border_color), str(hover.border_color)])
	_check(pressed != null and pressed.bg_color != hover.bg_color \
			and pressed.border_color != hover.border_color,
		"pressed 又是另一种观感（底色 %s / 描边 %s）"
			% [str(pressed.bg_color), str(pressed.border_color)])
	_check(button.focus_mode == Control.FOCUS_ALL and button.has_focus(),
		"按钮默认拿到键盘焦点（focus_mode=%d, has_focus=%s）"
			% [button.focus_mode, button.has_focus()])


# ---------------------------------------------------------------------------
# 7. 真跳场景
# ---------------------------------------------------------------------------

func _test_real_scene_switch() -> void:
	print("[7] 真跳场景")
	await _spawn(Vector2i(1280, 720))
	if _node == null:
		return
	# 前面的用例都把跳转关掉（无头里换场景会连带重置 SceneTree），这一节必须真的跳。
	_node.set("change_scene_enabled", true)
	var event := InputEventKey.new()
	event.keycode = KEY_ENTER
	event.physical_keycode = KEY_ENTER
	event.pressed = true
	Input.parse_input_event(event)
	# change_scene_to_file 是延迟到帧末执行的：先等它换掉场景，再等新场景 _ready 完。
	var waited: int = 0
	while current_scene == null and waited < 120:
		await process_frame
		waited += 1
	for i in 3:
		await process_frame
	var current: Node = current_scene
	_check(current != null and current.scene_file_path == MAIN_SCENE_PATH,
		"回车之后 current_scene 变成 %s（实际 %s）"
			% [MAIN_SCENE_PATH, "(空)" if current == null else current.scene_file_path])
	_check(current != null and current.name == "Main",
		"主场景根节点名是 Main（实际 %s）" % ("(空)" if current == null else str(current.name)))


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

func _spawn(size_px: Vector2i) -> void:
	await _despawn()
	var packed: Variant = load(SCENE_PATH)
	if packed == null or not (packed is PackedScene):
		_check(false, "场景无法加载：%s" % SCENE_PATH)
		return
	_node = (packed as PackedScene).instantiate() as Control
	root.add_child(_node)
	# SceneTree 工具脚本里 add_child() 不会立刻触发 _ready()（要等第一帧）
	await process_frame
	await process_frame
	_node.size = Vector2(size_px)
	# 测试里不真的切场景（第 7 节单独验证真切换），只记录意图
	_node.set("change_scene_enabled", false)
	_start_events = 0
	_node.connect("start_requested", func() -> void: _start_events += 1)
	await process_frame
	# 版面收敛要一帧：Label 的最小高度在换字号后要等到下一帧才更新（标题页会自己重排一次）
	await process_frame


func _despawn() -> void:
	if _node != null and is_instance_valid(_node):
		root.remove_child(_node)
		_node.free()
	_node = null
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("  ✓ %s" % message)
	else:
		_failures.append(message)
		print("  ✗ %s" % message)


func _backup_user_files() -> void:
	_saved_existed.clear()
	_saved_bytes.clear()
	for path in STORE_PATHS:
		var exists: bool = FileAccess.file_exists(path)
		_saved_existed.append(exists)
		_saved_bytes.append(FileAccess.get_file_as_bytes(path) if exists else PackedByteArray())


func _restore_user_files() -> void:
	for index in range(STORE_PATHS.size()):
		var path: String = STORE_PATHS[index]
		if _saved_existed[index]:
			_write_bytes(path, _saved_bytes[index])
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _finish() -> void:
	await _despawn()
	_restore_user_files()
	print("")
	if _checks < EXPECTED_CHECKS:
		print("RESULT: FAIL 断言执行数量异常：实际 %d 项 < 期望 %d 项（中途崩了？）"
			% [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if _failures.is_empty():
		print("结果：通过 %d 项 / 失败 0 项（共 %d 项）" % [_checks, _checks])
		print("RESULT: OK 标题界面 %d 项断言全部通过（装配/文案/字体覆盖/三档版面自适应/源码卫生/回车空格点击/悬停反馈/真跳主场景）"
			% _checks)
		quit(0)
	else:
		print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）"
			% [_checks - _failures.size(), _failures.size(), _checks])
		for failure in _failures:
			print("  ✗ %s" % failure)
		print("RESULT: FAIL 标题界面 %d 项不通过" % _failures.size())
		quit(1)
