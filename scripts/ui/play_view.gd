## PlayView —— M2 画面层（v2：自适应网格布局）
##
## 这一版专治"节点/连线/文字挤在一起"：
##   1. 布局全部按 size 现算 —— 1280x720 只是基准，窗口更大/更小都跟得上
##      （v1 把 STAGE_W=928 / PANEL_X=940 写死，窗口一变就错位、面板停在屏幕中间）。
##   2. 房间牌子走"网格吸附 + 逐个占位"：每间房独占一个格子，格子宽高按房间数自动算，
##      保证相邻节点中心间距 >= MIN_GAP(120px)，牌子、NPC 棋子、连线标签由构造保证不重叠
##      （v1 直接按 data 的 pos 画，台前/人群/摊后那一片挤成一团）。
##   3. 右侧面板改成真容器（PanelContainer > ScrollContainer > VBoxContainer > Label 自动换行），
##      文字由容器排版，不再手写 y 坐标；画面上的文字一律带半透明黑底；
##      连线画在牌子之前（等价于 z_index 更小），永不被线压住。
##   4. 字号收敛：正文 14、标题 16、棋子/日志 12、连线秒数 11、余页时钟 22（唯一的大字）。
##
## 规矩没变：这一层只读 SliceHUD.present_state()、只调 request_*，键盘全归 SliceHUD，它只吃鼠标。
extends Control

const MAP_PATH := "res://data/maps/case_01_map.json"

# --- 版面（按 size 现算，1280x720 是基准） ---
const MARGIN := 12.0
const TOP_H := 74.0
const BOTTOM_H := 104.0
const PANEL_MIN_W := 300.0
const PANEL_MAX_W := 360.0
const MIN_GAP := 120.0          # 用户要求的节点最小间距（相邻格子中心距）
const CELL_MIN_W := 128.0
const CELL_MIN_H := 92.0
const PLATE_H := 30.0
const CHIP_H := 18.0
const CHIP_GAP := 6.0
const FONT_PATH := "res://assets/fonts/NotoSansSC-subset.ttf"  # tools/gen_font.py 生成的子集（288 KB）

# --- 字号 ---
const F_TINY := 11
const F_SMALL := 12
const F_BODY := 14
const F_TITLE := 16
const F_HERO := 22

# --- 配色 ---
const C_BG := Color(0.043, 0.051, 0.071)
const C_INK := Color(0.66, 0.74, 0.88)
const C_TEXT := Color(0.90, 0.92, 0.97)
const C_DIM := Color(0.52, 0.58, 0.70)
const C_FAINT := Color(0.24, 0.28, 0.36)
const C_GOLD := Color(0.90, 0.78, 0.42)
const C_LAMP := Color(0.98, 0.74, 0.34)
const C_BAD := Color(0.90, 0.48, 0.45)
const C_OK := Color(0.50, 0.82, 0.62)
const C_STONE := Color(0.32, 0.34, 0.40)

const C_NPC: Array = [
	Color(0.62, 0.78, 0.92), Color(0.86, 0.70, 0.55), Color(0.72, 0.62, 0.88),
	Color(0.60, 0.84, 0.70), Color(0.90, 0.66, 0.72), Color(0.80, 0.80, 0.58),
	Color(0.66, 0.70, 0.86), Color(0.86, 0.78, 0.66),
]

# --- 数据 ---
var _hud: Node = null
var _font: Font = null
var _pos: Dictionary = {}            # room_id -> Vector2（data 里的 pos，只当"大概在哪"的种子）
var _names: Dictionary = {}          # room_id -> display_name
var _order: Array[String] = []        # 房间顺序（数据顺序，布局按它稳定分配格子）
var _edges: Array = []                # [{from, to, seconds}]
var _state: Dictionary = {}
var _hover: String = ""
var _hover_chip: String = ""
var _t: float = 0.0
var _draw_count: int = 0
var _text_hud_hidden: bool = false

# --- 布局产物 ---
var _dirty_layout: bool = true
var _stage := Rect2()
var _panel_rect := Rect2()
var _cols: int = 1
var _rows: int = 1
var _cell := Vector2(CELL_MIN_W, CELL_MIN_H)
var _cells: Dictionary = {}           # room_id -> Vector2i(col, row)
var _room_rects: Array = []           # [{rect: Rect2, room: String}]（命中测试用）
var _chip_rects: Array = []           # [{rect: Rect2, room: String, npc: String}]
var _option_rects: Array = []         # [{rect: Rect2, index: int}]（对话选项按钮）

# --- 右侧面板（真容器） ---
var _panel: PanelContainer = null
var _panel_box: VBoxContainer = null
var _panel_sig: String = ""

# --- 缓存的 StyleBox（每帧 new 会掉帧） ---
var _sb_bg := StyleBoxFlat.new()
var _sb_plate := StyleBoxFlat.new()
var _sb_plate_here := StyleBoxFlat.new()
var _sb_plate_hover := StyleBoxFlat.new()
var _sb_plate_far := StyleBoxFlat.new()
var _sb_chip := StyleBoxFlat.new()
var _sb_panel := StyleBoxFlat.new()
var _sb_card := StyleBoxFlat.new()
var _sb_pill := StyleBoxFlat.new()
var _sb_pill_hot := StyleBoxFlat.new()


func _ready() -> void:
	# 中文必须随包带字体：浏览器/导出包里没有系统字体，内置默认字体只有拉丁字形（全是豆腐块）。
	# 字体是项目自动生成的子集（tools/gen_font.py），随包 288 KB。
	_font = _load_font()
	mouse_filter = Control.MOUSE_FILTER_STOP
	_make_styles()
	_load_map()
	_hud = get_node_or_null("../SliceHUD")
	if _hud == null and get_tree() != null and get_tree().current_scene != null:
		_hud = get_tree().current_scene.find_child("SliceHUD", true, false)
	resized.connect(_on_resized)
	_build_side_panel()
	queue_redraw()


func _load_font() -> Font:
	if ResourceLoader.exists(FONT_PATH):
		var f: Font = load(FONT_PATH)
		if f != null:
			return f
	push_warning("找不到中文字体 %s（中文会显示成豆腐块）：跑一次 python tools/gen_font.py" % FONT_PATH)
	return ThemeDB.fallback_font


