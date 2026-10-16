extends RefCounted
## ============================================================================
##  player_travel.gd —— 玩家走位状态机（实体层；不引用任何 Autoload）
## ----------------------------------------------------------------------------
##  它解决的问题：
##    走位耗时必须能被"余页秒数"驱动。表现层每一帧把它接上 TimeLoopManager.tick()，
##    于是"现在能不能赶到碑阴"变成一道真实的算术题，而不是按一下 TAB 就换房。
##
##  契约（M1 走位耗时）：
##    1. **移动期间不能再次发起移动**：is_moving() 为真时 start_move() 返回 0（拒绝），
##       想改主意必须先 cancel_move()；
##    2. **到达时刻是整数秒拍点**：耗时以"点下去那一刻"算好的整数秒为准（_total_seconds），
##       内部用浮点累积（_elapsed_in_move），到达判定是 `已走 + dt >= 耗时 - 容差`
##       —— 绝不写 `已走 == 耗时` 这种整数比较（浮点累加会永远差一点）；
##    3. **可被倍速逐秒补发**：tick(1/60) 跑 480 次与 tick(8.0) 跑一次结果完全一致
##       （与 time_loop_manager.tick() 的用法一致：小步、多次、顺序推进）；
##    4. **零第三方依赖**：只依赖 map_loader.gd（preload），不引用 Autoload、不碰 UI。
##
##  用法（表现层）：
##      const MapLoader = preload("res://scripts/data/map_loader.gd")
##      const PlayerTravel = preload("res://scripts/entities/player_travel.gd")
##      var travel := PlayerTravel.new(MapLoader.load_for_case(1), "baihutai")
##      var seconds := travel.start_move("baihutai_bei")   # 0 = 走不了
##      if seconds > 0:
##          # 每帧：travel.tick(delta)，到达时 is_moving() 变 false、get_room() 变碑阴
##          pass
## ============================================================================


## 到达判定的**相对**容差（秒/秒）。浮点累加做不到"刚好等于耗时"：
## 8.0 - 7.999999 = 1.0000000000287557e-06，误差随耗时线性增长。
## 所以容差按耗时缩放（_arrive_epsilon() = 耗时 * 1e-9），既远小于任何真实 dt（60fps 也有 0.016 秒），
## 又比 double 累加的舍入尾数（相对 1e-16 量级）大几个数量级。
## 对外一律报整数秒（get_remaining_seconds / get_travel_seconds）。
const ARRIVE_EPSILON_RATIO: float = 0.000000001

## 走位图（map_loader.gd 的 RoomMap 实例）。用无类型声明，避免依赖 class_name。
var _map = null
var _map_loaded: bool = false

## 玩家现在实际所在的房间（移动途中仍是出发地）。
var _room: String = ""

## 移动状态。
var _moving: bool = false
var _from_room: String = ""
var _to_room: String = ""
var _total_seconds: int = 0
var _elapsed_in_move: float = 0.0

## 统计（HUD / 测试用；不参与任何判定）。
var _travelled_seconds: int = 0
var _move_count: int = 0
var _last_arrived_room: String = ""


## 新走位机：map 由 map_loader.gd 装载，start_room 是玩家初始所在房间（默认取第一个房间）。
static func create(map, start_room: String = ""):
	var instance = new(map, start_room)
	return instance


func _init(map = null, start_room: String = "") -> void:
	_map = map
	_map_loaded = map != null
	var initial := start_room
	if initial.is_empty() and _map_loaded:
		initial = _map.default_room()
	if _map_loaded and not _map.has_room(initial):
		initial = _map.default_room()
	_room = initial


# ---------------------------------------------------------------------------
#  查询
# ---------------------------------------------------------------------------

## 玩家现在所在的房间。移动途中返回**出发地**（到达那一刻才变）—— 位置永远诚实。
func get_room() -> String:
	return _room


func get_map():
	return _map


func is_map_loaded() -> bool:
	return _map_loaded


## 能否从这里走到 room：地图在、房间在、不是当前房间、且耗时为正。
func can_go(room: String) -> bool:
	if not _map_loaded:
		return false
	if room == _room:
		return false
	if not _map.has_room(room):
		return false
	return _map.travel_seconds(_room, room) > 0


## 到某房间的最短路房间序列（含起点与终点）。走不到返回空数组。
func get_route_to(room: String) -> Array[String]:
	if not _map_loaded:
		return [] as Array[String]
	return _map.find_path(_room, room)


## 从当前房间到 room 的耗时（整数秒）。走不到（或就是当前房间）返回 0。
func get_travel_seconds_to(room: String) -> int:
	if not _map_loaded:
		return 0
	return _map.travel_seconds(_room, room)


func is_moving() -> bool:
	return _moving


