extends Control
## ============================================================================
##  overlay_ui.gd —— 覆盖层：新手引导弹窗 + 结案结算弹窗（Phase 2 / Phase 3）
## ----------------------------------------------------------------------------
##  分工纪律（与 play_view.gd 同一条）：
##    * 本层**只读** SliceHUD.present_state()，只通过 request_* 回写玩法层；
##      自己不判胜负、不碰时钟、不改心灯、不碰存档（唯一例外：开新档要点名调
##      SliceHUD.request_restart_case()，那是表现层公开的动作入口）。
##    * 键盘一律留给 SliceHUD（本层不接 _input）；鼠标：弹窗开着时才吃点击。
##    * 版面按 size 现算（AGENTS §4：stretch/mode=canvas_items 下 Control.size 跟窗口走）。
##
##  为什么不暂停时钟来做引导：引导盖住的只是画面，玩家想立刻上手就点「知道了」；
##  一暂停就把 TimeLoopManager 的状态搅了（纵切片试玩的 179 项断言全是按余页时钟走的）。
##  所以引导的 30 秒倒计时走**真实时间**（_process 的 delta，不受倍速/暂停影响）。
##
##  鼠标穿透怎么保证（这是本层最容易踩的地方）：
##    * 根 Control：mouse_filter = IGNORE(2) —— 自己不吃点击，子节点照常收。
##    * 遮罩 ColorRect：STOP(0)，但只在弹窗开着时 visible；隐藏的 Control 不参与命中测试。
##    * 两个 CenterContainer 同理，关掉就 visible = false。
##    ⇒ 弹窗关着时，底下 PlayView 的"点房间就走、点人就说话"一个字都不用改。
## ============================================================================

const UIPrefs = preload("res://scripts/data/ui_prefs.gd")

## 引导弹窗自动关闭的秒数（真实时间）。
const TUTORIAL_SECONDS: float = 30.0

## 弹窗宽度：按窗口宽度现算，夹在 420..700 之间（窄窗口不挤成一列，宽窗口不满屏）。
const PANEL_WIDTH_RATIO: float = 0.52
const PANEL_MIN_WIDTH: float = 420.0
const PANEL_MAX_WIDTH: float = 700.0

const F_HERO: int = 22
const F_TITLE: int = 16
const F_BODY: int = 14
const F_SMALL: int = 12

const C_TEXT: Color = Color(0.91, 0.93, 0.97, 1.0)
const C_DIM: Color = Color(0.58, 0.62, 0.71, 1.0)
const C_WARM: Color = Color(0.95, 0.83, 0.55, 1.0)
const C_ACCENT: Color = Color(0.30, 0.12, 0.09, 0.96)
const C_ACCENT_EDGE: Color = Color(0.86, 0.34, 0.24, 1.0)
const C_PANEL_BG: Color = Color(0.07, 0.075, 0.10, 0.97)
const C_PANEL_EDGE: Color = Color(0.40, 0.35, 0.34, 0.90)
const C_BLOCK: Color = Color(0.02, 0.02, 0.03, 0.62)
const C_KEY_BG: Color = Color(0.11, 0.10, 0.13, 1.0)
const C_KEY_EDGE: Color = Color(0.46, 0.40, 0.38, 0.95)

## 玩法层（SliceHUD）。测试里把它注进来即可无头跑；场景里由 ../SliceHUD 自动找到。
var hud: Node = null

var _blocker: ColorRect = null
var _tutorial_layer: CenterContainer = null
var _tutorial_body: Label = null
var _tutorial_keys: Label = null
var _tutorial_sub: Label = null
var _tutorial_footer: Label = null
var _settle_layer: CenterContainer = null
var _settle_sub: Label = null
var _settle_stats: Label = null

var _tutorial_open: bool = false
var _tutorial_left: float = 0.0
var _settle_open: bool = false
var _settle_seen: bool = false
var _last_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	if hud == null:
		hud = get_node_or_null("../SliceHUD")
	_build_blocker()
	_build_tutorial()
	_build_settlement()
	_blocker.visible = false
	_tutorial_layer.visible = false
	_settle_layer.visible = false
	resized.connect(_sync_layout)
	_sync_layout()
	# 首次进入才弹；看过一次就记在 user://ui_prefs.json 里，之后不再打扰。
	if not UIPrefs.has_seen_tutorial():
		open_tutorial()


