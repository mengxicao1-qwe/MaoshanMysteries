extends Node
## ============================================================================
##  time_loop_manager.gd —— 时间循环控制器（核心系统 / Core）
## ----------------------------------------------------------------------------
##  单一职责：只管理"时间"这一件事。
##    1. 一轮循环的长度（默认 7 分钟 = 420 秒）与倒计时推进；
##    2. 时间流速缩放（time_scale），用于调试快进或剧情演出；
##    3. 时间耗尽 / 外部强制重置时，先把时钟清零，再开启下一轮循环；
##    4. 通过下方信号(t信号)对外广播状态变化。
##
##  设计约束（必须遵守）：
##    * 本脚本【绝不】引用任何 UI、场景节点、NPC 控制器或具体玩法逻辑；
##      表现层只能通过 signal 订阅状态 —— 这样核心系统可以被无头(Headless)测试。
##    * "上一轮世界状态的清理"由订阅 loop_reset 的系统各自负责（重置屏障）。
##    * 跨循环数据（线索卡片）由 PersistentMemoryManager 持有，本脚本不参与，
##      因此重置时绝不会、也不应该清空玩家已获得的线索。
##
##  挂载方式：项目设置 → 自动加载(Autoload) → 名称 TimeLoopManager
##  注意：脚本刻意【不写】 class_name，否则会与同名 Autoload 单例冲突
##        （GDScript 报错：Class "TimeLoopManager" hides an autoload singleton）。
##
##  典型用法：
##      TimeLoopManager.loop_started.connect(_on_loop_started)
##      TimeLoopManager.time_updated.connect(_on_time_updated)   # 每秒回调一次
##      TimeLoopManager.loop_reset.connect(_on_loop_reset)       # 清理上一轮世界
##      TimeLoopManager.trigger_loop_reset()                     # 例如玩家死亡时
##
##  时间语义约定（重要）：
##      * 剩余时间 remaining：loop_duration → 0；time_updated 广播的就是剩余秒数。
##      * 已流逝时间 elapsed ：0 → loop_duration；NPC 动线 JSON 的 second 字段按它索引。
##      * time_scale 是"游戏内时钟"的流速倍率，与 Engine.time_scale（会同时影响物理与
##        动画播放速度）是两回事，本项目不使用 Engine.time_scale。
## ============================================================================


# ---------------------------------------------------------------------------
# 信号
# ---------------------------------------------------------------------------

## 剩余秒数变化时触发：current_second = 剩余秒数（420 → 0）。
## 高倍速下一帧可能跨越多秒，此时会"逐秒补发"，订阅者不会漏拍。
signal time_updated(current_second)

## 一轮循环结束（时间耗尽 或 调用 trigger_loop_reset()）。
## 【契约】触发时时钟已停止、剩余秒数已清零，但下一轮尚未开始：
## 订阅者可在此安全地清理"仅属于上一轮"的世界状态（NPC 归位、门锁复原、临时线索等）。
signal loop_reset

## 新一轮循环开始。loop_index 从 0 开始递增，可用于剧情差分（第 N 轮的不同对白）。
signal loop_started(loop_index)

## 倒计时自然耗尽（与"玩家死亡等外部强制重置"区分开）。
signal loop_timeout

## 暂停状态变化，供 UI 显示"暂停中"。
signal pause_changed(is_paused)


# ---------------------------------------------------------------------------
# 常量与可配置参数
# ---------------------------------------------------------------------------

## 一轮循环的默认长度：7 分钟 = 420 秒（设计文档固定值）。
const DEFAULT_LOOP_DURATION: float = 420.0
const MIN_LOOP_DURATION: float = 1.0
const MAX_LOOP_DURATION: float = 3600.0

## 允许的最大时间流速倍率（防止调试时数值溢出/卡帧）。
const MAX_TIME_SCALE: float = 200.0