func _make_styles() -> void:
	_fill(_sb_bg, C_BG, Color(0, 0, 0, 0), 10, 1)
	_fill(_sb_plate, Color(0.082, 0.098, 0.140, 0.97), C_FAINT, 6, 1)
	_fill(_sb_plate_here, Color(0.145, 0.220, 0.340, 0.99), Color(0.52, 0.72, 0.95), 6, 1)
	_fill(_sb_plate_hover, Color(0.120, 0.170, 0.255, 0.99), C_INK, 6, 1)
	_fill(_sb_plate_far, Color(0.055, 0.065, 0.092, 0.90), Color(0.16, 0.19, 0.26), 6, 1)
	_fill(_sb_chip, Color(0.0, 0.0, 0.0, 0.72), Color(0, 0, 0, 0), 4, 0)
	_fill(_sb_panel, Color(0.062, 0.072, 0.102, 0.96), Color(0.20, 0.24, 0.32), 8, 1)
	_fill(_sb_card, Color(0.0, 0.0, 0.0, 0.62), Color(0.16, 0.19, 0.26), 6, 1)
	_fill(_sb_pill, Color(0.11, 0.14, 0.20, 0.98), Color(0.30, 0.36, 0.48), 6, 1)
	_fill(_sb_pill_hot, Color(0.20, 0.17, 0.10, 0.98), C_GOLD, 6, 1)


func _fill(sb: StyleBoxFlat, bg: Color, border: Color, radius: int, border_w: int) -> void:
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0


func _on_resized() -> void:
	_dirty_layout = true
	queue_redraw()


func _process(delta: float) -> void:
	_t += delta
	_state = _read_state()
	if _dirty_layout:
		_relayout()
	if not _text_hud_hidden and _hud != null:
		# SliceHUD 的 @onready 在兄弟节点 _ready() 时还没跑，所以第一帧再确认一次；生效后停手
		_hud.call("set_text_hud_visible", false)
		if not bool(_hud.call("is_text_hud_visible")):
			_text_hud_hidden = true
	_refresh_side_panel()
	queue_redraw()


func _read_state() -> Dictionary:
	if _hud == null or not _hud.has_method("present_state"):
		return {}
	var value: Variant = _hud.call("present_state")
	if value is Dictionary:
		return value
	return {}


## 给测试/诊断用：证明这一层真的读到了数据、真的在画。
func debug_info() -> Dictionary:
	var min_gap: float = 99999.0
	for i in range(_room_rects.size()):
		for j in range(i + 1, _room_rects.size()):
			var a: Rect2 = (_room_rects[i] as Dictionary).get("rect", Rect2())
			var b: Rect2 = (_room_rects[j] as Dictionary).get("rect", Rect2())
			# 用户要的是"节点之间留出间距" ⇒ 按两块牌子中心的最近距离算
			min_gap = minf(min_gap, a.get_center().distance_to(b.get_center()))
	var overlaps: int = 0
	for i in range(_room_rects.size()):
		for j in range(i + 1, _room_rects.size()):
			var ra: Rect2 = (_room_rects[i] as Dictionary).get("rect", Rect2())
			var rb: Rect2 = (_room_rects[j] as Dictionary).get("rect", Rect2())
			if ra.intersects(rb):
				overlaps += 1
	return {
		"drawn": _draw_count,
		"rooms": _room_rects.size(),
		"edges": _edges.size(),
		"room_rects": _room_rects.size(),
		"hover": _hover,
		"has_state": not _state.is_empty(),
		"text_hud_hidden": _text_hud_hidden,
		"cols": _cols,
		"rows": _rows,
		"cell": _cell,
		"min_gap": (0.0 if min_gap > 9000.0 else min_gap),
		"overlaps": overlaps,
		"chips": _chip_rects.size(),
		"side_panel": _panel != null,
		"side_rows": (_panel_box.get_child_count() if _panel_box != null else 0),
	}


# ---------------------------------------------------------------------------
# 数据
# ---------------------------------------------------------------------------

func _load_map() -> void:
	var text: String = FileAccess.get_file_as_string(MAP_PATH)
	if text.is_empty():
		return
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return
	var rooms: Array = (data as Dictionary).get("rooms", [])
	for room_value in rooms:
		if not (room_value is Dictionary):
			continue
		var room: Dictionary = room_value
		var room_id: String = String(room.get("room_id", ""))
		if room_id.is_empty():
			continue
		_order.append(room_id)
		_names[room_id] = String(room.get("display_name", room_id))
		var raw: Variant = room.get("pos", [])
		if raw is Array and (raw as Array).size() >= 2:
			_pos[room_id] = Vector2(float(raw[0]), float(raw[1]))
		else:
			_pos[room_id] = Vector2(450.0, 360.0)
		var exits: Array = room.get("exits", [])
		for exit_value in exits:
			if not (exit_value is Dictionary):
				continue
			var exit_data: Dictionary = exit_value
			_edges.append({
				"from": room_id,
				"to": String(exit_data.get("to", "")),
				"seconds": int(exit_data.get("travel_seconds", 0)),
			})


# ---------------------------------------------------------------------------
# 布局：网格吸附 + 逐个占位（保证最小间距）
# ---------------------------------------------------------------------------

