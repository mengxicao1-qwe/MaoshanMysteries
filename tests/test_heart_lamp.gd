extends SceneTree
## ============================================================================
##  test_heart_lamp.gd —— 心灯 + 线索双档轮换落盘 测试（Headless，不需要打开编辑器）
## ----------------------------------------------------------------------------
##  运行方式（在项目根目录执行）：
##      godot --headless --path . --script res://tests/test_heart_lamp.gd
##
##  退出码：0 = 全部通过；1 = 存在失败项（可直接接入 CI）。
##  末行：唯一一行 `RESULT: OK ...` / `RESULT: FAIL ...`（与 tools/*.gd 的约定一致）。
##
##  覆盖范围（对应 task-2 的 5 条硬要求）：
##    ① 扣血数值：重开 3 次 = -24、余页内每秒 -0.02、结案 +25 且上限为 max；
##    ② tick 累计到归零会发出 heart_lamp_extinguished（且不会重复归零）；
##    ③ 归零后线索数 -1；被遗忘的线索在【心灯重新点亮之后】再次 add_clue 能重新获得；
##    ④ 落盘（.tmp → 主档轮换）后重新 load，线索一条不丢；
##    ⑤ 崩溃安全：残留 .tmp / 删除 .tmp / 主档损坏，都不会破坏已存在的主存档。
##    另加：没有注入记忆管理器时心灯依然安全（不崩、不重复吃记忆）。
##
##  2026-10 验收员问题 1/4/6/7/8/9/10/12/13/14/15 补的断言：
##    ⑥ 双档轮换与崩溃窗口恢复：主档缺失 + 完整 .tmp → 从 .tmp 恢复；主档损坏 + 合法 .bak
##       → 回退 .bak 且损坏档另存 user://clue_store.json.corrupt（问题 4：不再被下次 save 抹掉）；
##       正常 save() 后主档与 .bak 同时存在、主档是最新内容（问题 1/12）；
##    ⑦ 心灯数值跨"重启"保留（问题 7/13）：62 → 落盘 → 新实例 restore_from_store() → 62；
##    ⑧ 熄灯期间遗忘是永久的（问题 8/14）：add_clue 返回 false、黑名单不解除；
##       重新点亮之后再查获才成功；
##    ⑨ 熄灯期间每重开一遍再划掉一笔（问题 9/15），丢到空之后只警告不报错。
##
##  关于 ⑤ 里的 "quit(1)"：
##    测试进程自己不能真的 quit(1) —— 那会让整个套件无法给出 RESULT 行。
##    所以这里用【崩溃现场回放】来等价验证：先在主档完好的前提下往
##    user://clue_store.json.tmp 写一份截断的 JSON（= 写到一半进程被杀），
##    再断言主档逐字节不变、load_clues() 完好，最后删除残留 tmp 再断言一次。
##    这正是"下一次启动"看到的现场。
##
##  测试隔离：开始前把可能存在的真实存档（主档 + .tmp + .bak + .corrupt）备份到内存，
##  结束时先清空四种文件再逐字节还原，不留任何残留文件。
##  说明：这里直接 load() 脚本并 new() 出实例，不依赖 Autoload，因此确定性、CI 友好。
## ============================================================================


const HeartLamp = preload("res://scripts/entities/heart_lamp.gd")
const ClueStore = preload("res://scripts/data/clue_store.gd")
const MEMORY_SCRIPT: String = "res://scripts/core/persistent_memory_manager.gd"

## 本文件里 _check() 的调用点总数（新增断言时请同步更新）。
## 用于防止"测试中途因运行时错误中断，却因为没人断言失败而报绿"的假通过：
## GDScript 的运行时错误不会让退出码变红，只能靠执行数量来兜底。
const EXPECTED_CHECKS: int = 173

var _passed: int = 0
var _failed: int = 0

## 测试期间 new() 出来的 Node，结束时统一 free()，避免退出时报泄漏告警。
var _instances: Array = []

## 信号探针（GDScript 的 lambda 按值捕获局部变量，回调要写回的状态一律放成员变量）。
var _changed_log: Array = []
var _extinguished_log: Array[String] = []

## 测试会碰到的四种存档文件（备份 / 还原 / 残留检查都按这张表来）。
const STORE_FILES: Array[String] = [
	"user://clue_store.json",
	"user://clue_store.json.tmp",
	"user://clue_store.json.bak",
	"user://clue_store.json.corrupt",
]

## 真实存档的备份（路径 → 原始字节；测试结束后逐字节还原，不留任何残留文件）。
var _backup_bytes: Dictionary = {}


func _initialize() -> void:
	print("==========================================================")
	print(" 心灯（heart_lamp）与线索原子落盘（clue_store）测试")
	print("==========================================================")

	_backup_existing_store()

	_test_drain_numbers()
	_test_extinguish_loses_clue()
	_test_atomic_save_and_reload()
	_test_forgotten_persists_across_reload()
	_test_crash_safety()
	_test_corrupt_store_is_safe()
	_test_lamp_without_memory()
	_test_rotation_and_recovery()
	_test_lamp_value_persists()
	_test_extinguished_burns_extra_clue()
	_test_offline_recovery()

	# 收尾先还原存档，再断言"没有留下任何测试残渣"（问题 16：测试不留残留文件）。
	_restore_backup()
	_check(_store_matches_backup(), "测试收尾：存档已还原、无残留（现存 %s）" % str(_existing_store_files()))

	var executed: int = _passed + _failed
	if executed < EXPECTED_CHECKS:
		_failed += 1
		printerr("  [FAIL] 只执行了 %d 项断言，少于预期的 %d 项 —— 测试很可能在中途被运行时错误中断了！"
			% [executed, EXPECTED_CHECKS])

	print("----------------------------------------------------------")
	print("结果：通过 %d 项 / 失败 %d 项（共 %d 项）" % [_passed, _failed, executed])

	_cleanup()
	if _failed > 0:
		print("RESULT: FAIL 心灯/落盘 有 %d 项断言不通过（共 %d 项）" % [_failed, executed])
		quit(1)
	else:
		print("RESULT: OK 心灯/落盘 %d 项断言全部通过（重开-8、每秒-0.02、结案+25、离线每分钟+1、归零丢一条记忆、双档轮换不丢档）"
			% _passed)
		quit(0)


