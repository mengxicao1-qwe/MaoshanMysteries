extends RefCounted
## ============================================================================
##  clue_store.gd —— 线索 + 心灯数值持久化（崩溃安全 / 双档轮换）
## ----------------------------------------------------------------------------
##  为什么不能靠 rename_absolute() 直接覆盖主档（docs/market/01_立项调研与推荐方案.md §8 风险 7）：
##    本作里"线索 = 记忆"，玩家的整局进度就是这一份线索列表。
##    但 Windows 上 DirAccess.rename_absolute() 对【已存在的目标】并不是原子的：
##    Godot 的 DirAccessWindows::rename 会先 remove(目标) 再 MoveFileW —— 两步之间
##    崩溃/掉电，主档就没了，而新数据还躺在 .tmp 里没人读 ⇒ 整档丢失（不可能恢复）。
##    所以本模块的写入永远是"双档轮换"，绝不 rename 去覆盖一个已存在的文件：
##      1) 先写同目录下的临时文件 user://clue_store.json.tmp；
##      2) flush() + close() 确保字节真正落盘（不是停留在用户态缓冲里）；
##      3) 把主档改名成 user://clue_store.json.bak（目标若已存在先删掉，删失败不致命；
##         但"主档 → .bak"这一步失败会立刻返回 false，之后什么都不做，主档原地不动）；
##      4) 再把 .tmp 改名成主档 —— 此刻主档【不存在】，不存在"先删后移"的窗口。
##    ⇒ 任何一步崩溃/掉电，磁盘上总留着一份完整存档（主档 / .tmp / .bak 至少一个可解析），
##      最坏情况只是丢掉"最后一次追加"，绝不会整档丢失。
##
##  读取顺序（_read_raw()）：主档 → .tmp → .bak。
##    主档【存在但 JSON 解析失败或结构非法】时：先把主档字节原样另存到
##    user://clue_store.json.corrupt（覆盖上一份），push_warning 打印主档与副本的绝对路径，
##    再回退去读 .tmp / .bak；三者都不可用才返回空结构。
##    ⇒ 损坏但可能可抢救的档案，不会被下一次 save() 以空底库整表覆盖抹掉。
##
##  设计约束：
##    * 只有 static 方法，且【不写 class_name】（工具/测试一律 preload()）。
##    * 只追加不重写：save() 把新线索并进既有表，绝不整体覆盖导致丢线；
##      唯一会"删掉"线索的入口是 mark_forgotten()（心灯归零专用，见 heart_lamp.gd）。
##    * "已遗忘线索"黑名单：PersistentMemoryManager（冻结文件）没有删除单条线索的
##      公开接口，所以"永久丢失一条线索的记忆"落在这份黑名单上：
##        - 被遗忘的 clue_id 会从 clues 表移入 forgotten 表（存档里仍有记录，UI 可变灰）；
##        - load_clues() 不会把它交还给记忆（不可用于推理）；
##        - 只有心灯被【重新点亮】之后重新查获同一条线索，才允许 unmark_forgotten()
##          （心灯还熄着的时候 heart_lamp.gd 会直接拒绝查获，见那边 add_clue() 的注释）。
##    * 心灯数值存在同一份 JSON 的 "lamp_value" 键下：缺省的旧档（version 1 没有这个键）
##      读回默认值 100。
##    * 版本兼容：SAVE_VERSION = 2；version 1 的旧档结构完全兼容，读取一律接受，
##      只是没有 lamp_value 这个键（走默认值）。
##    * load_* 面对任何异常（文件缺失 / 空文件 / JSON 损坏 / 顶层不是对象）都不会崩溃，
##      也绝不修改原文件：能回退就回退（.tmp / .bak），回退不了才返回空。
##
##  典型用法：
##      const ClueStore = preload("res://scripts/data/clue_store.gd")
##      ClueStore.save(["clue_letter_under_plate"])          # 追加落盘
##      var clues: Array[String] = ClueStore.load_clues()    # 读回（主档坏了会自动回退 .bak）
##      ClueStore.save_lamp_state(62, now_unix)              # 心灯数值 + 时间戳落盘
##      var lamp: Dictionary = ClueStore.load_lamp_state()   # {"value": 62, "seen_unix": …}
## ============================================================================