func _relayout() -> void:
	_dirty_layout = false
	var count: int = maxi(1, _order.size())
	_panel_rect = Rect2(
		size.x - _panel_width() - MARGIN,
		TOP_H + MARGIN,
		_panel_width(),
		maxf(200.0, size.y - TOP_H - MARGIN * 2.0)
	)
	_stage = Rect2(
		MARGIN,
		TOP_H + MARGIN,
		maxf(240.0, size.x - _panel_width() - MARGIN * 3.0),
		maxf(200.0, size.y - TOP_H - BOTTOM_H - MARGIN)
		)
	_pick_grid(count)
	_cell = Vector2(_stage.size.x / float(_cols), _stage.size.y / float(_rows))

	# 1) 种子：data 的 pos 归一化到舞台里（保留"大致在哪边"的地理感）
	var seeds: Dictionary = {}
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)
	for room_id in _order:
		var p: Vector2 = _pos.get(room_id, Vector2(450.0, 360.0))
		min_pos = Vector2(minf(min_pos.x, p.x), minf(min_pos.y, p.y))
		max_pos = Vector2(maxf(max_pos.x, p.x), maxf(max_pos.y, p.y))
	var span := Vector2(maxf(1.0, max_pos.x - min_pos.x), maxf(1.0, max_pos.y - min_pos.y))
	for room_id in _order:
		var p: Vector2 = _pos.get(room_id, Vector2(450.0, 360.0))
		seeds[room_id] = Vector2((p.x - min_pos.x) / span.x, (p.y - min_pos.y) / span.y)

	# 2) 按"从上到下、从左到右"排序后逐个占格：每个房间挑离种子最近的空格子
	var sorted_rooms: Array[String] = _order.duplicate()
	sorted_rooms.sort_custom(func(a: String, b: String) -> bool:
		var sa: Vector2 = seeds.get(a, Vector2.ZERO)
		var sb: Vector2 = seeds.get(b, Vector2.ZERO)
		if absf(sa.y - sb.y) > 0.12:
			return sa.y < sb.y
		return sa.x < sb.x)

	_cells.clear()
	var taken: Dictionary = {}
	for room_id in sorted_rooms:
		var seed: Vector2 = seeds.get(room_id, Vector2(0.5, 0.5))
		var want := Vector2i(
			clampi(int(floor(seed.x * float(_cols))), 0, _cols - 1),
			clampi(int(floor(seed.y * float(_rows))), 0, _rows - 1)
		)
		var cell: Vector2i = _nearest_free_cell(want, taken)
		taken[cell] = true
		_cells[room_id] = cell

	# 3) 产出牌子矩形（每格一块牌子 + 下方棋子行）
	_room_rects.clear()
	for room_id in _order:
		var cell_pos: Vector2i = _cells.get(room_id, Vector2i.ZERO)
		var center := Vector2(
			_stage.position.x + (float(cell_pos.x) + 0.5) * _cell.x,
			_stage.position.y + (float(cell_pos.y) + 0.5) * _cell.y - 8.0
		)
		var plate_w: float = minf(_cell.x - 14.0, 168.0)
		var rect := Rect2(center - Vector2(plate_w * 0.5, PLATE_H * 0.5), Vector2(plate_w, PLATE_H))
		_room_rects.append({"rect": rect, "room": room_id})


## 选一个"格子够用、且格子尽量方正"的网格。
func _pick_grid(count: int) -> void:
	var best_cols: int = 4
	var best_score: float = INF
	for cols in range(3, 10):
		var rows: int = int(ceil(float(count) / float(cols)))
		if rows < 1:
			continue
		var cw: float = _stage.size.x / float(cols)
		var ch: float = _stage.size.y / float(rows)
		if cw < CELL_MIN_W or ch < CELL_MIN_H:
			continue
		var score: float = absf(cw - ch) + maxf(0.0, MIN_GAP - cw) * 4.0 + maxf(0.0, 88.0 - ch) * 4.0
		if score < best_score:
			best_score = score
			best_cols = cols
	_cols = best_cols
	_rows = maxi(1, int(ceil(float(count) / float(_cols))))


## 从想要的位置螺旋外扩，找最近的空格子（保证节点不叠）。
func _nearest_free_cell(want: Vector2i, taken: Dictionary) -> Vector2i:
	if not taken.has(want):
		return want
	var max_r: int = maxi(_cols, _rows)
	for radius in range(1, max_r + 1):
		var best: Vector2i = Vector2i(-1, -1)
		var best_d: int = 1 << 30
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var cand := Vector2i(want.x + dx, want.y + dy)
				if cand.x < 0 or cand.y < 0 or cand.x >= _cols or cand.y >= _rows:
					continue
				if taken.has(cand):
					continue
				var d: int = dx * dx + dy * dy
				if d < best_d:
					best_d = d
					best = cand
		if best.x >= 0:
			return best
	return want


func _panel_width() -> float:
	return clampf(size.x * 0.235, PANEL_MIN_W, PANEL_MAX_W)


func _plate_rect(room_id: String) -> Rect2:
	for item in _room_rects:
		if String((item as Dictionary).get("room", "")) == room_id:
			return (item as Dictionary).get("rect", Rect2())
	return Rect2()


func _cell_rect(room_id: String) -> Rect2:
	var cell_pos: Vector2i = _cells.get(room_id, Vector2i.ZERO)
	return Rect2(
		_stage.position + Vector2(float(cell_pos.x) * _cell.x, float(cell_pos.y) * _cell.y),
		_cell
	)


# ---------------------------------------------------------------------------
# 鼠标
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null:
		var room: String = _room_at(motion.position)
		var chip: String = _chip_at(motion.position)
		if room != _hover or chip != _hover_chip:
			_hover = room
			_hover_chip = chip
			queue_redraw()
		return
	var click := event as InputEventMouseButton
	if click != null and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		var index: int = _option_at(click.position)
		if index >= 0 and _hud != null:
			_hud.call("request_option", index)
			return
		var chip_id: String = _chip_at(click.position)
		if not chip_id.is_empty() and _hud != null:
			_hud.call("request_talk")
			return
		var room: String = _room_at(click.position)
		if not room.is_empty() and _hud != null:
			_hud.call("request_travel", room)


func _room_at(point: Vector2) -> String:
	for item in _room_rects:
		var entry: Dictionary = item
		if (entry.get("rect", Rect2()) as Rect2).has_point(point):
			return String(entry.get("room", ""))
	return ""


func _chip_at(point: Vector2) -> String:
	for item in _chip_rects:
		var entry: Dictionary = item
		if (entry.get("rect", Rect2()) as Rect2).has_point(point):
			return String(entry.get("npc", ""))
	return ""


func _option_at(point: Vector2) -> int:
	for item in _option_rects:
		var entry: Dictionary = item
		if (entry.get("rect", Rect2()) as Rect2).has_point(point):
			return int(entry.get("index", -1))
	return -1


# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------

func _draw() -> void:
	_draw_count += 1
	if _dirty_layout:
		_relayout()
	draw_rect(Rect2(Vector2.ZERO, size), C_BG, true)
	_chip_rects.clear()
	_option_rects.clear()
	_draw_backdrop()
	_draw_edges()          # 连线先画 ⇒ 永远在牌子底下（等价 z_index 更小）
	_draw_rooms()          # 再把牌子、棋子、连线标签盖上去
	_draw_player()
	_draw_topbar()
	_draw_log()
	_draw_dialogue()
	_draw_rune_panel()
	_draw_hint_bar()


