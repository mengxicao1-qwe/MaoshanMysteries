extends Control
## ============================================================================
##  slice_hud.gd —— M0 可玩纵切片的表现层（临时 UI，正式 UI 到位后整块替换）
## ----------------------------------------------------------------------------
##  它把已经就位的四块拼成一个"能玩的 360 秒"：
##      scripts/data/case_loader.gd        → 读 data/scenarios/case_01_*.json
##      TimeLoopManager（Autoload，冻结）  → 倒计时 / 重开 / 流速
##      PersistentMemoryManager（冻结）    → 线索跨循环永久保留
##      scripts/entities/heart_lamp.gd     → 心灯：推演有代价、归零丢一条记忆
##
##  玩法（本切片的最小闭环）：
##      1) 每一秒结算一次：玩家所在房间里"正在发生"的线索事件会解锁线索；
##      2) 解锁的线索立刻进记忆并原子落盘（关掉游戏再开还在，见 clue_store.gd）；
##      3) 余页重开 → 心灯 -8、线索保留（这是本作的核心体验）；
##      4) 心灯归零 → 永久少一条线索（不是死亡）；
##      5) 满足 meta.secret.resolve_conditions → 结案，心灯 +25。
##         条件按数据契约逐条判定：require_clues（线索）、require_min_loop（遍数）。
##         require_ritual（画符）在本切片还没有输入层，只在 HUD 里如实显示、暂不拦结案
##         —— 见 README §7.6，属于 M1 的辨笔画符玩法。
##
##  按键：
##      TAB / E = 去下一个走得到的房间     Q = 上一个     1..9 = 去第 N 个房间
##        （走位要花余页里的秒数：按最短路一段一段走，暂停就走不动、快进就一起快进）
##      F       = 和同屋的人交谈（对话是线索的第二个来源，案一有 2 条只能这么拿）
##      B       = 摊开/收起推演板（已入录的线索拼成推论、把"对不上"顶到最前）
##      H       = 重演上一遍路线（把上一遍走过的房间照着重走一遍，别再手动点一遍）
##      空格    = 快进到下一处拍点（60x，到点自动回到 1x）—— "秒级重演"的雏形
##      T       = 1x / 10x / 60x 循环
##      P       = 暂停/继续      R = 强制重开本遍
##
##  分层纪律：本文件是表现层，可以随便改；核心三件套（scripts/core/**、
##  npc_timeline_parser.gd）一行都不动，只调用它们的公开 API。
##  不写 class_name（依赖编辑器类缓存，刚 clone 时不可用），一律 preload()。
## ============================================================================

const CaseLoader = preload("res://scripts/data/case_loader.gd")
const HeartLamp = preload("res://scripts/entities/heart_lamp.gd")
const DialogueLoader = preload("res://scripts/data/dialogue_loader.gd")
const LoopMutation = preload("res://scripts/entities/loop_mutation.gd")
const NpcMemory = preload("res://scripts/entities/npc_memory.gd")
const MapLoader = preload("res://scripts/data/map_loader.gd")
const PlayerTravel = preload("res://scripts/entities/player_travel.gd")
const DeductionBoard = preload("res://scripts/entities/deduction_board.gd")
const RuneLoader = preload("res://scripts/data/rune_loader.gd")
const RuneInput = preload("res://scripts/entities/rune_input.gd")
const ClueStore = preload("res://scripts/data/clue_store.gd")

## 没有案件数据时的兜底余页长度（与 TimeLoopManager 默认值一致）。
const DEFAULT_DURATION: float = 420.0
## T 键循环的倍速档位。
const SCALE_STEPS: Array = [1.0, 10.0, 60.0]
## 日志保底显示条数。
const LOG_LINES: int = 6
## 快进用的最高倍速（= SCALE_STEPS 的最后一档）。
const FAST_SCALE: float = 60.0

# ------------------------------- 运行时状态 -------------------------------

var _case: CaseLoader.CaseData = null
var _lamp: HeartLamp = null
var _label: Label = null

## 这一局**在余页之内**累计走过多少秒（跨遍累加，结案结算里给玩家看"耗时"）。
## 为什么不用 TimeLoopManager 的 _elapsed：它每一遍都会归零（那是"第几秒"的口径）。
## 为什么不用真实帧时间：快进(T=60x)/暂停不该影响这个数 —— 玩家花的是"余页里的时间"。
var _elapsed_total: float = 0.0
## _elapsed_total 的累加基线：只吃游戏时钟的**正向增量**，归零/回退一律不算
## （核心在 _perform_loop_reset 里会先把 _elapsed 顶到 loop_duration 再清，直接取差会多算一整遍）。
var _elapsed_mark: float = 0.0

## 玩家当前所在房间（房间 id，来自 meta.rooms）。
var _player_room: String = ""

## 线索可观测窗口：[{start, end, room, npc_id, display_name, clue_id, note}]
## 窗口 = 该 NPC 做这个动作的秒 → 他移动去下一个节点的秒（期间玩家进房间就能看见）。
var _windows: Array[Dictionary] = []

## 本遍已经结算过的线索（跨遍清空，但记忆不清空）。
var _taken: Dictionary = {}

## 结案条件里的线索 id（来自 meta.secret.resolve_conditions.require_clues）。
var _required_clues: Array[String] = []

## 结案条件里的最少遍数（require_min_loop；0 = 数据没写，不设门槛）。
var _min_loop_required: int = 0

## 结案条件里是否有 require_ritual（画符）——M0 没有输入层，只显示不拦截。
var _ritual_required: bool = false

## "线索齐了但遍数还不够"只提示一次，避免每秒刷屏。
var _gate_warned: bool = false

## 本遍已经报告过"没能记下"的线索（避免站在房间里每秒刷屏）。
var _warned: Dictionary = {}

## 案一的对话表（M1 第一步接线；为 null = 对话数据没读进来）。
var _dialogue: DialogueLoader.DialogueTable = null

## 对话的可说窗口：[{npc_id, start, end, dialogue_id}]
## 规则（Lead 裁定，见 AGENTS.md §6）：loader 的 is_active_at() 只认"锚点那一秒"，
## 太苛刻；HUD 放宽成"该 NPC 停在这个房间的整段时间" —— 与看得见的线索窗口同宽。
var _talk_windows: Array[Dictionary] = []

## 本遍已经追问过的选项，键 = "dialogue_id|选项文本"（跨遍清空 = 每遍都能重问一遍）。
var _talked: Dictionary = {}

## 对话的"可视化状态"：给 scripts/ui/play_view.gd 画对话框用（M2 表现层）。
## 结构：{active, speaker, line, reply, dialogue_id, options:[{text, reply, gives_clue, asked}], entry}
## 纯附加：文字 HUD 的行为不受它影响（entry 只给表现层点选项时回填用，不进 present_state()）。
var _dialogue_view: Dictionary = {}

## 世界状态递进（M1 第三步；per_loop_mutation = 每遍多出来的"不属于这一天的痕迹"）。
var _mutation: LoopMutation = null

## NPC 跨轮记忆阶（M1 第三步；阶数 = 线索集合 + 遍数下限，现算，不落盘）。
var _memory: NpcMemory = null

## 案一地图（M1 第二步；有向图，边权 = 走这段路花掉的余页秒数）。
var _map = null

## 玩家的走位状态机；为 null = 地图没读进来（退回直跳的调试旁路）。
var _travel: PlayerTravel = null

## 当前这条路线还没走完的段落（多跳目的地用）。
var _route: Array[String] = []

## 上一次走位结算时的"已过秒"（走位由余页时钟驱动，不是帧 delta）。
var _last_travel_second: int = 0

## 本局是否已经结案（结案后再集齐也不重复 +25）。
var _resolved: bool = false

## 推演板（M1 第四步）：把已入录的线索拼成推论、把"对不上"的地方顶到最前。
var _board: DeductionBoard = null

## `B` 键：主视图 ↔ 推演板视图。
var _board_open: bool = false

## 上一次"有新线索入录"的遍数 + 当时的线索数：连续两遍没新线索就主动给落点（死法 3）。
var _last_progress_loop: int = 0
var _last_progress_clue_count: int = 0

## `H` 键重演上一遍路线：本遍走过的房间、上一遍的路线、待重演的队列（死法 1）。
var _loop_route: Array[String] = []
var _last_loop_route: Array[String] = []
var _replay_queue: Array[String] = []

## ⑤ 画符（M1 第五步）：结案要做的仪式 = 把阙文照回原样。
## 数据在 data/runes/case_01_runes.json；输入层只判"笔数 + 每一笔的方向串"。
var _runes = null                      # RuneLoader.RuneTable
var _rune: RuneInput = null
var _rune_mode: bool = false
var _rune_gate_warned: bool = false

## 快进目标秒（-1 = 没在快进）。
var _fast_forward_to: int = -1

## 当前倍速档位下标。
var _scale_index: int = 0

## 屏幕上的事件日志（最新的在前）。
var _log: Array[String] = []


# ============================================================================
#  生命周期
# ============================================================================