## 主存档路径（相对 user://，测试与其他模块只认这几个常量）。
const SAVE_PATH: String = "user://clue_store.json"
## 临时文件路径：写入总是先落这里，再改名成 SAVE_PATH。
const TMP_PATH: String = "user://clue_store.json.tmp"
## 备份档：上一次成功落盘的主档（主档损坏 / 丢失时靠它回退）。
const BAK_PATH: String = "user://clue_store.json.bak"
## 损坏档副本：主档读不出来时，先把它的字节原样留一份在这里备查（不参与自动恢复）。
const CORRUPT_PATH: String = "user://clue_store.json.corrupt"

## 存档格式版本号，便于后续升级结构。version 1 的旧档照样能读（只缺 lamp_value）。
const SAVE_VERSION: int = 2

const KEY_VERSION: String = "version"
const KEY_CLUES: String = "clues"
const KEY_FORGOTTEN: String = "forgotten"
const KEY_LAMP_VALUE: String = "lamp_value"
## 最近一次心灯数值落盘时的时间戳（Unix 秒）。心灯的"现实时间恢复"靠它算离线了多久。
const KEY_SEEN_UNIX: String = "seen_unix"

## 心灯数值的默认值（与 heart_lamp.gd 的 DEFAULT_MAX_VALUE 对齐）：旧档 / 缺键 / 坏档都读回它。
const DEFAULT_LAMP_VALUE: int = 100


# ---------------------------------------------------------------------------
# 写入 —— 线索
# ---------------------------------------------------------------------------

## 追加保存一组线索（已有的线索不会被丢掉，重复的会被忽略）。
## 返回 true = 已落盘；false = 写失败（主档 / .bak 保持原样，绝不会半写）。
static func save(clues: Array) -> bool:
	var data: Dictionary = _read_raw()
	var stored: Array[String] = _to_string_array(data.get(KEY_CLUES))
	for item in clues:
		if typeof(item) != TYPE_STRING:
			continue
		var clue_id: String = item
		if clue_id.is_empty() or stored.has(clue_id):
			continue
		stored.append(clue_id)

	data[KEY_VERSION] = SAVE_VERSION
	data[KEY_CLUES] = stored
	# 黑名单原样保留：save() 只追加，不碰遗忘记录。
	data[KEY_FORGOTTEN] = _to_string_array(data.get(KEY_FORGOTTEN))
	# 心灯数值与线索同档：save() 也必须把它原样带过去，不能顺手清零。
	data[KEY_LAMP_VALUE] = _int_or(data.get(KEY_LAMP_VALUE), DEFAULT_LAMP_VALUE)
	# 时间戳也要原样带过去：线索写入不能顺手把"上次活跃时间"刷新掉（否则离线恢复永远算不出点）。
	data[KEY_SEEN_UNIX] = _int_or(data.get(KEY_SEEN_UNIX), 0)
	return _write_atomic(data)


## 把一条线索标记为"永久遗忘"：从 clues 移入 forgotten，并落盘。
## 这是本模块唯一会删除线索的入口（心灯归零时由 heart_lamp.gd 调用）。
static func mark_forgotten(clue_id: String) -> bool:
	if clue_id.is_empty():
		push_warning("[ClueStore] mark_forgotten() 收到空 clue_id，已忽略。")
		return false

	var data: Dictionary = _read_raw()
	var clues: Array[String] = _to_string_array(data.get(KEY_CLUES))
	var forgotten: Array[String] = _to_string_array(data.get(KEY_FORGOTTEN))
	clues.erase(clue_id)
	if not forgotten.has(clue_id):
		forgotten.append(clue_id)

	data[KEY_VERSION] = SAVE_VERSION
	data[KEY_CLUES] = clues
	data[KEY_FORGOTTEN] = forgotten
	data[KEY_LAMP_VALUE] = _int_or(data.get(KEY_LAMP_VALUE), DEFAULT_LAMP_VALUE)
	# 时间戳也要原样带过去：线索写入不能顺手把"上次活跃时间"刷新掉（否则离线恢复永远算不出点）。
	data[KEY_SEEN_UNIX] = _int_or(data.get(KEY_SEEN_UNIX), 0)
	return _write_atomic(data)