# ---------------------------------------------------------------------------
# ① 数值
# ---------------------------------------------------------------------------

func _test_drain_numbers() -> void:
	print("[1] 心灯数值：重开 -8 / 余页内每秒 -0.02 / 结案 +25（上限 max）")
	ClueStore.erase_store()
	var memory = _new_memory()
	var lamp = _new_lamp(memory)

	_check(lamp.get_value() == 100, "初始值 = 100，实际 %d" % lamp.get_value())
	_check(lamp.get_max_value() == 100, "默认上限 max_value = 100，实际 %d" % lamp.get_max_value())
	_check(not lamp.is_extinguished(), "初始不是熄灭状态")

	_changed_log.clear()
	lamp.reset_for_new_loop()
	_check(lamp.get_value() == 92, "重开 1 次后 = 92，实际 %d" % lamp.get_value())
	lamp.reset_for_new_loop()
	_check(lamp.get_value() == 84, "重开 2 次后 = 84，实际 %d" % lamp.get_value())
	lamp.reset_for_new_loop()
	_check(lamp.get_value() == 76, "重开 3 次后 = 76（100 - 3×8 = -24），实际 %d" % lamp.get_value())
	_check(_changed_log.size() == 3, "每扣一点广播一次 heart_lamp_changed，实际 %d 次" % _changed_log.size())
	_check(_changed_log.size() == 3 and _changed_log[2][0] == 76 and _changed_log[2][1] == 100,
		"最后一次广播的载荷是 (76, 100)")

	lamp.set_value(100)
	lamp.tick(55.0)
	_check(lamp.get_value() == 99, "余页内 55 秒 = -1 点（0.02×55，攒满即扣），实际 %d" % lamp.get_value())
	lamp.tick(40.0)
	_check(lamp.get_value() == 99, "未攒满 1 点的 40 秒不扣（浮点累积），实际 %d" % lamp.get_value())
	lamp.tick(10.0)
	_check(lamp.get_value() == 98, "再攒满 1 点 → 98，实际 %d" % lamp.get_value())
	lamp.set_in_loop(false)
	lamp.tick(1000.0)
	_check(lamp.get_value() == 98, "余页之外 tick 不消耗，实际 %d" % lamp.get_value())
	lamp.set_in_loop(true)

	lamp.set_value(50)
	lamp.resolve_case()
	_check(lamp.get_value() == 75, "结案 +25：50 → 75，实际 %d" % lamp.get_value())
	lamp.set_value(90)
	lamp.resolve_case()
	_check(lamp.get_value() == 100, "结案不会超过 max_value（90+25 → 100），实际 %d" % lamp.get_value())
	lamp.restore(999)
	_check(lamp.get_value() == 100, "已满时 restore() 不会溢出，实际 %d" % lamp.get_value())
	lamp.drain(0)
	lamp.drain(-5)
	lamp.restore(-5)
	_check(lamp.get_value() == 100, "drain(0)/drain(-5)/restore(-5) 都是空操作，实际 %d" % lamp.get_value())


# ---------------------------------------------------------------------------
# ②③ 归零 = 永久丢失一条线索的记忆（不是死亡）
# ---------------------------------------------------------------------------