func _ready() -> void:
	_label = get_node_or_null("InfoLabel") as Label

	# 心灯：手动驱动（auto_subscribe = false），先注入记忆管理器再订阅信号，
	# 避免"心灯先扣了 8 点、记忆还没接上"的时序问题。
	_lamp = HeartLamp.new()
	_lamp.name = "HeartLamp"
	_lamp.auto_subscribe = false
	add_child(_lamp)
	_lamp.set_memory_manager(PersistentMemoryManager)
	_lamp.heart_lamp_changed.connect(_on_lamp_changed)
	_lamp.heart_lamp_extinguished.connect(_on_lamp_extinguished)

	# M1 第三步：世界状态递进 + NPC 跨轮记忆。两者都是 Node 组件，自己订阅
	# /root/TimeLoopManager 的 loop_reset / loop_started（auto_subscribe 默认 true），
	# 所以每遍结束它们会自己清掉"仅属于上一遍"的状态（docs/story/09:17）。
	# 它们不引用 Autoload：记忆阶靠 set_memory_manager() 注入，事件靠 scene tree 解析。
	_mutation = LoopMutation.new()
	_mutation.name = "LoopMutation"
	add_child(_mutation)
	_memory = NpcMemory.new()
	_memory.name = "NpcMemory"
	add_child(_memory)
	_memory.set_memory_manager(PersistentMemoryManager)

	# M1 第四步：推演板。实例化必须早于 _load_case() → _configure_world()（那里会 configure）。
	_board = DeductionBoard.new()
	_board.name = "DeductionBoard"
	add_child(_board)

	# M1 第五步：画符（结案的仪式）。数据在 _configure_world() 里灌进来；
	# 输入层自己订阅 loop_reset 清掉"上一遍画了一半"的状态。
	_rune = RuneInput.new()
	_rune.name = "RuneInput"
	add_child(_rune)
	_rune.set_memory_manager(_lamp)

	# 开档：把上次玩到一半的线索从磁盘灌回记忆（崩溃安全落盘见 clue_store.gd）。
	var restored: int = _lamp.restore_from_store()
	if restored > 0:
		_append_log("开档：从存档里想起 %d 条线索" % restored)

	# 现实时间恢复（docs/story/09:175「余页之外按分钟 +1」）：必须在 restore_from_store() 之后调用
	# —— 它要用开档时抓住的"上次活跃时间戳"来算离线了多久。
	var recovered: int = _lamp.apply_offline_recovery()
	if recovered > 0:
		_append_log("[+] 离线恢复：心灯回了 %d 点（现在 %d）" % [recovered, _lamp.get_value()])

	# 卡关预警的基线：开档时就已经在记忆里的线索算"推进过"，不算这一局停滞。
	_last_progress_clue_count = _lamp.get_available_clues().size()

	_load_case()

	TimeLoopManager.time_updated.connect(_on_time_updated)
	TimeLoopManager.loop_reset.connect(_on_loop_reset)
	TimeLoopManager.loop_started.connect(_on_loop_started)
	TimeLoopManager.loop_timeout.connect(_on_loop_timeout)
	TimeLoopManager.pause_changed.connect(_on_pause_changed)

	var duration: float = DEFAULT_DURATION
	if _case != null and _case.ok and _case.loop_duration_seconds > 0:
		duration = float(_case.loop_duration_seconds)
	TimeLoopManager.set_loop_duration(duration)
	TimeLoopManager.start_loop()
	# 开档就判定一次：上次退出时线索已经齐了、只差最后一笔的情况不该被漏掉。
	_check_resolution()
	_refresh()


## 每帧只做一件小事：把余页时钟的正向增量累进 _elapsed_total（结案结算的"耗时"）。
## 放在 _process 而不是 _on_time_updated：那是"每秒一拍"，高倍速下会跨秒补发，
## 按拍累加会把 60x 快进算成 1 秒；这里按帧取差，快进多少就记多少。
func _process(_delta: float) -> void:
	var now_elapsed: float = TimeLoopManager.get_elapsed_time()
	var diff: float = now_elapsed - _elapsed_mark
	if diff > 0.0:
		_elapsed_total += diff
	_elapsed_mark = now_elapsed


# ============================================================================
#  案件数据 → 可观测窗口
# ============================================================================

func _load_case() -> void:
	var path: String = CaseLoader.find_case_path()
	if path.is_empty():
		_append_log("data/scenarios 下还没有案件数据，先空跑时钟")
		# 导出包里 `res://` 不是本地目录：这条错误一旦出现，浏览器控制台/日志里必须看得见
		push_error("[SliceHUD] 找不到案件数据（%s 下没有 case_*.json）—— 导出包请检查 DirAccess 用法" % CaseLoader.SCENARIO_DIR)
		return

	_case = CaseLoader.load_case(path)
	for warning in _case.warnings:
		_dev_note("数据警告：" + warning)
	if not _case.ok:
		_append_log("案件数据有问题：" + _case.error_summary())
		push_error("[SliceHUD] 案件数据有问题：%s" % _case.error_summary())
		return

	_build_windows()
	_required_clues = _read_required_clues()
	_min_loop_required = _read_min_loop()
	_ritual_required = _has_ritual_requirement()
	if not _case.rooms.is_empty():
		_player_room = _case.rooms[0]

	_dev_note("读入 %s：%d 间房 / %d 个 NPC / %d 个节点 / 可观测线索 %d 处" % [
		_case.display_title(), _case.rooms.size(), _case.npc_count(),
		_case.total_nodes(), _windows.size(),
	])
	_load_dialogues()
	_configure_world()
	_load_map()


# ============================================================================
#  走位耗时（M1 第二步）：去哪儿要花余页里的秒数
#  —— 这是"时间循环 + 空间"的核心张力：跑一趟 90 秒，这一遍就少了 90 秒。
# ============================================================================

## 读入地图并把玩家放进第一间房。读不到不算致命：HUD 仍可试玩（键位退回直跳）。
func _load_map() -> void:
	var map: Variant = MapLoader.load_for_case(1)
	if map == null:
		_append_log("地图没读进来：data/maps 下没有本案文件（走位退回按键直跳）")
		return
	for warning in map.warnings:
		_dev_note("地图警告：" + String(warning))
	if not bool(map.ok):
		_append_log("地图不合法：" + String(map.error_summary()))
		return
	_map = map
	if _player_room.is_empty() or not bool(map.has_room(_player_room)):
		_player_room = String(map.default_room())
	_travel = PlayerTravel.create(map, _player_room)
	_last_travel_second = int(TimeLoopManager.get_elapsed_seconds())
	_dev_note("地图读入：%d 间房 / %d 条路（走一趟要按秒算）" % [
		int(map.room_count()), int(map.edge_count()),
	])


## 动身去某间房：走最短路，路上按秒扣。到不了就直说，不悄悄瞬移。
func _travel_to(target: String) -> void:
	if target.is_empty():
		return
	if _travel == null:
		_player_room = target                       # 没有地图数据时的调试兜底
		return
	if not bool(_map.has_room(target)):
		_append_log("没有这间房：[%s]" % target)
		return
	if _travel.is_moving():
		_travel.cancel_move()
		_route.clear()
	if target == _player_room:
		_append_log("你已经在 [%s]" % _room_name(target))
		return
	var route: Array = _travel.get_route_to(target)
	if route.size() < 2:
		_append_log("走不到 [%s]：这一遍没有路" % _room_name(target))
		return
	_route.clear()
	for index in range(1, route.size()):
		_route.append(String(route[index]))
	_append_log("去 [%s]：%d 秒的路" % [_room_name(target), int(_travel.get_travel_seconds_to(target))])
	_step_route()


## 走路线上的下一段；到了自动接着走下一段（多跳目的地）。
func _step_route() -> void:
	if _travel == null or _route.is_empty():
		return
	var next: String = _route[0]
	_route.remove_at(0)
	var seconds: int = _travel.start_move(next)
	if seconds <= 0:
		_append_log("这一段走不通：[%s] → [%s]" % [_room_name(_player_room), _room_name(next)])
		_route.clear()
		return
	_append_log("动身：[%s] → [%s]，%d 秒" % [_room_name(_player_room), _room_name(next), seconds])


## 走位由余页时钟驱动：暂停就走不动，快进就一起快进（帧 delta 做不到这点）。
func _tick_travel(elapsed: int) -> void:
	if _travel == null:
		return
	var step: int = elapsed - _last_travel_second
	_last_travel_second = elapsed
	if step <= 0 or step > 3600 or not _travel.is_moving():
		return
	if _travel.tick(float(step)):
		_player_room = String(_travel.get_room())
		_append_log("到了 [%s]" % _room_name(_player_room))
		if _loop_route.is_empty() or _loop_route[_loop_route.size() - 1] != _player_room:
			_loop_route.append(_player_room)      # H 键重演上一遍路线要用
		_step_route()


func _room_name(room_id: String) -> String:
	if _map == null:
		return room_id
	return String(_map.get_display_name(room_id))


## HUD 的走位行：正在路上就报还剩几秒。
func _travel_text() -> String:
	if _travel == null or not _travel.is_moving():
		return ""
	return "（正在去 [%s]：还剩 %d 秒）" % [
		_room_name(String(_travel.get_target_room())), int(_travel.get_remaining_seconds()),
	]


# ============================================================================
#  世界状态递进 + NPC 跨轮记忆（M1 第三步）：本作真正的差异位
#  —— 线索跨遍保留是品类标配；"第 N 遍的余页和第一遍不一样"才是卖点。
# ============================================================================

## 把案件数据喂给两个组件。读不到不算致命：HUD 仍可试玩，只是少了这一层。
func _configure_world() -> void:
	if _mutation != null:
		_mutation.configure(_case)
		for warning in _mutation.get_warnings():
			_dev_note("世界状态警告：" + warning)
	_memory.configure(1)
	for warning in _memory.get_warnings():
		_dev_note("记忆警告：" + warning)
	_dev_note("NPC 记忆规则：%d 名 / %d 条（线索一变，阶数立刻变）" % [
		_memory.get_npc_ids().size(), _memory.total_rule_count(),
	])
	# ④ 推演板：线索是同一批线索，板子只做"拼起来"和"指出对不上"。
	_board.configure(1)
	_board.set_memory_manager(_lamp)
	for warning in _board.get_warnings():
		_dev_note("推演板警告：" + warning)
	_dev_note("推演板：%d 条推论 / %d 处对不上 / %d 条卡关提示" % [
		_board.total_deduction_count(), _board.total_conflict_count(), _board.total_stuck_hint_count(),
	])
	# ⑤ 画符：结案要做的仪式（案例 meta.secret.resolve_conditions.require_ritual）。
	_runes = RuneLoader.load_for_case(1)
	if _runes == null or not _runes.ok:
		_append_log("仪式数据没读进来：%s" % ("（null）" if _runes == null else _runes.error_summary()))
		return
	for warning in _runes.warnings:
		_dev_note("仪式警告：" + warning)
	_dev_note("仪式：%d 个 / %d 步 / %d 笔（%s）" % [
		_runes.count(), _runes.total_steps(), _runes.total_strokes(),
		"、".join(_runes.rune_ids()),
	])
	_rune.configure_with_table(_runes)
	for warning in _rune.get_warnings():
		_dev_note("仪式输入警告：" + warning)


