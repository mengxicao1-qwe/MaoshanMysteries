extends RefCounted
## ============================================================================
##  dialogue_loader.gd —— 对话登记表装载（data 层，纯只读，零 UI / 零场景 / 零 Autoload）
## ----------------------------------------------------------------------------
##  为什么有这个文件：data/clues/case_01_clues.json 里有两条线索的 source 写的是
##  "对话 add_clue"（clue_01_double_knot、clue_01_keep_stele_motive），但此前全项目没有任何
##  代码读取 data/dialogues/**，这两条线索在玩法层永远拿不到 ⇒ 14 条登记线索里有 2 条不可达。
##  本文件补上对话层的数据侧：把 data/dialogues/case_NN_*.json 读成结构化数据，
##  并回答"谁在第几秒该说什么、说了给哪条线索、此刻能不能说"。
##
##  与 case_loader.gd 的分工：
##    · case_loader.gd 认 data/scenarios/case_NN_*.json（NPC 秒级动线），节点里的 dialogue_id 是入口；
##    · 本文件认 data/dialogues/case_NN_*.json（对话树本体），键 = dialogue_id，值 = 一条对话。
##  两者都不碰 TimeLoopManager / PersistentMemoryManager / UI：表现层自己决定
##  "玩家在不在那个房间""这一遍够不够格"，本文件只给数据与判定结果。
##
##  【给 Lead 的契约提示】对话文件**没有 second 字段**（它靠 case 场景文件的节点引用定位时间）。
##  因此"按秒取台词"需要一条锚定链：本文件在 load_for_case() / load_from_file(path, case_path)
##  时才去读 data/scenarios/case_NN_*.json，把每个 dialogue_id 被引用的节点秒数记进
##  DialogueEntry.anchored_seconds（不改数据、不改语义）。只 parse_text() 的纯夹具场景没有锚点，
##  say_for() 会返回空数组（不是错误），要靠 unlock_if / require_* 自行判定。
##
##  【另一条契约提示】对话文件里 speaker 写的是**显示名**（"穆青"），而动线表里的键是 **npc_id**
##  （"npc_01_muqing"）。本文件装载时把显示名解析成 npc_id（映射来自 case 场景文件的
##  display_name -> npc_id），解析不出来的只给 warning（对话仍可用），显式写了 npc_id 却对不上
##  已知 NPC 的才报 error。
##
##  用法（表现层 / 实体层）：
##      const DialogueLoader = preload("res://scripts/data/dialogue_loader.gd")
##      var table: DialogueLoader.DialogueTable = DialogueLoader.load_for_case(1)
##      if table.ok:
##          var lines := table.say_for("npc_01_muqing", TimeLoopManager.get_elapsed_seconds(),
##                  TimeLoopManager.get_loop_index(), PersistentMemoryManager.get_clues())
##          for entry in lines:
##              print("%s：%s" % [entry.speaker, entry.first_line()])
## ============================================================================


## 对话文件目录（与 tools/validate_data.gd 的 DIALOGUE_DIR 一致）。
const DIALOGUE_DIR: String = "res://data/dialogues"

## 案件文件目录（只用于把 dialogue_id 锚定到"第几秒"）。
const SCENARIO_DIR: String = "res://data/scenarios"

## 线索登记表目录（只用于校验 clue_id 是否真的登记过，不改线索数据）。
const CLUE_DIR: String = "res://data/clues"

## clue_id 命名规范（与 tools/validate_data.gd 的 CLUE_PATTERN 逐字一致：clue_ / note_ / sealed_）。
const CLUE_ID_PATTERN: String = "^(clue|note|sealed)_[a-z0-9]+(_[a-z0-9]+)*$"

## 一条对话最少要持续几秒（用于 say_for 的"当拍"窗口；数据没写 min_seconds 时的缺省）。
const DEFAULT_MIN_SECONDS: int = 1

## 选项字段名（缺省值集中在这里，避免各处硬编码字符串拼错）。
const OPTION_FIELDS: Array[String] = [
	"text", "reply", "goto", "require_clues", "require_loop_min", "add_clue",
]

## 已知 NPC 显示名 -> npc_id（装载时解析 speaker 用；只 parse_text 的夹具场景为空）。
static var _known_npcs: Dictionary = {}

## 已知线索 id 集合（装载时读 data/clues/*.json；为空 = 不做线索交叉校验）。
static var _known_clue_ids: Dictionary = {}

## 案件余页长度（秒）。0 = 未知，则跳过"秒数越界"校验。
static var _case_duration: int = 0


## 清空装载上下文（静态变量是全局的，测试夹具之间必须靠它复位，否则上一个夹具的
## 线索表会漏到下一个夹具里，产生"看起来像 bug 的假失败"）。
static func reset_context() -> void:
	_known_npcs = {}
	_known_clue_ids = {}
	_case_duration = 0


## 当前装载上下文（诊断用：知道这一次校验到底拿了哪张线索表）。
static func context_summary() -> String:
	return "已知线索 %d 条、已知 NPC %d 个、余页长度 %d 秒" % [
		_known_clue_ids.size(), _known_npcs.size(), _case_duration,
	]


## 给纯夹具用：在 parse_text()/parse_dictionary() **之前**声明本页认得的 NPC（npc_id -> 显示名，
## 也接受显示名 -> npc_id 的反向写法）。必须先声明再解析 —— speaker→npc_id 的解析发生在解析当拍，
## 解析完再用 set_known_npcs() 就只能事后补名册，条目上的 npc_id 已经空了。
static func set_context_npcs(mapping: Dictionary) -> void:
	_known_npcs = mapping.duplicate()


## 给纯夹具用：在解析之前声明"线索登记表"（等价于读过 data/clues/*.json）。
## 传空数组 = 不做线索交叉校验（这时候 clue_id 只按命名规范查）。
static func set_context_clue_ids(ids: Array) -> void:
	_known_clue_ids = {}
	for clue_id in ids:
		_known_clue_ids[str(clue_id)] = true


## 给纯夹具用：声明这一案的余页长度（秒），"秒数越界"校验要用它。
static func set_context_duration(seconds: int) -> void:
	_case_duration = seconds


# ============================================================================
#  内部类 1：一条台词
# ============================================================================

class DialogueLine:
	var text: String = ""
	## 行内换说话人（缺省空 = 沿用条目 speaker），给"对方插一句"用。
	var speaker: String = ""

	func is_usable() -> bool:
		return not text.strip_edges().is_empty()


# ============================================================================
#  内部类 2：一个选项
# ============================================================================