func _test_extinguish_loses_clue() -> void:
	print("[2] 心灯归零：丢一条记忆 + 广播信号 + 可重新查获")
	ClueStore.erase_store()
	var memory = _new_memory()
	var lamp = _new_lamp(memory)

	_check(lamp.add_clue("clue_a", 0), "add_clue(clue_a) 新获得")
	_check(lamp.add_clue("clue_b", 0), "add_clue(clue_b) 新获得")
	_check(lamp.add_clue("clue_c", 2), "add_clue(clue_c) 新获得")
	_check(not lamp.add_clue("clue_a", 0), "重复 add_clue 幂等（返回 false）")
	_check(memory.get_clue_count() == 3, "记忆里有 3 条线索，实际 %d" % memory.get_clue_count())

	_extinguished_log.clear()
	_changed_log.clear()
	lamp.set_value(5)
	lamp.tick(260.0)
	_check(lamp.get_value() == 0, "余页内 260 秒（-5.2 点）后归零，实际 %d" % lamp.get_value())
	_check(lamp.is_extinguished(), "is_extinguished() 为真")
	_check(_changed_log.size() == 2 and _changed_log[1][0] == 0 and _changed_log[1][1] == 100,
		"归零也广播了 heart_lamp_changed(0, 100)")
	_check(_extinguished_log.size() == 1, "归零广播 1 次 heart_lamp_extinguished，实际 %d 次" % _extinguished_log.size())
	_check(_extinguished_log.size() == 1 and _extinguished_log[0] == "clue_c",
		"丢的是'最后一次获得'的 clue_c，实际 %s" % str(_extinguished_log))
	_check(memory.get_clue_count() == 2, "记忆里的线索数 -1（3 → 2），实际 %d" % memory.get_clue_count())
	_check(not memory.has_clue("clue_c"), "clue_c 已从 PersistentMemoryManager 的记忆中移除")
	_check(ClueStore.is_forgotten("clue_c"), "clue_c 已记入'已遗忘'黑名单")
	_check(lamp.get_available_clues().size() == 2, "可用于推理的线索 2 条，实际 %d" % lamp.get_available_clues().size())
	_check(not lamp.get_available_clues().has("clue_c"), "clue_c 不可再用于推理")

	# 已经归零时继续 tick：不能再重复归零、也不能继续吃记忆。
	lamp.tick(500.0)
	_check(_extinguished_log.size() == 1, "心灯已归零后继续 tick 不重复归零，实际 %d 次" % _extinguished_log.size())
	_check(memory.get_clue_count() == 2, "心灯已归零后继续 tick 不再吃记忆，实际 %d 条" % memory.get_clue_count())

	# 熄灯期间遗忘是永久的（问题 8/14）：重新查获被拒绝，黑名单也不会被解除。
	_check(not lamp.add_clue("clue_c", 3), "心灯已熄时重新查获 clue_c 被拒绝（返回 false）")
	_check(ClueStore.is_forgotten("clue_c"), "熄灯期间 clue_c 仍在黑名单里（没有被解除遗忘）")
	_check(not memory.has_clue("clue_c"), "熄灯期间 clue_c 没有回到记忆")
	_check(memory.get_clue_count() == 2, "熄灯期间线索数仍是 2，实际 %d" % memory.get_clue_count())

	# 归零不是死亡：结案/恢复后重新点亮；重新点亮【之后】查获才解除遗忘。
	lamp.resolve_case()
	_check(lamp.get_value() == 25, "归零后结案恢复到 25，实际 %d" % lamp.get_value())
	_check(not lamp.is_extinguished(), "恢复后不再是熄灭状态（归零 ≠ 死亡）")
	_check(lamp.get_extinguish_count() == 1, "累计被划掉 1 笔，实际 %d" % lamp.get_extinguish_count())

	_check(lamp.add_clue("clue_c", 3), "重新点亮之后重新查获 clue_c 返回 true（解除遗忘）")
	_check(not ClueStore.is_forgotten("clue_c"), "clue_c 已从黑名单移除")
	_check(memory.has_clue("clue_c"), "clue_c 重新回到记忆")
	_check(memory.get_clue_count() == 3, "线索数回到 3，实际 %d" % memory.get_clue_count())
	_check(lamp.get_available_clues().has("clue_c"), "clue_c 重新可用于推理")

	_extinguished_log.clear()
	lamp.set_value(2)
	lamp.drain(2)
	_check(lamp.get_value() == 0 and _extinguished_log.size() == 1, "第二次归零会再次广播并再丢一条记忆")
	_check(lamp.get_extinguish_count() == 2, "累计被划掉 2 笔，实际 %d" % lamp.get_extinguish_count())
	_check(memory.get_clue_count() == 2, "第二次归零后记忆剩 2 条，实际 %d" % memory.get_clue_count())


# ---------------------------------------------------------------------------
# ④ 原子落盘 + 重新 load
# ---------------------------------------------------------------------------

func _test_atomic_save_and_reload() -> void:
	print("[3] 原子落盘 + 重新 load：线索一条不丢")
	_check(ClueStore.erase_store(), "清空测试存档")
	_check(not FileAccess.file_exists(ClueStore.SAVE_PATH), "起始状态：主存档不存在")
	_check(not FileAccess.file_exists(ClueStore.TMP_PATH), "起始状态：没有残留临时文件")

	var memory = _new_memory()
	var lamp = _new_lamp(memory)
	lamp.add_clue("clue_letter", 1)
	lamp.add_clue("clue_knife", 1)

	_check(FileAccess.file_exists(ClueStore.SAVE_PATH), "add_clue 之后主存档已生成")
	_check(not FileAccess.file_exists(ClueStore.TMP_PATH), "落盘后没有残留 .tmp（已被 rename 掉）")

	var reloaded: Array[String] = ClueStore.load_clues()
	_check(_same_strings(reloaded, ["clue_letter", "clue_knife"]),
		"重新 load 内容与顺序一致：%s" % str(reloaded))

	var memory2 = _new_memory()
	var lamp2 = _new_lamp(memory2)
	_check(lamp2.restore_from_store() == 2, "新记忆管理器从存档恢复 2 条线索")
	_check(memory2.has_clue("clue_letter") and memory2.has_clue("clue_knife"), "两条线索都在新记忆里")

	# 只追加不重写整表：旧线索绝不能被覆盖掉。
	_check(ClueStore.save(["clue_rope"]), "追加保存 clue_rope 成功")
	var grown: Array[String] = ClueStore.load_clues()
	_check(_same_strings(grown, ["clue_letter", "clue_knife", "clue_rope"]),
		"追加后旧线索没被覆盖：%s" % str(grown))
	_check(ClueStore.save([123, "", "clue_letter"]), "非法项/重复项不会让落盘失败")
	var stable: Array[String] = ClueStore.load_clues()
	_check(_same_strings(stable, ["clue_letter", "clue_knife", "clue_rope"]),
		"非法项被忽略，表仍是 3 条：%s" % str(stable))

	var text: String = _read_text(ClueStore.SAVE_PATH)
	var json: JSON = JSON.new()
	_check(json.parse(text) == OK, "主存档是合法 JSON")
	var parsed: Variant = json.data
	_check(typeof(parsed) == TYPE_DICTIONARY and parsed.get("version") == 2,
		"存档带 version=2（JSON 数字是 float，比较仍然成立）")


# ---------------------------------------------------------------------------
# ④b "已遗忘"跨启动保留
# ---------------------------------------------------------------------------