## HUD 的"世界状态"行：每遍都会变的那部分（案一是 grow = 痕迹越来越多）。
func _mutation_text() -> String:
	if _mutation == null or not _mutation.is_configured():
		return "世界状态：未配置"
	var base: String = _mutation.describe()
	if not _mutation.is_affected(_player_room):
		return "世界状态：" + base + "（此处不在异变范围）"
	return "世界状态：" + base + "（此处 %d 个）" % _mutation.entity_count(_player_room)


## HUD 的"NPC 记忆"行：此刻在场的人里，谁的记忆已经变了阶。
func _memory_text(second: int) -> String:
	if _memory == null or not _memory.is_configured():
		return "NPC 记忆：未配置"
	var parts: Array[String] = []
	for npc_id in _npc_ids_in_room(second):
		var key: String = String(npc_id)
		var stage: int = _memory.get_stage(key)
		if stage <= 0:
			continue
		parts.append("%s %d/%d 阶" % [
			_npc_display_name(key), stage, _memory.get_max_stage(key),
		])
	if parts.is_empty():
		return "NPC 记忆：此处的人还没察觉（换个人、或再过一遍）"
	return "NPC 记忆：" + "，".join(parts)


## 记忆阶带来的额外对话（cross-loop memory 的玩法收益：第 3 遍他才会说那句话）。
func _memory_extra_entry(npc_id: String, loop_now: int, owned: Array) -> Variant:
	if _memory == null or _dialogue == null:
		return null
	var effects: Dictionary = _memory.get_effects(npc_id)
	var extra_id: String = String(effects.get("extra_dialogue_id", ""))
	if extra_id.is_empty():
		return null
	var entry: DialogueLoader.DialogueEntry = _dialogue.get_dialogue(extra_id)
	if entry == null or not entry.is_unlocked(loop_now, owned):
		return null
	return entry


# ============================================================================
#  对话层（M1 第一步）：线索的第二个来源
#  案一有 12 条线索挂在 NPC 拍点上"看得见"，另有 2 条只能靠追问对话拿到
#  （data/clues/case_01_clues.json 的 source 写明是 add_clue）。
# ============================================================================

## 读入案一的对话表。读不到不算致命：HUD 仍可试玩，只是少了对话这条线索来源。
func _load_dialogues() -> void:
	var table: DialogueLoader.DialogueTable = DialogueLoader.load_for_case(1)
	if table == null:
		_append_log("对话数据没读进来：data/dialogues 下没有本案文件")
		return
	for warning in table.warnings:
		_dev_note("对话警告：" + warning)
	if not table.ok:
		_append_log("对话数据有问题：" + table.error_summary())
		return
	_dialogue = table
	_dev_note("对话表读入：%d 条 / %d 行台词 / %d 个线索选项" % [
		table.count(), table.total_lines(), table.total_options(),
	])
	_build_talk_windows()


## 把"锚点秒"翻译成"该 NPC 停在这个房间的整段时间"，供 _entries_to_say() 用。
func _build_talk_windows() -> void:
	_talk_windows.clear()
	if _dialogue == null or _case == null or not _case.ok:
		return
	for dialogue_id in _dialogue.dialogue_ids():
		var entry := _dialogue.get_dialogue(dialogue_id)
		if entry == null or not entry.is_anchored():
			continue
		var npc_id: String = String(entry.npc_id)
		if not _case.npcs.has(npc_id):
			continue
		var schedule: CaseLoader.NPCSchedule = _case.npcs[npc_id]
		if schedule == null:
			continue
		var anchor: int = int(entry.start_second)
		if anchor < 0:
			continue
		var stay_end: int = _case.loop_duration_seconds
		var next_node = schedule.next_node_after(anchor)
		if next_node != null:
			stay_end = int(next_node.second)
		_talk_windows.append({
			"npc_id": npc_id,
			"start": anchor,
			"end": stay_end,
			"dialogue_id": dialogue_id,
		})


## 此刻这个 NPC 能说的话。
## 口径（Lead 裁定，写进 AGENTS.md §6）：**该 NPC 停在这个房间的整段时间**都算，
## 而不是 loader 的 `is_active_at()` 那一秒 —— 走位、快进、逐秒补发都不会"错过一句话"。
## 只取有锚点的条目：无锚点的 goto 续话条目由 _speak() 顺着选项跳过去，不在这里凭空触发。
func _entries_to_say(npc_id: String, second: int, loop_now: int, owned: Array) -> Array:
	var result: Array = []
	if _dialogue == null:
		return result
	for window in _talk_windows:
		if String(window["npc_id"]) != npc_id:
			continue
		if second < int(window["start"]) or second >= int(window["end"]):
			continue
		var entry := _dialogue.get_dialogue(String(window["dialogue_id"]))
		if entry == null or not entry.is_unlocked(loop_now, owned):
			continue
		if not result.has(entry):
			result.append(entry)
	result.sort_custom(func(a, b) -> bool: return int(a.start_second) < int(b.start_second))
	return result


## 遍历案件动线，找出"此刻和玩家同屋"的 NPC id。
func _npc_ids_in_room(second: int) -> Array:
	var result: Array = []
	if _case == null or not _case.ok:
		return result
	for npc_id in _case.npc_order:
		var schedule: CaseLoader.NPCSchedule = _case.npcs[npc_id]
		if schedule != null and schedule.room_at(second) == _player_room:
			result.append(npc_id)
	return result


## npc_id → 中文显示名（对话里的 speaker 就是显示名）。
func _npc_display_name(npc_id: String) -> String:
	if _case != null and _case.npcs.has(npc_id):
		var schedule: CaseLoader.NPCSchedule = _case.npcs[npc_id]
		if schedule != null:
			return schedule.display_name
	return npc_id


## F 键：和同屋的人说话。对话里能给的线索走 heart_lamp.add_clue
## （它会去重、落盘、并且心灯熄着时会拒绝——那时只提示"没能记下"）。
func _talk() -> void:
	if _dialogue == null or _case == null or not _case.ok:
		_append_log("没有可用的对话数据（先看 case_01_dialogues.json 是否读入成功）")
		return

	var second: int = int(TimeLoopManager.get_elapsed_seconds())
	var loop_now: int = TimeLoopManager.get_loop_index()
	var owned: Array = _lamp.get_available_clues()
	var here: Array = _npc_ids_in_room(second)
	if here.is_empty():
		_append_log("%s [%s] 此刻没有人可以说话" % [_clock(second), _player_room])
		return

	for npc_id in here:
		var key: String = String(npc_id)
		var entries: Array = _entries_to_say(key, second, loop_now, owned)
		# 记忆阶带来的额外对话：他这一次才想起来的事（M1 第三步的玩法收益）。
		var extra: Variant = _memory_extra_entry(key, loop_now, owned)
		if extra != null and not entries.has(extra):
			entries.append(extra)
		if entries.is_empty():
			_append_log("%s %s 此刻没说什么" % [_clock(second), _npc_display_name(key)])
			continue
		for entry in entries:
			_speak(entry, second, loop_now, owned, 0)
		# 记忆阶到位的"松口"：他这一次会把某条线索直接交出来（数据里只有甘凤仪的碗底走这条路）。
		var reveal: String = String(_memory.get_effects(key).get("reveal_clue_id", ""))
		if not reveal.is_empty() and not PersistentMemoryManager.has_clue(reveal):
			if _lamp.add_clue(reveal, loop_now):
				_append_log("[+] 入录（他终于说出口）：" + _clue_text(reveal))
				_check_resolution()
			else:
				_append_log("[!] %s 想说什么，但心灯太暗——没能记下" % _npc_display_name(key))


## 播报一条对话，并自动追问"这条里还没问过"的第一个选项；选项带 goto 就接着往下说
## （案一的追问链：qdm_02_bag → qdm_03_admit → … → qdm_04_ningque）。
## 一次按键只走一条链，避免一键把整段对话刷完。
func _speak(entry, second: int, loop_now: int, owned: Array, depth: int) -> void:
	var speaker: String = String(entry.speaker)
	if speaker.is_empty():
		speaker = _npc_display_name(String(entry.npc_id))
	_append_log("%s %s：%s" % [_clock(second), speaker, String(entry.first_line())])

	var options: Array = _dialogue.available_options(String(entry.dialogue_id), loop_now, owned)
	var chosen = null
	var chosen_key: String = ""
	for option in options:
		var key: String = "%s|%s" % [String(entry.dialogue_id), String(option.text)]
		if _talked.has(key):
			continue
		chosen = option
		chosen_key = key
		break
	if chosen == null:
		_append_log("   （这条已经问完了）")
		return
	_talked[chosen_key] = true

	var line: String = "   追问「%s」" % String(chosen.text)
	if not String(chosen.reply).is_empty():
		line += "：" + String(chosen.reply)
	_append_log(line)

	# 给表现层留一份"刚才说了什么、还能问什么"（M2 对话框；文字 HUD 行为不变）
	_dialogue_view = {
		"active": true,
		"speaker": speaker,
		"line": String(entry.first_line()),
		"reply": String(chosen.reply),
		"dialogue_id": String(entry.dialogue_id),
		"options": _options_view(options, String(entry.dialogue_id)),
		"entry": entry,
	}

	var clue_id: String = String(chosen.add_clue)
	if not clue_id.is_empty():
		if _lamp.add_clue(clue_id, loop_now):
			_append_log("   [+] 入录：%s" % _clue_text(clue_id))
			_check_resolution()
		else:
			_append_log("   [!] %s 没能记下（心灯已熄或存档写入失败），回头再来问" % _clue_text(clue_id))

	var goto_id: String = String(chosen.goto)
	if goto_id.is_empty() or depth >= 3:
		return
	var next_entry := _dialogue.get_dialogue(goto_id)
	if next_entry == null:
		return
	if not next_entry.is_anchored() and next_entry.is_unlocked(loop_now, owned):
		_speak(next_entry, second, loop_now, owned, depth + 1)