func _process(delta: float) -> void:
	_sync_layout()
	_tick_tutorial(delta)
	_watch_resolution()


# ============================================================================
#  第一节：节点搭建（全代码建，场景文件里只留一个挂脚本的 Control）
# ============================================================================

func _build_blocker() -> void:
	_blocker = ColorRect.new()
	_blocker.name = "Blocker"
	_blocker.color = C_BLOCK
	_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_blocker)


func _build_tutorial() -> void:
	_tutorial_layer = CenterContainer.new()
	_tutorial_layer.name = "TutorialLayer"
	_tutorial_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tutorial_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_tutorial_layer)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "TutorialPanel"
	panel.add_theme_stylebox_override("panel", _panel_style())
	_tutorial_layer.add_child(panel)

	var box: VBoxContainer = VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	box.add_child(_label("余页初记", F_HERO, C_WARM, true))
	_tutorial_sub = _label("案一 · 白鹄不举", F_SMALL, C_DIM, true)
	box.add_child(_tutorial_sub)
	box.add_child(_rule())

	_tutorial_body = _label("", F_BODY, C_TEXT, false)
	_tutorial_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_body.add_theme_constant_override("line_spacing", 8)
	box.add_child(_tutorial_body)
	box.add_child(_rule())

	_tutorial_keys = _label("", F_SMALL, C_DIM, false)
	_tutorial_keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_keys.add_theme_constant_override("line_spacing", 6)
	box.add_child(_tutorial_keys)

	var bottom: HBoxContainer = HBoxContainer.new()
	bottom.name = "Bottom"
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 18)
	_tutorial_footer = _label("", F_SMALL, C_DIM, true)
	bottom.add_child(_tutorial_footer)
	var close_button: Button = _button("知道了", true)
	close_button.pressed.connect(_on_tutorial_closed)
	bottom.add_child(close_button)
	box.add_child(bottom)


func _build_settlement() -> void:
	_settle_layer = CenterContainer.new()
	_settle_layer.name = "SettlementLayer"
	_settle_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settle_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_settle_layer)

	var panel: PanelContainer = PanelContainer.new()
	panel.name = "SettlementPanel"
	panel.add_theme_stylebox_override("panel", _panel_style())
	_settle_layer.add_child(panel)

	var box: VBoxContainer = VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	box.add_child(_label("此案已结", F_HERO, C_WARM, true))
	_settle_sub = _label("", F_SMALL, C_DIM, true)
	box.add_child(_settle_sub)
	box.add_child(_rule())

	_settle_stats = _label("", F_BODY, C_TEXT, false)
	_settle_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settle_stats.add_theme_constant_override("line_spacing", 8)
	box.add_child(_settle_stats)

	var bottom: HBoxContainer = HBoxContainer.new()
	bottom.name = "Bottom"
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.add_theme_constant_override("separation", 14)
	var restart_button: Button = _button("重新开始", true)
	restart_button.pressed.connect(_on_restart_pressed)
	bottom.add_child(restart_button)
	var stay_button: Button = _button("留在此页", false)
	stay_button.pressed.connect(_on_settlement_closed)
	bottom.add_child(stay_button)
	box.add_child(bottom)


func _label(text: String, font_size: int, color: Color, centered: bool) -> Label:
	var node: Label = Label.new()
	node.text = text
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)
	if centered:
		node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return node


func _rule() -> HSeparator:
	var node: HSeparator = HSeparator.new()
	node.name = "Rule"
	return node


func _button(text: String, primary: bool) -> Button:
	var node: Button = Button.new()
	node.text = text
	node.add_theme_font_size_override("font_size", F_TITLE - 1)
	node.add_theme_color_override("font_color", C_TEXT)
	node.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	node.add_theme_color_override("font_pressed_color", C_WARM)
	var bg: Color = C_ACCENT if primary else C_KEY_BG
	var edge: Color = C_ACCENT_EDGE if primary else C_KEY_EDGE
	node.add_theme_stylebox_override("normal", _button_style(bg, edge))
	node.add_theme_stylebox_override("hover", _button_style(bg.lightened(0.16), edge.lightened(0.12)))
	node.add_theme_stylebox_override("pressed", _button_style(bg.darkened(0.18), edge))
	node.add_theme_stylebox_override("focus", _button_style(Color(0, 0, 0, 0), C_WARM))
	node.custom_minimum_size = Vector2(148.0, 38.0)
	return node


