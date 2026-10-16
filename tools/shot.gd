extends SceneTree
## 表现层截图工具：用【带窗口】的 Godot 跑，把主场景的渲染结果存成 PNG。
##
## 用法：
##   godot --path . --script res://tools/shot.gd -- --out res://.shots/main.png --seconds 150 --keys "TAB"
##
## 注意：`--headless` 没有渲染器，会存出一张空图；本工具必须用带窗口的引擎跑。
## 参数：
##   --scene <路径>    场景（默认 res://scenes/main.tscn）
##   --out <路径>      输出 PNG（默认 res://.shots/main.png）
##   --seconds <秒>    先快进到第几个游戏内秒再截图（默认 0 = 开局）
##   --scale <倍速>    快进用的时间倍速（默认 60）
##   --keys <键>       截图前按下的键，逗号分隔（如 TAB,F,G；在 SliceHUD 上合成）
##   --room <房 id>    先让 HUD 走过去（走位耗时照旧）
##   --after <秒>      按完键之后再往前跑几秒（等走位/动画到位）
##   --legs <段>       多段走位：`"房间@等几秒;房间@等几秒"`（走过去 → 等拍点 → 再走过去）
##   --keys2 <键>      跑到 --after / --legs 之后再按的键（如到位后 F 交谈、B 摊开推演板）
##   --frames <帧>     帧预算上限（默认 4000）
##   --prefs <模式>    截图前把"新手引导看过没有"设成确定值：
##                       fresh = 删掉偏好（引导会弹出来）；seen = 记成看过（引导不弹）
##                       不传就按当前档走；无论哪种，结束时都按快照原样还回去
##   --open <弹窗>     截图前直接摊开某个覆盖层：tutorial（新手引导）/ settlement（结案结算）
##
## **不碰存档 / 偏好**：开跑前把 user:// 的存档 4 件套 + ui_prefs.json 做字节快照，结束时原样还回去
## （截图是"看一眼"，不该把玩家的档烧掉 —— 心灯会被跑掉的；也不该改掉"引导已看过"）。
##
## 工具脚本约定：extends SceneTree + _initialize() + quit(code)，不写 class_name，
## 最后一行打印唯一一行 RESULT: ...（与 tools/cli.gd 一致）。

const DEFAULT_SCENE := "res://scenes/main.tscn"
const DEFAULT_OUT := "res://.shots/main.png"

## 存档 4 件套 + 引导偏好（截图前后逐字节还原）
const STORE_PATHS: Array[String] = [
	"user://clue_store.json",
	"user://clue_store.json.tmp",
	"user://clue_store.json.bak",
	"user://clue_store.json.corrupt",
	"user://ui_prefs.json",
]

const UIPrefs = preload("res://scripts/data/ui_prefs.gd")

## 允许合成的按键名 → keycode（够用即可，扩展就往这里加）
const KEY_NAMES := {
	"TAB": KEY_TAB,
	"E": KEY_E,
	"Q": KEY_Q,
	"F": KEY_F,
	"B": KEY_B,
	"H": KEY_H,
	"G": KEY_G,
	"P": KEY_P,
	"R": KEY_R,
	"T": KEY_T,
	"SPACE": KEY_SPACE,
	"ENTER": KEY_ENTER,
	"BACKSPACE": KEY_BACKSPACE,
	"1": KEY_1,
	"2": KEY_2,
	"3": KEY_3,
	"4": KEY_4,
	"5": KEY_5,
	"UP": KEY_UP,
	"DOWN": KEY_DOWN,
	"LEFT": KEY_LEFT,
	"RIGHT": KEY_RIGHT,
}


func _initialize() -> void:
	_run(OS.get_cmdline_user_args())