## 可用选项 → 表现层要的形状（带"问过没有"，按钮可以据此置灰）。
func _options_view(options: Array, dialogue_id: String) -> Array:
	var out: Array = []
	for option in options:
		var key: String = "%s|%s" % [dialogue_id, String(option.text)]
		out.append({
			"text": String(option.text),
			"reply": String(option.reply),
			"gives_clue": not String(option.add_clue).is_empty(),
			"asked": _talked.has(key),
		})
	return out


## 表现层点了一个选项（鼠标点对话框的按钮）→ 走和 F 键一样的结算。
## 只认当前这一条对话的选项；选项本身不给线索时只留一句台词。
func request_option(index: int) -> void:
	var entry: Variant = _dialogue_view.get("entry", null)
	var options: Array = _dialogue_view.get("options", [])
	if entry == null or index < 0 or index >= options.size():
		return
	var option_data: Dictionary = options[index]
	if bool(option_data.get("asked", false)):
		_append_log("   （这条已经问完了）")
		_refresh()
		return
	var loop_now: int = TimeLoopManager.get_loop_index()
	var second: int = int(TimeLoopManager.get_elapsed_seconds())
	var dialogue_id: String = String(_dialogue_view.get("dialogue_id", ""))
	_talked["%s|%s" % [dialogue_id, String(option_data.get("text", ""))]] = true

	var line: String = "   追问「%s」" % String(option_data.get("text", ""))
	if not String(option_data.get("reply", "")).is_empty():
		line += "：" + String(option_data.get("reply", ""))
	_append_log(line)

	# 选项 → 线索：靠 entry 上原样的 DialogueOption 走（add_clue 是唯一出口）
	var chosen: Variant = null
	for candidate in _dialogue.available_options(dialogue_id, loop_now, _lamp.get_available_clues()):
		if String(candidate.text) == String(option_data.get("text", "")):
			chosen = candidate
			break
	if chosen != null:
		var clue_id: String = String(chosen.add_clue)
		if not clue_id.is_empty():
			if _lamp.add_clue(clue_id, loop_now):
				_append_log("   [+] 入录：%s" % _clue_text(clue_id))
				_check_resolution()
			else:
				_append_log("   [!] %s 没能记下（心灯已熄或存档写入失败），回头再来问" % _clue_text(clue_id))
	# 问过的选项从按钮里去掉（重画一次对话框）
	_dialogue_view["options"] = _options_view(
		_dialogue.available_options(dialogue_id, loop_now, _lamp.get_available_clues()), dialogue_id)
	_dialogue_view["reply"] = String(option_data.get("reply", ""))
	_refresh()
	if chosen == null:
		return
	var goto_id: String = String(chosen.goto)
	if goto_id.is_empty():
		return
	var next_entry: Variant = _dialogue.get_dialogue(goto_id)
	if next_entry != null and not next_entry.is_anchored() and next_entry.is_unlocked(loop_now, _lamp.get_available_clues()):
		_speak(next_entry, second, loop_now, _lamp.get_available_clues(), 3)
		_refresh()


## HUD 里的对话提示行：告诉玩家此刻能和谁说话。
func _dialogue_hint_text(second: int) -> String:
	if _dialogue == null:
		return "对话数据未读入"
	if _case == null or not _case.ok:
		return "无案件数据"
	var here: Array = _npc_ids_in_room(second)
	if here.is_empty():
		return "此处无人（TAB/E 换房间找人）"
	var loop_now: int = TimeLoopManager.get_loop_index()
	var owned: Array = _lamp.get_available_clues()
	var talkable: Array[String] = []
	var idle: Array[String] = []
	for npc_id in here:
		var name: String = _npc_display_name(String(npc_id))
		if _entries_to_say(String(npc_id), second, loop_now, owned).is_empty():
			idle.append(name)
		else:
			talkable.append(name)
	if talkable.is_empty():
		return "此处：%s（此刻都没话说）" % ", ".join(idle)
	var text: String = "F 交谈：%s" % ", ".join(talkable)
	if not idle.is_empty():
		text += "（%s 此刻没话说）" % ", ".join(idle)
	return text


func _build_windows() -> void:
	_windows.clear()
	for npc_id in _case.npc_order:
		var schedule: CaseLoader.NPCSchedule = _case.npcs[npc_id]
		var clue_nodes: Array = schedule.clue_nodes()
		for node in clue_nodes:
			var window_end: int = _case.loop_duration_seconds
			var next_node = schedule.next_node_after(node.second)
			if next_node != null:
				window_end = next_node.second
			_windows.append({
				"start": node.second,
				"end": window_end,
				"room": node.room,
				"npc_id": npc_id,
				"display_name": schedule.display_name,
				"clue_id": node.clue_id,
				"loop_min": node.loop_min,
				"note": node.note,
			})


func _read_required_clues() -> Array[String]:
	var result: Array[String] = []
	if _case == null:
		return result
	var conditions: Variant = _case.secret.get("resolve_conditions", {})
	if typeof(conditions) != TYPE_DICTIONARY:
		return result
	var ids: Variant = (conditions as Dictionary).get("require_clues", [])
	if typeof(ids) != TYPE_ARRAY:
		return result
	for clue_id in (ids as Array):
		result.append(String(clue_id))
	return result


## 结案条件里的最少遍数：require_min_loop（数据没写或写得不是整数就返回 0 = 不设门槛）。
func _read_min_loop() -> int:
	var conditions: Variant = _resolve_conditions()
	if conditions.is_empty():
		return 0
	var raw: Variant = (conditions as Dictionary).get("require_min_loop", 0)
	if typeof(raw) == TYPE_INT:
		return maxi(int(raw), 0)
	if typeof(raw) == TYPE_FLOAT:
		return maxi(int(raw), 0)
	if typeof(raw) == TYPE_STRING and String(raw).is_valid_int():
		return maxi(String(raw).to_int(), 0)
	return 0


## 是否写了 require_ritual（画符）。M0 没有符盘输入层，只如实显示。
func _has_ritual_requirement() -> bool:
	var conditions: Variant = _resolve_conditions()
	if conditions.is_empty():
		return false
	var raw: Variant = (conditions as Dictionary).get("require_ritual", null)
	if raw == null:
		return false
	if typeof(raw) == TYPE_STRING:
		return not String(raw).strip_edges().is_empty()
	if typeof(raw) == TYPE_BOOL:
		return bool(raw)
	if typeof(raw) == TYPE_ARRAY:
		return not (raw as Array).is_empty()
	return true


func _resolve_conditions() -> Dictionary:
	if _case == null:
		return {}
	var conditions: Variant = _case.secret.get("resolve_conditions", {})
	if typeof(conditions) != TYPE_DICTIONARY:
		return {}
	return conditions as Dictionary


# ============================================================================
#  核心信号
# ============================================================================

## 每秒结算一次。
## 注意：核心的 time_updated(current_second) 广播的是【剩余】秒数（倒计时口径，
## 420 → 0），不是已过秒数 —— 需要"第几秒"一律用 get_elapsed_seconds()。
func _on_time_updated(_remaining_second: int) -> void:
	_lamp.tick(1.0)                       # 余页之内每秒 -0.02（累积满 1 点才扣）
	var elapsed: int = int(TimeLoopManager.get_elapsed_seconds())
	_tick_travel(elapsed)                 # 走位跟余页时钟一起走
	_drive_replay()                       # 重演队列：站住了就继续走下一站
	_check_observations(elapsed)
	_check_resolution()                   # 每秒都判定：遍数门槛一旦满足立刻结案
	if _fast_forward_to >= 0 and elapsed >= _fast_forward_to:
		_fast_forward_to = -1
		_apply_scale(0)
		_append_log("快进结束，回到 1x")
	_refresh()


func _on_loop_reset() -> void:
	# 核心契约：这个信号广播时时钟已停、下一遍还没开始 —— 正好是清理世界的时机。
	_lamp.reset_for_new_loop()            # -8：反复推演是有代价的
	_taken.clear()
	_warned.clear()
	_talked.clear()                       # 新一遍 = 对话可以重新问一遍
	_gate_warned = false
	_fast_forward_to = -1
	_apply_scale(0)
	# 余页重开 = 人回到这一遍的入口（走位清零；路走了一半就白走了）。
	_route.clear()
	_last_travel_second = 0
	if not _loop_route.is_empty():
		_last_loop_route = _loop_route.duplicate()   # 上一遍走了哪些房间（H 键重演用）
	_loop_route.clear()
	_replay_queue.clear()
	_board_open = false
	_rune_mode = false                    # 画符画到一半遇上重开：退回普通视角（输入层自己已清笔）
	_elapsed_mark = 0.0                    # 新一遍从 0 秒起算（_elapsed_total 继续累加，不清零）
	if _travel != null and not _case.rooms.is_empty():
		_travel.reset_to(_case.rooms[0])
		_player_room = _case.rooms[0]
		_loop_route.append(_player_room)
	_append_log("余页重开：心灯 -%d（现在 %d）" % [HeartLamp.DRAIN_PER_LOOP_RESET, _lamp.get_value()])
	_refresh()