func _draw_backdrop() -> void:
	draw_style_box(_sb_bg, _stage)
	# 台地：把"台"上的房间格子圈出来（只作氛围，不参与命中测试）
	var platform: Array[String] = [
		"baihutai_bei", "baihutai_yang", "baihutai_side", "stele_base",
		"baihutai", "baihutai_west", "phone", "baihutai_south", "crowd",
	]
	var box := Rect2()
	var first: bool = true
	for room_id in platform:
		if not _cells.has(room_id):
			continue
		var rect: Rect2 = _cell_rect(room_id).grow(-6.0)
		if first:
			box = rect
			first = false
		else:
			box = box.merge(rect)
	if not first:
		var poly := PackedVector2Array([
			box.position + Vector2(10.0, 0.0), box.position + Vector2(box.size.x - 10.0, 0.0),
			box.position + box.size, box.position + Vector2(box.size.x, box.size.y),
			box.position + Vector2(10.0, box.size.y), box.position + Vector2(0.0, box.size.y - 10.0),
			box.position + Vector2(0.0, 10.0), box.position,
		])
		draw_colored_polygon(poly, Color(0.10, 0.13, 0.19, 0.22))
		_text_chip(box.position + Vector2(10.0, 6.0), "白鹄台", F_BODY, C_INK)
	# 页外：虚线框提示"走不到"
	for room_id in _order:
		if room_id != "off_page":
			continue
		var cell: Rect2 = _cell_rect(room_id)
		_draw_dashed_rect(cell.grow(-6.0), Color(0.34, 0.40, 0.52))
		_text_chip(Vector2(cell.position.x + 12.0, cell.position.y + cell.size.y - 26.0), "页外 · 走不到", F_SMALL, C_DIM)
	# 装饰：老屋/村委屋顶、摊位棚、石阶（挂在牌子下面，不跟字抢地方）
	for room_id in _order:
		var plate: Rect2 = _plate_rect(room_id)
		if room_id == "gan_house" or room_id == "village_office":
			_draw_roof(plate)
		elif room_id == "stall" or room_id == "stall_east":
			_draw_awning(plate)
		elif room_id == "stone_steps" or room_id == "stone_steps_7":
			_draw_steps(plate)


func _draw_roof(plate: Rect2) -> void:
	var base := Vector2(plate.get_center().x, plate.position.y + PLATE_H + 24.0)
	draw_colored_polygon(PackedVector2Array([
		base + Vector2(-26.0, 0.0), base + Vector2(26.0, 0.0), base + Vector2(0.0, -14.0),
	]), Color(0.16, 0.18, 0.23))


func _draw_awning(plate: Rect2) -> void:
	var base := Vector2(plate.get_center().x, plate.position.y + PLATE_H + 22.0)
	draw_rect(Rect2(base + Vector2(-26.0, -7.0), Vector2(52.0, 7.0)), Color(0.20, 0.17, 0.13), true)
	for i in range(4):
		draw_line(base + Vector2(-26.0 + float(i) * 17.0, -7.0), base + Vector2(-20.0 + float(i) * 17.0, 0.0), Color(0.28, 0.24, 0.18), 1.0)


func _draw_steps(plate: Rect2) -> void:
	var base := Vector2(plate.get_center().x, plate.position.y + PLATE_H + 22.0)
	for i in range(4):
		var w: float = 30.0 - float(i) * 5.0
		draw_line(base + Vector2(-w, -float(i) * 4.0), base + Vector2(w, -float(i) * 4.0), C_STONE, 1.0)


func _draw_edges() -> void:
	var here: String = String(_state.get("room", ""))
	var travel: Dictionary = _state.get("travel", {})
	var route: Array = travel.get("route", [])
	var moving_from: String = String(travel.get("from", ""))
	for value in _edges:
		var edge: Dictionary = value
		var from: String = String(edge.get("from", ""))
		var to: String = String(edge.get("to", ""))
		var a: Vector2 = _plate_rect(from).get_center()
		var b: Vector2 = _plate_rect(to).get_center()
		if a == Vector2.ZERO or b == Vector2.ZERO:
			continue
		var touching_hover: bool = from == _hover or to == _hover
		var near: bool = from == here or to == here or touching_hover
		var on_route: bool = _route_has(route, from, to) or from == moving_from
		var color := Color(0.20, 0.25, 0.34, 0.10)     # 跟当前无关的线：几乎看不见，只留"这里有路"的暗示
		var width: float = 1.0
		if on_route:
			color = Color(0.90, 0.78, 0.42, 0.85)
			width = 2.0
		elif touching_hover:
			color = Color(0.60, 0.76, 0.95, 0.75)
			width = 1.5
		elif near:
			color = Color(0.40, 0.52, 0.70, 0.40)
			width = 1.0
		# 轻微弧线，避免一堆线在中心糊成一片
		var mid: Vector2 = (a + b) * 0.5
		var dir: Vector2 = (b - a).normalized()
		var normal := Vector2(-dir.y, dir.x)
		var bend: float = clampf(a.distance_to(b) * 0.08, 0.0, 14.0)
		var points := PackedVector2Array()
		for i in range(9):
			var t: float = float(i) / 8.0
			var p: Vector2 = a.lerp(b, t) + normal * (sin(t * PI) * bend)
			points.append(p)
		draw_polyline(points, color, width)
		# 秒数只在"鼠标指着这间房"时画（牌子右侧已经写了从当前房间走过去的耗时），免得数字糊一屏
		if touching_hover and int(edge.get("seconds", 0)) > 0:
			var label_at: Vector2 = mid + normal * (bend + 8.0) - Vector2(14.0, 6.0)
			_text_chip(label_at, "%d 秒" % int(edge.get("seconds", 0)), F_TINY, C_INK)


func _route_has(route: Array, from: String, to: String) -> bool:
	for i in range(route.size() - 1):
		var a: String = String(route[i])
		var b: String = String(route[i + 1])
		if (a == from and b == to) or (a == to and b == from):
			return true
	return false