func _panel_style() -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = C_PANEL_BG
	style.border_color = C_PANEL_EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(20.0)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 10
	return style


func _button_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8.0)
	return style


# ============================================================================
#  第二节：版面（窗口尺寸变了要重算，不许写死像素）
# ============================================================================

func _sync_layout() -> void:
	if size.is_equal_approx(_last_size):
		return
	_last_size = size
	var width: float = clampf(size.x * PANEL_WIDTH_RATIO, PANEL_MIN_WIDTH, PANEL_MAX_WIDTH)
	if _tutorial_body != null:
		_tutorial_body.custom_minimum_size = Vector2(width, 0.0)
	if _tutorial_keys != null:
		_tutorial_keys.custom_minimum_size = Vector2(width, 0.0)
	if _settle_stats != null:
		_settle_stats.custom_minimum_size = Vector2(width, 0.0)


# ============================================================================
#  第三节：新手引导
# ============================================================================

## 打开引导（首次进入由 _ready() 调；调试时也可以手动调）。
func open_tutorial() -> void:
	if _tutorial_open or _settle_open:
		return
	_tutorial_sub.text = "案一 · " + _case_title()
	_tutorial_body.text = "\n".join(_tutorial_lines())
	_tutorial_keys.text = _keys_line()
	_tutorial_left = TUTORIAL_SECONDS
	_tutorial_footer.text = _countdown_text()
	_tutorial_open = true
	_tutorial_layer.visible = true
	_refresh_blocker()


func _tick_tutorial(delta: float) -> void:
	if not _tutorial_open:
		return
	_tutorial_left = maxf(0.0, _tutorial_left - delta)
	_tutorial_footer.text = _countdown_text()
	if _tutorial_left <= 0.0:
		close_tutorial()


## 关闭引导并记一笔（30 秒到点、或玩家点「知道了」，两条路都走这里）。
func close_tutorial() -> void:
	if not _tutorial_open:
		return
	_tutorial_open = false
	_tutorial_layer.visible = false
	_refresh_blocker()
	UIPrefs.mark_tutorial_seen()


func is_tutorial_open() -> bool:
	return _tutorial_open


func tutorial_seconds_left() -> float:
	return _tutorial_left


func _countdown_text() -> String:
	return "（%d 秒后自动关闭）" % int(ceil(_tutorial_left))


## 核心规则四条：**数字全部从 present_state() 现取**（余页多长、要几条线索都是数据说了算），
## 不写死 360 / 6，免得改了案一数据这里变成假话。
func _tutorial_lines() -> Array[String]:
	var duration: float = 360.0
	var need: int = 6
	if hud != null and hud.has_method("present_state"):
		var state: Dictionary = hud.call("present_state")
		duration = float(state.get("duration", duration))
		need = _count(state.get("required"))
	var minutes: int = int(round(duration / 60.0))
	var lines: Array[String] = [
		"一、你在白鹄台村守着一页余页：一轮 %d 分钟（%d 秒）。钟走到头，这一遍就过去了 —— 时间不会等你。"
			% [minutes, int(duration)],
		"二、线索只有两个来源：走到对的房间蹲到那一拍；和同屋的人说话（点棋子，或按 F）。",
		"三、线索跨遍永久留下，但每一遍都要付代价：重开一遍心灯 -8、余页之内每秒 -0.02。心灯熄了，会永久划掉一条记忆。",
		"四、集齐 %d 条必需线索、再按 G 把那道符画完，此案才结得了（结案心灯 +25）。" % need,
	]
	return lines


func _keys_line() -> String:
	return "鼠标：点房间就走，点同屋的人就说话。\n" \
		+ "键盘：TAB/E 下一间 · Q 上一间 · 1-9 直接去 · F 交谈 · B 推演板 · H 重演 · G 画符 · 空格 快进 · T 倍速 · P 暂停 · R 重开"


## 案名（玩家向）：present_state()["title"] 是案件装载器的 display_title()，形如
## "案 01《白鹄不举》"——弹窗自己已经写了"案一 ·"，所以这里只取书名号里的案名，
## 免得出现"案一 · 案 01《白鹄不举》"这种叠字。
func _clean_case_title(raw: String) -> String:
	var text: String = raw.strip_edges()
	var open_bracket: int = text.find("《")
	var close_bracket: int = text.find("》")
	if open_bracket >= 0 and close_bracket > open_bracket + 1:
		text = text.substr(open_bracket + 1, close_bracket - open_bracket - 1)
	return text if text != "" else "白鹄不举"