func _on_loop_started(loop_index: int) -> void:
	# 玩家口径：核心的 loop_index 是 0 基，但对玩家说"第 0 遍余页"像 bug ⇒ 显示时 +1。
	# 核心层不动（require_min_loop / loop_reset 全按 0 基算），只有台词是 1 基。
	_append_log("第 %d 遍余页开始" % (loop_index + 1))
	_check_resolution()                   # 到了 require_min_loop 那一遍就该结案
	_refresh()


func _on_loop_timeout() -> void:
	_append_log("余页到头（第 %d 遍结束）" % (TimeLoopManager.get_loop_index() + 1))
	_refresh()


func _on_pause_changed(_is_paused: bool) -> void:
	_refresh()


func _on_lamp_changed(_value: int, _max_value: int) -> void:
	if _label != null:                     # 数值每变一点刷新一次（便宜且不会漏）
		_refresh()


func _on_lamp_extinguished(lost_clue_id: String) -> void:
	if lost_clue_id.is_empty():
		_append_log("[!] 心灯熄灭：记忆已空，没有可失去的东西了")
	else:
		_append_log("[!] 心灯熄灭：永久失去了「%s」的记忆" % _clue_text(lost_clue_id))
	_refresh()


# ============================================================================
#  玩法规程
# ============================================================================

## 每秒结算一次：玩家所在房间里，哪些线索事件"此刻正在发生"且还没被取走。
## 遍数锁（M2）：`data/scenarios` 的节点可以带 `loop_min` —— 那一处要到第 N 遍才看得出来
## （依据 `docs/story/04` 的"获得方式"：四字位第二遍、半笔"寸"第三遍、灰布袋第四遍……）。
func _check_observations(second: int) -> void:
	if _case == null or not _case.ok:
		return
	for window in _windows:
		var start: int = int(window["start"])
		var end: int = int(window["end"])
		if second < start or second >= end:
			continue
		if String(window["room"]) != _player_room:
			continue
		var clue_id: String = String(window["clue_id"])
		if _taken.has(clue_id):
			continue
		var loop_min: int = int(window.get("loop_min", 0))
		if TimeLoopManager.get_loop_index() < loop_min:
			# 站在对的地方也看不见：直说"还不到时候"，别让玩家以为是 bug（每处只提醒一次）。
			var gate_key: String = "loop:%s" % clue_id
			if not _warned.has(gate_key):
				_warned[gate_key] = true
				_append_log("（%s 这一处还没到时候：要第 %d 遍才看得出来）" % [_clue_text(clue_id), loop_min + 1])
			continue
		# 上一遍（或更早）已经记下的线索：本遍不再重复播报，但依旧算"看过"。
		if PersistentMemoryManager.has_clue(clue_id) and not _lamp.get_forgotten_clues().has(clue_id):
			_taken[clue_id] = true
			continue
		if _lamp.add_clue(clue_id, TimeLoopManager.get_loop_index()):
			_taken[clue_id] = true
			_append_log("%s 在[%s]看见 %s：%s" % [
				_clock(second), String(window["room"]),
				String(window["display_name"]), _clue_text(clue_id),
			])
			_check_resolution()
		elif not _warned.has(clue_id):
			# add_clue() 返回 false 有两种原因：心灯已熄（这条记忆被永久划掉），
			# 或者落盘失败。两种都不能标记成"已取走"——否则玩家以为记下了，
			# 重启却发现没有（验收员 2026-10 发现的问题 7）。
			_warned[clue_id] = true
			_append_log("[!] %s 没能记下（心灯已熄或存档写入失败），可以再来看一次" % _clue_text(clue_id))


## 结案判定：数据契约里的条件全部满足 → +25（只结算一次）。
## 条件目前有两道：require_clues（线索齐）与 require_min_loop（遍数够）。
## require_ritual（画符）在 M0 还没有输入层，不拦结案（见文件头说明）。
func _check_resolution() -> void:
	if _resolved or _required_clues.is_empty():
		return
	if not PersistentMemoryManager.has_all_clues(_required_clues):
		return
	var loop_now: int = TimeLoopManager.get_loop_index()
	if _min_loop_required > 0 and loop_now < _min_loop_required:
		if not _gate_warned:
			_gate_warned = true
			_append_log("线索已齐，但这一案写明「须第 %d 遍之后才能结案」（现在第 %d 遍）" % [
				_min_loop_required + 1, loop_now + 1,
			])
			_refresh()
		return
	# ⑤ 仪式门槛：线索齐了不等于案结得了 —— 这一案要先把阙文照回原样。
	# 数据没读进来时放行（数据出问题不该把玩家锁死在案里），只在日志里说清。
	if _ritual_required:
		if _rune == null or not _rune.is_ok():
			if not _rune_gate_warned:
				_rune_gate_warned = true
				_append_log("[!] 结案要仪式「%s」，可仪式数据没读进来 —— 先放你结案" % _rune_name())
		elif not _rune.is_completed():
			if not _rune_gate_warned:
				_rune_gate_warned = true
				_append_log("线索已齐，但这一案要先做完仪式：%s（按 G 画符）" % _rune_name())
				_refresh()
			return
	_resolved = true
	_lamp.resolve_case()
	_append_log("[!] 结案：心灯 +%d（现在 %d）" % [HeartLamp.RESTORE_PER_CASE_RESOLVED, _lamp.get_value()])
	_refresh()


# ============================================================================
#  输入
# ============================================================================

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	# 画符模式下方向键/回车/退格归仪式用；G 随时开关，其它键照旧。
	if _rune_mode and _handle_rune_key(key.keycode):
		_refresh()
		return
	match key.keycode:
		KEY_TAB, KEY_E:
			_cycle_room(1)
		KEY_Q:
			_cycle_room(-1)
		KEY_F:
			_talk()
		KEY_B:
			_board_open = not _board_open
			_append_log("推演板：%s" % ("摊开" if _board_open else "收起"))
		KEY_H:
			_replay_last_route()
		KEY_G:
			_toggle_rune_mode()
		KEY_SPACE:
			_fast_forward()
		KEY_T:
			_apply_scale((_scale_index + 1) % SCALE_STEPS.size())
			_append_log("倍速 → %sx" % _scale_text())
			_refresh()
		KEY_P:
			TimeLoopManager.toggle_pause()
			_append_log("暂停" if TimeLoopManager.is_paused() else "继续")
			_refresh()
		KEY_R:
			TimeLoopManager.trigger_loop_reset()
		KEY_QUOTELEFT:
			_toggle_text_hud()
			_append_log("文字 HUD：%s" % ("开" if is_text_hud_visible() else "关（画面上看）"))
		_:
			if key.keycode >= KEY_1 and key.keycode <= KEY_9:
				_jump_room(key.keycode - KEY_1)
	_refresh()


## TAB/E / Q：在"真的走得到"的房间之间环选目的地（走不到的不进列表，免得按了没反应）。
func _cycle_room(step: int) -> void:
	if _case == null or _case.rooms.is_empty():
		return
	var size: int = _case.rooms.size()
	var index: int = _case.rooms.find(_player_room)
	if index < 0:
		index = 0
	for _try in range(size):
		index = (index + step + size) % size
		var candidate: String = _case.rooms[index]
		if not _is_reachable(candidate):
			continue
		_travel_to(candidate)
		return
	_append_log("这一遍哪儿也去不了（地图读进来了吗？）")


func _jump_room(index: int) -> void:
	if _case == null or index < 0 or index >= _case.rooms.size():
		return
	_travel_to(_case.rooms[index])


## 能不能走到（同一间房算"到得了"；没有地图数据时一律放行 = 调试旁路）。
func _is_reachable(room_id: String) -> bool:
	if _travel == null:
		return true
	if room_id == _player_room:
		return true
	return int(_travel.get_travel_seconds_to(room_id)) > 0


## "秒级重演"的雏形：把时钟快进到下一处有 NPC 拍点的时刻，到点自动回 1x。
func _fast_forward() -> void:
	if _case == null or not _case.ok:
		return
	var after: int = int(TimeLoopManager.get_elapsed_seconds())
	var target: int = _case.next_interesting_second(after)
	if target < 0:
		_append_log("本遍之后没有新的拍点了")
		return
	_fast_forward_to = target
	_apply_scale(-1)                      # -1 = 直接跳到最高倍速
	_append_log("快进到 %s（%sx）" % [_clock(target), _scale_text()])


func _apply_scale(index: int) -> void:
	if index < 0:
		_scale_index = SCALE_STEPS.size() - 1
	else:
		_scale_index = index % SCALE_STEPS.size()
	TimeLoopManager.set_time_scale(float(SCALE_STEPS[_scale_index]))


func _scale_text() -> String:
	var scale: float = float(SCALE_STEPS[_scale_index])
	return "%d" % int(scale) if scale >= 1.0 else "%.1f" % scale


# ============================================================================
#  画面
# ============================================================================

