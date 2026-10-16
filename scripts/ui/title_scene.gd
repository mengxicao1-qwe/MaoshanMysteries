extends Control
## ============================================================================
##  title_scene.gd —— 极简标题界面（M2 表现层：标题页）
## ----------------------------------------------------------------------------
##  由 scenes_src/title_scene.json 生成 scenes/title_scene.tscn，树结构：
##    TitleScene (Control, 本脚本)
##      ├─ TitleLabel      《茅山秘录·诡异录》
##      ├─ SubtitleLabel    第一案 · 白鹄不举
##      ├─ HintLabel        一轮余页 · 六分钟 · 记得越多，代价越大
##      └─ StartButton      【开始推演】 → res://scenes/main.tscn
##
##  画面：全部出自 _draw() 的图元（底色渐变 / 墨雾晕染 / 纸纹横纹 / 四角暗角 /
##  朱砂点缀），不引用任何 PNG 美术。
##  交互：鼠标点按钮、回车、小键盘回车、空格 → change_scene_to_file(NEXT_SCENE)。
##
##  ★ 版面一律按 size 现算（AGENTS.md §4：stretch/mode=canvas_items 下 Control.size
##    跟着窗口走）。本文件里没有写死的分辨率常量：字号取窗口高度的比例，坐标取宽高的
##    比例，整块高度由 Label 自己量出来的行高累加 —— 换成别的窗口尺寸也不会错位。
##  ★ 本脚本刻意不引用任何 Autoload：这样 --check-only 才可信，无头单测也不必注入
##    任何管理器（标题页本来也不需要存档）。
## ============================================================================

## 点【开始推演】/ 回车 / 空格之后进入的正式场景。
const NEXT_SCENE: String = "res://scenes/main.tscn"

## 请求开始（无头单测用它数"到底触发了几次"）。
signal start_requested()

# --- 配色：墨 + 一点朱砂 ------------------------------------------------------
const C_INK_TOP: Color = Color(0.020, 0.023, 0.034, 1.0)
const C_INK_BOTTOM: Color = Color(0.070, 0.068, 0.082, 1.0)
const C_MIST: Color = Color(0.48, 0.56, 0.70, 1.0)
const C_CINNABAR: Color = Color(0.80, 0.22, 0.15, 1.0)
const C_EDGE: Color = Color(0.42, 0.40, 0.44, 1.0)
const C_EDGE_HOVER: Color = Color(0.86, 0.34, 0.24, 1.0)
const C_EDGE_PRESSED: Color = Color(1.0, 0.52, 0.36, 1.0)
const C_BTN_FILL: Color = Color(0.10, 0.09, 0.12, 0.72)
const C_BTN_FILL_HOVER: Color = Color(0.26, 0.11, 0.08, 0.80)
const C_BTN_FILL_PRESSED: Color = Color(0.40, 0.15, 0.10, 0.90)
const C_TEXT: Color = Color(0.93, 0.90, 0.84, 1.0)
const C_TEXT_HOVER: Color = Color(1.0, 0.94, 0.82, 1.0)

# --- 版面比例（全部乘 size，没有一个像素常量） --------------------------------
## 整块内容的中心落在窗口高度的这个比例上（略高于几何中心，视觉更稳）
const BLOCK_CENTER_Y_RATIO: float = 0.44
const FS_TITLE_RATIO: float = 0.072
const FS_TITLE_MIN: int = 26
const FS_TITLE_MAX: int = 76
const FS_SUBTITLE_RATIO: float = 0.028
const FS_SUBTITLE_MIN: int = 13
const FS_SUBTITLE_MAX: int = 32
const FS_HINT_RATIO: float = 0.017
const FS_HINT_MIN: int = 11
const FS_HINT_MAX: int = 20
const FS_BUTTON_RATIO: float = 0.026
const FS_BUTTON_MIN: int = 13
const FS_BUTTON_MAX: int = 30
const GAP_TITLE_TO_SUBTITLE: float = 0.028
const GAP_SUBTITLE_TO_HINT: float = 0.013
const GAP_HINT_TO_BUTTON: float = 0.045
const BUTTON_H_RATIO: float = 0.070
const BUTTON_W_PAD_RATIO: float = 0.11
const BUTTON_W_RATIO_MIN: float = 0.20
const BUTTON_W_RATIO_MAX: float = 0.42
## 按钮 StyleBox 上下 content_margin 之和（算最小高度时要加上）
const BUTTON_CONTENT_MARGIN: float = 12.0
## 拿不到字体时的兜底行高系数（正常情况下用不到）
const LINE_HEIGHT_FALLBACK: float = 1.45