func _run(args: PackedStringArray) -> void:
	var scene_path: String = _arg(args, "--scene", DEFAULT_SCENE)
	var out_path: String = _arg(args, "--out", DEFAULT_OUT)
	var target_seconds: float = float(_arg(args, "--seconds", "0"))
	var time_scale: float = float(_arg(args, "--scale", "60"))
	var max_frames: int = int(_arg(args, "--frames", "4000"))
	var keys: String = _arg(args, "--keys", "")
	var room: String = _arg(args, "--room", "")
	var after_seconds: float = float(_arg(args, "--after", "0"))
	var legs: String = _arg(args, "--legs", "")
	var late_keys: String = _arg(args, "--keys2", "")
	var prefs_mode: String = _arg(args, "--prefs", "")
	var open_target: String = _arg(args, "--open", "")

	var packed: Variant = load(scene_path)
	if packed == null or not (packed is PackedScene):
		print("RESULT: FAIL 场景无法加载：%s" % scene_path)
		quit(1)
		return
	# 截图不该动玩家的档：先做字节快照，结束前还回去（心灯会被跑掉的）
	var saved_existed: Array[bool] = []
	var saved_bytes: Array[PackedByteArray] = []
	for path in STORE_PATHS:
		var exists: bool = FileAccess.file_exists(path)
		saved_existed.append(exists)
		saved_bytes.append(FileAccess.get_file_as_bytes(path) if exists else PackedByteArray())
	# 快照之后再翻偏好开关，结束时的还原会把玩家原来的那份放回去
	_apply_prefs(prefs_mode)
	var instance: Node = (packed as PackedScene).instantiate()
	root.add_child(instance)
	# SceneTree 工具脚本里 add_child 不会立刻触发 _ready()（要等第一帧），
	# 所以先让装配跑完再按键/改倍速 —— 否则表现层还没接上，按了等于没按。
	await process_frame
	await process_frame

	var loop: Node = root.get_node_or_null("TimeLoopManager")
	if loop != null and loop.has_method("set_time_scale"):
		loop.set_time_scale(time_scale)

	var frames: int = await _advance_to(loop, target_seconds, max_frames)

	var hud: Node = instance.get_node_or_null("SliceHUD")
	if hud != null and not room.is_empty():
		hud.call("request_travel", room)
	if hud != null and not keys.is_empty():
		for raw in keys.split(",", false):
			_press(hud, raw.strip_edges().to_upper())
	if after_seconds > 0.0:
		frames += await _advance_to(loop, target_seconds + after_seconds, max_frames)
	# 多段走位：--legs "房间@等几秒;房间@等几秒"（先走过去，再往前跑几秒等拍点）
	for leg in legs.split(";", false):
		var parts: PackedStringArray = leg.split("@", false)
		var leg_room: String = parts[0].strip_edges()
		if hud != null and not leg_room.is_empty():
			hud.call("request_travel", leg_room)
		if parts.size() > 1 and float(parts[1]) > 0.0 and loop != null:
			frames += await _advance_to(loop, loop.get_elapsed_seconds() + float(parts[1]), max_frames)
	if hud != null and not late_keys.is_empty():
		for raw in late_keys.split(",", false):
			_press(hud, raw.strip_edges().to_upper())
	# 直接摊开覆盖层（引导 / 结算）：结案条件在真流程里要走到第九遍，这里只截"长什么样"
	var overlay: Node = instance.get_node_or_null("OverlayUI")
	if overlay != null and not open_target.is_empty():
		match open_target.to_lower():
			"tutorial":
				overlay.call("open_tutorial")
			"settlement":
				overlay.call("open_settlement")
			_:
				print("  跳过未知 --open：%s（只有 tutorial / settlement）" % open_target)

	# 让表现层把新状态画出来（少等几帧，避免截到半张图）
	for i in 6:
		await process_frame

	var image: Image = root.get_texture().get_image()
	if image == null:
		_restore_stores(saved_existed, saved_bytes)
		print("RESULT: FAIL 取不到渲染结果（是否用了 --headless？）")
		quit(1)
		return
	var absolute: String = ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var err: int = image.save_png(out_path)
	_restore_stores(saved_existed, saved_bytes)
	if err != OK:
		print("RESULT: FAIL 存图失败 err=%d path=%s" % [err, out_path])
		quit(1)
		return

	var elapsed: float = loop.get_elapsed_seconds() if loop != null else -1.0
	print("RESULT: OK shot=%s size=%dx%d frames=%d 游戏内=%.1fs keys=\"%s\"" % [
		out_path, image.get_width(), image.get_height(), frames, elapsed, keys,
	])
	quit(0)


## 把"新手引导看过没有"设成确定值：fresh = 删偏好（引导会弹）/ seen = 记成看过（不弹）。
## 只该在存档快照**之后**调用 —— 结束时 _restore_stores() 会把玩家原来的那份放回去。
func _apply_prefs(mode: String) -> void:
	match mode.to_lower():
		"":
			pass
		"fresh":
			UIPrefs.erase()
		"seen":
			UIPrefs.mark_tutorial_seen()
		_:
			print("  跳过未知 --prefs：%s（只有 fresh / seen）" % mode)


## 把存档 4 件套还原成截图前的样子（没动过也必须还原：跑过的档会被心灯扣掉）。
func _restore_stores(existed: Array[bool], bytes: Array[PackedByteArray]) -> void:
	for index in range(STORE_PATHS.size()):
		var path: String = STORE_PATHS[index]
		if index < existed.size() and existed[index]:
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_buffer(bytes[index])
				file.close()
		elif FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


## 空跑到"至少第 N 游戏秒"（loop 为空时按帧数兜底）。返回消耗的帧数。
func _advance_to(loop: Node, seconds: float, max_frames: int) -> int:
	var frames: int = 0
	while frames < max_frames and (loop == null or loop.get_elapsed_seconds() < seconds):
		await process_frame
		frames += 1
	return frames


## 在表现层上合成一次"按下 + 抬起"（与 tests/test_slice_hud.gd 的驱动口径一致）。
func _press(hud: Node, key_name: String) -> void:
	if not KEY_NAMES.has(key_name):
		print("  跳过未知按键：%s" % key_name)
		return
	var code: int = KEY_NAMES[key_name]
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		hud._input(event)


func _arg(args: PackedStringArray, flag: String, fallback: String) -> String:
	var index := args.find(flag)
	if index < 0 or index + 1 >= args.size():
		return fallback
	return args[index + 1]