## 解除遗忘（玩家重新查获了同一条线索 → 记忆被找回来），并落盘。
## 注意：调用方必须保证心灯已经重新点亮（heart_lamp.gd 会在熄灯时拒绝查获）。
static func unmark_forgotten(clue_id: String) -> bool:
	if clue_id.is_empty():
		push_warning("[ClueStore] unmark_forgotten() 收到空 clue_id，已忽略。")
		return false

	var data: Dictionary = _read_raw()
	var clues: Array[String] = _to_string_array(data.get(KEY_CLUES))
	var forgotten: Array[String] = _to_string_array(data.get(KEY_FORGOTTEN))
	forgotten.erase(clue_id)
	if not clues.has(clue_id):
		clues.append(clue_id)

	data[KEY_VERSION] = SAVE_VERSION
	data[KEY_CLUES] = clues
	data[KEY_FORGOTTEN] = forgotten
	data[KEY_LAMP_VALUE] = _int_or(data.get(KEY_LAMP_VALUE), DEFAULT_LAMP_VALUE)
	# 时间戳也要原样带过去：线索写入不能顺手把"上次活跃时间"刷新掉（否则离线恢复永远算不出点）。
	data[KEY_SEEN_UNIX] = _int_or(data.get(KEY_SEEN_UNIX), 0)
	return _write_atomic(data)


# ---------------------------------------------------------------------------
# 写入 —— 心灯数值
# ---------------------------------------------------------------------------

## 保存心灯数值 + 时间戳（修复"数值从不落盘 → 退出重进白回 100，记忆却已经真的丢了"的不对称）。
##
## seen_unix = 这次落盘时的系统时间（Unix 秒）。心灯的现实时间恢复规则
## （docs/story/09:175「现实时间（余页之外）按分钟 +1」）靠"现在 - seen_unix"算离线了多久，
## 所以**每一次数值变化都要连同时间戳一起写**，否则无法区分"刚存过"和"离线了一天"。
static func save_lamp_state(value: int, seen_unix: int) -> bool:
	var data: Dictionary = _read_raw()
	data[KEY_VERSION] = SAVE_VERSION
	data[KEY_CLUES] = _to_string_array(data.get(KEY_CLUES))
	data[KEY_FORGOTTEN] = _to_string_array(data.get(KEY_FORGOTTEN))
	data[KEY_LAMP_VALUE] = value
	data[KEY_SEEN_UNIX] = seen_unix
	return _write_atomic(data)


## 只存心灯数值（时间戳取当前系统时间）。保留给"只想改数值"的调用方。
static func save_lamp_value(value: int) -> bool:
	return save_lamp_state(value, int(Time.get_unix_time_from_system()))


# ---------------------------------------------------------------------------
# 删除
# ---------------------------------------------------------------------------

## 删除整份存档（主档 + 残留 .tmp + .bak + .corrupt）。用于"开新档"与测试收尾。
static func erase_store() -> bool:
	var ok: bool = true
	for path: String in [SAVE_PATH, TMP_PATH, BAK_PATH, CORRUPT_PATH]:
		if not FileAccess.file_exists(path):
			continue
		var err: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if err != OK:
			push_warning("[ClueStore] 无法删除 %s（错误码 %d）。" % [path, err])
			ok = false
	return ok


# ---------------------------------------------------------------------------
# 读取
# ---------------------------------------------------------------------------

## 读回线索表。主档缺失/损坏时按 主档 → .tmp → .bak 的顺序恢复；
## 三者都不可用才返回**空数组**并打印一行警告，绝不崩溃、绝不覆盖原文件。
static func load_clues() -> Array[String]:
	var data: Dictionary = _read_raw()
	var stored: Array[String] = _to_string_array(data.get(KEY_CLUES))
	var forgotten: Array[String] = _to_string_array(data.get(KEY_FORGOTTEN))

	var usable: Array[String] = []
	for clue_id in stored:
		if forgotten.has(clue_id):
			continue  # 已遗忘的记忆不会被交还给玩家
		usable.append(clue_id)
	return usable


## 读回"已遗忘线索"黑名单（UI 上把这些线索画成灰色用）。
static func load_forgotten() -> Array[String]:
	var data: Dictionary = _read_raw()
	return _to_string_array(data.get(KEY_FORGOTTEN))