## 是否在 _ready() 时自动开始倒计时。
## 默认 false：正式流程应由引导层（阶段一为调试 HUD，正式版为 GameBootstrap）
## 先读取 JSON 数据表、确定循环时长之后再调用 start_loop()，避免"数据还没到表就开跑"。
var auto_start: bool = false

## 当前这一轮循环的长度（秒）。可由数据表 meta.loop_duration_seconds 覆盖。
var loop_duration: float = DEFAULT_LOOP_DURATION

## 时间流速倍率：1.0 = 实时；10.0 = 十倍速；0.0 表示时钟停走。
var time_scale: float = 1.0

## 当前循环编号，第 1 轮为 0。
var loop_index: int = 0


# ---------------------------------------------------------------------------
# 内部状态
# ---------------------------------------------------------------------------

var _remaining: float = DEFAULT_LOOP_DURATION  # 本轮剩余秒数（浮点）
var _elapsed: float = 0.0                     # 本轮已流逝秒数（= loop_duration - _remaining）
var _last_second: int = -1                    # 上一次广播出去的整数秒，用于去重
var _running: bool = false                    # 倒计时是否在跑
var _paused: bool = false                     # 是否被暂停
var _resetting: bool = false                  # 重入保护：重置过程中再次请求重置时忽略


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

func _ready() -> void:
	_remaining = loop_duration
	if auto_start:
		start_loop()


func _process(delta: float) -> void:
	# 时钟没跑或已暂停时直接返回；不做任何跨系统副作用。
	tick(delta)


# ---------------------------------------------------------------------------
# 对外 API —— 推进时钟
# ---------------------------------------------------------------------------

## 推进时钟 delta 秒（会被 time_scale 缩放）。
## 正常情况下由 _process 每帧调用；把它独立成公开方法是为了：
##   1. 无头测试可以确定性地手动推进时间（见 tests/test_phase1_smoke.gd）；
##   2. 将来若改用固定步长(Fixed Timestep)驱动，只需改调用点。
func tick(delta: float) -> void:
	if not _running or _paused:
		return
	if delta <= 0.0:
		return
	var scaled: float = delta * time_scale
	if scaled <= 0.0:
		return

	_remaining = maxf(0.0, _remaining - scaled)
	_elapsed = loop_duration - _remaining
	_flush_second_signals()

	if _remaining <= 0.0:
		_handle_timeout()


# ---------------------------------------------------------------------------
# 对外 API —— 循环流程控制
# ---------------------------------------------------------------------------

## 开始（或重新开始）当前编号的这一轮循环。第一次启动时 loop_index 为 0。
func start_loop() -> void:
	_running = true
	_paused = false
	_remaining = loop_duration
	_elapsed = 0.0
	_last_second = ceili(_remaining)
	loop_started.emit(loop_index)
	time_updated.emit(_last_second)


## 强制触发清零重置：立即结束当前循环并开启下一轮。
## 典型触发时机：玩家被发现/死亡、关键条件达成、调试快捷键。
func trigger_loop_reset() -> void:
	_perform_loop_reset(false)


## 暂停倒计时（不影响 Player/NPC 的其它逻辑，由调用方决定是否一起冻结）。
func pause_loop() -> void:
	if not _running or _paused:
		return
	_paused = true
	pause_changed.emit(true)


## 恢复倒计时。
func resume_loop() -> void:
	if not _running or not _paused:
		return
	_paused = false
	pause_changed.emit(false)


## 暂停 / 恢复一键切换（调试用）。
func toggle_pause() -> void:
	if _paused:
		resume_loop()
	else:
		pause_loop()


## 设置时间流速倍率（自动钳制到 [0, MAX_TIME_SCALE]）。
func set_time_scale(value: float) -> void:
	time_scale = clampf(value, 0.0, MAX_TIME_SCALE)


func get_time_scale() -> float:
	return time_scale


func get_loop_duration() -> float:
	return loop_duration