func _refresh() -> void:
	if _label == null:
		return
	_sync_rune()
	var elapsed: float = TimeLoopManager.get_elapsed_seconds()
	var second: int = int(elapsed)
	var lines: Array[String] = []

	lines.append("%s   ·   第 %d 遍余页   ·   %sx%s" % [
		_case.display_title() if _case != null and _case.ok else "（无案件数据）",
		TimeLoopManager.get_loop_index() + 1,
		_scale_text(),
		"   [已暂停]" if TimeLoopManager.is_paused() else "",
	])
	lines.append("余页 %s / %s   剩余 %d 秒   进度 %d%%" % [
		_clock(second), _clock(int(TimeLoopManager.get_loop_duration())),
		int(ceil(TimeLoopManager.get_remaining_seconds())),
		int(round(TimeLoopManager.get_progress_ratio() * 100.0)),
	])
	# 案卷规模钉在抬头：日志会滚走，但"这一遍有多少地方、多少处拍点"要一直在眼前。
	if _case != null and _case.ok:
		lines.append("%d 间房 / %d 个 NPC / %d 个节点 / 可观测线索 %d 处" % [
			_case.rooms.size(), _case.npc_count(), _case.total_nodes(), _windows.size(),
		])
	lines.append("心灯 %s %d/%d   已被划掉 %d 笔" % [
		_bar(_lamp.get_value(), _lamp.get_max_value()),
		_lamp.get_value(), _lamp.get_max_value(), _lamp.get_extinguish_count(),
	])
	if _lamp.is_extinguished():
		lines.append("   （灯已熄：还能记起的线索永久少一条，结案或恢复可重新点亮）")

	lines.append("你在 [%s]   此处还有：%s%s" % [
		_room_name(_player_room), _occupants_text(second), _travel_text(),
	])
	lines.append(_dialogue_hint_text(second))

	lines.append(_mutation_text())
	lines.append(_memory_text(second))
	_track_progress()
	lines.append(_board_conflict_text())
	var stuck_text := _stuck_text()
	if not stuck_text.is_empty():
		lines.append(stuck_text)
	lines.append("线索 %d 条%s" % [PersistentMemoryManager.get_clue_count(), _resolve_text()])

	var clues: Array[String] = _lamp.get_available_clues()
	for index in range(clues.size()):
		lines.append("   * %s" % _clue_text(clues[index]))
	if clues.is_empty():
		lines.append("   （记忆里还没有线索：去有人的房间蹲守拍点）")

	var forgotten: Array[String] = _lamp.get_forgotten_clues()
	for clue_id in forgotten:
		lines.append("   x 已遗忘：%s" % _clue_text(clue_id))

	if _board_open:
		lines.append("-------- 推演板（B 收起） --------")
		for board_line in _board.board_lines(14):
			lines.append("   " + String(board_line))

	if _rune_mode:
		lines.append("-------- 画符（G 收起） --------")
		for rune_line in _rune_panel_lines():
			lines.append("   " + String(rune_line))
	else:
		var rune_hint := _rune_hint_text()
		if not rune_hint.is_empty():
			lines.append(rune_hint)

	lines.append(_next_beat_text(second))
	lines.append("-------- 最近发生 --------")
	for index in range(mini(LOG_LINES, _log.size())):
		lines.append("   " + _log[index])
	lines.append("按键： TAB/E 去下一间  Q 上一间  1-9 去第 N 间（都按走位耗时走）  F 交谈  B 推演板  H 重演上一遍路线  G 画符  空格 快进到下一处  T 倍速  P 暂停  R 强制重开")

	_label.text = "\n".join(lines)


## 结案条件的可读描述：让玩家一眼看到"还差什么"（而不是集齐了却不知道为什么没结案）。
func _resolve_text() -> String:
	if _required_clues.is_empty():
		return ""
	var have: int = 0
	for clue_id in _required_clues:
		if PersistentMemoryManager.has_clue(clue_id):
			have += 1
	var parts: Array[String] = ["线索 %d/%d" % [have, _required_clues.size()]]
	if _min_loop_required > 0:
		var loop_now: int = TimeLoopManager.get_loop_index()
		if loop_now < _min_loop_required:
			# 玩家口径（1 基）：核心与数据里的 require_min_loop 是 0 基的 loop_index，
			# 写"须第 8 遍"会让玩家数到第 8 遍发现结不了案 —— 显示时 +1。
			parts.append("须第 %d 遍之后（现在第 %d 遍）" % [_min_loop_required + 1, loop_now + 1])
		else:
			parts.append("遍数已够")
	if _ritual_required:
		if _rune != null and _rune.is_ok():
			parts.append("仪式「%s」%s" % [_rune_name(), "已做完" if _rune.is_completed() else "还没做（G 画符）"])
		else:
			parts.append("还需画符（仪式数据未就绪，暂不拦结案）")
	if _resolved:
		parts.append("已结案")
	return "（%s）" % "，".join(parts)


## 下一个拍点提示（画面底栏那一行）。这是**给玩家看**的，所以：
##   * 房间一律用中文名（_room_name），不甩 baihutai|west 这种数据 id；
##   * 这一遍**走不到**的房间（如案一的"页外"）不列出来 —— 列了只会让人白跑一趟；
##   * 最多列 3 间，其余收成"等 N 处"（底栏就一行，铺不下全村的拍点）。
func _next_beat_text(second: int) -> String:
	if _case == null or not _case.ok:
		return "（无）"
	var target: int = _case.next_interesting_second(second)
	if target < 0:
		return "本遍没有更多拍点了（心灯还在流逝，可以按 R 重开）"
	var rooms: Dictionary = _case.rooms_at(target)
	var names: Array[String] = []
	var more: int = 0
	for room in rooms.keys():
		var room_id: String = String(room)
		if not _is_reachable(room_id):
			continue
		if names.size() >= 3:
			more += 1
			continue
		names.append(_room_name(room_id))
	if names.is_empty():
		return "%s 有拍点，但都在这一遍去不到的地方" % _clock(target)
	var text: String = "%s 下一处拍点：%s" % [_clock(target), "、".join(names)]
	if more > 0:
		text += " 等 %d 处" % (names.size() + more)
	return text


func _occupants_text(second: int) -> String:
	if _case == null or not _case.ok:
		return "（无）"
	var rooms: Dictionary = _case.rooms_at(second)
	if not rooms.has(_player_room):
		return "空无一人"
	return ", ".join(rooms[_player_room])


## 线索显示文本：优先用节点上的 note（作者写给玩家看的一句话），否则退回 id。
func _clue_text(clue_id: String) -> String:
	for window in _windows:
		if String(window["clue_id"]) == clue_id:
			var note: String = String(window["note"])
			if not note.is_empty():
				return note
			break
	return clue_id


## 心灯进度条。刻意只用 ASCII：# 与 -（Godot 默认字体不含 U+2588 全块字符，
## 用制表块会渲染成豆腐块）。正式 UI 会换成真正的贴图/Shader，这里只要能看清。
func _bar(value: int, max_value: int) -> String:
	var width: int = 10
	var filled: int = 0
	if max_value > 0:
		filled = clampi(int(round(float(value) / float(max_value) * float(width))), 0, width)
	return "[%s%s]" % ["#".repeat(filled), "-".repeat(width - filled)]


## 时钟格式化放在表现层：核心层只给"第几秒"，不关心 mm:ss。
func _clock(seconds: int) -> String:
	var safe: int = maxi(seconds, 0)
	return "%02d:%02d" % [safe / 60, safe % 60]


## 记一条日志（最新的在最前面）。
func _append_log(text: String) -> void:
	_log.push_front(text)
	if _log.size() > 40:
		_log.resize(40)


## 开发向信息**只进 stdout**，不进玩家的「最近发生」（Phase 3 清屏：界面是给玩家的，
## 不是控制台）。判据：这条信息能改变玩家此刻的操作吗？不能 ⇒ 走这里。
## 仍然是一条真实输出：浏览器控制台 / 命令行都看得到（排障不用改代码）。
func _dev_note(text: String) -> void:
	print("[SliceHUD] " + text)


# ============================================================================
#  推演板 / 矛盾高亮 / 卡关预警 / 一键重演（M1 第四步）
#  —— 对应 docs/market/01 §2.5 的死法 1（循环内重复劳动）与死法 3（引导缺失卡关）。
# ============================================================================

## 记下"上一次有新线索入录是哪一遍"。卡关预警的分母就是这个。
func _track_progress() -> void:
	var count: int = _lamp.get_available_clues().size()
	if count == _last_progress_clue_count:
		return
	if _board != null:
		_board.refresh()                  # 线索一变，板子立刻重算（多一条就可能点亮一处）
	if count > _last_progress_clue_count:
		_last_progress_loop = TimeLoopManager.get_loop_index()
	_last_progress_clue_count = count


## 主视图顶上那一行"对不上"：把最该注意的矛盾顶到眼前（B 键看全部）。
func _board_conflict_text() -> String:
	if _board == null or not _board.is_ok():
		return "推演板：（数据没读进来）"
	var ready: Array = _board.ready_conflicts()
	if ready.is_empty():
		return "推演板：还没凑出对不上的地方（线索 %d 条）" % _lamp.get_available_clues().size()
	var top: Variant = ready[0]
	if top == null or not (top is Dictionary):
		return "推演板：还没凑出对不上的地方（线索 %d 条）" % _lamp.get_available_clues().size()
	var title: String = String((top as Dictionary).get("title", ""))
	if bool((top as Dictionary).get("resolved", false)):
		return "推演板：%d 处对不上，最前一处已收束 —— %s" % [ready.size(), title]
	return "⚠ 对不上：%s（共 %d 处 · B 看推演板）" % [title, ready.size()]


## 卡关预警：连着两遍没有新线索就主动把落点点出来（替代看攻略）。
func _stuck_text() -> String:
	if _board == null or not _board.is_ok():
		return ""
	var loops_without_progress: int = TimeLoopManager.get_loop_index() - _last_progress_loop
	if loops_without_progress < 2:
		return ""
	var hint: Variant = _board.stuck_hint(loops_without_progress, TimeLoopManager.get_loop_index())
	if hint == null or not (hint is Dictionary) or (hint as Dictionary).is_empty():
		return ""
	return "提示（连着 %d 遍没有新线索）：%s" % [
		loops_without_progress, String((hint as Dictionary).get("text", "")),
	]


## H 键：把上一遍走过的房间照着重走一遍 —— 任何已经解锁过的动作都不该让玩家再手动点一次。
func _replay_last_route() -> void:
	if _last_loop_route.is_empty():
		_append_log("还没有可重演的路线（先走一遍）")
		_refresh()
		return
	_replay_queue = _last_loop_route.duplicate()
	if not _replay_queue.is_empty() and _replay_queue[0] == _player_room:
		_replay_queue.remove_at(0)
	_append_log("重演上一遍路线：%d 站" % _replay_queue.size())
	_drive_replay()
	_refresh()