func _test_forgotten_persists_across_reload() -> void:
	print("[4] '已遗忘'黑名单跨启动保留（线索 = 记忆，丢档 = 玩家记忆全灭）")
	ClueStore.save(["clue_seal"])

	var memory = _new_memory()
	var lamp = _new_lamp(memory)
	_check(lamp.restore_from_store() == 4, "从存档恢复 4 条线索，实际 %d" % memory.get_clue_count())
	lamp.set_value(1)
	lamp.drain(1)
	_check(lamp.is_extinguished(), "心灯归零")
	_check(ClueStore.is_forgotten("clue_seal"), "最后获得的 clue_seal 被记入黑名单")

	var after: Array[String] = ClueStore.load_clues()
	_check(_same_strings(after, ["clue_letter", "clue_knife", "clue_rope"]),
		"load_clues() 不再交还已遗忘的 clue_seal：%s" % str(after))
	_check(ClueStore.load_forgotten().has("clue_seal"), "load_forgotten() 里有 clue_seal")

	# 模拟"重启游戏"：全新的记忆管理器 + 从同一份存档恢复。
	var memory2 = _new_memory()
	var lamp2 = _new_lamp(memory2)
	lamp2.restore_from_store()
	_check(memory2.get_clue_count() == 3, "重启后记忆里 3 条，实际 %d" % memory2.get_clue_count())
	_check(not memory2.has_clue("clue_seal"), "被遗忘的 clue_seal 不会在重启后复活")
	_check(lamp2.get_forgotten_clues().has("clue_seal"), "重启后黑名单里仍有 clue_seal（UI 可以画灰）")


# ---------------------------------------------------------------------------
# ⑤ 崩溃安全
# ---------------------------------------------------------------------------

func _test_crash_safety() -> void:
	print("[5] 崩溃安全：残留 .tmp / 删除 .tmp 都不破坏已存在的主存档")
	var before: String = _read_text(ClueStore.SAVE_PATH)
	_check(not before.is_empty(), "主存档已有内容（%d 字符）" % before.length())

	# 崩溃现场：tmp 里留一份截断的 JSON（rename 从未发生）。
	_write_text(ClueStore.TMP_PATH, "{\n\t\"version\": 1,\n\t\"clues\": [\"clue_let")
	_check(FileAccess.file_exists(ClueStore.TMP_PATH), "残留临时文件已写入（模拟写到一半被 quit/断电）")
	_check(_read_text(ClueStore.SAVE_PATH) == before, "主存档逐字节未被破坏")
	_check(_same_strings(ClueStore.load_clues(), ["clue_letter", "clue_knife", "clue_rope"]),
		"残留 .tmp 不参与读取，主档线索完好")

	# 崩溃现场之后仍然能正常落盘。
	_check(ClueStore.save(["clue_new"]), "崩溃现场之后仍能正常原子落盘")
	_check(not FileAccess.file_exists(ClueStore.TMP_PATH), "成功落盘后临时文件已被 rename 走")
	_check(_same_strings(ClueStore.load_clues(), ["clue_letter", "clue_knife", "clue_rope", "clue_new"]),
		"落盘后表变成 4 条")

	# 下次启动清理残留 tmp（等价于 quit 之后人工删除）：主档依然完好。
	var before_clean: String = _read_text(ClueStore.SAVE_PATH)
	_write_text(ClueStore.TMP_PATH, "garbage 垃圾数据")
	var removed: Error = DirAccess.remove_absolute(ProjectSettings.globalize_path(ClueStore.TMP_PATH))
	_check(removed == OK and not FileAccess.file_exists(ClueStore.TMP_PATH), "残留临时文件被删除")
	_check(_read_text(ClueStore.SAVE_PATH) == before_clean, "删除 .tmp 后主存档逐字节不变")
	_check(_same_strings(ClueStore.load_clues(), ["clue_letter", "clue_knife", "clue_rope", "clue_new"]),
		"删除 .tmp 后主档仍能完整读出 4 条线索")


# ---------------------------------------------------------------------------
# 损坏 / 缺失存档
# ---------------------------------------------------------------------------

func _test_corrupt_store_is_safe() -> void:
	print("[6] load_clues() 对缺失/空/损坏存档：只警告，不崩，不交还垃圾数据")
	ClueStore.erase_store()
	var missing: Array[String] = ClueStore.load_clues()
	_check(missing.is_empty() and typeof(missing) == TYPE_ARRAY, "文件不存在 → 空数组")

	_write_text(ClueStore.SAVE_PATH, "")
	_check(ClueStore.load_clues().is_empty(), "空文件 → 空数组")

	_write_text(ClueStore.SAVE_PATH, "{ 这不是 JSON")
	_check(ClueStore.load_clues().is_empty(), "损坏 JSON → 空数组（不崩溃）")
	_check(not ClueStore.is_forgotten("clue_x"), "损坏存档时 is_forgotten() 安全返回 false")
	_check(ClueStore.load_forgotten().is_empty(), "损坏存档时 load_forgotten() 返回空数组")

	_write_text(ClueStore.SAVE_PATH, "[1, 2, 3]")
	_check(ClueStore.load_clues().is_empty(), "顶层是数组而不是对象 → 空数组")

	# 坏档之上重新落盘：_read_raw() 已把它当空存档，于是重建出一份干净存档。
	_check(ClueStore.save(["clue_recover"]), "坏档之上仍能重新落盘（不会被坏档卡死）")
	_check(_same_strings(ClueStore.load_clues(), ["clue_recover"]), "重写后存档干净可用")

	_write_text(ClueStore.SAVE_PATH, "{\"clues\": [1, \"clue_ok\", null, \"clue_ok\", \"\"], \"forgotten\": [\"clue_ok\"]}")
	_check(ClueStore.load_clues().is_empty(), "非字符串/重复/空串被过滤，且黑名单生效 → 空数组")

	_write_text(ClueStore.SAVE_PATH, "{\"clues\": [1, \"clue_ok\", null, \"clue_dup\", \"clue_dup\"]}")
	var cleaned: Array[String] = ClueStore.load_clues()
	_check(_same_strings(cleaned, ["clue_ok", "clue_dup"]), "非法项被过滤、重复被去重：%s" % str(cleaned))
	_check(ClueStore.save(["clue_extra"]) and _same_strings(ClueStore.load_clues(), ["clue_ok", "clue_dup", "clue_extra"]),
		"即使原档是手工改过的，save() 也只追加、不吞掉既有线索")