## 设置循环长度。建议在 start_loop() 之前调用（例如读取数据表之后）；
## 未运行时调用会同步刷新剩余时间。
func set_loop_duration(seconds: float) -> void:
	loop_duration = clampf(seconds, MIN_LOOP_DURATION, MAX_LOOP_DURATION)
	if not _running:
		_remaining = loop_duration
		_last_second = ceili(_remaining)


# ---------------------------------------------------------------------------
# 对外 API —— 只读查询（表现层与玩法层都从这里取状态）
# ---------------------------------------------------------------------------

func is_running() -> bool:
	return _running


func is_paused() -> bool:
	return _paused


func get_loop_index() -> int:
	return loop_index


## 把循环编号归零（"开新档 / 重新开始一案"专用）。
## 与 trigger_loop_reset() 的区别：**不广播 loop_reset** —— 那是"上一遍结束"的
## 世界清理屏障，订阅者会照着它做心灯扣血、NPC 归位这类**代价**动作；
## "开新档"由调用方负责把自己的状态清干净（表现层走的是整场重载），再调 start_loop()。
## 加上它是为了不出现"第 0 遍的余页却挂着第 9 遍编号"这种脏状态。
func reset_loop_index() -> void:
	loop_index = 0


## 剩余秒数（向上取整，420 → 0）：显示"07:00"用的就是这个值。
func get_remaining_seconds() -> int:
	return ceili(maxf(0.0, _remaining))


## 已流逝秒数（向下取整，0 → 420）：NPC 动线 JSON 的 second 字段按它索引。
func get_elapsed_seconds() -> int:
	return int(floor(_elapsed))


func get_remaining_time() -> float:
	return _remaining


func get_elapsed_time() -> float:
	return _elapsed


## 本轮进度 0.0 → 1.0（用于进度条，但核心层只给数值，不做任何绘制）。
func get_progress_ratio() -> float:
	if loop_duration <= 0.0:
		return 1.0
	return clampf(_elapsed / loop_duration, 0.0, 1.0)


# ---------------------------------------------------------------------------
# 内部实现
# ---------------------------------------------------------------------------

## 每秒（或高倍速下跨秒）广播 time_updated。
## 逐秒补发保证依赖"每秒事件"的系统（NPC 动线调度、环境音等）不会漏拍。
func _flush_second_signals() -> void:
	var current: int = ceili(maxf(0.0, _remaining))
	if current == _last_second:
		return
	var step: int = 1 if current > _last_second else -1
	var guard: int = 0
	while _last_second != current and guard < 4096:
		_last_second += step
		time_updated.emit(_last_second)
		guard += 1
	_last_second = current


## 时间耗尽：停止 → 广播 loop_timeout → 广播 loop_reset → 开启下一轮。
func _handle_timeout() -> void:
	_perform_loop_reset(true)


## 统一的"结束本轮 + 开启下一轮"流程。from_timeout 决定是否额外广播 loop_timeout。
func _perform_loop_reset(from_timeout: bool) -> void:
	if _resetting:
		# 订阅者（例如某个 loop_reset 回调里又触发了重置）导致的递归调用，直接忽略。
		push_warning("[TimeLoopManager] 重置流程中再次收到重置请求，已忽略本次重入调用。")
		return
	_resetting = true

	_stop_and_zero_clock()
	if from_timeout:
		loop_timeout.emit()
	loop_reset.emit()          # 世界清理屏障：此刻 time==0 且时钟已停
	loop_index += 1
	start_loop()

	_resetting = false


## 停止计时并清零。清零后广播一次 time_updated(0)，保证 UI 一定收得到"归零"事件。
func _stop_and_zero_clock() -> void:
	var was_paused: bool = _paused
	_running = false
	_paused = false
	_remaining = 0.0
	_elapsed = loop_duration
	if _last_second != 0:
		_last_second = 0
		time_updated.emit(0)
	if was_paused:
		pause_changed.emit(false)