## 该线索是否已被心灯烧掉（不可用于推理）。
static func is_forgotten(clue_id: String) -> bool:
	if clue_id.is_empty():
		return false
	return load_forgotten().has(clue_id)


## 读回心灯数值 + 时间戳。存档不存在 / 损坏 / version 1 旧档（没有这两个键）：
## value 返回 DEFAULT_LAMP_VALUE（100），seen_unix 返回 0（"从没存过" ⇒ 不补离线点）。
static func load_lamp_state() -> Dictionary:
	var data: Dictionary = _read_raw()
	return {
		"value": _int_or(data.get(KEY_LAMP_VALUE), DEFAULT_LAMP_VALUE),
		"seen_unix": _int_or(data.get(KEY_SEEN_UNIX), 0),
	}


## 读回心灯数值（时间戳见 load_lamp_state()）。
static func load_lamp_value() -> int:
	return int(load_lamp_state()["value"])


# ---------------------------------------------------------------------------
# 内部实现 —— 写入
# ---------------------------------------------------------------------------

## 崩溃安全写入：.tmp 写完 → flush → close → 主档转 .bak → .tmp 转主档。
## 任何一步失败都返回 false，并且保证【磁盘上仍有一份完整存档】：
##   * 写 .tmp 失败：主档 / .bak 都没被碰过；
##   * 主档转 .bak 失败：主档原样不动，最新数据留在 .tmp（下次启动会从它恢复）；
##   * .tmp 转主档失败：主档虽然在 .bak 里，但内容和上一次成功落盘的一样，一条线索没丢。
static func _write_atomic(data: Dictionary) -> bool:
	var target_native: String = ProjectSettings.globalize_path(SAVE_PATH)
	var tmp_native: String = ProjectSettings.globalize_path(TMP_PATH)
	var bak_native: String = ProjectSettings.globalize_path(BAK_PATH)

	var file: FileAccess = FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[ClueStore] 无法写入临时存档 %s（错误码 %d），本次不落盘，主存档未受影响。"
			% [TMP_PATH, FileAccess.get_open_error()])
		return false

	file.store_string(JSON.stringify(data, "\t"))
	file.flush()
	file.close()  # 必须先关闭句柄，Windows 上打开中的文件无法被改名

	# 第 1 步：主档 → .bak。先把上一份 .bak 删掉：这一步失败不致命，
	# 但绝不能留着它去让 rename "先删后移"（那正是我们要避开的窗口）。
	if FileAccess.file_exists(SAVE_PATH):
		if FileAccess.file_exists(BAK_PATH):
			DirAccess.remove_absolute(bak_native)
		var bak_err: Error = DirAccess.rename_absolute(target_native, bak_native)
		if bak_err != OK:
			push_warning("[ClueStore] 主存档转存 .bak 失败（rename 错误码 %d）：主存档保持原样，本次不落盘；最新数据留在 %s，下次启动会自动从它恢复。" % [bak_err, TMP_PATH])
			return false

	# 第 2 步：.tmp → 主档。此刻主档通常不存在 ⇒ 没有"先删后移"的窗口。
	var err: Error = DirAccess.rename_absolute(tmp_native, target_native)
	if err != OK:
		push_warning("[ClueStore] 临时文件转正失败（rename 错误码 %d）：上一份完整存档在 %s，最新数据留在 %s，重启后会自动恢复，一条线索都不会丢。" % [err, BAK_PATH, TMP_PATH])
		return false
	return true


## 逐字节复制一个文件（用于把损坏的主档另存为 .corrupt，绝不做任何编码转换）。
static func _copy_bytes(from_path: String, to_path: String) -> bool:
	var src: FileAccess = FileAccess.open(from_path, FileAccess.READ)
	if src == null:
		return false
	var bytes: PackedByteArray = src.get_buffer(src.get_length())
	src.close()

	var dst: FileAccess = FileAccess.open(to_path, FileAccess.WRITE)
	if dst == null:
		return false
	dst.store_buffer(bytes)
	dst.flush()
	dst.close()
	return true


# ---------------------------------------------------------------------------
# 内部实现 —— 读取与恢复
# ---------------------------------------------------------------------------