# --- 背景图元的确定性参数（写死在表里 ⇒ 同一尺寸必然画出同一张图） ------------
## 每团墨雾：[中心 x 比例, 中心 y 比例, 半径比例(取短边), 每层透明度]
## 层数多、每层淡 ⇒ 化开的边缘更细腻（层数少会看出一圈圈的硬边）
const BLOOMS: Array = [
	[0.20, 0.28, 0.36, 0.021],
	[0.82, 0.20, 0.30, 0.018],
	[0.68, 0.82, 0.33, 0.019],
	[0.16, 0.86, 0.27, 0.016],
	[0.50, 0.42, 0.26, 0.013],
]
const BLOOM_RINGS: int = 10
## 右下角那枚印歪多少度（手落印不会正；纯几何图案，不写字）
const SEAL_TILT_DEG: float = 7.0
## 每条纸纹：[y 比例, 起点 x 比例, 终点 x 比例, 透明度]
const STREAKS: Array = [
	[0.145, 0.06, 0.44, 0.045],
	[0.198, 0.52, 0.95, 0.032],
	[0.262, 0.10, 0.38, 0.026],
	[0.318, 0.62, 0.90, 0.040],
	[0.398, 0.04, 0.27, 0.022],
	[0.455, 0.72, 0.97, 0.028],
	[0.530, 0.12, 0.41, 0.034],
	[0.585, 0.55, 0.88, 0.022],
	[0.660, 0.07, 0.33, 0.030],
	[0.705, 0.60, 0.93, 0.026],
	[0.775, 0.15, 0.47, 0.036],
	[0.820, 0.50, 0.80, 0.020],
	[0.885, 0.08, 0.36, 0.028],
	[0.938, 0.58, 0.95, 0.030],
]
const VIGNETTE_LAYERS: int = 16
const VIGNETTE_BAND_RATIO: float = 0.016

# --- 节点与状态 --------------------------------------------------------------
var _title: Label = null
var _subtitle: Label = null
var _hint: Label = null
var _start_button: Button = null

## 版面是否已经算过（_draw 里的装饰件要等它算完才画）
var _laid_out: bool = false
## 这一帧的版面里有没有"被旧字号顶住、要下一帧再算一次"的行（收到就重排一次，幂等收敛）
var _needs_relayout: bool = false
## 标题文字下沿 + 标题与副标题的间距（_draw 用它定位那条朱砂横线）
var _title_bottom: float = 0.0
var _gap_title: float = 0.0
## 另两处行距与整块高度：只给 debug_info() 看，版面本身每次现算
var _gap_subtitle: float = 0.0
var _gap_button: float = 0.0
var _block_height: float = 0.0
## 鼠标是否停在按钮上（悬停时在按钮后面点一团朱砂晕）
var _hover: bool = false
## 已经接受过"开始"指令（防重入：连按两次回车只切一次场景）
var _leaving: bool = false

## 切换场景的目标（无头单测可以换掉它，避免真的加载主场景）
var next_scene_path: String = NEXT_SCENE
## 置 false 后 _accept() 只记录意图、不真的切场景（无头单测用）
var change_scene_enabled: bool = true
## 最近一次"请求开始"的目标路径（空 = 还没请求过）
var requested_scene: String = ""


func _ready() -> void:
	_title = get_node_or_null("TitleLabel") as Label
	_subtitle = get_node_or_null("SubtitleLabel") as Label
	_hint = get_node_or_null("HintLabel") as Label
	_start_button = get_node_or_null("StartButton") as Button

	if _start_button != null:
		_style_button(_start_button)
		_start_button.pressed.connect(_accept)
		_start_button.mouse_entered.connect(_on_button_hover.bind(true))
		_start_button.mouse_exited.connect(_on_button_hover.bind(false))
		# 默认把焦点给按钮：插着手柄/键盘也能直接回车进游戏
		_start_button.grab_focus()

	# 窗口尺寸变了就重排（本页所有坐标都是 size 的函数）
	resized.connect(_layout)
	_layout()


## 只在"上一帧有行被旧字号的最小高度顶住"时才重排一次（幂等，最多两帧就稳住）。
func _process(_delta: float) -> void:
	if _needs_relayout:
		_needs_relayout = false
		_layout()


# ---------------------------------------------------------------------------
#  输入与动作
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER or key.keycode == KEY_SPACE:
		# 按钮自己也会把 ui_accept 变成 pressed（焦点在它身上），_leaving 负责去重
		_accept()