## 重演驱动：人站住了就走下一站（余页时钟每秒调一次，和走位同一个节拍）。
func _drive_replay() -> void:
	if _replay_queue.is_empty() or _travel == null or _travel.is_moving():
		return
	var next: String = _replay_queue[0]
	if next == _player_room:
		_replay_queue.remove_at(0)
		return
	_replay_queue.remove_at(0)
	_travel_to(next)


# ============================================================================
#  ⑤ 画符（结案的仪式）
# ============================================================================

## 每一帧画面都同步一次：输入层要靠"人在哪、第几遍"判能不能开画。
func _sync_rune() -> void:
	if _rune == null:
		return
	_rune.set_room(_player_room)
	_rune.set_loop_index(TimeLoopManager.get_loop_index())
	if _lamp != null:
		_rune.set_memory_manager(_lamp)   # 顺手把"心灯还记得哪些线索"同步给输入层


## G 键：进/出画符模式。进的时候顺手开画（不满足门槛就把原因说清楚）。
func _toggle_rune_mode() -> void:
	_rune_mode = not _rune_mode
	if not _rune_mode:
		_append_log("画符：收起")
		_refresh()
		return
	if _rune == null or not _rune.is_ok():
		_append_log("画符：仪式数据没读进来")
		_refresh()
		return
	if _rune.is_running():
		_append_log("画符：接着画「%s」" % _rune_name())
		_refresh()
		return
	if _rune.is_completed():
		_append_log("画符：「%s」已经做完了" % _rune_name())
		_refresh()
		return
	if _rune.start_rune(""):
		_append_log("画符：起手「%s」 —— %s" % [_rune_name(), _rune.get_last_message()])
	else:
		_append_log("画符：还开不了 —— %s" % _rune.get_last_message())
	_refresh()


## 画符模式下的按键。返回 true = 这个键归仪式用，外层不要再处理。
func _handle_rune_key(keycode: int) -> bool:
	if keycode == KEY_G:
		return false                      # G 永远归外层：开关模式
	if _rune == null or not _rune.is_ok():
		return false
	if not _rune.is_running():
		return false                      # 没开画时其它键照旧（走动、交谈都不该被锁）
	match keycode:
		KEY_UP:
			return _feed_rune_token("up")
		KEY_DOWN:
			return _feed_rune_token("down")
		KEY_LEFT:
			return _feed_rune_token("left")
		KEY_RIGHT:
			return _feed_rune_token("right")
		KEY_KP_7:
			return _feed_rune_token("up_left")
		KEY_KP_9:
			return _feed_rune_token("up_right")
		KEY_KP_1:
			return _feed_rune_token("down_left")
		KEY_KP_3:
			return _feed_rune_token("down_right")
		KEY_BACKSPACE:
			if not _rune.current_tokens().is_empty():
				_rune.undo_token()
				_append_log("画符：退一笔方向（还有 %d 个）" % _rune.current_tokens().size())
			elif _rune.undo_stroke():
				_append_log("画符：整笔退掉（现在第 %d 笔）" % (_rune.current_stroke_index() + 1))
			else:
				_append_log("画符：没有可退的")
			return true
		KEY_ENTER, KEY_KP_ENTER:
			return _confirm_rune_step()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			return _choose_rune_option(keycode - KEY_1)
		_:
			return false


func _feed_rune_token(token: String) -> bool:
	# 输入层的约定：只有 drawing 状态才收 token，而每次 commit 之后会回到 step
	# ⇒ 要喂第一笔（或上一笔刚落完）时，表现层先替玩家起笔。
	if String(_rune.get_state()) != RuneInput.STATE_DRAWING:
		_rune.begin_stroke()
	if not _rune.feed_token(token):
		return false
	var tokens: Array = _rune.current_tokens()
	_append_log("画符：%s（%s）" % [
		_rune_direction_text(token), _rune_tokens_text(tokens),
	])
	return true


## 回车：画符步 = 交这一笔；门槛/念白步 = 确认往下走。
func _confirm_rune_step() -> bool:
	var step: Variant = _rune.get_current_step()
	if step != null and bool(step.call("is_draw")):
		# 三笔已经落齐 ⇒ 回车是"接着往下"（交给下面的 advance()）；
		# 还没画够、笔尖又是空的 ⇒ 提醒描一笔。
		var tokens: Array = _rune.current_tokens()
		if tokens.is_empty() and int(_rune.current_stroke_index()) >= int(step.call("stroke_count")):
			pass
		elif tokens.is_empty():
			_append_log("画符：这一笔还是空的（方向键描一笔，退格退）")
			return true
		else:
			var result: Dictionary = _rune.commit_stroke()
			var status: String = String(result.get("status", ""))
			if status == "ok":
				_append_log("画符：%s 落笔对了（第 %d 笔）" % [
					String(result.get("stroke_name", "")), int(result.get("stroke_index", 0)) + 1,
				])
				if bool(result.get("step_done")):
					_append_log("画符：三笔齐 —— 阙文回来了。回车接着往下")
			else:
				_append_log("画符：%s" % String(result.get("hint", "")))
			return true
	if _rune.advance():
		var step_now: Variant = _rune.get_current_step()
		var step_name: String = "" if step_now == null else String(step_now.get("name"))
		if _rune.is_completed():
			_append_log("[+] 仪式完成：%s" % _rune_name())
			_check_resolution()
		else:
			_append_log("画符：%s" % step_name)
		return true
	_append_log("画符：这一步还走不了 —— %s" % _rune.get_last_message())
	return true


func _choose_rune_option(index: int) -> bool:
	var step: Variant = _rune.get_current_step()
	if step == null or not bool(step.call("is_choice")):
		return false
	var options: Array = step.get("options")
	if index < 0 or index >= options.size():
		return false
	var option: Variant = options[index]
	var result: Dictionary = _rune.choose_option(String(option.get("option_id")))
	_append_log("画符：%s" % String(result.get("reply", "")))
	if bool(result.get("correct")) and bool(result.get("step_done")):
		_append_log("画符：这一步过了，回车往下")
	return true


## 画符面板：当前该干什么 + 已画到哪，全用数据里的中文。
func _rune_panel_lines() -> Array[String]:
	var lines: Array[String] = []
	if _rune == null or not _rune.is_ok():
		lines.append("（仪式数据没读进来）")
		return lines
	if _rune.is_completed():
		lines.append("「%s」已做完。" % _rune_name())
		return lines
	if not _rune.is_running():
		lines.append("「%s」还没起手：%s" % [_rune_name(), _rune_block_reason()])
		return lines
	var step: Variant = _rune.get_current_step()
	if step != null:
		lines.append(_rune.describe_step())
	if step != null and bool(step.call("is_draw")):
		var strokes: Array = step.get("strokes")
		var at: int = _rune.current_stroke_index()
		if at < strokes.size():
			var stroke: Variant = strokes[at]
			lines.append("第 %d/%d 笔「%s」：%s" % [
				at + 1, strokes.size(), String(stroke.get("name")),
				_rune_pattern_text(stroke.get("pattern")),
			])
		var drawn: int = _rune.drawn_strokes().size()
		if drawn > 0:
			lines.append("已经落笔：%d 笔" % drawn)
		var tokens: Array = _rune.current_tokens()
		lines.append("这一笔现在画到：%s%s" % [
			_rune_tokens_text(tokens), "" if tokens.is_empty() else "（回车落笔 / 退格退）",
		])
	for line in _rune.prompt_lines(3):
		lines.append(String(line))
	return lines


## 没开画符模式时的一行提示：够条件了就点一下，不够就说差什么。
func _rune_hint_text() -> String:
	if not _ritual_required or _rune == null or not _rune.is_ok():
		return ""
	if _rune.is_completed():
		return ""
	if _rune.is_running():
		return "画符还没收起：按 G 接着画"
	if _rune.can_start(""):
		return "G 画符：把阙文照回原样（%s）" % _rune_name()
	return ""


func _rune_block_reason() -> String:
	if _rune == null:
		return "输入层没起来"
	if not _rune.is_ok():
		return _rune.error_summary()
	var message: String = _rune.get_last_message()
	if not message.is_empty():
		return message
	return "先走到该在的房间、凑齐该有的线索"


func _rune_name() -> String:
	if _runes == null or _runes.count() == 0:
		return ""
	var rune_id: String = String(_runes.rune_ids()[0])
	var entry: Variant = _runes.get_rune(rune_id)
	if entry == null:
		return rune_id
	var display: String = String(entry.get("display_name"))
	return display if not display.is_empty() else String(entry.get("name"))


## 方向 token → 中文（玩家看到的是"回、照、录"的笔顺，不是 up/down）。
func _rune_direction_text(token: String) -> String:
	match token:
		"up":
			return "上"
		"down":
			return "下"
		"left":
			return "左"
		"right":
			return "右"
		"up_left":
			return "左上"
		"up_right":
			return "右上"
		"down_left":
			return "左下"
		"down_right":
			return "右下"
	return token


func _rune_tokens_text(tokens: Array) -> String:
	var parts: Array[String] = []
	for token in tokens:
		parts.append(_rune_direction_text(String(token)))
	return "".join(parts) if not parts.is_empty() else "（空）"


## 把数据里的参考方向串念出来（提示用；判对判错都在输入层）。
func _rune_pattern_text(pattern: Variant) -> String:
	var parts: Array[String] = []
	if pattern is Array:
		for token in (pattern as Array):
			parts.append(_rune_direction_text(String(token)))
	return "、".join(parts)


# ============================================================================
#  M2 表现层接口：scripts/ui/play_view.gd 只读 present_state()、只走 request_*
#  （这一节全是附加的只读访问器与转发，不改任何既有行为 —— 文字 HUD 与
#   tests/test_slice_hud.gd 的 142 项断言都照旧。）
# ============================================================================