## 移动中的目的房间；没在移动时返回空串。
func get_target_room() -> String:
	return _to_room if _moving else ""


## 移动中的出发房间；没在移动时返回空串。
func get_from_room() -> String:
	return _from_room if _moving else ""


## 本次移动的总耗时秒数（整数拍点）；没在移动时为 0。
func get_travel_seconds() -> int:
	return _total_seconds if _moving else 0


## 本次移动的到达容差（秒）。到达判定用 `已走 + dt >= 耗时 - 容差`，
## 容差按耗时缩放：远小于任何真实 dt（60fps 也有 0.016 秒），又远大于 double 累加的舍入尾数。
func get_arrive_epsilon() -> float:
	if not _moving:
		return 0.0
	return _arrive_epsilon()


## 本次移动还剩多少秒（秒级采样，向上取整到整数秒）；没在移动时为 0。
func get_remaining_seconds() -> int:
	if not _moving:
		return 0
	return maxi(ceili(_remaining()), 0)


## 本次移动内部已经累积走了多少秒（浮点）。只给调试/测试看，正常逻辑不要依赖它。
func get_elapsed_for_debug() -> float:
	return _elapsed_in_move


## 本遍/本次会话累计走过的秒数（整数秒）—— HUD 想显示"你花了多少时间在路上"时用。
func get_total_travelled_seconds() -> int:
	return _travelled_seconds


func get_move_count() -> int:
	return _move_count


# ---------------------------------------------------------------------------
#  命令
# ---------------------------------------------------------------------------

## 直接落位（换遍重开、装存档、调试直跳用）。会取消进行中的移动。返回是否成功。
func set_room(room: String) -> bool:
	if not _map_loaded:
		return false
	if not _map.has_room(room):
		return false
	_room = room
	_reset_movement()
	return true


## 出发。返回本次耗时秒数；**0 表示走不了**（已在移动中 / 没有路 / 就是当前房间）。
## 移动期间不能再次发起移动 —— 先 cancel_move() 再走。
func start_move(room: String) -> int:
	if _moving:
		return 0
	if not can_go(room):
		return 0
	var seconds: int = int(_map.travel_seconds(_room, room))
	if seconds <= 0:
		return 0
	_from_room = _room
	_to_room = room
	_total_seconds = seconds
	_elapsed_in_move = 0.0
	_moving = true
	return seconds


## 推进移动。delta 是"余页秒数"（与 time_loop_manager.tick() 同一口径）：
## 多次小 dt 与一次大 dt 结果一致。走完就切换房间并返回 true（调用方据此刷新 HUD）。
##
## 实现要点：用**累加已走时间**而不是**递减剩余时间**（`_elapsed_in_move += delta` 对
## `_total_seconds` 取整比较），这样同一串 dt 不管怎么切分，累加到的都是同一个和，
## 不会因为每一步的舍入在末尾差出一整个 tick。
func tick(delta: float) -> bool:
	if not _moving:
		return false
	if delta <= 0.0:
		return false
	var total := float(_total_seconds)
	if _elapsed_in_move + delta >= total - _arrive_epsilon():
		# --- 到达：按"耗时秒数"这个整数拍点结算，多出来的零头不带进下一段移动 ---
		_room = _to_room
		_travelled_seconds += _total_seconds
		_move_count += 1
		var arrived_room := _room
		_reset_movement()
		_last_arrived_room = arrived_room
		return true
	_elapsed_in_move += delta
	return false


## 半途改主意：停在原地（当前房间不变），返回是否真的取消了移动。
func cancel_move() -> bool:
	if not _moving:
		return false
	_reset_movement()
	return true


## 回到出发地并清空状态（换遍重开用）。
func reset_to(room: String) -> bool:
	if not set_room(room):
		return false
	_travelled_seconds = 0
	_move_count = 0
	_last_arrived_room = ""
	return true


## 上一次真正到达的房间（供表现层播提示）；没到达过返回空串。
func get_last_arrived_room() -> String:
	return _last_arrived_room


# ---------------------------------------------------------------------------
#  内部
# ---------------------------------------------------------------------------

## 当前这次移动的到达容差（按耗时缩放，见 ARRIVE_EPSILON_RATIO 的说明）。
func _arrive_epsilon() -> float:
	return float(_total_seconds) * ARRIVE_EPSILON_RATIO


## 本次移动还剩多少秒（浮点；没在移动时为 0）。
func _remaining() -> float:
	if not _moving:
		return 0.0
	return maxf(float(_total_seconds) - _elapsed_in_move, 0.0)


## 清空移动状态（不动 _room）。
func _reset_movement() -> void:
	_moving = false
	_from_room = ""
	_to_room = ""
	_total_seconds = 0
	_elapsed_in_move = 0.0