## 唯一允许的"开始"入口：按钮点击 / 回车 / 空格 都走这里。
func _accept() -> void:
	if _leaving:
		return
	_leaving = true
	requested_scene = next_scene_path
	start_requested.emit()
	if not change_scene_enabled:
		return
	var err: int = get_tree().change_scene_to_file(next_scene_path)
	if err != OK:
		# 切不过去就把门重新打开，别把玩家锁在标题页
		_leaving = false
		requested_scene = ""
		print("[title_scene] 切换场景失败 err=%d path=%s" % [err, next_scene_path])


func _on_button_hover(hovered: bool) -> void:
	if _hover == hovered:
		return
	_hover = hovered
	queue_redraw()


# ---------------------------------------------------------------------------
#  版面：全部按 size 现算
# ---------------------------------------------------------------------------

func _layout() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 2.0 or h < 2.0:
		return
	if _title == null or _subtitle == null or _hint == null or _start_button == null:
		return

	var title_fs: int = _scaled_font_size(h, FS_TITLE_RATIO, FS_TITLE_MIN, FS_TITLE_MAX)
	var subtitle_fs: int = _scaled_font_size(h, FS_SUBTITLE_RATIO, FS_SUBTITLE_MIN, FS_SUBTITLE_MAX)
	var hint_fs: int = _scaled_font_size(h, FS_HINT_RATIO, FS_HINT_MIN, FS_HINT_MAX)
	var button_fs: int = _scaled_font_size(h, FS_BUTTON_RATIO, FS_BUTTON_MIN, FS_BUTTON_MAX)

	var gap_title: float = h * GAP_TITLE_TO_SUBTITLE
	var gap_hint: float = h * GAP_SUBTITLE_TO_HINT
	var gap_button: float = h * GAP_HINT_TO_BUTTON

	# 第一遍：量出每一行的真实高度（Label 有最小尺寸 + 描边，写死行高会被顶开）。
	# 位置一律用"绝对基准 y + 整体平移量"现算 ⇒ 重复 _layout()（resized 会反复触发）
	# 也不会越挪越偏。
	var title_h: float = _measure(_title, title_fs, w)
	var title_y: float = 0.0
	var subtitle_y: float = title_h + gap_title
	var subtitle_h: float = _measure(_subtitle, subtitle_fs, w)
	var hint_y: float = subtitle_y + subtitle_h + gap_hint
	var hint_h: float = _measure(_hint, hint_fs, w)
	var button_y: float = hint_y + hint_h + gap_button

	# 按钮宽度按"文字实测宽度 + 一点余量"，但始终落在窗口宽度的比例区间里，
	# 免得极窄/极宽窗口下按钮被拉成一整条。高度也要压过按钮自己的最小高度
	# （行高 + StyleBox 的上下 content_margin），否则设定值会被顶掉。
	var button_font: Font = _start_button.get_theme_font("font")
	var text_width: float = button_font.get_string_size(
		_start_button.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, button_fs).x
	var button_w: float = clampf(text_width + h * BUTTON_W_PAD_RATIO,
		w * BUTTON_W_RATIO_MIN, w * BUTTON_W_RATIO_MAX)
	_start_button.add_theme_font_size_override("font_size", button_fs)
	var button_h: float = maxf(h * BUTTON_H_RATIO,
		_line_height(button_font, button_fs) + BUTTON_CONTENT_MARGIN)
	_start_button.size = Vector2(button_w, button_h)

	# 第二遍：整块平移到视觉中心
	var block_h: float = button_y + button_h
	var shift: float = h * BLOCK_CENTER_Y_RATIO - block_h * 0.5
	_title.position = Vector2(0.0, title_y + shift)
	_subtitle.position = Vector2(0.0, subtitle_y + shift)
	_hint.position = Vector2(0.0, hint_y + shift)
	_start_button.position = Vector2((w - button_w) * 0.5, button_y + shift)

	_title_bottom = _title.position.y + _title.size.y
	_gap_title = gap_title
	_gap_subtitle = gap_hint
	_gap_button = gap_button
	_block_height = block_h
	_laid_out = true
	queue_redraw()


## 设定字号并返回这一行的真实高度。
## ★ 行高必须由 Font.get_height() 现算：Label 自己的最小高度要**等下一帧**才跟上
##   theme_override_font_sizes 的改动（本机实测：改完立刻读还是上一档字号的高度），
##   拿它当版面依据会让窗口变小时行距留在旧值上 —— 整块就不成比例了。
func _measure(label: Label, font_size: int, width: float) -> float:
	label.add_theme_font_size_override("font_size", font_size)
	var line_height: float = _line_height(label.get_theme_font("font"), font_size)
	label.size = Vector2(width, line_height)
	if absf(label.size.y - line_height) > 0.5:
		# 被上一档字号遗留的最小高度顶住了：等它跟上再算一遍（_layout 幂等，会收敛）
		_needs_relayout = true
	return line_height