func _case_title() -> String:
	var raw: String = ""
	if hud != null and hud.has_method("present_state"):
		raw = String(Dictionary(hud.call("present_state")).get("title", ""))
	return _clean_case_title(raw)


# ============================================================================
#  第四节：结案结算
# ============================================================================

## 只认一个信号源：present_state()["resolved"] 由 false 变 true ⇒ 弹一次（不重复弹）。
func _watch_resolution() -> void:
	if _settle_seen or _settle_open or _tutorial_open:
		return
	if hud == null or not hud.has_method("present_state"):
		return
	var state: Dictionary = hud.call("present_state")
	if not bool(state.get("resolved", false)):
		return
	_settle_seen = true
	open_settlement(state)


## 打开结算弹窗；不传 state 就自己去取一份。
func open_settlement(state: Dictionary = {}) -> void:
	if _settle_open:
		return
	if state.is_empty() and hud != null and hud.has_method("present_state"):
		state = hud.call("present_state")
	_settle_sub.text = "案一 · %s —— 六环相扣，余页回照" % _clean_case_title(String(state.get("title", "")))
	_settle_stats.text = "\n".join(_settlement_lines(state))
	_settle_open = true
	_settle_layer.visible = true
	_refresh_blocker()


func close_settlement() -> void:
	if not _settle_open:
		return
	_settle_open = false
	_settle_layer.visible = false
	_refresh_blocker()


func is_settlement_open() -> bool:
	return _settle_open


## 结算四项统计：用了几遍 / 余页内耗时 / 心灯 / 线索。
## 遍数按玩家口径显示（第 1 遍起），核心层的 loop_index 是 0 基 —— 两边各自说清自己的话。
func _settlement_lines(state: Dictionary) -> Array[String]:
	var loops: int = int(state.get("loop_index", 0)) + 1
	var min_loop: int = int(state.get("min_loop", 0)) + 1
	var elapsed: float = float(state.get("elapsed_total", 0.0))
	var lamp: int = int(state.get("lamp", 0))
	var lamp_max: int = int(state.get("lamp_max", 100))
	var lost: int = int(state.get("lamp_lost", 0))
	var clue_count: int = _count(state.get("clues"))
	var clue_total: int = int(state.get("clue_total", clue_count))
	var lamp_note: String = ("（心灯熄过 %d 次）" % lost) if lost > 0 else "（心灯没熄过）"
	var lines: Array[String] = [
		"· 用了几遍：第 %d 遍（这页案子要走到第 %d 遍才回照得全）" % [loops, min_loop],
		"· 余页内耗时：%s" % _clock(int(round(elapsed))),
		"· 心灯：%d / %d %s" % [lamp, lamp_max, lamp_note],
		"· 入案线索：%d / %d" % [clue_count, clue_total],
	]
	return lines


func _clock(seconds: int) -> String:
	var safe: int = maxi(0, seconds)
	return "%02d:%02d" % [safe / 60, safe % 60]


## present_state() 里是 Variant，取个长度要防它根本不是数组（拿默认值就好）。
func _count(value: Variant) -> int:
	if value is Array:
		var array: Array = value
		return array.size()
	return 0


# ============================================================================
#  第五节：动作与状态（外部只用这几个入口，别直接摸内部节点）
# ============================================================================

func _on_tutorial_closed() -> void:
	close_tutorial()


func _on_settlement_closed() -> void:
	close_settlement()


## 「重新开始」= 开新档：把玩家的记忆档清掉、遍数归零、整场重来。
## 具体怎么做由玩法层决定（SliceHUD.request_restart_case），本层不替它做主。
func _on_restart_pressed() -> void:
	close_settlement()
	_settle_seen = false
	if hud != null and hud.has_method("request_restart_case"):
		hud.call("request_restart_case")


func _refresh_blocker() -> void:
	_blocker.visible = _tutorial_open or _settle_open


## 供测试/调试读状态（不参与玩法判断）。
func debug_info() -> Dictionary:
	return {
		"tutorial_open": _tutorial_open,
		"tutorial_left": _tutorial_left,
		"settlement_open": _settle_open,
		"settlement_seen": _settle_seen,
		"blocker_visible": _blocker.visible,
		"panel_width": _tutorial_body.custom_minimum_size.x if _tutorial_body != null else 0.0,
	}