## 这一帧该画什么，整包交给表现层。
func present_state() -> Dictionary:
	var second: int = int(TimeLoopManager.get_elapsed_seconds())
	var rooms: Array[String] = []
	if _case != null and _case.ok:
		rooms = _case.rooms.duplicate()

	var reachable: Dictionary = {}
	for room_id in rooms:
		if _map == null:
			reachable[room_id] = 0
		elif _is_reachable(room_id):
			reachable[room_id] = _map.travel_seconds(_player_room, room_id)

	var clue_ids: Array = _lamp.get_available_clues()
	var clue_names: Dictionary = {}
	for clue_id in clue_ids:
		clue_names[String(clue_id)] = _board.card_name(String(clue_id)) if _board != null else String(clue_id)

	var npcs: Array = []
	if _case != null and _case.ok:
		for npc_id in _case.npc_order:
			var schedule: Variant = _case.npcs.get(npc_id)
			var room: String = String(schedule.room_at(second)) if schedule != null else ""
			var stage: int = _memory.get_stage(String(npc_id)) if _memory != null else 0
			npcs.append({
				"id": String(npc_id),
				"name": _npc_display_name(String(npc_id)),
				"room": room,
				"here": room == _player_room,
				"stage": stage,
			})

	var conflicts: Array = []
	if _board != null:
		for item in _board.ready_conflicts():
			conflicts.append({
				"title": String(item.get("title", "")),
				"text": String(item.get("text", "")),
				"severity": String(item.get("severity", "")),
				"resolved": bool(item.get("resolved", false)),
			})

	var travel: Dictionary = {
		"moving": _travel.is_moving() if _travel != null else false,
		"from": _travel.get_from_room() if _travel != null else _player_room,
		"to": _travel.get_target_room() if _travel != null else "",
		"remaining": _travel.get_remaining_seconds() if _travel != null else 0.0,
		"total": _travel.get_travel_seconds() if _travel != null else 0.0,
		"route": _route.duplicate(),
	}

	var dialogue: Dictionary = {"active": false}
	if bool(_dialogue_view.get("active", false)):
		dialogue = {
			"active": true,
			"speaker": String(_dialogue_view.get("speaker", "")),
			"line": String(_dialogue_view.get("line", "")),
			"reply": String(_dialogue_view.get("reply", "")),
			"options": (_dialogue_view.get("options", []) as Array).duplicate(true),
		}

	var rune: Dictionary = {
		"active": _rune_mode,
		"ready": _runes != null and _rune != null and _rune.is_ok(),
		"running": _rune.is_running() if _rune != null else false,
		"completed": _rune.is_completed() if _rune != null else false,
		"name": _rune_name() if _rune_mode else "",
		"step_name": "",
		"step_index": _rune.get_step_index() if _rune != null else -1,
		"step_count": _rune.get_step_count() if _rune != null else 0,
		"stroke_index": _rune.current_stroke_index() if _rune != null else -1,
		"stroke_count": 0,
		"strokes": [],
		"tokens": _rune.current_tokens() if _rune != null else [],
		"drawn": _rune.drawn_strokes().size() if _rune != null else 0,
		"message": _rune.get_last_message() if _rune != null else "",
		"prompts": _rune.prompt_lines(3) if _rune != null else [],
	}
	if _rune != null and _rune.is_ok():
		var step: Variant = _rune.get_current_step()
		if step != null:
			rune["step_name"] = String(step.get("name"))
			var strokes: Array = []
			for stroke in (step.get("strokes") as Array):
				strokes.append({
					"name": String(stroke.get("name")),
					"pattern": (stroke.get("pattern") as Array).duplicate(),
				})
			rune["strokes"] = strokes
			rune["stroke_count"] = strokes.size()

	return {
		"ok": _case != null and _case.ok,
		"title": _case.display_title() if _case != null and _case.ok else "",
		"loop_index": TimeLoopManager.get_loop_index(),
		"second": second,
		"duration": int(TimeLoopManager.get_loop_duration()),
		"remaining": int(ceil(TimeLoopManager.get_remaining_seconds())),
		"elapsed_total": _elapsed_total,
		"paused": TimeLoopManager.is_paused(),
		"room": _player_room,
		"room_name": _room_name(_player_room),
		"rooms": rooms,
		"reachable": reachable,
		"lamp": _lamp.get_value(),
		"lamp_max": _lamp.get_max_value(),
		"lamp_lost": _lamp.get_extinguish_count(),
		"lamp_warning": _lamp_warning_text(),
		"extinguished": _lamp.is_extinguished(),
		"clues": clue_ids,
		"clue_names": clue_names,
		"clue_total": _board.total_clue_count() if _board != null else clue_ids.size(),
		"required": _required_clues.duplicate(),
		"resolved": _resolved,
		"ritual_required": _ritual_required,
		"ritual_ready": _runes != null and _rune != null and _rune.is_ok(),
		"ritual_done": _rune.is_completed() if _rune != null else false,
		"min_loop": _min_loop_required,
		"npcs": npcs,
		"conflicts": conflicts,
		"board_open": _board_open,
		"board_lines": (_board.board_lines(14) if _board != null else []),
		"stuck": _stuck_text(),
		"next_beat": _next_beat_text(second),
		"occupants": _occupants_text(second),
		"log": _log.slice(0, mini(LOG_LINES, _log.size())),
		"travel": travel,
		"dialogue": dialogue,
		"rune": rune,
		"text_hud": is_text_hud_visible(),
	}


## 表现层：走过去（走位耗时照旧由核心时钟驱动；走不到就说一句）。
## 心灯还能撑几遍：最坏情况 = 每遍都跑满（重开 -8 + 余页之内每秒按 DRAIN_PER_SECOND，现值 0.02）。
## 这条是给玩家的诚实交代：数值撑不住时，别让他自己一头撞上"永久划掉一条记忆"。
func _lamp_warning_text() -> String:
	if _lamp == null:
		return ""
	var worst_per_loop: float = float(HeartLamp.DRAIN_PER_LOOP_RESET) \
		+ float(HeartLamp.DRAIN_PER_SECOND) * TimeLoopManager.get_loop_duration()
	if _lamp.is_extinguished():
		return "灯已熄：再重开会再划掉一笔；余页之外真实时间每分钟回 1 点"
	var loops_left: int = int(floor(float(_lamp.get_value()) / maxf(worst_per_loop, 0.01)))
	if loops_left <= 1:
		return "警告：照这样跑满每遍约 -%d 点，再走一遍就见底（结案 +25）" % int(ceil(worst_per_loop))
	return "照这样跑满每遍约 -%d 点，还能撑 %d 遍（结案 +25）" % [int(ceil(worst_per_loop)), loops_left]


func request_travel(room_id: String) -> void:
	if room_id.is_empty() or _case == null:
		return
	if room_id == _player_room:
		return
	_dialogue_view = {}
	_travel_to(room_id)


## 表现层：和此刻同屋的人说话（等于按 F）。
func request_talk() -> void:
	_talk()
	_refresh()


## 表现层：推演板开合（等于按 B）。
func request_board() -> void:
	_board_open = not _board_open
	_append_log("推演板：%s" % ("摊开" if _board_open else "收起"))
	_refresh()


## 表现层：画符模式开合（等于按 G）。
func request_rune() -> void:
	_toggle_rune_mode()


## 表现层：回到起点重开这一遍（等于按 R）。
func request_reset() -> void:
	TimeLoopManager.trigger_loop_reset()


## 表现层：**开新档 / 重新开始一案**（结案结算面板上的按钮走这里）。
## 语义与 request_reset() 完全不同：那个是"这一遍重来"（心灯 -8，记忆全留），
## 这个是"把这一局抹掉重开"（记忆、心灯、推演板、画符、日志全归零）。
##
## 为什么最后是"重载场景"而不是逐项重置：
##   心灯 / 推演板 / 画符 / 重演队列 / 日志各有一份"这一局"的状态，逐项重置漏一个
##   就是脏状态；重载场景走的正是冷启动那条路径（tests/test_slice_hud.gd 第一节
##   就是钉它的），代价只是多读一次数据（本案数据很小）。
## 落盘也一并清干净：clue_store 的主档 / .tmp / .bak / .corrupt 全删 —— 否则下次
## 开档 restore_from_store() 又会把刚抹掉的记忆"想起来"。
func request_restart_case() -> void:
	ClueStore.erase_store()
	PersistentMemoryManager.reset_for_new_game()
	TimeLoopManager.reset_loop_index()      # 核心：编号回到 0（第 1 遍），不广播 loop_reset
	# 编号归零之后要**重新起钟**：余页回到满的一页（否则"开新档"却接着上一局的剩余秒数跑，
	# 玩家会看到第 1 遍一开局就只剩四分钟）。整场重载时这一句会被新场景的 _ready() 再走一遍，
	# 只是幂等；但不重载的场景（编辑器里单跑 HUD、无头测试）靠它才自洽。
	TimeLoopManager.start_loop()
	_elapsed_total = 0.0
	_elapsed_mark = 0.0
	_resolved = false
	_gate_warned = false
	_rune_gate_warned = false
	_log.clear()
	_append_log("开新档：余页回到第 1 遍，线索与心灯都从头记起")
	_refresh()
	var tree: SceneTree = get_tree()
	if tree != null and tree.current_scene != null and tree.current_scene == owner:
		tree.reload_current_scene()


## 文字 HUD（整屏文本）的显示开关：开 = 老的可玩切片样子，关 = 看画面。
func set_text_hud_visible(on: bool) -> void:
	if _label != null:
		_label.visible = on


func is_text_hud_visible() -> bool:
	return _label != null and _label.visible


func _toggle_text_hud() -> void:
	set_text_hud_visible(not is_text_hud_visible())