func _line_height(font: Font, font_size: int) -> float:
	if font == null:
		return float(font_size) * LINE_HEIGHT_FALLBACK
	return font.get_height(font_size)


func _scaled_font_size(height: float, ratio: float, min_size: int, max_size: int) -> int:
	return clampi(int(round(height * ratio)), min_size, max_size)


func _style_button(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _box(C_BTN_FILL, C_EDGE, 1))
	button.add_theme_stylebox_override("hover", _box(C_BTN_FILL_HOVER, C_EDGE_HOVER, 2))
	button.add_theme_stylebox_override("pressed", _box(C_BTN_FILL_PRESSED, C_EDGE_PRESSED, 2))
	# focus 不另画框（会和 hover 打架），只留颜色 —— 键盘流也看得见
	button.add_theme_stylebox_override("focus", _box(Color(0.0, 0.0, 0.0, 0.0), C_EDGE_HOVER, 1))
	button.add_theme_color_override("font_color", C_TEXT)
	button.add_theme_color_override("font_hover_color", C_TEXT_HOVER)
	button.add_theme_color_override("font_pressed_color", C_TEXT_HOVER)
	button.add_theme_color_override("font_focus_color", C_TEXT_HOVER)


func _box(fill: Color, edge: Color, edge_width: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(edge_width)
	box.set_corner_radius_all(2)
	box.content_margin_left = 10.0
	box.content_margin_right = 10.0
	box.content_margin_top = 6.0
	box.content_margin_bottom = 6.0
	return box


# ---------------------------------------------------------------------------
#  画面：全部是图元
# ---------------------------------------------------------------------------

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w < 2.0 or h < 2.0:
		return
	_draw_ink(w, h)
	_draw_seal(w, h)
	if _laid_out:
		_draw_title_mark(w, h)
		_draw_button_glow()


## 底色（上深下浅的墨）+ 墨雾晕染 + 纸纹横纹 + 四角压暗。
func _draw_ink(w: float, h: float) -> void:
	var short_side: float = minf(w, h)
	draw_polygon(
		PackedVector2Array([Vector2(0.0, 0.0), Vector2(w, 0.0), Vector2(w, h), Vector2(0.0, h)]),
		PackedColorArray([C_INK_TOP, C_INK_TOP, C_INK_BOTTOM, C_INK_BOTTOM]))

	# 墨雾：每团画若干层同心圆，层数越多中心越浓，边缘自然化开
	for bloom in BLOOMS:
		var center := Vector2(w * float(bloom[0]), h * float(bloom[1]))
		var radius: float = short_side * float(bloom[2])
		var alpha: float = float(bloom[3])
		for ring in BLOOM_RINGS:
			var t: float = 1.0 - float(ring) / float(BLOOM_RINGS)
			draw_circle(center, radius * (0.30 + 0.70 * t), Color(C_MIST, alpha))

	# 纸纹：一条条淡淡的横纹，像旧纸的帘纹
	var streak_width: float = maxf(1.0, h * 0.0016)
	for streak in STREAKS:
		var y: float = h * float(streak[0])
		draw_line(Vector2(w * float(streak[1]), y), Vector2(w * float(streak[2]), y),
			Color(C_MIST, float(streak[3])), streak_width)

	# 四角压暗：一圈由外向内、越来越淡的描边
	var band: float = maxf(1.0, short_side * VIGNETTE_BAND_RATIO)
	for layer in VIGNETTE_LAYERS:
		var inset: float = band * float(layer)
		var fade: float = 1.0 - float(layer) / float(VIGNETTE_LAYERS)
		draw_rect(Rect2(inset, inset, w - inset * 2.0, h - inset * 2.0),
			Color(0.0, 0.0, 0.0, 0.055 * fade), false, band)


## 标题下的朱砂横线 + 线心一枚朱砂点 + 标题后一团极淡的红晕。
func _draw_title_mark(w: float, h: float) -> void:
	var center_x: float = w * 0.5
	var title_center_y: float = _title_bottom - _title.size.y * 0.5
	# 红晕贴着标题本身（半径跟着标题行高走，不跟着窗口宽度走 —— 否则大窗口里会糊成一片脏红）
	for ring in 4:
		draw_circle(Vector2(center_x, title_center_y),
			_title.size.y * (0.80 + 0.34 * float(ring)), Color(C_CINNABAR, 0.017))

	var rule_y: float = _title_bottom + maxf(_gap_title * 0.42, 4.0)
	var half: float = w * 0.10
	var rule_width: float = maxf(1.0, h * 0.0022)
	draw_line(Vector2(center_x - half, rule_y), Vector2(center_x + half, rule_y),
		Color(C_CINNABAR, 0.85), rule_width, true)
	var dot: float = maxf(3.0, h * 0.007)
	draw_colored_polygon(PackedVector2Array([
		Vector2(center_x, rule_y - dot),
		Vector2(center_x + dot, rule_y),
		Vector2(center_x, rule_y + dot),
		Vector2(center_x - dot, rule_y),
	]), Color(C_CINNABAR, 0.95))


## 右下角一枚"落印"：外框 + 内回纹 + 淡红印面，歪 7°。
## 纯几何，不含任何文字（生僻字收不进字体子集，见 AGENTS.md §4）。
func _draw_seal(w: float, h: float) -> void:
	var side: float = clampf(minf(w, h) * 0.055, 18.0, 72.0)
	var center := Vector2(w - side - w * 0.055, h - side - h * 0.11)
	var tilt: float = deg_to_rad(SEAL_TILT_DEG)
	var edge: float = maxf(1.0, side * 0.055)
	draw_colored_polygon(_square_points(center, side, tilt), Color(C_CINNABAR, 0.07))
	draw_polyline(_square_points(center, side, tilt, true), Color(C_CINNABAR, 0.62), edge, true)
	draw_polyline(_square_points(center + Vector2(0.0, side * 0.02), side * 0.42, tilt, true),
		Color(C_CINNABAR, 0.30), edge * 0.9, true)


## 以 center 为中心、边长 side、旋转 angle 弧度的正方形；closed=true 时首尾相连（给 draw_polyline）
func _square_points(center: Vector2, side: float, angle: float, closed: bool = false) -> PackedVector2Array:
	var half: float = side * 0.5
	var points := PackedVector2Array()
	for corner_v in [Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)]:
		var corner: Vector2 = corner_v
		points.append(center + corner.rotated(angle))
	if closed:
		points.append(points[0])
	return points