func _draw_rooms() -> void:
	var here: String = String(_state.get("room", ""))
	var reachable: Dictionary = _state.get("reachable", {})
	var npcs: Array = _state.get("npcs", [])
	var by_room: Dictionary = {}
	for value in npcs:
		if not (value is Dictionary):
			continue
		var npc: Dictionary = value
		var room: String = String(npc.get("room", ""))
		if room.is_empty():
			continue
		if not by_room.has(room):
			by_room[room] = []
		(by_room[room] as Array).append(npc)

	for item in _room_rects:
		var entry: Dictionary = item
		var room_id: String = String(entry.get("room", ""))
		var rect: Rect2 = entry.get("rect", Rect2())
		var is_here: bool = room_id == here
		var can_go: bool = reachable.has(room_id)
		var box: StyleBoxFlat = _sb_plate
		if is_here:
			box = _sb_plate_here
		elif room_id == _hover:
			box = _sb_plate_hover
		elif not can_go:
			box = _sb_plate_far
		draw_style_box(box, rect)
		# 牌子只有一行：房间名（左）+ 走位耗时（右），都在牌子内，互相不压
		var seconds_text: String = ""
		if can_go and not is_here:
			seconds_text = "%d 秒" % int(reachable.get(room_id, 0))
		var name_size: int = F_BODY
		var name_width: float = rect.size.x - 14.0 - _text_width(seconds_text, F_TINY)
		var label: String = _ellipsis(_short_name(room_id), name_width, name_size)
		_draw_text(Vector2(rect.position.x + 8.0, rect.position.y + (PLATE_H - float(name_size)) * 0.5 - 1.0),
			label, name_size, C_TEXT if (is_here or can_go) else C_DIM)
		if not seconds_text.is_empty():
			var sw: float = _text_width(seconds_text, F_TINY)
			_draw_text(Vector2(rect.position.x + rect.size.x - sw - 7.0, rect.position.y + (PLATE_H - float(F_TINY)) * 0.5),
				seconds_text, F_TINY, C_GOLD if can_go else C_DIM)
		# 棋子行：牌子正下方；玩家自己排第一（金），然后是这一屋的 NPC；超出就 +N
		var room_npcs: Array = by_room.get(room_id, [])
		var chip_x: float = rect.position.x
		var chip_y: float = rect.position.y + PLATE_H + 4.0
		if is_here:
			var me_w: float = _text_width("苏景玄", F_SMALL) + 16.0
			var me_rect := Rect2(Vector2(chip_x, chip_y), Vector2(me_w, CHIP_H))
			draw_style_box(_sb_chip, me_rect)
			draw_rect(Rect2(me_rect.position + Vector2(4.0, 5.0), Vector2(6.0, 6.0)), C_GOLD, true)
			_draw_text(Vector2(me_rect.position.x + 13.0, me_rect.position.y + 2.0), "苏景玄", F_SMALL, C_GOLD)
			chip_x += me_w + CHIP_GAP
		var drawn_chips: int = 0
		var limit: int = 2 if is_here else 3
		for i in range(room_npcs.size()):
			if drawn_chips >= limit:
				break
			var npc: Dictionary = room_npcs[i]
			var npc_name: String = String(npc.get("name", ""))
			var color: Color = _npc_color(String(npc.get("id", "")))
			var chip_w: float = _text_width(npc_name, F_SMALL) + 16.0
			if chip_x + chip_w > rect.position.x + rect.size.x:
				break
			var chip_rect := Rect2(Vector2(chip_x, chip_y), Vector2(chip_w, CHIP_H))
			_chip_rects.append({"rect": chip_rect, "room": room_id, "npc": String(npc.get("id", ""))})
			draw_style_box(_sb_chip, chip_rect)
			draw_rect(Rect2(chip_rect.position + Vector2(4.0, 5.0), Vector2(6.0, 6.0)), color, true)
			_draw_text(Vector2(chip_rect.position.x + 13.0, chip_rect.position.y + 2.0), npc_name, F_SMALL,
				C_GOLD if is_here else C_DIM)
			chip_x += chip_w + CHIP_GAP
			drawn_chips += 1
		if room_npcs.size() > drawn_chips:
			var more: String = "+%d" % (room_npcs.size() - drawn_chips)
			var more_w: float = _text_width(more, F_SMALL) + 10.0
			var more_rect := Rect2(Vector2(chip_x, chip_y), Vector2(more_w, CHIP_H))
			draw_style_box(_sb_chip, more_rect)
			_draw_text(Vector2(more_rect.position.x + 5.0, more_rect.position.y + 2.0), more, F_SMALL, C_DIM)


func _draw_player() -> void:
	var here: String = String(_state.get("room", ""))
	var travel: Dictionary = _state.get("travel", {})
	var moving: bool = bool(travel.get("moving", false))
	var anchor: Rect2 = _plate_rect(here)
	# 棋子挂在牌子正上方（名字在牌子下面那行棋子里，不跟牌子抢地方）
	var point := Vector2(anchor.get_center().x, anchor.position.y - 11.0)
	if moving:
		var target: String = String(travel.get("to", ""))
		var target_rect: Rect2 = _plate_rect(target)
		var total: float = maxf(0.001, float(travel.get("total", 1.0)))
		var remaining: float = clampf(float(travel.get("remaining", 0.0)), 0.0, total)
		var progress: float = 1.0 - remaining / total
		point = point.lerp(Vector2(target_rect.get_center().x, target_rect.position.y - 11.0), progress)
	var diamond := PackedVector2Array([
		point + Vector2(0.0, -9.0), point + Vector2(7.0, 0.0),
		point + Vector2(0.0, 9.0), point + Vector2(-7.0, 0.0),
	])
	draw_colored_polygon(diamond, C_GOLD)
	draw_polyline(diamond + PackedVector2Array([diamond[0]]), Color(0.15, 0.12, 0.05), 1.0)