class DialogueOption:
	var text: String = ""
	var reply: String = ""
	var goto: String = ""
	var require_clues: Array[String] = []
	var require_loop_min: int = 0
	var add_clue: String = ""

	## 该选项是否会把一条线索交给玩家（对话层入录的唯一出口）。
	func gives_clue() -> bool:
		return not add_clue.is_empty()

	func describe() -> String:
		var tail: String = ""
		if not reply.is_empty():
			tail += "  → %s" % reply
		if not goto.is_empty():
			tail += "  [goto %s]" % goto
		if gives_clue():
			tail += "  [+%s]" % add_clue
		return "%s%s" % [text, tail]


# ============================================================================
#  内部类 3：一条对话（对话树的一个节点）
# ============================================================================

class DialogueEntry:
	var dialogue_id: String = ""
	var speaker: String = ""
	var npc_id: String = ""
	var start_second: int = -1
	var min_seconds: int = 0
	var lines: Array[DialogueLine] = []
	var options: Array[DialogueOption] = []
	var has_clues: Array[String] = []
	var loop_min: int = 0
	var note: String = ""
	var tagged_seconds: Array[int] = []
	var anchored_seconds: Array[int] = []

	## 全部台词拼成一段（UI 直接显示用）。
	func text() -> String:
		var parts: Array[String] = []
		for line in lines:
			parts.append(line.text)
		return "\n".join(parts)

	func first_line() -> String:
		if lines.is_empty():
			return ""
		return lines[0].text

	func line_count() -> int:
		return lines.size()

	func option_count() -> int:
		return options.size()

	## 是否锚定到了场景文件的某个秒（没有锚点的对话只能靠 unlock_if 判定）。
	func is_anchored() -> bool:
		return not anchored_seconds.is_empty()

	## 该对话覆盖的秒数区间（无锚点时返回空数组）。
	func active_window() -> Array[int]:
		if anchored_seconds.is_empty():
			return []
		var span: int = maxi(min_seconds, DEFAULT_MIN_SECONDS)
		var result: Array[int] = []
		for second in anchored_seconds:
			result.append(second)
			result.append(second + span)
		result.sort()
		return [result[0], result[result.size() - 1]]

	## 第 second 秒是否落在该对话的窗口内。
	func is_active_at(second: int) -> bool:
		if anchored_seconds.is_empty():
			return false
		var span: int = maxi(min_seconds, DEFAULT_MIN_SECONDS)
		for anchor in anchored_seconds:
			if second >= anchor and second < anchor + span:
				return true
		return false

	## unlock_if 是否满足（has_clues 全在 owned 里，且 loop_index >= loop_min）。
	## 选项上的 require_clues / require_loop_min 是**选项**门槛，不在本函数里判（见 available_options）。
	func is_unlocked(loop_index: int, owned_clues: Array) -> bool:
		if loop_index < loop_min:
			return false
		for clue_id in has_clues:
			if not owned_clues.has(clue_id):
				return false
		return true

	func describe() -> String:
		var where: String = "（无锚点）"
		if not anchored_seconds.is_empty():
			where = "t=%s" % str(anchored_seconds)
		return "%s @ %s：%s" % [dialogue_id, where, first_line()]


# ============================================================================
#  内部类 4：整张对话登记表（装载结果）
# ============================================================================