# ---------------------------------------------------------------------------
# 没有记忆管理器也要安全
# ---------------------------------------------------------------------------

func _test_lamp_without_memory() -> void:
	print("[7] 未注入记忆管理器时心灯依然安全（不崩、不重复归零）")
	ClueStore.erase_store()
	var lamp = _new_lamp(null)
	_extinguished_log.clear()

	_check(lamp.add_clue("clue_orphan"), "没有记忆管理器时 add_clue 仍把线索落盘")
	_check(_same_strings(ClueStore.load_clues(), ["clue_orphan"]), "线索确实写进了存档")
	_check(lamp.get_available_clues().is_empty(), "没有记忆管理器时可用线索为空")

	lamp.set_value(3)
	lamp.drain(3)
	_check(lamp.is_extinguished(), "无线索可丢时心灯依然会熄（归零不是死亡）")
	_check(_extinguished_log.size() == 1 and _extinguished_log[0] == "",
		"广播了空 lost_clue_id（记忆为空，没东西可划掉）")
	_check(lamp.get_available_clues().is_empty(), "归零后依然安全，没有崩")


# ---------------------------------------------------------------------------
# ⑧ 双档轮换 + 崩溃窗口恢复（2026-10 验收员问题 1 / 4 / 12）
# ---------------------------------------------------------------------------

func _test_rotation_and_recovery() -> void:
	print("[8] 双档轮换：崩溃窗口可恢复、轮换后主档最新、损坏档另存 .corrupt")
	ClueStore.erase_store()

	# ③ 正常 save() 之后：主档与 .bak 同时存在，且主档是最新内容。
	_check(ClueStore.save(["clue_one"]), "第一次落盘成功（此时还没有 .bak）")
	_check(not FileAccess.file_exists(ClueStore.BAK_PATH), "第一次落盘没有 .bak（没有上一份可轮换）")
	_check(ClueStore.save(["clue_two"]), "第二次落盘成功（主档 → .bak 轮换）")
	_check(FileAccess.file_exists(ClueStore.SAVE_PATH) and FileAccess.file_exists(ClueStore.BAK_PATH),
		"第二次落盘后主档与 .bak 同时存在")
	_check(_same_strings(_clues_in_file(ClueStore.SAVE_PATH), ["clue_one", "clue_two"]),
		"主档是最新内容（2 条），实际 %s" % str(_clues_in_file(ClueStore.SAVE_PATH)))
	_check(_same_strings(_clues_in_file(ClueStore.BAK_PATH), ["clue_one"]),
		".bak 是上一份内容（1 条），实际 %s" % str(_clues_in_file(ClueStore.BAK_PATH)))

	# ① 崩溃窗口：主档"还没被 rename 过来"（主档缺失）+ .tmp 里是完整的新数据。
	_check(_write_clues_file(ClueStore.TMP_PATH, ["clue_one", "clue_two", "clue_tmp"]),
		"手工造出崩溃现场：.tmp 里是完整的新数据")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(ClueStore.SAVE_PATH))
	_check(not FileAccess.file_exists(ClueStore.SAVE_PATH), "主档已删除（模拟 remove 与 MoveFile 之间掉电）")
	_check(_same_strings(ClueStore.load_clues(), ["clue_one", "clue_two", "clue_tmp"]),
		"load_clues() 从 .tmp 恢复出最新数据（整档没有丢失）：%s" % str(ClueStore.load_clues()))

	# ② 主档损坏 + 合法 .bak → 回退 .bak，且损坏档另存 .corrupt。
	ClueStore.erase_store()
	_write_clues_file(ClueStore.BAK_PATH, ["clue_bak_a", "clue_bak_b"])
	_write_text(ClueStore.SAVE_PATH, "{ 这不是 JSON")
	_check(not FileAccess.file_exists(ClueStore.CORRUPT_PATH), "起始状态：没有 .corrupt")
	var recovered: Array[String] = ClueStore.load_clues()
	_check(_same_strings(recovered, ["clue_bak_a", "clue_bak_b"]), "主档损坏 → 回退 .bak：%s" % str(recovered))
	_check(FileAccess.file_exists(ClueStore.CORRUPT_PATH), "损坏的主档已另存 .corrupt（不会被下一次 save 抹掉）")
	_check(_read_text(ClueStore.CORRUPT_PATH) == "{ 这不是 JSON", ".corrupt 逐字节等于损坏的主档")

	# 结构非法（顶层不是对象）同样算"主档不可用" → 回退 .bak。
	_write_text(ClueStore.SAVE_PATH, "[1, 2, 3]")
	_check(_same_strings(ClueStore.load_clues(), ["clue_bak_a", "clue_bak_b"]), "顶层不是对象也回退 .bak")

	# 版本号高于本程序（玩家降级运行）也算不可用 → 回退 .bak，认不出来的新档不会被当成空档。
	_write_text(ClueStore.SAVE_PATH, "{\"version\": 99, \"clues\": [\"clue_future\"]}")
	_check(_same_strings(ClueStore.load_clues(), ["clue_bak_a", "clue_bak_b"]), "版本号过高也回退 .bak")

	# ④ 损坏档不会被下一次 save() 销毁：.corrupt 里留着一份备查。
	_check(ClueStore.save(["clue_after_recover"]), "坏档之上仍能正常落盘")
	_check(FileAccess.file_exists(ClueStore.CORRUPT_PATH)
		and _read_text(ClueStore.CORRUPT_PATH).begins_with("{\"version\": 99"),
		"下一次 save() 之后 .corrupt 仍在（问题 4：损坏档不再被抹掉）")
	_check(_same_strings(ClueStore.load_clues(), ["clue_bak_a", "clue_bak_b", "clue_after_recover"]),
		"恢复后重写的表 = .bak 内容 + 新线索：%s" % str(ClueStore.load_clues()))

	# 三者都不可用：返回空表，不崩，损坏档照样留一份。
	ClueStore.erase_store()
	_write_text(ClueStore.SAVE_PATH, "坏")
	_write_text(ClueStore.TMP_PATH, "也坏")
	_write_text(ClueStore.BAK_PATH, "还坏")
	_check(ClueStore.load_clues().is_empty(), "主档 / .tmp / .bak 全不可用 → 空表（不崩）")
	_check(FileAccess.file_exists(ClueStore.CORRUPT_PATH), "全不可用时损坏档同样留了 .corrupt 备查")

	# erase_store() 连 .corrupt 一起删（开新档不留残渣）。
	_check(ClueStore.erase_store(), "erase_store() 清理四种存档文件")
	_check(not FileAccess.file_exists(ClueStore.CORRUPT_PATH), "erase_store() 也删掉了 .corrupt")