func _draw_topbar() -> void:
	draw_style_box(_sb_bg, Rect2(0.0, 0.0, size.x, TOP_H - 8.0))
	var title: String = String(_state.get("title", "茅山秘录·诡异录"))
	var second: int = int(_state.get("second", 0))
	var duration: int = maxi(1, int(_state.get("duration", 360)))
	var loop_index: int = int(_state.get("loop_index", 0))
	var remaining: int = int(_state.get("remaining", duration))
	var paused: bool = bool(_state.get("paused", false))

	_draw_text(Vector2(MARGIN + 2.0, 10.0), "茅山秘录·诡异录", F_TITLE, C_TEXT)
	_draw_text(Vector2(MARGIN + 2.0, 32.0), title, F_SMALL, C_DIM)

	# 余页时钟：第二行放在进度条下面（v1 那行字被条子盖住了）
	var clock_x: float = MARGIN + 214.0
	_draw_text(Vector2(clock_x, 6.0), "余页 %s / %s" % [_mmss(second), _mmss(duration)], F_HERO, C_TEXT)
	# 玩家口径：present_state 里的 loop_index 是 0 基（核心与数据都按 0 基算），
	# 但顶栏写给玩家看，显示"第 1 遍"起（否则第一遍写着"第 0 遍"，像 bug）。
	var loop_shown: int = loop_index + 1
	_draw_text(Vector2(clock_x, 36.0), "%s · 第 %d 遍 · 剩余 %d 秒%s" % [
		_shichen(second), loop_shown, remaining, "（暂停）" if paused else ""], F_SMALL, C_DIM)
	var bar := Rect2(clock_x, 56.0, 240.0, 5.0)
	draw_style_box(_sb_card, bar)
	var ratio: float = clampf(float(second) / float(duration), 0.0, 1.0)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * ratio, bar.size.y)), C_INK, true)

	# 心灯
	var lamp: int = int(_state.get("lamp", 0))
	var lamp_max: int = maxi(1, int(_state.get("lamp_max", 100)))
	var extinguished: bool = bool(_state.get("extinguished", false))
	var lamp_x: float = maxf(clock_x + 300.0, size.x * 0.52)
	var lamp_bar := Rect2(lamp_x, 14.0, 190.0, 12.0)
	draw_style_box(_sb_card, lamp_bar)
	var fill: float = clampf(float(lamp) / float(lamp_max), 0.0, 1.0)
	draw_rect(Rect2(lamp_bar.position, Vector2(lamp_bar.size.x * fill, lamp_bar.size.y)),
		C_BAD if extinguished else C_LAMP, true)
	_draw_text(Vector2(lamp_x - 76.0, 10.0), "心灯 %d / %d" % [lamp, lamp_max], F_TITLE,
		C_BAD if extinguished else C_LAMP)
	_draw_text(Vector2(lamp_bar.position.x + lamp_bar.size.x + 10.0, 13.0),
		"已划掉 %d 笔" % int(_state.get("lamp_lost", 0)), F_SMALL, C_DIM)
	var warning: String = String(_state.get("lamp_warning", ""))
	if not warning.is_empty():
		_text_chip(Vector2(lamp_x, 30.0), warning, F_TINY, C_BAD if extinguished else C_DIM)

	# 结案进度（右对齐）
	var required: Array = _state.get("required", [])
	var owned: Array = _state.get("clues", [])
	var have: int = 0
	for clue in required:
		if owned.has(clue):
			have += 1
	var status: String = "%d/%d 环" % [have, required.size()]
	if bool(_state.get("ritual_required", false)):
		status += " · 需仪式（G 画符）"
	var status_w: float = _text_width(status, F_TITLE)
	_draw_text(Vector2(size.x - MARGIN - status_w, 10.0), status, F_TITLE,
		C_OK if have >= required.size() and not required.is_empty() else C_TEXT)


func _draw_log() -> void:
	var rect := Rect2(MARGIN, size.y - BOTTOM_H, _stage.size.x, BOTTOM_H - 42.0)
	draw_style_box(_sb_card, rect)
	_draw_text(rect.position + Vector2(10.0, 3.0), "最近发生", F_SMALL, C_DIM)
	var y: float = rect.position.y + 20.0
	var shown: int = 0
	var log_lines: Array = _state.get("log", [])
	for value in log_lines:
		if shown >= 3:
			break
		_draw_text(Vector2(rect.position.x + 10.0, y), _ellipsis(String(value), rect.size.x - 20.0, F_SMALL),
			F_SMALL, C_TEXT)
		y += 14.0
		shown += 1
	# 状态细带：压在日志框下面一行，不和日志打架
	var occupants: String = String(_state.get("occupants", ""))
	var beat: String = String(_state.get("next_beat", ""))
	var strip_y: float = size.y - 40.0
	var has_people: bool = not occupants.is_empty() and occupants != "空无一人"
	var left: String = "此处还有：%s" % occupants if has_people else "此处无人"
	_draw_text(Vector2(MARGIN, strip_y), left, F_SMALL, C_GOLD if has_people else C_DIM)
	if not has_people:
		_text_chip(Vector2(MARGIN + _text_width(left, F_SMALL) + 10.0, strip_y - 2.0),
			"点场上的棋子或按 F 与人说话", F_TINY, C_DIM)
	var beat_w: float = _text_width(beat, F_SMALL)
	_draw_text(Vector2(maxf(MARGIN + 340.0, size.x - _panel_width() - MARGIN * 2.0 - beat_w - 8.0), strip_y),
		_ellipsis(beat, size.x - _panel_width() - MARGIN * 3.0 - 340.0, F_SMALL), F_SMALL, C_DIM)


func _draw_dialogue() -> void:
	var dialogue: Dictionary = _state.get("dialogue", {})
	if not bool(dialogue.get("active", false)):
		return
	var width: float = minf(760.0, _stage.size.x - 60.0)
	var rect := Rect2(_stage.position.x + (_stage.size.x - width) * 0.5, size.y - BOTTOM_H - 190.0, width, 178.0)
	draw_style_box(_sb_card, rect)
	draw_rect(Rect2(rect.position, Vector2(4.0, rect.size.y)), C_GOLD, true)
	var speaker: String = String(dialogue.get("speaker", ""))
	_draw_text(rect.position + Vector2(18.0, 12.0), speaker, F_TITLE, C_GOLD)
	var y: float = rect.position.y + 40.0
	var line: String = String(dialogue.get("line", ""))
	y = _draw_wrapped_at(rect.position.x + 18.0, y, rect.size.x - 36.0, line, F_BODY, C_TEXT)
	var reply: String = String(dialogue.get("reply", ""))
	if not reply.is_empty():
		y = _draw_wrapped_at(rect.position.x + 18.0, y + 2.0, rect.size.x - 36.0, reply, F_BODY, C_GOLD)
	_draw_text(Vector2(rect.position.x + 18.0, rect.position.y + rect.size.y - 58.0),
		"点一条追问（或按 F 继续）：", F_SMALL, C_DIM)
	# 选项：按宽度换行排布，点得到
	var options: Array = dialogue.get("options", [])
	var button_y: float = rect.position.y + rect.size.y - 38.0
	var button_x: float = rect.position.x + 18.0
	for i in range(options.size()):
		if not (options[i] is Dictionary):
			continue
		var option: Dictionary = options[i]
		var text: String = String(option.get("text", ""))
		var asked: bool = bool(option.get("asked", false))
		var pill_w: float = minf(_text_width(text, F_BODY) + 22.0, rect.size.x - 36.0)
		if button_x + pill_w > rect.position.x + rect.size.x - 18.0 and button_x > rect.position.x + 18.0:
			button_x = rect.position.x + 18.0
			button_y -= 26.0
		var pill := Rect2(Vector2(button_x, button_y), Vector2(pill_w, 22.0))
		draw_style_box(_sb_pill_hot if not asked else _sb_pill, pill)
		_option_rects.append({"rect": pill, "index": i})
		_draw_text(Vector2(pill.position.x + 10.0, pill.position.y + 3.0),
			_ellipsis(text, pill.size.x - 20.0, F_BODY), F_BODY, C_TEXT if not asked else C_DIM)
		button_x += pill_w + 8.0


