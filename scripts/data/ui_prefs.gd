extends RefCounted
## ============================================================================
##  ui_prefs.gd —— 界面偏好（跟玩法进度无关的小开关）
## ----------------------------------------------------------------------------
##  为什么单独一份文件，而不是塞进 clue_store.json：
##    * `user://clue_store.json` 是"玩家的记忆"本身（线索表 + 心灯 + 遗忘黑名单），
##      结构/版本被 173 项心灯测试钉死了（SAVE_VERSION = 2）。往里面加"引导看过没有"
##      这种键，等于动那份契约，还会让存档测试的夹具全部失配。
##    * 这份文件的崩溃安全等级**刻意低于** clue_store：丢了最多是"引导再看一遍"，
##      不会丢记忆 ⇒ 直接整文件覆写（不搞 .tmp/.bak 双档轮换），但读取对任何
##      损坏/缺键/版本不认识的情况都容错（一律回默认值，绝不崩）。
##
##  典型用法：
##      const UIPrefs = preload("res://scripts/data/ui_prefs.gd")
##      if not UIPrefs.has_seen_tutorial():
##          UIPrefs.mark_tutorial_seen()
## ============================================================================

## 偏好文件路径（相对 user://，测试与其他模块只认这个常量）。
const PREFS_PATH: String = "user://ui_prefs.json"
## 格式版本号：将来结构变了靠它判断要不要迁移（现在只有引导开关）。
const PREFS_VERSION: int = 1
const KEY_VERSION: String = "version"
## 新手引导是否已经看过（true = 之后不再弹）。
const KEY_TUTORIAL_SEEN: String = "tutorial_seen"


## 读回整份偏好。文件不存在 / 空 / JSON 坏 / 顶层不是对象：一律返回默认值（不崩、不改文件）。
static func load_prefs() -> Dictionary:
	var defaults: Dictionary = {
		KEY_VERSION: PREFS_VERSION,
		KEY_TUTORIAL_SEEN: false,
	}
	if not FileAccess.file_exists(PREFS_PATH):
		return defaults
	var file: FileAccess = FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return defaults
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("[UIPrefs] %s 读不出来（不是 JSON 对象），按默认值走。" % PREFS_PATH)
		return defaults
	var data: Dictionary = parsed
	var out: Dictionary = defaults.duplicate()
	out[KEY_VERSION] = int(data.get(KEY_VERSION, PREFS_VERSION))
	out[KEY_TUTORIAL_SEEN] = bool(data.get(KEY_TUTORIAL_SEEN, false))
	return out


## 落盘整份偏好。返回 true = 写成功。
static func save_prefs(data: Dictionary) -> bool:
	var payload: Dictionary = data.duplicate()
	payload[KEY_VERSION] = PREFS_VERSION
	var file: FileAccess = FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("[UIPrefs] %s 写不进去（错误码 %d）—— 本次偏好没落盘，不影响玩法。"
			% [PREFS_PATH, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(payload, "  "))
	file.flush()
	file.close()
	return true


## 新手引导看过没有（默认 false = 该弹一次）。
static func has_seen_tutorial() -> bool:
	return bool(load_prefs().get(KEY_TUTORIAL_SEEN, false))


## 记下"引导看过了"（点关闭或自动关闭时各调一次都无所谓，幂等）。
static func mark_tutorial_seen() -> bool:
	var data: Dictionary = load_prefs()
	if bool(data.get(KEY_TUTORIAL_SEEN, false)):
		return true
	data[KEY_TUTORIAL_SEEN] = true
	return save_prefs(data)


## 把整份偏好删掉（开新档 / 测试收尾用：删干净才不会污染玩家自己的目录）。
static func erase() -> bool:
	var ok: bool = true
	if FileAccess.file_exists(PREFS_PATH):
		ok = DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS_PATH)) == OK
	return ok