# ---------------------------------------------------------------------------
# ⑨ 心灯数值跨重启保留（2026-10 验收员问题 7 / 13）
# ---------------------------------------------------------------------------

func _test_lamp_value_persists() -> void:
	print("[9] 心灯数值落盘：跨重启保留（不再白回 100）")
	ClueStore.erase_store()
	var memory = _new_memory()
	var lamp = _new_lamp(memory)

	_check(lamp.add_clue("clue_lamp_a", 1), "先拿到一条线索")
	lamp.set_value(62)
	_check(lamp.get_value() == 62, "心灯设为 62，实际 %d" % lamp.get_value())
	_check(ClueStore.load_lamp_value() == 62,
		"数值已落盘（load_lamp_value() = 62），实际 %d" % ClueStore.load_lamp_value())

	# 模拟"退出重进"：全新心灯 + 全新记忆管理器，从同一份存档恢复。
	var memory2 = _new_memory()
	var lamp2 = _new_lamp(memory2)
	var restored: int = lamp2.restore_from_store()
	_check(restored == 1, "重启后从存档恢复 1 条线索，实际 %d" % restored)
	_check(lamp2.get_value() == 62, "重启后心灯数值仍是 62（问题 7），实际 %d" % lamp2.get_value())
	_check(not lamp2.is_extinguished(), "重启后不是熄灭状态")

	# 每一种数值变化都要落盘：重开 -8 / 结案 +25 / 每秒 -0.02 攒满 1 点。
	lamp2.reset_for_new_loop()
	_check(lamp2.get_value() == 54 and ClueStore.load_lamp_value() == 54,
		"重开后落盘值同步（62-8=54），心灯 %d / 存档 %d" % [lamp2.get_value(), ClueStore.load_lamp_value()])
	lamp2.resolve_case()
	_check(lamp2.get_value() == 79 and ClueStore.load_lamp_value() == 79,
		"结案后落盘值同步（54+25=79），心灯 %d / 存档 %d" % [lamp2.get_value(), ClueStore.load_lamp_value()])
	lamp2.tick(55.0)
	_check(lamp2.get_value() == 78 and ClueStore.load_lamp_value() == 78,
		"tick 攒满 1 点后落盘值同步（79-1=78），心灯 %d / 存档 %d" % [lamp2.get_value(), ClueStore.load_lamp_value()])

	# version 1 的旧档没有 lamp_value 键 → 读回默认 100，且旧线索照样能读、能追加。
	ClueStore.erase_store()
	_write_text(ClueStore.SAVE_PATH, "{\"version\": 1, \"clues\": [\"clue_old\"]}")
	_check(ClueStore.load_lamp_value() == 100,
		"version 1 旧档没有 lamp_value → 默认 100，实际 %d" % ClueStore.load_lamp_value())
	_check(_same_strings(ClueStore.load_clues(), ["clue_old"]), "version 1 旧档的线索照样读得出来")
	_check(ClueStore.save_lamp_value(41), "save_lamp_value() 落盘成功")
	_check(ClueStore.load_lamp_value() == 41 and _same_strings(ClueStore.load_clues(), ["clue_old"]),
		"写 lamp_value 不会弄丢旧档里的线索")

	# set_store_enabled(false)：完全不碰磁盘（测试/工具用），add_clue 只看"进了记忆没有"。
	var memory3 = _new_memory()
	var lamp3 = _new_lamp(memory3)
	lamp3.set_store_enabled(false)
	_check(not lamp3.is_store_enabled(), "落盘开关可以关掉")
	var before: Array[String] = ClueStore.load_clues()
	_check(lamp3.add_clue("clue_offline", 1), "关掉落盘后 add_clue 只看记忆（返回 true）")
	_check(_same_strings(ClueStore.load_clues(), before), "关掉落盘后磁盘内容一个字都没变")
	lamp3.set_value(70)
	_check(ClueStore.load_lamp_value() == 41, "关掉落盘后心灯数值也不写盘（仍是 41）")