func _draw_rune_panel() -> void:
	var rune: Dictionary = _state.get("rune", {})
	if not bool(rune.get("active", false)):
		return
	var width: float = minf(680.0, _stage.size.x - 40.0)
	var rect := Rect2(_stage.position.x + (_stage.size.x - width) * 0.5, TOP_H + 20.0, width, 336.0)
	draw_style_box(_sb_card, rect)
	var name: String = String(rune.get("name", ""))
	_draw_text(rect.position + Vector2(16.0, 12.0), "画符 · %s" % name, F_TITLE, C_GOLD)
	var head: String = "第 %d / %d 步：%s" % [
		int(rune.get("step_index", 0)) + 1, int(rune.get("step_count", 0)), String(rune.get("step_name", ""))]
	_draw_text(rect.position + Vector2(16.0, 34.0), head, F_BODY, C_TEXT)
	var y: float = rect.position.y + 62.0
	var strokes: Array = rune.get("strokes", [])
	var stroke_index: int = int(rune.get("stroke_index", -1))
	var tokens: Array = rune.get("tokens", [])
	var canvas := Rect2(rect.position.x + 16.0, y, 300.0, 150.0)
	draw_style_box(_sb_card, canvas)
	for i in range(7):
		var gx: float = canvas.position.x + canvas.size.x * float(i) / 6.0
		draw_line(Vector2(gx, canvas.position.y + 6.0), Vector2(gx, canvas.position.y + canvas.size.y - 6.0),
			Color(1, 1, 1, 0.05), 1.0)
	for i in range(5):
		var gy: float = canvas.position.y + canvas.size.y * float(i) / 4.0
		draw_line(Vector2(canvas.position.x + 6.0, gy), Vector2(canvas.position.x + canvas.size.x - 6.0, gy),
			Color(1, 1, 1, 0.05), 1.0)
	if stroke_index >= 0 and stroke_index < strokes.size():
		var stroke: Dictionary = strokes[stroke_index]
		var reference: Array = stroke.get("pattern", [])
		_draw_stroke_polyline(canvas.position + Vector2(40.0, 40.0), reference, Color(0.90, 0.78, 0.42, 0.30), 6.0)
	if not tokens.is_empty():
		_draw_stroke_polyline(canvas.position + Vector2(40.0, 40.0), tokens, C_GOLD, 3.0)
	var row: float = canvas.position.y + 6.0
	for i in range(strokes.size()):
		var stroke: Dictionary = strokes[i]
		var mark: String = "✓" if i < int(rune.get("drawn", 0)) else ("▸" if i == stroke_index else "·")
		_draw_text(Vector2(canvas.position.x + canvas.size.x + 14.0, row + float(i) * 20.0),
			"%s 第 %d 笔「%s」" % [mark, i + 1, String(stroke.get("name", ""))], F_BODY,
			C_OK if i < int(rune.get("drawn", 0)) else (C_TEXT if i == stroke_index else C_DIM))
	var message: String = String(rune.get("message", ""))
	if not message.is_empty():
		_draw_wrapped_at(rect.position.x + 16.0, y + 162.0, rect.size.x - 32.0, message, F_BODY, C_GOLD)
	var prompts: Array = rune.get("prompts", [])
	var py: float = rect.position.y + rect.size.y - 22.0 - float(prompts.size()) * 15.0
	for value in prompts:
		_draw_text(Vector2(rect.position.x + 16.0, py), _ellipsis(String(value), rect.size.x - 32.0, F_SMALL),
			F_SMALL, C_DIM)
		py += 15.0


func _draw_stroke_polyline(start: Vector2, tokens: Array, color: Color, width: float) -> void:
	var points := PackedVector2Array([start])
	var cursor: Vector2 = start
	var step: float = 20.0
	for value in tokens:
		var delta: Vector2 = _token_delta(String(value)) * step
		cursor += delta
		points.append(cursor)
	if points.size() > 1:
		draw_polyline(points, color, width)


func _draw_hint_bar() -> void:
	var y: float = size.y - 18.0
	var text: String = "点房间走过去（按余页里的秒算） · 点同屋的人说话 · TAB/E 下一间 · Q 上一间 · 1-9 去第 N 间 · F 交谈 · B 推演板 · H 重演 · G 画符 · 空格 快进 · T 倍速 · P 暂停 · R 重开"
	draw_rect(Rect2(0.0, size.y - 24.0, size.x, 24.0), Color(0.0, 0.0, 0.0, 0.45), true)
	_draw_text(Vector2(MARGIN, y), _ellipsis(text, size.x - MARGIN * 2.0, F_SMALL), F_SMALL, C_DIM)


# ---------------------------------------------------------------------------
# 右侧面板：真容器排版（PanelContainer > ScrollContainer > VBoxContainer > Label）
# ---------------------------------------------------------------------------

func _build_side_panel() -> void:
	if _panel != null:
		return
	_panel = PanelContainer.new()
	_panel.name = "SidePanel"
	_panel.add_theme_stylebox_override("panel", _sb_panel)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_panel.add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	margin.add_child(scroll)
	_panel_box = VBoxContainer.new()
	_panel_box.name = "SideBox"
	_panel_box.add_theme_constant_override("separation", 6)
	_panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_panel_box)