## 恢复感知的读取：主档 → .tmp → .bak。所有公开读取/写入都只走这一个入口。
## 主档存在但不可用时：先把它另存一份 .corrupt（覆盖旧的），再回退；三者都不可用才返回空字典。
static func _read_raw() -> Dictionary:
	var main_result: Dictionary = _read_candidate(SAVE_PATH)
	if bool(main_result["ok"]):
		return main_result["data"]

	# missing = 主档根本不存在（全新存档的正常情形，不用留损坏副本）。
	var damaged: bool = not bool(main_result["missing"])
	if damaged:
		_preserve_corrupt(str(main_result["reason"]))

	for path: String in [TMP_PATH, BAK_PATH]:
		var candidate: Dictionary = _read_candidate(path)
		if bool(candidate["ok"]):
			if damaged:
				push_warning("[ClueStore] 主存档 %s %s，已改用 %s 恢复（损坏档另存 %s 备查）。"
					% [SAVE_PATH, str(main_result["reason"]), path, CORRUPT_PATH])
			return candidate["data"]

	if damaged:
		push_warning("[ClueStore] 主存档 %s %s，且 .tmp / .bak 都不可用：按空存档处理（损坏档已另存 %s）。"
			% [SAVE_PATH, str(main_result["reason"]), CORRUPT_PATH])
	return {}


## 尝试解析一个候选存档文件。
## 返回 {"ok": bool, "data": Dictionary, "reason": String, "missing": bool}：
##   ok      = 解析成功且结构合法（顶层是对象、版本不高于本程序）
##   missing = 文件根本不存在（区别于"存在但坏了"）
##   reason  = 失败原因的中文短语（拼进警告里）
static func _read_candidate(path: String) -> Dictionary:
	var result: Dictionary = {"ok": false, "data": {}, "reason": "", "missing": false}
	if not FileAccess.file_exists(path):
		result["missing"] = true
		return result

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		result["reason"] = "存在但打不开（错误码 %d）" % FileAccess.get_open_error()
		return result

	var text: String = file.get_as_text()
	file.close()

	if text.strip_edges().is_empty():
		result["reason"] = "是空文件"
		return result

	var json: JSON = JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		# JSON.get_error_line() 是 0 基的，展示时 +1。
		result["reason"] = "已损坏（第 %d 行：%s）" % [json.get_error_line() + 1, json.get_error_message()]
		return result

	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		result["reason"] = "顶层不是 JSON 对象"
		return result

	var data: Dictionary = parsed
	# 结构非法：版本号比本程序还新（玩家降级回旧版本运行）。
	# version 1 的旧档照收 —— 它只是没有 lamp_value 键，由 load_lamp_value() 走默认值。
	var version: int = _int_or(data.get(KEY_VERSION), 0)
	if version > SAVE_VERSION:
		result["reason"] = "版本号 %d 高于本程序支持的 %d" % [version, SAVE_VERSION]
		return result

	result["ok"] = true
	result["data"] = data
	return result


## 把不可用的主档逐字节另存到 CORRUPT_PATH（覆盖旧的 .corrupt），绝不修改主档本身。
## 这是"损坏档会被下一次 save() 抹掉"的修复：留一份备查，人肉也能救回来。
static func _preserve_corrupt(reason: String) -> bool:
	var main_native: String = ProjectSettings.globalize_path(SAVE_PATH)
	var corrupt_native: String = ProjectSettings.globalize_path(CORRUPT_PATH)
	var copied: bool = _copy_bytes(SAVE_PATH, CORRUPT_PATH)
	if copied:
		push_warning("[ClueStore] 主存档损坏（%s），已另存一份备查：%s ← %s" % [reason, corrupt_native, main_native])
	else:
		push_warning("[ClueStore] 主存档损坏（%s），且另存 %s 失败；原文件 %s 保持原样。" % [reason, corrupt_native, main_native])
	return copied


## 把 JSON 里读出来的数字安全转成 int（JSON.parse 把所有数字都读成 float）。
static func _int_or(value: Variant, fallback: int) -> int:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return int(value)
	return fallback


## 把任意 Variant 安全地转成去重的 Array[String]（JSON.parse 出来的数组里什么都可能有）。
static func _to_string_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(value) != TYPE_ARRAY:
		return out
	var raw: Array = value
	for item in raw:
		if typeof(item) != TYPE_STRING:
			continue
		var text: String = item
		if text.is_empty() or out.has(text):
			continue
		out.append(text)
	return out