# ---------------------------------------------------------------------------
# ⑩ 熄灯期间每一遍重开再划掉一笔（2026-10 验收员问题 9 / 15）
# ---------------------------------------------------------------------------

func _test_extinguished_burns_extra_clue() -> void:
	print("[10] 熄灯期间重开一遍：再丢一条记忆（故意烧灯不再是纯赚）")
	ClueStore.erase_store()
	var memory = _new_memory()
	var lamp = _new_lamp(memory)

	_check(lamp.add_clue("clue_p", 0) and lamp.add_clue("clue_q", 1) and lamp.add_clue("clue_r", 2),
		"先拿到 3 条线索")
	_check(memory.get_clue_count() == 3, "记忆里 3 条，实际 %d" % memory.get_clue_count())

	_extinguished_log.clear()
	lamp.set_value(4)
	lamp.drain(4)
	_check(lamp.is_extinguished() and _extinguished_log.size() == 1, "心灯烧灭：划掉最后获得的一条（clue_r）")
	_check(memory.get_clue_count() == 2, "熄灭后剩 2 条，实际 %d" % memory.get_clue_count())

	# 熄灯期间重开一遍：额外再划一笔 —— 这就是"故意烧灯"的代价。
	_extinguished_log.clear()
	lamp.reset_for_new_loop()
	_check(lamp.get_value() == 0, "熄灯后重开不会把心灯扣成负数，实际 %d" % lamp.get_value())
	_check(_extinguished_log.size() == 1 and _extinguished_log[0] == "clue_q",
		"熄灯期间重开一遍又划掉一条（clue_q），实际 %s" % str(_extinguished_log))
	_check(memory.get_clue_count() == 1, "记忆剩 1 条，实际 %d" % memory.get_clue_count())
	_check(ClueStore.is_forgotten("clue_q") and ClueStore.is_forgotten("clue_r"), "两条都在黑名单里")

	lamp.reset_for_new_loop()
	_check(memory.get_clue_count() == 0, "再重开一遍：最后一条也被划掉，实际 %d" % memory.get_clue_count())
	_check(lamp.get_extinguish_count() == 1, "额外划掉的是记忆，不增加'归零次数'，实际 %d" % lamp.get_extinguish_count())

	# 已经没得可失时：只警告、不报错、不重复广播。
	_extinguished_log.clear()
	lamp.reset_for_new_loop()
	_check(_extinguished_log.size() == 0,
		"记忆已空时重开不再广播 heart_lamp_extinguished，实际 %d 次" % _extinguished_log.size())
	_check(lamp.is_extinguished() and memory.get_clue_count() == 0, "依然安全：心灯仍熄着，记忆仍为空")

	# 点亮之后：重开只扣 8 点，不再额外划记忆。
	lamp.restore(20)
	_check(lamp.get_value() == 20 and not lamp.is_extinguished(), "restore(20) 重新点亮，实际 %d" % lamp.get_value())
	_check(lamp.add_clue("clue_s", 4), "点亮之后重新查获 clue_s 正常进记忆")
	lamp.reset_for_new_loop()
	_check(memory.get_clue_count() == 1, "点亮期间重开不再划记忆，实际 %d 条" % memory.get_clue_count())
	_check(lamp.get_value() == 12, "点亮期间重开照常 -8（20 → 12），实际 %d" % lamp.get_value())


# ---------------------------------------------------------------------------
# ⑪ 离线现实时间恢复（docs/story/09:175「现实时间（余页之外）按分钟 +1」）
# ---------------------------------------------------------------------------

func _test_offline_recovery() -> void:
	print("[11] 离线现实时间恢复：余页之外每分钟 +1（案一要走到第 8 遍，没有它数值上通不了关）")
	ClueStore.erase_store()
	var lamp = _new_lamp(_new_memory())

	# 全新存档：从来没有落过盘 ⇒ seen_unix = 0 ⇒ 不补点（否则新玩家一开局就白拿）。
	var fresh: Dictionary = ClueStore.load_lamp_state()
	_check(int(fresh["seen_unix"]) == 0,
		"新档没有时间戳（seen_unix=0），实际 %d" % int(fresh["seen_unix"]))
	_check(lamp.apply_offline_recovery(1000000) == 0, "没有时间戳时不补点")
	_check(lamp.get_value() == 100 and lamp.get_last_offline_recovery() == 0,
		"没有时间戳时心灯保持 100，实际 %d" % lamp.get_value())

	# 伪造"半小时前落过盘"，重启后应当补 30 点。
	var now: int = int(Time.get_unix_time_from_system())
	_check(ClueStore.save_lamp_state(50, now - 1800), "伪造一份 30 分钟前的存档（数值 50）")
	var lamp2 = _new_lamp(_new_memory())
	lamp2.restore_from_store()
	_check(lamp2.get_value() == 50, "重启后心灯数值仍是 50，实际 %d" % lamp2.get_value())
	var gained: int = lamp2.apply_offline_recovery(now)
	_check(gained == 30, "离线 30 分钟回 30 点，实际 %d" % gained)
	_check(lamp2.get_value() == 80, "心灯 50 → 80，实际 %d" % lamp2.get_value())
	_check(lamp2.get_last_offline_recovery() == 30, "get_last_offline_recovery() 记下本次补点")
	_check(lamp2.apply_offline_recovery(now) == 0, "紧接着再调不再补点（时间戳已被刷新）")

	# 不足 1 分钟不补；时间倒流不补。
	_check(ClueStore.save_lamp_state(80, now), "把时间戳刷成现在（数值 80）")
	var lamp3 = _new_lamp(_new_memory())
	lamp3.restore_from_store()
	_check(lamp3.apply_offline_recovery(now + 59) == 0, "离线 59 秒不补点")
	_check(lamp3.get_value() == 80, "不足 1 分钟时数值不变，实际 %d" % lamp3.get_value())
	_check(lamp3.apply_offline_recovery(now - 600) == 0, "时间倒流（now < seen_unix）不补点")
	_check(lamp3.get_value() == 80, "时间倒流时数值也不变，实际 %d" % lamp3.get_value())

	# 熄灯着离线回来：恢复即重新点亮（否则玩家只能靠结案自救，形成死锁）。
	ClueStore.erase_store()
	var memory4 = _new_memory()
	var lamp4 = _new_lamp(memory4)
	_check(lamp4.add_clue("clue_off_a", 0), "先拿到一条线索")
	lamp4.set_value(2, false)
	lamp4.drain(2)
	_check(lamp4.is_extinguished(), "心灯烧灭，实际 %d" % lamp4.get_value())
	_check(ClueStore.save_lamp_state(0, now - 1200), "伪造一份 20 分钟前的熄灯存档")
	var lamp5 = _new_lamp(_new_memory())
	lamp5.restore_from_store()
	_check(lamp5.is_extinguished(), "重启后仍是熄灭状态（不会白丢第二条记忆）")
	_check(lamp5.apply_offline_recovery(now) == 20, "离线 20 分钟回 20 点")
	_check(not lamp5.is_extinguished(), "恢复即重新点亮，实际 %d" % lamp5.get_value())


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