## 按钮后面一团朱砂晕（鼠标悬停或键盘焦点时才有）。
## 收紧在按钮周围：半径按按钮自身高度算 —— 按整块宽度算会糊出一大团脏红。
func _draw_button_glow() -> void:
	if _start_button == null:
		return
	if not (_hover or _start_button.has_focus()):
		return
	var center: Vector2 = _start_button.position + _start_button.size * 0.5
	var radius: float = _start_button.size.y * 1.15
	for ring in 3:
		draw_circle(center, radius * (1.0 - 0.24 * float(ring)), Color(C_CINNABAR, 0.030))


# ---------------------------------------------------------------------------
#  供无头测试与调试读取的现状（全部现算，不缓存猜测值）
# ---------------------------------------------------------------------------

func debug_info() -> Dictionary:
	var rects: Array[Rect2] = []
	for node in [_title, _subtitle, _hint, _start_button]:
		if node != null:
			var control := node as Control
			rects.append(Rect2(control.position, control.size))
	var button_center := Vector2.ZERO
	var button_text: String = ""
	var title_text: String = ""
	if _start_button != null:
		button_center = _start_button.position + _start_button.size * 0.5
		button_text = _start_button.text
	if _title != null:
		title_text = _title.text
	return {
		"size": size,
		"rects": rects,
		"overlaps": _overlap_count(rects),
		"button_center": button_center,
		"button_text": button_text,
		"title_text": title_text,
		"title_font_size": 0 if _title == null else _title.get_theme_font_size("font_size"),
		"font_sizes": {
			"title": 0 if _title == null else _title.get_theme_font_size("font_size"),
			"subtitle": 0 if _subtitle == null else _subtitle.get_theme_font_size("font_size"),
			"hint": 0 if _hint == null else _hint.get_theme_font_size("font_size"),
			"button": 0 if _start_button == null else _start_button.get_theme_font_size("font_size"),
		},
		"gaps": {
			"title_to_subtitle": _gap_title,
			"subtitle_to_hint": _gap_subtitle,
			"hint_to_button": _gap_button,
		},
		"block_height": _block_height,
		"hover": _hover,
		"leaving": _leaving,
		"requested_scene": requested_scene,
		"laid_out": _laid_out,
	}


func _overlap_count(rects: Array[Rect2]) -> int:
	var count: int = 0
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				count += 1
	return count