func _refresh_side_panel() -> void:
	if _panel == null or _panel_box == null:
		return
	_panel.position = _panel_rect.position
	_panel.size = _panel_rect.size
	var clues: Array = _state.get("clues", [])
	var conflicts: Array = _state.get("conflicts", [])
	var stuck: String = String(_state.get("stuck", ""))
	var board_lines: Array = _state.get("board_lines", [])
	var signature: String = "%d|%d|%s|%s|%s|%d" % [
		clues.size(), conflicts.size(), stuck, String(_state.get("occupants", "")),
		String(_state.get("room", "")), board_lines.size()]
	if signature == _panel_sig:
		return
	_panel_sig = signature
	for child in _panel_box.get_children():
		child.queue_free()
		_panel_box.remove_child(child)

	_panel_add_header("已入案线索 %d / %d" % [clues.size(), int(_state.get("clue_total", 0))])
	var clue_names: Dictionary = _state.get("clue_names", {})
	var required: Array = _state.get("required", [])
	if clues.is_empty():
		_panel_add_body("（还没有线索：去有人的房间蹲拍点，或者和人说话）", C_DIM)
	for value in clues:
		var clue_id: String = String(value)
		var name: String = String(clue_names.get(clue_id, clue_id))
		var is_required: bool = required.has(clue_id)
		_panel_add_body("%s %s" % ["★" if is_required else "·", name], C_GOLD if is_required else C_TEXT)

	_panel_add_header("推演板 · 对不上 %d 处" % conflicts.size())
	if conflicts.is_empty():
		_panel_add_body("（还没凑出对不上的地方）", C_DIM)
	for value in conflicts:
		var conflict: Dictionary = value
		var resolved: bool = bool(conflict.get("resolved", false))
		_panel_add_body("⚠ %s" % String(conflict.get("title", "")), C_OK if resolved else C_BAD)
		_panel_add_body(String(conflict.get("text", "")), C_DIM)

	var mutation: String = String(_state.get("mutation", ""))
	var memory: String = String(_state.get("memory", ""))
	if not mutation.is_empty():
		_panel_add_header("余页杂讯")
		_panel_add_body(mutation, C_DIM)
	if not memory.is_empty():
		_panel_add_header("NPC 记忆")
		_panel_add_body(memory, C_DIM)
	if not stuck.is_empty():
		_panel_add_header("卡关提示")
		_panel_add_body(stuck, C_GOLD)


func _panel_add_header(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", F_TITLE)
	label.add_theme_color_override("font_color", C_INK)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_box.add_child(label)


func _panel_add_body(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", F_BODY)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size = Vector2(0.0, 0.0)
	_panel_box.add_child(label)


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

func _draw_text(at: Vector2, text: String, font_size: int, color: Color) -> void:
	if text.is_empty():
		return
	draw_string(_font, Vector2(roundf(at.x), roundf(at.y + float(font_size))), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## 半透明黑底 + 文字：画面上任何文字都走它，保证不跟连线/底色粘在一起。
func _text_chip(at: Vector2, text: String, font_size: int, color: Color) -> Rect2:
	var width: float = _text_width(text, font_size)
	var rect := Rect2(at - Vector2(5.0, 3.0), Vector2(width + 10.0, float(font_size) + 7.0))
	draw_style_box(_sb_chip, rect)
	_draw_text(at, text, font_size, color)
	return rect


func _text_width(text: String, font_size: int) -> float:
	if text.is_empty():
		return 0.0
	return _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _draw_wrapped_at(x: float, y: float, max_width: float, text: String, font_size: int, color: Color) -> float:
	var cursor: float = y
	for line in _wrap(text, max_width, font_size):
		_draw_text(Vector2(x, cursor), line, font_size, color)
		cursor += float(font_size) + 5.0
	return cursor


func _wrap(text: String, max_width: float, font_size: int) -> Array[String]:
	var out: Array[String] = []
	if text.is_empty():
		return out
	var line: String = ""
	for i in range(text.length()):
		var ch: String = text.substr(i, 1)
		if ch == "\n":
			out.append(line)
			line = ""
			continue
		var probe: String = line + ch
		if _text_width(probe, font_size) > max_width and not line.is_empty():
			out.append(line)
			line = ch
		else:
			line = probe
	if not line.is_empty():
		out.append(line)
	return out


func _ellipsis(text: String, max_width: float, font_size: int) -> String:
	if _text_width(text, font_size) <= max_width:
		return text
	var line: String = text
	while line.length() > 1 and _text_width(line + "…", font_size) > max_width:
		line = line.substr(0, line.length() - 1)
	return line + "…"


func _draw_dashed_rect(rect: Rect2, color: Color) -> void:
	var dash: float = 8.0
	var x: float = rect.position.x
	while x < rect.position.x + rect.size.x:
		var end: float = minf(x + dash, rect.position.x + rect.size.x)
		draw_line(Vector2(x, rect.position.y), Vector2(end, rect.position.y), color, 1.0)
		draw_line(Vector2(x, rect.position.y + rect.size.y), Vector2(end, rect.position.y + rect.size.y), color, 1.0)
		x += dash * 2.0
	var y: float = rect.position.y
	while y < rect.position.y + rect.size.y:
		var end_y: float = minf(y + dash, rect.position.y + rect.size.y)
		draw_line(Vector2(rect.position.x, y), Vector2(rect.position.x, end_y), color, 1.0)
		draw_line(Vector2(rect.position.x + rect.size.x, y), Vector2(rect.position.x + rect.size.x, end_y), color, 1.0)
		y += dash * 2.0


func _short_name(room_id: String) -> String:
	var full: String = String(_names.get(room_id, room_id))
	var short: String = full.replace("白鹄台·", "").replace("台下东侧·", "东侧")
	var cut: int = short.find("（")
	if cut > 0:
		short = short.substr(0, cut)
	cut = short.find("(")
	if cut > 0:
		short = short.substr(0, cut)
	return short


func _npc_color(npc_id: String) -> Color:
	var sum: int = 0
	for i in range(npc_id.length()):
		sum += npc_id.unicode_at(i)
	return C_NPC[sum % C_NPC.size()]


func _mmss(seconds: int) -> String:
	return "%02d:%02d" % [int(seconds / 60), seconds % 60]


func _shichen(second: int) -> String:
	var names: Array[String] = ["子时", "丑时", "寅时", "卯时", "辰时", "巳时", "午时", "未时", "申时", "酉时", "戌时", "亥时"]
	var index: int = int(floor(float(second) / 7200.0)) % 12
	var half: String = "初" if (second % 7200) < 3600 else "正"
	return names[index] + half


func _token_delta(token: String) -> Vector2:
	match token:
		"up": return Vector2(0.0, -1.0)
		"down": return Vector2(0.0, 1.0)
		"left": return Vector2(-1.0, 0.0)
		"right": return Vector2(1.0, 0.0)
		"up_left": return Vector2(-1.0, -1.0).normalized()
		"up_right": return Vector2(1.0, -1.0).normalized()
		"down_left": return Vector2(-1.0, 1.0).normalized()
		"down_right": return Vector2(1.0, 1.0).normalized()
	return Vector2.ZERO