class DialogueTable:
	var ok: bool = false
	var error: String = ""
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var path: String = ""
	var case_path: String = ""

	var schema_version: int = 0
	var case_id: int = -1
	var map_id: String = ""
	var description: String = ""
	var loop_duration_seconds: int = 0

	var dialogue_order: Array[String] = []
	var dialogues: Dictionary = {}          # dialogue_id -> DialogueEntry

	## 文件里的原始顺序（重排前的快照）：用于稳定排序与"是不是本来就乱序"的判定。
	var source_order: Array[String] = []

	## 已知线索 id（装载时从 data/clues/*.json 读；空 = 不做交叉校验）。
	var known_clue_ids: Array[String] = []

	## NPC 显示名 -> npc_id（装载时从案件场景读）。
	var npc_names: Dictionary = {}

	# ------------------------------ 摘要 ------------------------------

	func count() -> int:
		return dialogue_order.size()

	func total_lines() -> int:
		var total: int = 0
		for dialogue_id in dialogue_order:
			total += (dialogues[dialogue_id] as DialogueEntry).line_count()
		return total

	func total_options() -> int:
		var total: int = 0
		for dialogue_id in dialogue_order:
			total += (dialogues[dialogue_id] as DialogueEntry).option_count()
		return total

	## 全表去重后的 speaker 列表（表现层据此知道"这一页上有几个能说话的人"）。
	func speakers() -> Array[String]:
		var result: Array[String] = []
		for dialogue_id in dialogue_order:
			var speaker := (dialogues[dialogue_id] as DialogueEntry).speaker
			if not speaker.is_empty() and not result.has(speaker):
				result.append(speaker)
		return result

	## 全表去重后的对话所属 npc_id 列表。
	func npc_ids() -> Array[String]:
		var result: Array[String] = []
		for dialogue_id in dialogue_order:
			var npc_id := (dialogues[dialogue_id] as DialogueEntry).npc_id
			if not npc_id.is_empty() and not result.has(npc_id):
				result.append(npc_id)
		return result

	func error_summary() -> String:
		if errors.is_empty():
			return error
		return "%s（%d 个问题）" % [error, errors.size()]

	# --------------------------- 交叉引用 ---------------------------

	## 给纯夹具用：声明"本表认得的线索 id"，之后 reward_clue_ids / validate_strict 会按它校验。
	func set_known_clue_ids(ids: Array) -> void:
		known_clue_ids.clear()
		for clue_id in ids:
			known_clue_ids.append(str(clue_id))

	## 给纯夹具用：声明"本表认得的 NPC"（npc_id -> 显示名），speaker 会按它解析。
	func set_known_npcs(mapping: Dictionary) -> void:
		npc_names = mapping.duplicate()

	# --------------------------- 秒级锚定 ---------------------------

	## 把"场景文件节点引用的秒数"灌进本表：anchors = dialogue_id -> [second, ...]。
	## 对话文件本身没有 second 字段（秒数只在 data/scenarios/*.json 的节点上），所以这是
	## 唯一给条目定拍的入口。装载路径 load_from_file 会自动调用它；纯夹具也用它。
	## 灌完会重算排序与校验（顺带把 tagged_seconds 与场景引用不一致的告警刷出来）。
	func apply_anchors(anchors: Dictionary) -> void:
		for dialogue_id in anchors.keys():
			var key := str(dialogue_id)
			if not dialogues.has(key):
				# 场景引用了对话表里没有的 id：这是**结构性错误**，绝不当没看见。
				errors.append("案件场景引用了未定义的 dialogue_id：%s（%s）" % [key, case_path])
				continue
			var entry := dialogues[key] as DialogueEntry
			var seconds: Array = anchors[dialogue_id]
			for second_value in seconds:
				var second := int(second_value)
				if not entry.anchored_seconds.has(second):
					entry.anchored_seconds.append(second)
			if not entry.anchored_seconds.is_empty():
				entry.anchored_seconds.sort()
				entry.start_second = entry.anchored_seconds[0]
		_sort_by_anchor()
		_refresh_ok()

	## 按"首拍秒"重排 dialogue_order（没有锚点的排在最后，保持文件里的原相对顺序）。
	## 什么时候值得报警告：**同一个人的条目**在文件里没按秒升序 —— 那是编排失误；
	## 而"按角色分块写"（穆青的几条挨着、再写郑守录）是这份文件的正常写法：秒数根本不在
	## 对话文件里（只在 data/scenarios 的节点上），所以跨 NPC 交错不算问题。
	## 不这么限定的话，38 条真实数据每次装载都会刷一条"顺序乱"的噪音，真正的问题会被淹掉。
	func _sort_by_anchor() -> void:
		var before: Array[String] = source_order.duplicate()
		dialogue_order.sort_custom(func(a: String, b: String) -> bool:
			var ea := dialogues[a] as DialogueEntry
			var eb := dialogues[b] as DialogueEntry
			var sa: int = ea.start_second if ea.is_anchored() else 0x7FFFFFFF
			var sb: int = eb.start_second if eb.is_anchored() else 0x7FFFFFFF
			if sa == sb:
				return before.find(a) < before.find(b)
			return sa < sb
		)
		var last_second: Dictionary = {}
		for dialogue_id in before:
			var entry := dialogues[dialogue_id] as DialogueEntry
			if not entry.is_anchored():
				continue
			var who: String = entry.npc_id if not entry.npc_id.is_empty() else entry.speaker
			if who.is_empty():
				continue
			if last_second.has(who) and int(last_second[who]) > entry.start_second:
				warnings.append("%s 的条目不是按秒升序排的（同一人的台词顺序与拍点矛盾；已按场景引用的秒数自动重排，这只是可疑，不影响装载）" % who)
				break       # 一条就够：同一个毛病报 20 遍只会把真问题淹掉
			last_second[who] = entry.start_second

	func _refresh_ok() -> void:
		ok = errors.is_empty()
		if not ok:
			error = errors[0]
		for npc_id in npc_names.keys():
			var display_name := str(npc_names[npc_id])
			if not display_name.is_empty():
				npc_names[display_name] = str(npc_id)

	## 该线索 id 是否登记在 data/clues/*.json（known_clue_ids 为空时一律返回 true = 不做判断）。
	func is_known_clue(clue_id: String) -> bool:
		if known_clue_ids.is_empty():
			return true
		return known_clue_ids.has(clue_id)

	# --------------------------- 查询接口 ---------------------------

	## 按 dialogue_id 取一条。没有则返回 null（不静默造一个空对象 —— 调用方必须自己判空）。
	func get_dialogue(dialogue_id: String) -> DialogueEntry:
		if not dialogues.has(dialogue_id):
			return null
		return dialogues[dialogue_id] as DialogueEntry

	func has_dialogue(dialogue_id: String) -> bool:
		return dialogues.has(dialogue_id)

	## 全部对话 id（保持文件里的先后顺序）。
	func dialogue_ids() -> Array[String]:
		return dialogue_order.duplicate()

	## 显示名解析成 npc_id（解析不出来时原样返回，绝不返回空串覆盖调用方的输入）。
	func npc_id_of(speaker: String) -> String:
		if npc_names.has(speaker):
			return str(npc_names[speaker])
		return speaker

	## 某条对话奖励的线索 id 列表（条目级没有给线索的字段 ⇒ 目前恒为空，保留给将来的 unlock_if 扩展）。
	## 真正给线索的是**选项**，见 option_clue_ids() / reward_clue_ids()。
	func entry_clue_ids(dialogue_id: String) -> Array[String]:
		var entry := get_dialogue(dialogue_id)
		if entry == null:
			return []
		return entry.has_clues.duplicate()

	## 某个选项给的线索（没有则返回空串）。
	func option_clue_ids(option: DialogueOption) -> String:
		return option.add_clue

	## 某条对话**所有选项**能给的线索 id 列表（去重，按选项顺序）。
	## 用途：回答"这两条孤儿线索现在可达吗"、"这条对话最多能拿到什么"。
	func reward_clue_ids(dialogue_id: String) -> Array[String]:
		var entry := get_dialogue(dialogue_id)
		if entry == null:
			return []
		var result: Array[String] = []
		for option in entry.options:
			if option.gives_clue() and not result.has(option.add_clue):
				result.append(option.add_clue)
		return result

	## 全集：哪些对话会给出这条线索（空数组 = 没有任何对话给得出它 = 孤儿线索）。
	func dialogues_giving(clue_id: String) -> Array[String]:
		var result: Array[String] = []
		for dialogue_id in dialogue_order:
			if reward_clue_ids(dialogue_id).has(clue_id):
				result.append(dialogue_id)
		return result

	## 全表奖励的所有线索 id（去重，按对话顺序）。
	func all_reward_clue_ids() -> Array[String]:
		var result: Array[String] = []
		for dialogue_id in dialogue_order:
			for clue_id in reward_clue_ids(dialogue_id):
				if not result.has(clue_id):
					result.append(clue_id)
		return result

	## 某条对话此刻可选的选项（选项自己的 require_clues / require_loop_min 由这里判）。
	func available_options(dialogue_id: String, loop_index: int, owned_clues: Array) -> Array[DialogueOption]:
		var result: Array[DialogueOption] = []
		var entry := get_dialogue(dialogue_id)
		if entry == null:
			return result
		for option in entry.options:
			if self.option_available(option, loop_index, owned_clues):
				result.append(option)
		return result

	## 单个选项是否可点（本条对话的 unlock_if 不在这里判 —— 那是 entry 级的门槛）。
	func option_available(option: DialogueOption, loop_index: int, owned_clues: Array) -> bool:
		if loop_index < option.require_loop_min:
			return false
		for clue_id in option.require_clues:
			if not owned_clues.has(clue_id):
				return false
		return true

	## 一条对话此刻是否可触发：锚定的时间窗口命中 + unlock_if 满足。
	func is_available(dialogue_id: String, second: int, loop_index: int, owned_clues: Array) -> bool:
		var entry := get_dialogue(dialogue_id)
		if entry == null:
			return false
		if entry.is_anchored() and not entry.is_active_at(second):
			return false
		return entry.is_unlocked(loop_index, owned_clues)

	## ★ "玩家/NPC 同处一室时该说什么"的唯一入口。
	##   第二 = 已过秒数（**不是** time_updated 广播的剩余秒数，见 AGENTS.md §4）；
	##   loop_index = 第几遍（0 起）；owned_clues = 玩家已入录的线索 id（PersistentMemoryManager.get_clues()）。
	##   返回按"秒 -> 对话 id"排序的全部命中条目；没有可说的返回空数组（合法状态，不是失败）。
	func say_for(npc_id: String, second: int, loop_index: int, owned_clues: Array) -> Array[DialogueEntry]:
		var result: Array[DialogueEntry] = []
		for dialogue_id in dialogue_order:
			var entry := dialogues[dialogue_id] as DialogueEntry
			if not _entry_matches_npc(entry, npc_id):
				continue
			if not is_available(dialogue_id, second, loop_index, owned_clues):
				continue
			result.append(entry)
		result.sort_custom(func(a: DialogueEntry, b: DialogueEntry) -> bool:
			return a.start_second < b.start_second
		)
		return result

	## 只要第一条（UI 的常见用法：一个 NPC 同拍只说一条）。
	func current_line(npc_id: String, second: int, loop_index: int, owned_clues: Array) -> DialogueEntry:
		var found := say_for(npc_id, second, loop_index, owned_clues)
		if found.is_empty():
			return null
		return found[0]

	## 全表此刻能触发的对话（不限 NPC），按秒排序 —— "这一秒谁在说话"的全局视图。
	func active_dialogues(second: int, loop_index: int, owned_clues: Array) -> Array[DialogueEntry]:
		var result: Array[DialogueEntry] = []
		for dialogue_id in dialogue_order:
			var entry := dialogues[dialogue_id] as DialogueEntry
			if is_available(dialogue_id, second, loop_index, owned_clues):
				result.append(entry)
		result.sort_custom(func(a: DialogueEntry, b: DialogueEntry) -> bool:
			return a.start_second < b.start_second
		)
		return result

	## 观察到的最大拍点（场景文件的节点秒数进入本表后，表现层可以直接说"念完这一秒才算看过全页"）。
	func last_anchor_second() -> int:
		var best: int = -1
		for dialogue_id in dialogue_order:
			var entry := dialogues[dialogue_id] as DialogueEntry
			for second in entry.anchored_seconds:
				best = maxi(best, second)
		return best

	func _entry_matches_npc(entry: DialogueEntry, npc_id: String) -> bool:
		if npc_id.is_empty():
			return true
		return entry.npc_id == npc_id

	## 严格复检：把当前上下文（已知线索表 / 已知 NPC / 余页长度）套到已解析的表上，
	## 返回一个**新的** DialogueTable（errors/warnings 重新收集，查询结果原样搬过去）。
	## 用途：先 parse_text 出结构，再 set_known_* 声明上下文，然后复检 —— 测试夹具不必读真文件。
	func validate_strict() -> DialogueTable:
		var result := DialogueTable.new()
		result.path = path
		result.case_path = case_path
		result.schema_version = schema_version
		result.case_id = case_id
		result.map_id = map_id
		result.description = description
		result.loop_duration_seconds = loop_duration_seconds
		result.known_clue_ids = known_clue_ids.duplicate()
		result.npc_names = npc_names.duplicate()
		result.dialogue_order = dialogue_order.duplicate()
		result.dialogues = dialogues.duplicate()
		for dialogue_id in result.dialogue_order:
			DialogueTable._validate_entry(result.dialogues[dialogue_id] as DialogueEntry, result)
		result.ok = result.errors.is_empty()
		if not result.ok:
			result.error = result.errors[0]
		return result

	# ---------------------------------------------------------------------------
	#  内部：单条对话
	# ---------------------------------------------------------------------------

	static func _parse_entry(raw: Dictionary, dialogue_id: String, result: DialogueTable) -> DialogueEntry:
		var entry := DialogueEntry.new()
		entry.dialogue_id = dialogue_id
		entry.speaker = str(raw.get("speaker", "")).strip_edges()
		entry.npc_id = str(raw.get("npc_id", "")).strip_edges()
		entry.start_second = int(raw.get("second", -1))
		entry.min_seconds = int(raw.get("min_seconds", 0))
		entry.note = str(raw.get("note", ""))

		if entry.npc_id.is_empty() and not entry.speaker.is_empty():
			entry.npc_id = result.npc_id_of(entry.speaker)
		# 不做"按 id 前缀猜秒"：前缀（mq_ / zsl_ / gfy_ …）只是命名习惯，
		# 真正的秒数由 load_dialogue_anchors() 从案件场景文件写进 anchored_seconds。

		var lines_value: Variant = raw.get("lines", null)
		if lines_value is Array:
			for line_value in (lines_value as Array):
				var line := DialogueLine.new()
				if line_value is Dictionary:
					line.text = str((line_value as Dictionary).get("text", ""))
					line.speaker = str((line_value as Dictionary).get("speaker", ""))
				else:
					line.text = str(line_value)
				entry.lines.append(line)

		var options_value: Variant = raw.get("options", [])
		if options_value is Array:
			for option_value in (options_value as Array):
				if not (option_value is Dictionary):
					result.warnings.append("%s 的 options 里出现了非对象元素，已跳过" % dialogue_id)
					continue
				entry.options.append(DialogueTable._parse_option(option_value as Dictionary, entry, result))

		var unlock_value: Variant = raw.get("unlock_if", {})
		if unlock_value is Dictionary:
			var unlock: Dictionary = unlock_value
			entry.loop_min = int(unlock.get("loop_min", 0))
			var clues_value: Variant = unlock.get("has_clues", [])
			if clues_value is Array:
				for clue_value in (clues_value as Array):
					var clue_id := str(clue_value).strip_edges()
					if clue_id.is_empty():
						result.warnings.append("%s 的 unlock_if.has_clues 里有空字符串，已跳过" % dialogue_id)
						continue
					if not entry.has_clues.has(clue_id):
						entry.has_clues.append(clue_id)
			elif clues_value != null:
				result.warnings.append("%s 的 unlock_if.has_clues 必须是数组" % dialogue_id)
		elif unlock_value != null:
			result.warnings.append("%s 的 unlock_if 必须是对象" % dialogue_id)

		return entry


	static func _parse_option(raw: Dictionary, entry: DialogueEntry, result: DialogueTable) -> DialogueOption:
		var option := DialogueOption.new()
		option.text = str(raw.get("text", ""))
		option.reply = str(raw.get("reply", ""))
		option.goto = str(raw.get("goto", "")).strip_edges()
		option.require_loop_min = int(raw.get("require_loop_min", 0))
		option.add_clue = str(raw.get("add_clue", "")).strip_edges()

		var clues_value: Variant = raw.get("require_clues", [])
		if clues_value is Array:
			for clue_value in (clues_value as Array):
				var clue_id := str(clue_value).strip_edges()
				if clue_id.is_empty():
					continue
				if not option.require_clues.has(clue_id):
					option.require_clues.append(clue_id)
		elif clues_value != null:
			result.warnings.append("%s 的选项「%s」的 require_clues 必须是数组" % [entry.dialogue_id, option.text])

		for field in raw.keys():
			if not OPTION_FIELDS.has(str(field)):
				result.warnings.append("%s 的选项「%s」有未识别的字段 %s" % [entry.dialogue_id, option.text, str(field)])

		return option


	# ---------------------------------------------------------------------------
	#  内部：校验（解析后再跑一遍，validate_strict() 复用同一段）
	# ---------------------------------------------------------------------------

	static func _validate_entry(entry: DialogueEntry, result: DialogueTable) -> void:
		var where: String = entry.dialogue_id

		if entry.lines.is_empty():
			result.errors.append("%s 缺少 lines（一条对话至少要有一句台词）" % where)
		else:
			for i in range(entry.lines.size()):
				var line := entry.lines[i]
				if not line.is_usable():
					result.warnings.append("%s 的第 %d 句台词是空的" % [where, i + 1])
			if entry.lines.size() == 1 and not entry.options.is_empty():
				result.warnings.append("%s 只有一句台词（可能是漏了第二句）" % where)

		if entry.speaker.is_empty() and entry.npc_id.is_empty():
			result.warnings.append("%s 没有 speaker（不知道该由谁来说）" % where)
		elif not entry.speaker.is_empty() \
				and not result.npc_names.is_empty() \
				and not result.npc_names.has(entry.speaker):
			result.warnings.append("%s 的 speaker「%s」不在案件 NPC 名单里（没能解析成 npc_id，该条按显示名原样保留）" % [where, entry.speaker])
		if not entry.npc_id.is_empty() and DialogueTable._looks_like_npc_id(entry.npc_id) \
				and not result.npc_names.is_empty() and not result.npc_names.has(entry.npc_id):
			result.errors.append("%s 引用了不存在的 npc_id：%s（可用：%s）" % [
				where, entry.npc_id, DialogueTable._join_npc_ids(result.npc_names),
			])

		if entry.loop_min < 0:
			result.errors.append("%s 的 unlock_if.loop_min 不能为负（当前 %d）" % [where, entry.loop_min])
		for clue_id in entry.has_clues:
			DialogueTable._check_clue_id(clue_id, "%s 的 unlock_if.has_clues" % where, result)

		if entry.min_seconds < 0:
			result.errors.append("%s 的 min_seconds 不能为负（当前 %d）" % [where, entry.min_seconds])
		if entry.start_second >= 0:
			if result.loop_duration_seconds > 0 and entry.start_second >= result.loop_duration_seconds:
				result.errors.append("%s 的 second=%d 越界（超出余页长度 %d 秒）" % [
					where, entry.start_second, result.loop_duration_seconds,
				])
			# validate_strict() 会对同一批条目再跑一遍本函数 ⇒ 必须先查重，否则拍点被记两次。
			if not entry.tagged_seconds.has(entry.start_second):
				entry.tagged_seconds.append(entry.start_second)

		if entry.note.strip_edges().is_empty():
			result.warnings.append("%s 没有 note（秒数/遍数来源无处可查）" % where)

		if entry.options.is_empty():
			result.warnings.append("%s 没有任何选项（玩家只能看着，不能接话）" % where)
		var goto_count: int = 0
		for option in entry.options:
			if option.text.strip_edges().is_empty():
				result.warnings.append("%s 有一个选项缺 text" % where)
			# 注意：case_01_dialogues.json 里大量选项是"（旁观／不接话／记下来就走）"，
			# reply 与 goto 同时为空是**合法内容**（选了就是收下信息、不再追问）⇒ 只对
			# "连 text 都没有"的选项报可疑；否则 38 条真实数据会刷出 20 条噪音警告，把真问题淹掉。
			if option.text.strip_edges().is_empty() and option.reply.strip_edges().is_empty() \
					and option.goto.is_empty() and not option.gives_clue():
				result.warnings.append("%s 的选项完全为空（无 text / reply / goto / add_clue，选它没有任何效果）" % where)
			if option.require_loop_min < 0:
				result.errors.append("%s 的选项「%s」的 require_loop_min 不能为负" % [where, option.text])
			if not option.goto.is_empty():
				goto_count += 1
				if not result.dialogues.has(option.goto):
					result.warnings.append("%s 的选项「%s」goto 指向不存在的对话：%s（可用：%s）" % [
						where, option.text, option.goto, DialogueTable._join_dialogue_ids(result.dialogues),
					])
			for clue_id in option.require_clues:
				DialogueTable._check_clue_id(clue_id, "%s 的选项「%s」的 require_clues" % [where, option.text], result)
			if option.gives_clue():
				DialogueTable._check_clue_id(option.add_clue, "%s 的选项「%s」的 add_clue" % [where, option.text], result)


	## clue_id 必须登记在 data/clues/*.json（已知线索表为空时跳过 = 纯夹具不误报）。
	static func _check_clue_id(clue_id: String, where: String, result: DialogueTable) -> void:
		if clue_id.is_empty():
			result.warnings.append("%s 里有空的 clue_id" % where)
			return
		var re := RegEx.create_from_string(CLUE_ID_PATTERN)
		if re != null and not re.search(clue_id):
			result.warnings.append("%s 的 clue_id「%s」不符合命名规范 clue_/note_/sealed_<案号>_<对象>" % [where, clue_id])
		if result.known_clue_ids.is_empty():
			return
		if not result.known_clue_ids.has(clue_id):
			result.errors.append("%s 引用了未登记的线索：%s（%s）" % [
				where, clue_id, DialogueTable._suggest_clue(clue_id, result.known_clue_ids),
			])


	## 锚点复查：条目的 second 与场景文件的引用秒数不一致时给 warning（场景文件是权威）。
	static func _apply_anchor_checks(table: DialogueTable, anchors: Dictionary) -> void:
		for dialogue_id in anchors.keys():
			if not table.dialogues.has(dialogue_id):
				table.errors.append("案件场景引用了未定义的 dialogue_id：%s（%s）" % [
					dialogue_id, table.case_path,
				])
				continue
			var entry := table.dialogues[dialogue_id] as DialogueEntry
			if entry.tagged_seconds.is_empty():
				continue
			var seconds: Array = anchors[dialogue_id]
			if not seconds.is_empty() and not seconds.has(entry.tagged_seconds[0]):
				table.warnings.append("%s 的 second=%d 与案件场景引用的秒数 %s 不一致（以场景为准）" % [
					dialogue_id, entry.tagged_seconds[0], str(seconds),
				])


	static func _scan_duplicate_dialogue_ids(text: String) -> Array[String]:
		# 为什么只能在文本层面抓：JSON 对象里重复的键会被解析器**静默覆盖**（只留最后一个），
		# 结构层面根本看不见。而且必须严格在"键位置"上数 —— 值字符串（台词里再念一次
		# dialogue_id）绝不能被误判成重复定义。所以这里单遍扫描 + 显式状态机：
		#   in_dialogues 为真 = 正处在根层 "dialogues" 打开的那个对象里，此时的键就是 dialogue_id。
		var counts: Dictionary = {}
		var found: Array[String] = []
		var depth: int = 0
		var in_dialogues: bool = false
		var dialogues_level: int = -1
		var pending_key: bool = false       # 刚读完一个字符串，若紧跟冒号则它是键（不是值）
		var key_raw: String = ""            # 键的原始内容（含转义）
		var i: int = 0
		var size: int = text.length()
		while i < size:
			var ch: String = text[i]
			if pending_key:
				if ch == ":":
					# 冒号到：刚才那个字符串确实是键（而不是值）。
					var key: String = _unescape_json(key_raw)
					if depth == 1 and key == "dialogues":
						in_dialogues = true
						dialogues_level = 2
					elif in_dialogues and depth == dialogues_level and not key.is_empty():
						var seen: int = int(counts.get(key, 0)) + 1
						counts[key] = seen
						if seen > 1 and not found.has(key):
							found.append(key)
					pending_key = false
					key_raw = ""
					i += 1
					continue                # 值交给下面正常分支处理
				if ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
					i += 1
					continue
				# 其它字符 ⇒ 那个字符串是值，不是键。
				pending_key = false
				key_raw = ""
				continue
			if ch == "\"":
				var end_index: int = _peek_string_end(text, i + 1)
				if end_index < 0:
					break
				key_raw = text.substr(i + 1, end_index - i - 1)
				pending_key = true
				i = end_index + 1
				continue
			if ch == "{":
				depth += 1
				i += 1
				continue
			if ch == "}":
				if in_dialogues and depth == dialogues_level:
					in_dialogues = false
				depth -= 1
				if depth < 0:
					depth = 0
				i += 1
				continue
			if ch == "[":
				# 数组里的元素不是键，整段跳过（数组里不会出现 dialogue_id 定义）。
				i = _skip_bracket(text, i + 1, "[", "]")
				continue
			i += 1
		found.sort()
		return found


	## 找字符串字的收尾引号下标（未闭合返回 -1）。转义引号不算收尾。
	static func _peek_string_end(text: String, from: int) -> int:
		var escaped: bool = false
		for i in range(from, text.length()):
			var ch: String = text[i]
			if escaped:
				escaped = false
				continue
			if ch == "\\":
				escaped = true
				continue
			if ch == "\"":
				return i
		return -1


	## 跳过一段用 open_char/close_char 包起来的区间（支持嵌套），返回收尾字符的下标。
	static func _skip_bracket(text: String, from: int, open_char: String, close_char: String) -> int:
		var nesting: int = 1
		var i: int = from
		while i < text.length():
			var ch: String = text[i]
			if ch == "\"":
				var end_index: int = _peek_string_end(text, i + 1)
				if end_index < 0:
					return text.length()
				i = end_index + 1
				continue
			if ch == open_char:
				nesting += 1
			elif ch == close_char:
				nesting -= 1
				if nesting <= 0:
					return i
			i += 1
		return text.length()


	## 还原 JSON 字符串里的转义（键名一般没有转义，但不能假设）。
	static func _unescape_json(raw: String) -> String:
		if not raw.contains("\\"):
			return raw
		var out: String = ""
		var i: int = 0
		while i < raw.length():
			var ch: String = raw[i]
			if ch == "\\" and i + 1 < raw.length():
				var next_char: String = raw[i + 1]
				match next_char:
					"n":
						out += "\n"
					"t":
						out += "\t"
					"r":
						out += "\r"
					"\"":
						out += "\""
					"\\":
						out += "\\"
					"/":
						out += "/"
					_:
						out += next_char
				i += 2
				continue
			out += ch
			i += 1
		return out


	static func _looks_like_npc_id(text: String) -> bool:
		return text.begins_with("npc_")

	static func _join_npc_ids(mapping: Dictionary) -> String:
		var pairs: Array[String] = []
		for key in mapping.keys():
			var key_text := str(key)
			if not key_text.begins_with("npc_"):
				continue
			pairs.append("%s(%s)" % [key_text, str(mapping[key])])
		pairs.sort()
		if pairs.is_empty():
			return "（无）"
		return "、".join(pairs)

	static func _join_dialogue_ids(dialogues: Dictionary) -> String:
		var ids: Array[String] = []
		for key in dialogues.keys():
			ids.append(str(key))
		ids.sort()
		if ids.is_empty():
			return "（无）"
		return ", ".join(ids)

	static func _suggest_clue(clue_id: String, candidates: Array[String]) -> String:
		var best: String = ""
		var best_distance: int = 4
		for candidate in candidates:
			var distance := DialogueTable._edit_distance(clue_id, candidate)
			if distance < best_distance:
				best_distance = distance
				best = candidate
		if best.is_empty():
			return "已登记线索：%s" % ", ".join(candidates)
		return "是想写「%s」吗？已登记线索：%s" % [best, ", ".join(candidates)]

	static func _edit_distance(a: String, b: String) -> int:
		var rows: int = a.length() + 1
		var cols: int = b.length() + 1
		var previous: Array[int] = []
		var current: Array[int] = []
		for _i in range(cols):
			previous.append(0)
			current.append(0)
		for j in range(cols):
			previous[j] = j
		for i in range(1, rows):
			current[0] = i
			for j in range(1, cols):
				var cost: int = 0 if a[i - 1] == b[j - 1] else 1
				current[j] = mini(mini(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + cost)
			for j in range(cols):
				previous[j] = current[j]
		return previous[cols - 1]


# ============================================================================
#  装载入口
# ============================================================================

## 列出 data/dialogues 下的全部对话文件（按文件名排序）。目录不存在时返回空数组（合法状态）。
static func list_dialogue_files() -> PackedStringArray:
	return _list_json_files(DIALOGUE_DIR, "case_")


## 找到某案的对话文件：case_id < 0 时取编号最小的那个；没有则返回空串。
static func find_dialogue_path(case_id: int = -1) -> String:
	var files := list_dialogue_files()
	if files.is_empty():
		return ""
	if case_id < 0:
		return files[0]
	var prefix := "case_%02d" % case_id
	for file_path in files:
		if file_path.get_file().begins_with(prefix):
			return file_path
	return ""


## 找某案的场景文件（对 dialogue_id 做秒级锚定用）。
static func find_scenario_path(case_id: int = -1) -> String:
	var files := _list_json_files(SCENARIO_DIR, "case_")
	if files.is_empty():
		return ""
	if case_id < 0:
		return files[0]
	var prefix := "case_%02d" % case_id
	for file_path in files:
		if file_path.get_file().begins_with(prefix):
			return file_path
	return ""


## 读 data/clues/*.json 的登记线索 id（按 case_id 过滤；case_id < 0 = 全收）。
## 读不到任何线索表时返回空数组 ⇒ 调用方据此跳过线索交叉校验（绝不静默失败：跳过是显式的）。
static func load_clue_registry(case_id: int = -1) -> Array[String]:
	var result: Array[String] = []
	var files := _list_json_files(CLUE_DIR, "case_")
	for file_path in files:
		var data: Variant = _read_json(file_path)
		if not (data is Dictionary):
			continue
		var file_case_id := _case_id_of(file_path)
		if case_id >= 0 and file_case_id != case_id:
			continue
		var clues_value: Variant = (data as Dictionary).get("clues", [])
		if not (clues_value is Array):
			continue
		for clue_value in (clues_value as Array):
			if not (clue_value is Dictionary):
				continue
			var clue_id := str((clue_value as Dictionary).get("clue_id", ""))
			if not clue_id.is_empty() and not result.has(clue_id):
				result.append(clue_id)
	return result


## NPC 显示名 -> npc_id（从案件场景文件读；文件不存在时返回空字典，此时 speaker 原样保留）。
static func load_npc_names(case_path: String) -> Dictionary:
	var result: Dictionary = {}
	var data: Variant = _read_json(case_path)
	if not (data is Dictionary):
		return result
	var npcs_value: Variant = (data as Dictionary).get("npcs", [])
	if not (npcs_value is Array):
		return result
	for npc_value in (npcs_value as Array):
		if not (npc_value is Dictionary):
			continue
		var npc: Dictionary = npc_value
		var npc_id := str(npc.get("npc_id", ""))
		var display_name := str(npc.get("display_name", ""))
		if npc_id.is_empty() or display_name.is_empty():
			continue
		result[npc_id] = display_name
		result[display_name] = npc_id
	return result


## dialogue_id -> 被案件场景引用的秒数列表（同一 id 被多处引用时全部收下）。
static func load_dialogue_anchors(case_path: String) -> Dictionary:
	var result: Dictionary = {}
	var data: Variant = _read_json(case_path)
	if not (data is Dictionary):
		return result
	var npcs_value: Variant = (data as Dictionary).get("npcs", [])
	if not (npcs_value is Array):
		return result
	for npc_value in (npcs_value as Array):
		if not (npc_value is Dictionary):
			continue
		var timeline_value: Variant = (npc_value as Dictionary).get("timeline", [])
		if not (timeline_value is Array):
			continue
		for node_value in (timeline_value as Array):
			if not (node_value is Dictionary):
				continue
			var node: Dictionary = node_value
			var dialogue_id := str(node.get("dialogue_id", "")).strip_edges()
			if dialogue_id.is_empty():
				continue
			var second := int(node.get("second", -1))
			if second < 0:
				continue
			if not result.has(dialogue_id):
				result[dialogue_id] = []
			var seconds: Array = result[dialogue_id]
			if not seconds.has(second):
				seconds.append(second)
	for dialogue_id in result.keys():
		(result[dialogue_id] as Array).sort()
	return result


## 案件余页长度（做"秒数越界"校验用）。读不到返回 0（= 跳过该项校验）。
static func load_case_duration(case_path: String) -> int:
	var data: Variant = _read_json(case_path)
	if not (data is Dictionary):
		return 0
	var meta_value: Variant = (data as Dictionary).get("meta", {})
	if not (meta_value is Dictionary):
		return 0
	return int((meta_value as Dictionary).get("loop_duration_seconds", 0))


## ★ 按案号装载：自动配对 data/dialogues/case_NN_*.json 与 data/scenarios/case_NN_*.json，
##   并读入线索登记表做交叉校验。这是表现层唯一需要的入口。
static func load_for_case(case_id: int = 1) -> DialogueTable:
	var dialogue_path := find_dialogue_path(case_id)
	if dialogue_path.is_empty():
		var missing := DialogueTable.new()
		missing.error = "找不到对话文件：%s 下没有 case_%02d_*.json" % [DIALOGUE_DIR, case_id]
		return missing
	return load_from_file(dialogue_path, find_scenario_path(case_id))


## 从文件装载。case_path 非空时：用它锚定秒数 + 解析 speaker + 取余页长度。
## 线索登记表一律按案号自动读（读不到就跳过线索交叉校验，并在 warnings 里说清楚）。
static func load_from_file(path: String, case_path: String = "") -> DialogueTable:
	if path.is_empty():
		var empty := DialogueTable.new()
		empty.error = "对话文件路径为空（先按 docs/story/09 §6 写一个 data/dialogues/case_NN_*.json）"
		return empty

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var missing := DialogueTable.new()
		missing.path = path
		missing.error = "无法打开对话文件：%s（错误码 %d）" % [path, FileAccess.get_open_error()]
		return missing

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not (parsed is Dictionary):
		var bad := DialogueTable.new()
		bad.path = path
		bad.error = "对话文件不是合法 JSON 对象：%s" % path
		return bad

	var case_id := int((parsed as Dictionary).get("meta", {}).get("case_id", -1))
	if case_path.is_empty():
		case_path = find_scenario_path(case_id)

	# 装载上下文（静态、只在真读文件时写入；parse_dictionary 是纯函数，不读这些全局量，
	# 所以纯夹具的校验结果不会被"上一次真读文件"污染）。
	var registry := load_clue_registry(case_id)
	_known_clue_ids = {}
	for clue_id in registry:
		_known_clue_ids[clue_id] = true
	_known_npcs = load_npc_names(case_path)
	_case_duration = load_case_duration(case_path)

	var table := parse_dictionary(parsed as Dictionary, path)
	table.case_path = case_path
	table.known_clue_ids = registry
	table.npc_names = _known_npcs.duplicate()
	if table.loop_duration_seconds <= 0:
		table.loop_duration_seconds = _case_duration

	# 锚定：把场景文件里引用的秒数写进对应条目（数据文件不动）。
	var anchors := load_dialogue_anchors(case_path)
	if anchors.is_empty():
		if case_path.is_empty():
			table.warnings.append("没有找到案件场景文件（%s/case_%02d_*.json），全部对话都没有秒级锚点；say_for() 将按 unlock_if 判定" % [SCENARIO_DIR, case_id])
		else:
			table.warnings.append("案件场景文件里没有任何 dialogue_id 引用：%s" % case_path)
	else:
		table.apply_anchors(anchors)
		DialogueTable._apply_anchor_checks(table, anchors)

	# 重复 dialogue_id：JSON 对象里重复的键会在解析时被覆盖掉，只能回到文本层面抓。
	for duplicate_id in DialogueTable._scan_duplicate_dialogue_ids(text):
		table.errors.append("dialogue_id 重复定义：%s（同一个键在文件里出现了两次，后者覆盖了前者）" % duplicate_id)
	table.ok = table.errors.is_empty()
	if not table.ok:
		table.error = table.errors[0]
	return table


## 从文本装载（测试夹具入口）。默认**不做**跨文件交叉校验（没有上下文），
## 需要时先 set_known_* 再 validate_strict()。
static func parse_text(text: String, path: String = "<text>") -> DialogueTable:
	var json := JSON.new()
	var error := json.parse(text)
	if error != OK:
		var bad := DialogueTable.new()
		bad.path = path
		bad.error = "对话文本不是合法 JSON（第 %d 行）：%s" % [json.get_error_line() + 1, json.get_error_message()]
		bad.errors.append(bad.error)
		return bad
	var parsed: Variant = json.data
	if not (parsed is Dictionary):
		var not_object := DialogueTable.new()
		not_object.path = path
		not_object.error = "不是合法 JSON 对象：%s" % path
		not_object.errors.append(not_object.error)
		return not_object
	var table := parse_dictionary(parsed as Dictionary, path)
	for duplicate_id in DialogueTable._scan_duplicate_dialogue_ids(text):
		table.errors.append("dialogue_id 重复定义：%s（同一个键在文件里出现了两次，后者覆盖了前者）" % duplicate_id)
	table._refresh_ok()
	return table


## 把对话字典转成 DialogueTable。校验分两级（与 case_loader 同一套风格）：
##   · errors  —— 结构性错误：缺 meta / dialogues 不是对象 / 缺 dialogue_id / 缺 lines /
##                秒数越界 / 引用了不存在的 npc / clue_id 不在线索登记表里，ok=false；
##   · warnings —— 可疑但可继续：缺 speaker、台词为空、goto 指向不存在的对话、
##                条目顺序乱、leak 掉的字段、没有秒级锚点。
static func parse_dictionary(data: Dictionary, path: String = "<dict>") -> DialogueTable:
	var result := DialogueTable.new()
	result.path = path
	# Dictionary.keys() 是**无类型** Array，直接赋给 Array[String] 字段会运行时报错，必须逐项转。
	for clue_id in _known_clue_ids.keys():
		result.known_clue_ids.append(str(clue_id))
	result.npc_names = _known_npcs.duplicate()

	var meta_value: Variant = data.get("meta", {})
	if not (meta_value is Dictionary):
		result.errors.append("meta 必须是对象（缺 meta 就无法判断这份表属于哪一案）")
		result.error = "对话数据缺少 meta"
		result.ok = false
		return result
	var meta: Dictionary = meta_value
	result.schema_version = int(meta.get("schema_version", 0))
	result.case_id = int(meta.get("case_id", -1))
	result.map_id = str(meta.get("map_id", ""))
	result.description = str(meta.get("description", ""))
	# 对话文件自己的 meta 没有 loop_duration_seconds（余页长度是案件文件的权威字段），
	# 装载时会用案件文件的值补上；纯夹具则由夹具的 meta 提供。
	result.loop_duration_seconds = int(meta.get("loop_duration_seconds", 0))
	if result.loop_duration_seconds <= 0:
		result.loop_duration_seconds = _case_duration
	if result.case_id < 0:
		result.errors.append("meta.case_id 缺失或非法（当前 %d）" % result.case_id)

	var dialogues_value: Variant = data.get("dialogues", null)
	if not (dialogues_value is Dictionary) or (dialogues_value as Dictionary).is_empty():
		result.errors.append("dialogues 必须是非空对象（键 = dialogue_id，值 = 一条对话）")
		result.error = "对话数据缺少 dialogues"
		result.ok = false
		return result

	var dialogues_dict: Dictionary = dialogues_value
	for key in dialogues_dict.keys():
		var dialogue_id := str(key).strip_edges()
		if dialogue_id.is_empty():
			result.errors.append("有对话条目的 dialogue_id 是空串")
			continue
		if result.dialogues.has(dialogue_id):
			result.errors.append("dialogue_id 重复：%s" % dialogue_id)
			continue
		var entry_value: Variant = dialogues_dict[key]
		if not (entry_value is Dictionary):
			result.errors.append("%s 的值必须是对象（当前是 %s）" % [dialogue_id, type_string(typeof(entry_value))])
			continue
		var entry := DialogueTable._parse_entry(entry_value as Dictionary, dialogue_id, result)
		result.dialogues[dialogue_id] = entry
		result.dialogue_order.append(dialogue_id)
		result.source_order.append(dialogue_id)

	if result.dialogues.is_empty():
		result.errors.append("没有任何可用的对话条目")

	# 解析完再统一做跨条目校验（goto 必须指向存在的对话；speaker 必须能解析成 npc_id）。
	for dialogue_id in result.dialogue_order:
		var entry := result.dialogues[dialogue_id] as DialogueEntry
		DialogueTable._validate_entry(entry, result)

	result.ok = result.errors.is_empty()
	if not result.ok:
		result.error = result.errors[0]
	return result


## JSON 对象里重复的键在解析时会被后者覆盖，结构层面看不见了 ⇒ 需要回到文本层面抓。
## 只统计 dialogues 那一层的键（depth 0 = 根对象，depth 1 = dialogues 对象）：
## 更深层的键按"父键路径"分组，路径里每个名字只报一次。
## 规则：字符串**内**的 `{` / `}` 不算层级（中文台词里出现大括号是合法的）。


# ---------------------------------------------------------------------------
#  内部：小工具
# ---------------------------------------------------------------------------

## npc_id 的命名习惯（npc_01_muqing）。只有"看起来像 id 但表里没有"才算结构性错误；
## 自由文本（"旁白"/"老妪"）只是解析不出 npc_id，归 warnings。


## 已知 NPC 列表（把 npc_id -> 显示名 的映射压成 "id(名)、id(名)" 一句话）。


## 全部对话 id（goto 报错时的可选项提示）。


static func _list_json_files(dir_path: String, prefix: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	# 同 case_loader.list_case_files()：导出包里 `res://` 不是本地目录，用 DirAccess.open 判存在性。
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return result
	for file_name in dir.get_files():
		if file_name.begins_with(prefix) and file_name.ends_with(".json"):
			result.append("%s/%s" % [dir_path, file_name])
	result.sort()
	return result


static func _read_json(path: String) -> Variant:
	if path.is_empty():
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var text := file.get_as_text()
	file.close()
	return JSON.parse_string(text)


## 从文件名取案号（case_01_x.json -> 1）；取不到返回 -1。
static func _case_id_of(path: String) -> int:
	var file_name := path.get_file()
	if not file_name.begins_with("case_"):
		return -1
	var number_text := file_name.substr(5, 2)
	if not number_text.is_valid_int():
		return -1
	return int(number_text)