## 按 ClueStore 的 JSON 结构手工写一份存档（造崩溃现场 / 造损坏档用）。
func _write_clues_file(path: String, clues: Array) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  [FAIL] 测试无法写入 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(
		{"version": 2, "clues": clues, "forgotten": [], "lamp_value": 100}, "\t"))
	file.flush()
	file.close()
	return true


## 直接读一份存档文件里的 clues（不走 ClueStore 的恢复逻辑，用于断言"哪个文件是第几版"）。
func _clues_in_file(path: String) -> Array[String]:
	var out: Array[String] = []
	var text: String = _read_text(path)
	if text.strip_edges().is_empty():
		return out
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return out
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return out
	var data: Dictionary = parsed
	var raw: Variant = data.get("clues")
	if typeof(raw) != TYPE_ARRAY:
		return out
	var list: Array = raw
	for item in list:
		if typeof(item) == TYPE_STRING:
			out.append(item)
	return out


## 当前实际存在的存档文件（"不留残留文件"的收尾断言用）。
func _existing_store_files() -> Array[String]:
	var found: Array[String] = []
	for path: String in STORE_FILES:
		if FileAccess.file_exists(path):
			found.append(path)
	return found


func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var bytes: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	return bytes


## 收尾断言：磁盘上的存档文件与测试前【完全一致】（存在性 + 逐字节）。
func _store_matches_backup() -> bool:
	var found: Array[String] = _existing_store_files()
	if found.size() != _backup_bytes.size():
		return false
	for path: String in found:
		if not _backup_bytes.has(path):
			return false
		var expected: PackedByteArray = _backup_bytes[path]
		if _read_bytes(path) != expected:
			return false
	return true


func _new_memory() -> Node:
	var script: GDScript = load(MEMORY_SCRIPT)
	var instance: Node = script.new()
	instance.name = "PMM_UnderTest"
	_instances.append(instance)
	return instance


## 造一个心灯并接上信号探针。返回值故意不标注类型，方便动态调用（无 class_name）。
func _new_lamp(memory: Node):
	var lamp = HeartLamp.new()
	lamp.auto_subscribe = false
	lamp.name = "HeartLamp_UnderTest"
	lamp.set_memory_manager(memory)
	lamp.connect("heart_lamp_changed", _on_lamp_changed)
	lamp.connect("heart_lamp_extinguished", _on_lamp_extinguished)
	_instances.append(lamp)
	return lamp


func _on_lamp_changed(value: int, max_value: int) -> void:
	_changed_log.append([value, max_value])


func _on_lamp_extinguished(lost_clue_id: String) -> void:
	_extinguished_log.append(lost_clue_id)


func _same_strings(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for i in actual.size():
		if typeof(actual[i]) != TYPE_STRING or typeof(expected[i]) != TYPE_STRING:
			return false
		if String(actual[i]) != String(expected[i]):
			return false
	return true


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _write_text(path: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("  [FAIL] 测试无法写入 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return
	file.store_string(text)
	file.flush()
	file.close()


## 备份可能存在的真实存档（主档 + .tmp + .bak + .corrupt 四种），测试结束后原样还原。
## 不存在的文件不会被凭空造出来（还原时以"测试前的存在性"为准）。
func _backup_existing_store() -> void:
	_backup_bytes.clear()
	for path: String in STORE_FILES:
		if not FileAccess.file_exists(path):
			continue
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		_backup_bytes[path] = file.get_buffer(file.get_length())
		file.close()


func _restore_backup() -> void:
	# 先清空四种文件（测试过程里可能造出原本不存在的 .tmp/.bak/.corrupt），再按字节还原。
	ClueStore.erase_store()
	for path: String in _backup_bytes.keys():
		var bytes: PackedByteArray = _backup_bytes[path]
		# 字节级还原（存档本来就是 UTF-8 文本，但绝不做任何编码转换）。
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			printerr("  [FAIL] 无法还原测试前的存档备份 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
			continue
		file.store_buffer(bytes)
		file.flush()
		file.close()


## 释放测试期间创建的所有 Node，避免退出时报 "ObjectDB instances were leaked"。
func _cleanup() -> void:
	for instance in _instances:
		if instance != null and is_instance_valid(instance):
			instance.free()
	_instances.clear()


func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
		print("  [PASS] %s" % label)
	else:
		_failed += 1
		printerr("  [FAIL] %s" % label)
