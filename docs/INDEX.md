# 项目索引 · 《茅山秘录·诡异录》

> 🤖 本文件由 `tools/gen_index.gd` 自动生成，**请勿手改**。
> 重新生成：`godot --headless --path . --script res://tools/gen_index.gd`
> 校验是否过期：结尾加 `-- --check`（过期或存在脚本解析失败时退出码 1）
>
> **这是进入本项目的唯一入口**：先读这一页确定「该改哪个文件」，再打开具体源文件。

## 0. 骨架

- 主场景：`res://scenes/title_scene.tscn`
- Autoload：`TimeLoopManager` → `res://scripts/core/time_loop_manager.gd`
- Autoload：`PersistentMemoryManager` → `res://scripts/core/persistent_memory_manager.gd`
- 模块统计：autoload 2, module 17, test 10, tool 7（合计 36 个 .gd）
- 解析检查：✅ 全部脚本可加载

## 1. 模块地图

| 路径 | 类名 / Autoload | 基类 | 行数 | 职责 |
| --- | --- | --- | --- | --- |
| `res://scripts/core/persistent_memory_manager.gd` | **Autoload** `PersistentMemoryManager` | Node | 172 | persistent_memory_manager.gd —— 跨循环记忆 / 线索管理器（核心系统 / Core） |
| `res://scripts/core/time_loop_manager.gd` | **Autoload** `TimeLoopManager` | Node | 310 | time_loop_manager.gd —— 时间循环控制器（核心系统 / Core） |
| `res://scripts/data/case_loader.gd` | — | RefCounted | 495 | case_loader.gd —— 案件数据装载（data 层，纯只读，零 UI / 零场景引用） |
| `res://scripts/data/clue_store.gd` | — | RefCounted | 408 | clue_store.gd —— 线索 + 心灯数值持久化（崩溃安全 / 双档轮换） |
| `res://scripts/data/dialogue_loader.gd` | — | RefCounted | 1279 | dialogue_loader.gd —— 对话登记表装载（data 层，纯只读，零 UI / 零场景 / 零 Autoload） |
| `res://scripts/data/map_loader.gd` | — | RefCounted | 549 | map_loader.gd —— 案发地的走位图装载（data 层，纯只读，零 UI / 零场景引用） |
| `res://scripts/data/npc_timeline_parser.gd` | `NPCTimelineParser` | RefCounted | 414 | npc_timeline_parser.gd —— NPC 动线 JSON 解析器（数据层 / Data） |
| `res://scripts/data/rune_loader.gd` | — | RefCounted | 958 | scripts/data/rune_loader.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**数据层** |
| `res://scripts/data/ui_prefs.gd` | — | RefCounted | 87 | ui_prefs.gd —— 界面偏好（跟玩法进度无关的小开关） |
| `res://scripts/entities/deduction_board.gd` | — | Node | 1221 | deduction_board.gd —— 推演板与矛盾高亮（M1 第 ④ 步 / Entities） |
| `res://scripts/entities/heart_lamp.gd` | — | Node | 556 | heart_lamp.gd —— 心灯（玩法层组件 / Entities） |
| `res://scripts/entities/loop_mutation.gd` | — | Node | 659 | loop_mutation.gd —— 世界状态递进（玩法层组件 / Entities） |
| `res://scripts/entities/npc_memory.gd` | — | Node | 959 | npc_memory.gd —— NPC 跨轮记忆（玩法层组件 / Entities） |
| `res://scripts/entities/player_travel.gd` | — | RefCounted | 268 | player_travel.gd —— 玩家走位状态机（实体层；不引用任何 Autoload） |
| `res://scripts/entities/rune_input.gd` | — | Node | 853 | scripts/entities/rune_input.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**输入状态机** |
| `res://scripts/ui/overlay_ui.gd` | — | Control | 465 | overlay_ui.gd —— 覆盖层：新手引导弹窗 + 结案结算弹窗（Phase 2 / Phase 3） |
| `res://scripts/ui/play_view.gd` | — | Control | 1102 | PlayView —— M2 画面层（v2：自适应网格布局） |
| `res://scripts/ui/slice_hud.gd` | — | Control | 1848 | slice_hud.gd —— M0 可玩纵切片的表现层（临时 UI，正式 UI 到位后整块替换） |
| `res://scripts/ui/title_scene.gd` | — | Control | 470 | title_scene.gd —— 极简标题界面（M2 表现层：标题页） |
| `res://tests/test_case_loader.gd` | — | SceneTree | 226 | test_case_loader.gd —— case_loader.gd 的离线自检（不依赖 data/scenarios 里有没有真文件） |
| `res://tests/test_deduction.gd` | — | SceneTree | 796 | tests/test_deduction.gd —— M1 第 ④ 步：推演板与矛盾高亮 |
| `res://tests/test_dialogue.gd` | — | SceneTree | 513 | test_dialogue.gd —— dialogue_loader.gd 的离线自检（M1 对话层） |
| `res://tests/test_heart_lamp.gd` | — | SceneTree | 797 | test_heart_lamp.gd —— 心灯 + 线索双档轮换落盘 测试（Headless，不需要打开编辑器） |
| `res://tests/test_npc_memory.gd` | — | SceneTree | 572 | 测试：NPC 跨轮记忆（npc_memory.gd）+ 世界状态递进（loop_mutation.gd）—— M1 第③步的唯一空白差异位。 |
| `res://tests/test_phase1_smoke.gd` | — | SceneTree | 372 | test_phase1_smoke.gd —— 阶段一冒烟测试（不需要打开编辑器） |
| `res://tests/test_runes.gd` | — | SceneTree | 1211 | tests/test_runes.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的自带断言测试 |
| `res://tests/test_slice_hud.gd` | — | SceneTree | 1114 | test_slice_hud.gd —— M0 可玩纵切片的无头试玩 |
| `res://tests/test_title_scene.gd` | — | SceneTree | 513 | test_title_scene.gd —— 标题界面（scenes/title_scene.tscn）无头测试 |
| `res://tests/test_travel.gd` | — | SceneTree | 1069 | test_travel.gd —— 走位耗时自检：map_loader + player_travel + 案一真实数据 |
| `res://tools/cli.gd` | — | SceneTree | 528 | tools/cli.gd —— 项目命令行（工具链第 2 步：状态探针） |
| `res://tools/gen_index.gd` | — | SceneTree | 658 | tools/gen_index.gd —— 符号索引生成器（工具链第 1 步） |
| `res://tools/gen_placeholders.gd` | — | SceneTree | 492 | gen_placeholders.gd —— 占位图生成器：assets_src/placeholder_manifest.json → PNG |
| `res://tools/gen_scene.gd` | — | SceneTree | 585 | gen_scene.gd —— 场景生成器：场景规格 JSON → .tscn（调用引擎自身的序列化器） |
| `res://tools/gen_theme.gd` | — | SceneTree | 561 | gen_theme.gd —— 主题生成器：assets_src/theme.json → theme/default_theme.tres |
| `res://tools/shot.gd` | — | SceneTree | 227 | 表现层截图工具：用【带窗口】的 Godot 跑，把主场景的渲染结果存成 PNG。 |
| `res://tools/validate_data.gd` | — | RefCounted | 884 | 数据 schema + 设计不变量校验器（工具链第 4 步） |

## 2. 接口清单

### `res://scripts/core/persistent_memory_manager.gd` — Autoload `PersistentMemoryManager`

> persistent_memory_manager.gd —— 跨循环记忆 / 线索管理器（核心系统 / Core）

- 基类：`Node`；行数 172；私有/内部方法 0 个
- 依赖 Autoload：无（完全解耦）
- 信号：`clue_added(clue_id: String, source_loop: int)`；`clue_duplicate_ignored(clue_id: String)`；`memory_reset()`
- 公开方法：
  - `func add_clue(clue_id: String, source_loop: int = …) -> bool`
  - `func add_clues(clue_ids: Array, source_loop: int = …) -> int`
  - `func has_clue(clue_id: String) -> bool`
  - `func has_all_clues(clue_ids: Array) -> bool`
  - `func get_clues() -> Array[String]`
  - `func get_clue_count() -> int`
  - `func get_clue_record(clue_id: String) -> Dictionary`
  - `func get_save_data() -> Dictionary`
  - `func apply_save_data(data: Dictionary) -> bool`
  - `func reset_for_new_game() -> void`
- 常量：SAVE_VERSION = 1

### `res://scripts/core/time_loop_manager.gd` — Autoload `TimeLoopManager`

> time_loop_manager.gd —— 时间循环控制器（核心系统 / Core）

- 基类：`Node`；行数 310；私有/内部方法 6 个
- 依赖 Autoload：无（完全解耦）
- 信号：`time_updated(current_second)`；`loop_reset()`；`loop_started(loop_index)`；`loop_timeout()`；`pause_changed(is_paused)`
- 公开方法：
  - `func tick(delta: float) -> void`
  - `func start_loop() -> void`
  - `func trigger_loop_reset() -> void`
  - `func pause_loop() -> void`
  - `func resume_loop() -> void`
  - `func toggle_pause() -> void`
  - `func set_time_scale(value: float) -> void`
  - `func get_time_scale() -> float`
  - `func get_loop_duration() -> float`
  - `func set_loop_duration(seconds: float) -> void`
  - `func is_running() -> bool`
  - `func is_paused() -> bool`
  - `func get_loop_index() -> int`
  - `func reset_loop_index() -> void`
  - `func get_remaining_seconds() -> int`
  - `func get_elapsed_seconds() -> int`
  - `func get_remaining_time() -> float`
  - `func get_elapsed_time() -> float`
  - `func get_progress_ratio() -> float`
- 常量：DEFAULT_LOOP_DURATION = 420.0；MIN_LOOP_DURATION = 1.0；MAX_LOOP_DURATION = 3600.0；MAX_TIME_SCALE = 200.0

### `res://scripts/data/case_loader.gd`

> case_loader.gd —— 案件数据装载（data 层，纯只读，零 UI / 零场景引用）

- 基类：`RefCounted`；行数 495；私有/内部方法 3 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func list_case_files() -> PackedStringArray`
  - `static func find_case_path(case_id: int = …) -> String`
  - `static func load_case(path: String = …) -> CaseData`
  - `static func parse_text(text: String, path: String = …) -> CaseData`
  - `static func parse_dictionary(data: Dictionary, path: String = …) -> CaseData`
- 内部类：TimelineNode, NPCSchedule, CaseData
- 常量：SCENARIO_DIR = res://data/scenarios；NODE_FIELDS = ["second", "room", "action", "facing", "dialogue_id", "cl…；FACINGS = ["north", "south", "east", "west", ""]

### `res://scripts/data/clue_store.gd`

> clue_store.gd —— 线索 + 心灯数值持久化（崩溃安全 / 双档轮换）

- 基类：`RefCounted`；行数 408；私有/内部方法 7 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func save(clues: Array) -> bool`
  - `static func mark_forgotten(clue_id: String) -> bool`
  - `static func unmark_forgotten(clue_id: String) -> bool`
  - `static func save_lamp_state(value: int, seen_unix: int) -> bool`
  - `static func save_lamp_value(value: int) -> bool`
  - `static func erase_store() -> bool`
  - `static func load_clues() -> Array[String]`
  - `static func load_forgotten() -> Array[String]`
  - `static func is_forgotten(clue_id: String) -> bool`
  - `static func load_lamp_state() -> Dictionary`
  - `static func load_lamp_value() -> int`
- 常量：SAVE_PATH = user://clue_store.json；TMP_PATH = user://clue_store.json.tmp；BAK_PATH = user://clue_store.json.bak；CORRUPT_PATH = user://clue_store.json.corrupt；SAVE_VERSION = 2；KEY_VERSION = version；KEY_CLUES = clues；KEY_FORGOTTEN = forgotten；KEY_LAMP_VALUE = lamp_value；KEY_SEEN_UNIX = seen_unix；DEFAULT_LAMP_VALUE = 100

### `res://scripts/data/dialogue_loader.gd`

> dialogue_loader.gd —— 对话登记表装载（data 层，纯只读，零 UI / 零场景 / 零 Autoload）

- 基类：`RefCounted`；行数 1279；私有/内部方法 3 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func reset_context() -> void`
  - `static func context_summary() -> String`
  - `static func set_context_npcs(mapping: Dictionary) -> void`
  - `static func set_context_clue_ids(ids: Array) -> void`
  - `static func set_context_duration(seconds: int) -> void`
  - `static func list_dialogue_files() -> PackedStringArray`
  - `static func find_dialogue_path(case_id: int = …) -> String`
  - `static func find_scenario_path(case_id: int = …) -> String`
  - `static func load_clue_registry(case_id: int = …) -> Array[String]`
  - `static func load_npc_names(case_path: String) -> Dictionary`
  - `static func load_dialogue_anchors(case_path: String) -> Dictionary`
  - `static func load_case_duration(case_path: String) -> int`
  - `static func load_for_case(case_id: int = …) -> DialogueTable`
  - `static func load_from_file(path: String, case_path: String = …) -> DialogueTable`
  - `static func parse_text(text: String, path: String = …) -> DialogueTable`
  - `static func parse_dictionary(data: Dictionary, path: String = …) -> DialogueTable`
- 内部类：DialogueLine, DialogueOption, DialogueEntry, DialogueTable
- 常量：DIALOGUE_DIR = res://data/dialogues；SCENARIO_DIR = res://data/scenarios；CLUE_DIR = res://data/clues；CLUE_ID_PATTERN = ^(clue|note|sealed)_[a-z0-9]+(_[a-z0-9]+)*$；DEFAULT_MIN_SECONDS = 1；OPTION_FIELDS = ["text", "reply", "goto", "require_clues", "require_loop_…

### `res://scripts/data/map_loader.gd`

> map_loader.gd —— 案发地的走位图装载（data 层，纯只读，零 UI / 零场景引用）

- 基类：`RefCounted`；行数 549；私有/内部方法 5 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func list_map_files() -> PackedStringArray`
  - `static func find_map_path(case_id: int = …) -> String`
  - `static func load_for_case(case_id: int = …) -> RoomMap`
  - `static func load_from_file(path: String = …, case_id: int = …) -> RoomMap`
  - `static func parse_text(text: String, path: String = …) -> RoomMap`
  - `static func parse_dictionary(data: Dictionary, path: String = …) -> RoomMap`
- 内部类：RoomMap
- 常量：MAP_DIR = res://data/maps；SUPPORTED_SCHEMA_VERSION = 1；LONG_TRAVEL_WARNING_SECONDS = 180；SUGGEST_MAX_DISTANCE = 3

### `res://scripts/data/npc_timeline_parser.gd`

> npc_timeline_parser.gd —— NPC 动线 JSON 解析器（数据层 / Data）

- 基类：`RefCounted`；行数 414；私有/内部方法 3 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func load_from_file(path: String = …) -> ParseResult`
  - `static func parse_text(text: String, source_label: String = …) -> ParseResult`
  - `static func parse_dictionary(root: Dictionary, source_label: String = …) -> ParseResult`
- 内部类：TimelineNode, NPCSchedule, ParseResult
- 常量：DEFAULT_TIMELINE_PATH = res://data/npc_timelines.json；SUPPORTED_SCHEMA_VERSION = 1；DEFAULT_LOOP_DURATION_SECONDS = 420

### `res://scripts/data/rune_loader.gd`

> scripts/data/rune_loader.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**数据层**

- 基类：`RefCounted`；行数 958；私有/内部方法 0 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func load_for_case(case_id: int = …) -> RuneTable`
  - `static func load_from_file(path: String, case_path: String = …) -> RuneTable`
  - `static func parse_text(text: String, path: String = …, case_path: String = …) -> RuneTable`
  - `static func parse_dictionary(data: Dictionary, path: String = …, case_path: String = …) -> RuneTable`
  - `static func list_rune_files() -> Array[String]`
  - `static func find_rune_path(case_id: int = …) -> String`
  - `static func find_scenario_path(case_id: int = …) -> String`
  - `static func load_known_clue_ids() -> Array[String]`
- 内部类：RuneStroke, RuneNearMiss, RuneOption, RuneStep, RuneEntry, RuneTable
- 常量：DEFAULT_CASE_ID = 1；RUNE_DIR = res://data/runes；CLUE_DIR = res://data/clues；SCENARIO_DIR = res://data/scenarios；SUPPORTED_SCHEMA_VERSION = 1；KINDS = ["gate", "draw", "npc", "choice"]；RUNE_KEYS = ["rune_id", "name", "display_name", "source_note", "requi…；STEP_KEYS = ["step", "step_id", "name", "kind", "require_clues", "gat…；STROKE_KEYS = ["index", "name", "pattern", "note"]；NEAR_MISS_KEYS = ["attempt_id", "pattern", "hint", "clue_note"]；OPTION_KEYS = ["option_id", "text", "correct", "reply"]；WRONG_HINT = 这一笔对不上原石：笔顺或方向不对。可以退一笔重描。

### `res://scripts/data/ui_prefs.gd`

> ui_prefs.gd —— 界面偏好（跟玩法进度无关的小开关）

- 基类：`RefCounted`；行数 87；私有/内部方法 0 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func load_prefs() -> Dictionary`
  - `static func save_prefs(data: Dictionary) -> bool`
  - `static func has_seen_tutorial() -> bool`
  - `static func mark_tutorial_seen() -> bool`
  - `static func erase() -> bool`
- 常量：PREFS_PATH = user://ui_prefs.json；PREFS_VERSION = 1；KEY_VERSION = version；KEY_TUTORIAL_SEEN = tutorial_seen

### `res://scripts/entities/deduction_board.gd`

> deduction_board.gd —— 推演板与矛盾高亮（M1 第 ④ 步 / Entities）

- 基类：`Node`；行数 1221；私有/内部方法 49 个
- 依赖 Autoload：无（完全解耦）
- 信号：`board_changed(unlocked_count: int, ready_conflict_count: int)`
- 公开方法：
  - `func configure(case_id: int = …) -> bool`
  - `func configure_with_rules(data: Dictionary, options: Dictionary = …) -> bool`
  - `func is_configured() -> bool`
  - `func is_ok() -> bool`
  - `func get_case_id() -> int`
  - `func get_source() -> String`
  - `func set_memory_manager(memory: Node) -> void`
  - `func get_memory_manager() -> Node`
  - `func set_owned_clues(clue_ids: Array) -> void`
  - `func get_owned_clues() -> Array[String]`
  - `func refresh() -> void`
  - `func reset() -> void`
  - `func owned_cards() -> Array[String]`
  - `func unlocked_deductions() -> Array[Dictionary]`
  - `func locked_deductions() -> Array[Dictionary]`
  - `func nearly_locked() -> Array[Dictionary]`
  - `func ready_conflicts() -> Array[Dictionary]`
  - `func pending_conflicts() -> Array[Dictionary]`
  - `func get_deduction(deduction_id: String) -> Dictionary`
  - `func has_deduction(deduction_id: String) -> bool`
  - `func get_conflict(conflict_id: String) -> Dictionary`
  - `func has_conflict(conflict_id: String) -> bool`
  - `func deduction_ids() -> Array[String]`
  - `func conflict_ids() -> Array[String]`
  - `func card_name(clue_id: String) -> String`
  - `func card_chain(clue_id: String) -> String`
  - `func npc_name(npc_id: String) -> String`
  - `func is_deduction_unlocked(deduction_id: String) -> bool`
  - `func is_conflict_ready(conflict_id: String) -> bool`
  - `func total_deduction_count() -> int`
  - `func total_conflict_count() -> int`
  - `func total_stuck_hint_count() -> int`
  - `func total_clue_count() -> int`
  - `func stuck_hint(loops_without_progress: int, loop_index: int = …) -> Dictionary`
  - `func describe() -> String`
  - `func describe_conflict(conflict_id: String) -> String`
  - `func board_lines(max_lines: int = …) -> Array[String]`
  - `func get_errors() -> Array[String]`
  - `func get_warnings() -> Array[String]`
  - `func error_summary() -> String`
  - `func get_state() -> Dictionary`
- 常量：DEFAULT_CASE_ID = 1；DATA_DIR = res://data/deduction；CLUE_DIR = res://data/clues；SCENARIO_DIR = res://data/scenarios；DEFAULT_LOOP_SECONDS = 360；SEVERITY_CORE = 核心；SEVERITY_MINOR = 次要；SEVERITIES = ["核心", "次要"]；PREFIX_CONFLICT = ⚠ 对不上：；PREFIX_RESOLVED = ✓ 已收束：；PREFIX_CORE = ★ ；PREFIX_PLAIN = · ；PREFIX_NEARLY = …差 

### `res://scripts/entities/heart_lamp.gd`

> heart_lamp.gd —— 心灯（玩法层组件 / Entities）

- 基类：`Node`；行数 556；私有/内部方法 15 个
- 依赖 Autoload：TimeLoopManager
- 信号：`heart_lamp_changed(value: int, max_value: int)`；`heart_lamp_extinguished(lost_clue_id: String)`
- 公开方法：
  - `func set_memory_manager(memory: Node) -> void`
  - `func get_memory_manager() -> Node`
  - `func set_store_enabled(enabled: bool) -> void`
  - `func is_store_enabled() -> bool`
  - `func get_value() -> int`
  - `func get_max_value() -> int`
  - `func is_extinguished() -> bool`
  - `func get_extinguish_count() -> int`
  - `func is_in_loop() -> bool`
  - `func get_available_clues() -> Array[String]`
  - `func get_forgotten_clues() -> Array[String]`
  - `func set_max_value(value: int) -> void`
  - `func set_value(value: int, allow_extinguish: bool = …) -> void`
  - `func set_in_loop(value: bool) -> void`
  - `func reset_for_new_loop() -> void`
  - `func tick(delta: float) -> void`
  - `func drain(amount: int) -> void`
  - `func restore(amount: int) -> void`
  - `func resolve_case() -> void`
  - `func add_clue(clue_id: String, source_loop: int = …) -> bool`
  - `func restore_from_store(source_loop: int = …) -> int`
  - `func apply_offline_recovery(now_unix: int = …) -> int`
  - `func get_last_offline_recovery() -> int`
- 常量：ClueStore = preload(res://scripts/data/clue_store.gd)；DEFAULT_MAX_VALUE = 100；DRAIN_PER_LOOP_RESET = 8；DRAIN_PER_SECOND = 0.02；RESTORE_PER_CASE_RESOLVED = 25；RECOVER_PER_REAL_MINUTE = 1；LOOP_MANAGER_PATH = /root/TimeLoopManager

### `res://scripts/entities/loop_mutation.gd`

> loop_mutation.gd —— 世界状态递进（玩法层组件 / Entities）

- 基类：`Node`；行数 659；私有/内部方法 15 个
- 依赖 Autoload：TimeLoopManager
- 信号：`loop_mutation_changed(loop_index: int, level: int)`
- 公开方法：
  - `func subscribe_loop_manager() -> bool`
  - `func unsubscribe_loop_manager() -> void`
  - `func on_loop_reset() -> void`
  - `func on_loop_started(loop_index: int) -> void`
  - `func configure(case_data) -> void`
  - `func set_memory_manager(memory: Node) -> void`
  - `func get_memory_manager() -> Node`
  - `func set_loop_index(loop_index: int) -> void`
  - `func apply_loop(loop_index: int) -> void`
  - `func reset() -> void`
  - `func is_configured() -> bool`
  - `func is_ok() -> bool`
  - `func get_mode() -> String`
  - `func get_level() -> int`
  - `func get_loop_index() -> int`
  - `func get_loop_number() -> int`
  - `func get_max_level() -> int`
  - `func get_note() -> String`
  - `func get_affected_rooms() -> Array[String]`
  - `func is_affected(room: String) -> bool`
  - `func base_count(room: String) -> int`
  - `func entity_count(room: String) -> int`
  - `func total_entity_count() -> int`
  - `func list_entities(room: String) -> Array[String]`
  - `func describe() -> String`
  - `func get_state() -> Dictionary`
  - `func get_errors() -> Array[String]`
  - `func get_warnings() -> Array[String]`
  - `func error_summary() -> String`
- 常量：MODE_GROW = grow；MODE_SHRINK = shrink；LOOP_MANAGER_PATH = /root/TimeLoopManager；LOOP_MANAGER_NAME = TimeLoopManager

### `res://scripts/entities/npc_memory.gd`

> npc_memory.gd —— NPC 跨轮记忆（玩法层组件 / Entities）

- 基类：`Node`；行数 959；私有/内部方法 22 个
- 依赖 Autoload：TimeLoopManager
- 信号：`npc_memory_stage_changed(npc_id: String, stage: int, max_stage: int)`
- 公开方法：
  - `func subscribe_loop_manager() -> bool`
  - `func unsubscribe_loop_manager() -> void`
  - `func on_loop_reset() -> void`
  - `func on_loop_started(loop_index: int) -> void`
  - `func configure(case_id: int = …) -> void`
  - `func configure_with_rules(rules: Dictionary, options: Dictionary = …) -> void`
  - `func set_memory_manager(memory: Node) -> void`
  - `func get_memory_manager() -> Node`
  - `func set_known_npcs(npc_ids: Array) -> void`
  - `func set_loop_index(loop_index: int) -> int`
  - `func apply_loop(loop_index: int) -> int`
  - `func refresh() -> int`
  - `func reset() -> void`
  - `func is_configured() -> bool`
  - `func is_ok() -> bool`
  - `func get_case_id() -> int`
  - `func get_source() -> String`
  - `func get_loop_index() -> int`
  - `func get_loop_number() -> int`
  - `func get_stage(npc_id: String) -> int`
  - `func get_max_stage(npc_id: String) -> int`
  - `func get_effects(npc_id: String) -> Dictionary`
  - `func list_changed_npcs() -> Array[String]`
  - `func get_reveal_clue_ids() -> Array[String]`
  - `func describe(npc_id: String) -> String`
  - `func get_npc_ids() -> Array[String]`
  - `func get_display_name(npc_id: String) -> String`
  - `func has_rules(npc_id: String) -> bool`
  - `func total_rule_count() -> int`
  - `func is_clue_known(clue_id: String) -> bool`
  - `func get_clue_registry_size() -> int`
  - `func get_state() -> Dictionary`
  - `func get_errors() -> Array[String]`
  - `func get_warnings() -> Array[String]`
  - `func error_summary() -> String`
- 常量：MEMORY_DIR = res://data/npc_memory；CLUE_DIR = res://data/clues；DIALOGUE_DIR = res://data/dialogues；LOOP_MANAGER_PATH = /root/TimeLoopManager；LOOP_MANAGER_NAME = TimeLoopManager；DEFAULT_CASE_ID = 1；EFFECT_KEYS = ["extra_dialogue_id", "reveal_clue_id", "note"]

### `res://scripts/entities/player_travel.gd`

> player_travel.gd —— 玩家走位状态机（实体层；不引用任何 Autoload）

- 基类：`RefCounted`；行数 268；私有/内部方法 4 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `static func create(map, start_room: String = …) -> void`
  - `func get_room() -> String`
  - `func get_map() -> void`
  - `func is_map_loaded() -> bool`
  - `func can_go(room: String) -> bool`
  - `func get_route_to(room: String) -> Array[String]`
  - `func get_travel_seconds_to(room: String) -> int`
  - `func is_moving() -> bool`
  - `func get_target_room() -> String`
  - `func get_from_room() -> String`
  - `func get_travel_seconds() -> int`
  - `func get_arrive_epsilon() -> float`
  - `func get_remaining_seconds() -> int`
  - `func get_elapsed_for_debug() -> float`
  - `func get_total_travelled_seconds() -> int`
  - `func get_move_count() -> int`
  - `func set_room(room: String) -> bool`
  - `func start_move(room: String) -> int`
  - `func tick(delta: float) -> bool`
  - `func cancel_move() -> bool`
  - `func reset_to(room: String) -> bool`
  - `func get_last_arrived_room() -> String`
- 常量：ARRIVE_EPSILON_RATIO = 0.000000001

### `res://scripts/entities/rune_input.gd`

> scripts/entities/rune_input.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的**输入状态机**

- 基类：`Node`；行数 853；私有/内部方法 24 个
- 依赖 Autoload：TimeLoopManager
- 信号：`rune_changed(state: String)`；`rune_step_changed(step_id: String, step_index: int, total: int)`；`rune_stroke_drawn(stroke_index: int, tokens: Array)`；`rune_completed(rune_id: String)`；`rune_failed(rune_id: String, reason: String)`
- 公开方法：
  - `func configure(case_id: int = …) -> bool`
  - `func configure_with_table(table, options: Dictionary = …) -> bool`
  - `func is_configured() -> bool`
  - `func is_ok() -> bool`
  - `func get_table() -> Variant`
  - `func get_errors() -> Array[String]`
  - `func get_warnings() -> Array[String]`
  - `func error_summary() -> String`
  - `func set_memory_manager(memory: Node) -> void`
  - `func get_memory_manager() -> Node`
  - `func set_owned_clues(clue_ids: Array) -> void`
  - `func get_owned_clues() -> Array[String]`
  - `func set_room(room_id: String) -> void`
  - `func get_room() -> String`
  - `func set_loop_index(index: int) -> void`
  - `func get_loop_index() -> int`
  - `func can_start(rune_id: String = …) -> bool`
  - `func start_rune(rune_id: String = …) -> bool`
  - `func is_running() -> bool`
  - `func get_state() -> String`
  - `func get_current_rune_id() -> String`
  - `func get_current_step() -> Variant`
  - `func get_step_index() -> int`
  - `func get_step_count() -> int`
  - `func begin_stroke() -> void`
  - `func feed_token(token: String) -> bool`
  - `func undo_token() -> bool`
  - `func current_tokens() -> Array[String]`
  - `func current_stroke_index() -> int`
  - `func drawn_strokes() -> Array`
  - `func undo_stroke() -> bool`
  - `func commit_stroke() -> Dictionary`
  - `func choose_option(option_id: String) -> Dictionary`
  - `func advance() -> bool`
  - `func is_completed() -> bool`
  - `func completed_rune_id() -> String`
  - `func fail_rune(reason: String = …) -> bool`
  - `func reset() -> void`
  - `func get_last_message() -> String`
  - `func describe() -> String`
  - `func describe_step() -> String`
  - `func prompt_lines(max_lines: int = …) -> Array[String]`
  - `func get_state_snapshot() -> Dictionary`
  - `func is_subscribed() -> bool`
- 常量：RuneLoader = preload(res://scripts/data/rune_loader.gd)；DEFAULT_CASE_ID = 1；STATE_IDLE = idle；STATE_STEP = step；STATE_DRAWING = drawing；STATE_DONE = done；STATUS_OK = ok；STATUS_NEAR_MISS = near_miss；STATUS_WRONG = wrong；WRONG_HINT = 这一笔对不上原石：笔顺或方向不对。可以退一笔重描。；LOOP_MANAGER_PATH = /root/TimeLoopManager；LOOP_MANAGER_NAME = TimeLoopManager

### `res://scripts/ui/overlay_ui.gd`

> overlay_ui.gd —— 覆盖层：新手引导弹窗 + 结案结算弹窗（Phase 2 / Phase 3）

- 基类：`Control`；行数 465；私有/内部方法 25 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `func open_tutorial() -> void`
  - `func close_tutorial() -> void`
  - `func is_tutorial_open() -> bool`
  - `func tutorial_seconds_left() -> float`
  - `func open_settlement(state: Dictionary = …) -> void`
  - `func close_settlement() -> void`
  - `func is_settlement_open() -> bool`
  - `func debug_info() -> Dictionary`
- 常量：UIPrefs = preload(res://scripts/data/ui_prefs.gd)；TUTORIAL_SECONDS = 30.0；PANEL_WIDTH_RATIO = 0.52；PANEL_MIN_WIDTH = 420.0；PANEL_MAX_WIDTH = 700.0；F_HERO = 22；F_TITLE = 16；F_BODY = 14；F_SMALL = 12；C_TEXT（复合值）；C_DIM（复合值）；C_WARM（复合值）；C_ACCENT（复合值）；C_ACCENT_EDGE（复合值）；C_PANEL_BG（复合值）；C_PANEL_EDGE（复合值）；C_BLOCK（复合值）；C_KEY_BG（复合值）；C_KEY_EDGE（复合值）

### `res://scripts/ui/play_view.gd`

> PlayView —— M2 画面层（v2：自适应网格布局）

- 基类：`Control`；行数 1102；私有/内部方法 49 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `func debug_info() -> Dictionary`
- 常量：MAP_PATH = res://data/maps/case_01_map.json；MARGIN = 12.0；TOP_H = 74.0；BOTTOM_H = 104.0；PANEL_MIN_W = 300.0；PANEL_MAX_W = 360.0；MIN_GAP = 120.0；CELL_MIN_W = 128.0；CELL_MIN_H = 92.0；PLATE_H = 30.0；CHIP_H = 18.0；CHIP_GAP = 6.0；FONT_PATH = res://assets/fonts/NotoSansSC-subset.ttf；F_TINY = 11；F_SMALL = 12；F_BODY = 14；F_TITLE = 16；F_HERO = 22；C_BG（复合值）；C_INK（复合值）；C_TEXT（复合值）；C_DIM（复合值）；C_FAINT（复合值）；C_GOLD（复合值）；C_LAMP（复合值）；C_BAD（复合值）；C_OK（复合值）；C_STONE（复合值）；C_NPC = [(0.62, 0.78, 0.92, 1.0), (0.86, 0.7, 0.55, 1.0), (0.72, …

### `res://scripts/ui/slice_hud.gd`

> slice_hud.gd —— M0 可玩纵切片的表现层（临时 UI，正式 UI 到位后整块替换）

- 基类：`Control`；行数 1848；私有/内部方法 72 个
- 依赖 Autoload：PersistentMemoryManager, TimeLoopManager
- 信号：无
- 公开方法：
  - `func request_option(index: int) -> void`
  - `func present_state() -> Dictionary`
  - `func request_travel(room_id: String) -> void`
  - `func request_talk() -> void`
  - `func request_board() -> void`
  - `func request_rune() -> void`
  - `func request_reset() -> void`
  - `func request_restart_case() -> void`
  - `func set_text_hud_visible(on: bool) -> void`
  - `func is_text_hud_visible() -> bool`
- 常量：CaseLoader = preload(res://scripts/data/case_loader.gd)；HeartLamp = preload(res://scripts/entities/heart_lamp.gd)；DialogueLoader = preload(res://scripts/data/dialogue_loader.gd)；LoopMutation = preload(res://scripts/entities/loop_mutation.gd)；NpcMemory = preload(res://scripts/entities/npc_memory.gd)；MapLoader = preload(res://scripts/data/map_loader.gd)；PlayerTravel = preload(res://scripts/entities/player_travel.gd)；DeductionBoard = preload(res://scripts/entities/deduction_board.gd)；RuneLoader = preload(res://scripts/data/rune_loader.gd)；RuneInput = preload(res://scripts/entities/rune_input.gd)；ClueStore = preload(res://scripts/data/clue_store.gd)；DEFAULT_DURATION = 420.0；SCALE_STEPS = [1.0, 10.0, 60.0]；LOG_LINES = 6；FAST_SCALE = 60.0

### `res://scripts/ui/title_scene.gd`

> title_scene.gd —— 极简标题界面（M2 表现层：标题页）

- 基类：`Control`；行数 470；私有/内部方法 18 个
- 依赖 Autoload：无（完全解耦）
- 信号：`start_requested()`
- 公开方法：
  - `func debug_info() -> Dictionary`
- 常量：NEXT_SCENE = res://scenes/main.tscn；C_INK_TOP（复合值）；C_INK_BOTTOM（复合值）；C_MIST（复合值）；C_CINNABAR（复合值）；C_EDGE（复合值）；C_EDGE_HOVER（复合值）；C_EDGE_PRESSED（复合值）；C_BTN_FILL（复合值）；C_BTN_FILL_HOVER（复合值）；C_BTN_FILL_PRESSED（复合值）；C_TEXT（复合值）；C_TEXT_HOVER（复合值）；BLOCK_CENTER_Y_RATIO = 0.44；FS_TITLE_RATIO = 0.072；FS_TITLE_MIN = 26；FS_TITLE_MAX = 76；FS_SUBTITLE_RATIO = 0.028；FS_SUBTITLE_MIN = 13；FS_SUBTITLE_MAX = 32；FS_HINT_RATIO = 0.017；FS_HINT_MIN = 11；FS_HINT_MAX = 20；FS_BUTTON_RATIO = 0.026；FS_BUTTON_MIN = 13；FS_BUTTON_MAX = 30；GAP_TITLE_TO_SUBTITLE = 0.028；GAP_SUBTITLE_TO_HINT = 0.013；GAP_HINT_TO_BUTTON = 0.045；BUTTON_H_RATIO = 0.07；BUTTON_W_PAD_RATIO = 0.11；BUTTON_W_RATIO_MIN = 0.2；BUTTON_W_RATIO_MAX = 0.42；BUTTON_CONTENT_MARGIN = 12.0；LINE_HEIGHT_FALLBACK = 1.45；BLOOMS = [[0.2, 0.28, 0.36, 0.021], [0.82, 0.2, 0.3, 0.018], [0.68…；BLOOM_RINGS = 10；SEAL_TILT_DEG = 7.0；STREAKS = [[0.145, 0.06, 0.44, 0.045], [0.198, 0.52, 0.95, 0.032], …；VIGNETTE_LAYERS = 16；VIGNETTE_BAND_RATIO = 0.016

### `res://tests/test_case_loader.gd`

> test_case_loader.gd —— case_loader.gd 的离线自检（不依赖 data/scenarios 里有没有真文件）

- 基类：`SceneTree`；行数 226；私有/内部方法 7 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：CaseLoader = preload(res://scripts/data/case_loader.gd)；EXPECTED_CHECKS = 35；VALID_FIXTURE = 
{
  "meta": {
    "schema_version": 1,
    "map_id": "test_map",
    "case_id": 1,
    "case_title": "白鹄不举",
    "loop_duration_seconds": 360,
    "rooms": ["hall", "cellar"],
    "description": "夹具案件",
    "secret": { "kind": "test", "per_loop_mutation": { "mode": "shrink" } }
  },
  "npcs": [
    {
      "npc_id": "npc_01_a",
      "display_name": "甲",
      "default_room": "hall",
      "timeline": [
        { "second": 0,   "room": "hall",   "action": "wait",  "clue_id": "" },
        { "second": 120, "room": "cellar", "action": "dig",   "clue_id": "clue_01_shovel" }
      ]
    },
    {
      "npc_id": "npc_01_b",
      "display_name": "乙",
      "default_room": "cellar",
      "timeline": [
        { "second": 0,  "room": "cellar", "action": "hide", "clue_id": "" },
        { "second": 60, "room": "hall",   "action": "talk", "clue_id": "clue_01_letter" }
      ]
    }
  ]
}
；SUSPICIOUS_FIXTURE = 
{
  "meta": {
    "schema_version": 1,
    "map_id": "test_map",
    "case_id": 2,
    "case_title": "夹具二",
    "loop_duration_seconds": 300,
    "rooms": ["hall", "cellar"]
  },
  "npcs": [
    {
      "npc_id": "npc_02_a",
      "display_name": "丙",
      "default_room": "hall",
      "timeline": [
        { "second": 100, "room": "cellar", "action": "dig" },
        { "second": 50,  "room": "celar",  "action": "walk" }
      ]
    }
  ]
}
；LEGACY_SHAPE_FIXTURE = 
{ "meta": { "map_id": "m", "case_id": 3, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": { "npc_03_a": { "display_name": "丁" } } }
；DUPLICATE_SECOND_FIXTURE = 
{ "meta": { "map_id": "m", "case_id": 4, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": [ { "npc_id": "npc_04_a", "display_name": "戊", "default_room": "hall",
    "timeline": [ { "second": 10, "room": "hall" }, { "second": 10, "room": "hall" } ] } ] }
；OUT_OF_RANGE_FIXTURE = 
{ "meta": { "map_id": "m", "case_id": 5, "loop_duration_seconds": 60, "rooms": ["hall"] },
  "npcs": [ { "npc_id": "npc_05_a", "display_name": "己", "default_room": "hall",
    "timeline": [ { "second": 90, "room": "hall" } ] } ] }


### `res://tests/test_deduction.gd`

> tests/test_deduction.gd —— M1 第 ④ 步：推演板与矛盾高亮

- 基类：`SceneTree`；行数 796；私有/内部方法 20 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 内部类：FakeMemory, FakeLamp
- 常量：DeductionBoard = preload(res://scripts/entities/deduction_board.gd)；DEDUCTION_DATA = res://data/deduction/case_01_deduction.json；EXPECTED_CHECKS = 263；CLOSING_CLUES = ["clue_01_four_in_three", "clue_01_half_stroke_cun", "clu…；ALL_CLUES = ["clue_01_four_in_three", "clue_01_two_hands", "clue_01_h…

### `res://tests/test_dialogue.gd`

> test_dialogue.gd —— dialogue_loader.gd 的离线自检（M1 对话层）

- 基类：`SceneTree`；行数 513；私有/内部方法 11 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：DialogueLoader = preload(res://scripts/data/dialogue_loader.gd)；EXPECTED_CHECKS = 114；FIXTURE_NPCS（复合值）；FIXTURE_CLUES = ["clue_01_knot", "clue_01_letter"]；VALID_FIXTURE = 
{
  "meta": {
    "schema_version": 1,
    "case_id": 7,
    "map_id": "test_map",
    "description": "夹具对话表"
  },
  "dialogues": {
    "a_00_hello": {
      "speaker": "甲先生",
      "unlock_if": { "has_clues": [], "loop_min": 0 },
      "lines": ["（他把手收进袖子里）你昨天也在这儿。", "我数了十九年台阶。"],
      "options": [
        { "text": "（先记住他站的是哪一级）", "reply": "（第七级。他一秒不差。）", "goto": "" },
        { "text": "再往上走一步？", "require_loop_min": 3, "goto": "a_01_up" }
      ],
      "note": "夹具：第一拍"
    },
    "a_01_up": {
      "speaker": "甲先生",
      "unlock_if": { "has_clues": ["clue_01_knot"], "loop_min": 3 },
      "lines": ["上面那级是空的。", "他数过的地方比别处亮一点。"],
      "options": [
        { "text": "（把那道结原样描在本子上）", "reply": "（双回结：先反手一圈，再回扣一道。）", "add_clue": "clue_01_knot", "goto": "" }
      ],
      "note": "夹具：第二拍"
    },
    "b_00_hide": {
      "speaker": "乙姑娘",
      "unlock_if": { "has_clues": [], "loop_min": 0 },
      "lines": ["（她把信压在碗底）", "（碗是空的，信也没有署名。）"],
      "options": [
        { "text": "（记下碗底压着什么）", "goto": "" }
      ],
      "note": "夹具：另一名 NPC"
    }
  }
}
；VALID_ANCHORS（复合值）；SUSPICIOUS_FIXTURE = 
{
  "meta": { "schema_version": 1, "case_id": 8, "map_id": "test_map" },
  "dialogues": {
    "c_00_late": {
      "speaker": "甲先生",
      "lines": ["这一条排在前面，但锚点在后。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 100"
    },
    "c_01_early": {
      "speaker": "甲先生",
      "lines": ["这一条锚点在前，却排在后面。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 50"
    },
    "c_02_nospeaker": {
      "lines": ["谁在说这句？"],
      "options": [ { "text": "（不知道是谁说的）", "goto": "" } ],
      "note": "夹具：缺 speaker"
    },
    "c_03_emptylines": {
      "speaker": "甲先生",
      "lines": ["", "   "],
      "options": [ { "text": "（空白台词）", "goto": "" } ],
      "note": "夹具：空文本"
    },
    "c_04_dangling": {
      "speaker": "甲先生",
      "lines": ["这一条跳向一个不存在的条目。"],
      "options": [ { "text": "跟过去", "goto": "no_such_dialogue" } ],
      "note": "夹具：悬空 goto"
    },
    "c_05_outsider": {
      "speaker": "路人甲乙丙",
      "lines": ["台词没问题，但说话的人不在本页名册上。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：speaker 不在名册"
    },
    "c_06_badclue": {
      "speaker": "甲先生",
      "lines": ["这一条给一条没登记的线索。"],
      "options": [ { "text": "（收下）", "add_clue": "clue-09-ghost", "goto": "" } ],
      "note": "夹具：clue_id 不合规范"
    },
    "c_07_shuffled": {
      "speaker": "乙姑娘",
      "lines": ["这一条按锚点应该在中间。"],
      "options": [ { "text": "（记下来）", "goto": "" } ],
      "note": "夹具：锚点 70"
    }
  }
}
；SUSPICIOUS_ANCHORS（复合值）；NO_META_FIXTURE = 
{ "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["缺 meta。"], "options": [] } } }
；DIALOGUES_AS_ARRAY_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": [ { "dialogue_id": "d_00", "lines": ["写成了数组。"] } ] }
；EMPTY_ID_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "": { "speaker": "甲先生", "lines": ["id 是空的。"], "options": [] } } }
；DUPLICATE_ID_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": {
    "d_00": { "speaker": "甲先生", "lines": ["第一份。"], "options": [] },
    "d_00": { "speaker": "甲先生", "lines": ["第二份，同 id。"], "options": [] }
  } }
；NO_LINES_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "options": [] } } }
；BAD_ENTRY_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 9, "map_id": "m" },
  "dialogues": { "d_00": "这一条写成了字符串", "d_01": null } }
；OUT_OF_RANGE_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["这一条锚在 999 秒。"], "options": [] } } }
；UNKNOWN_NPC_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "npc_99_ghost", "lines": ["说话的人不在名册上。"], "options": [] } } }
；UNKNOWN_CLUE_FIXTURE = 
{ "meta": { "schema_version": 1, "case_id": 10, "map_id": "m" },
  "dialogues": { "d_00": { "speaker": "甲先生", "lines": ["给一条没登记的线索。"],
    "options": [ { "text": "（收下）", "add_clue": "clue_01_knots", "goto": "" } ] } } }
；REAL_DIALOGUE_PATH = res://data/dialogues/case_01_dialogues.json；REAL_CLUE_PATH = res://data/clues/case_01_clues.json；ORPHAN_CLUES = ["clue_01_double_knot", "clue_01_keep_stele_motive"]

### `res://tests/test_heart_lamp.gd`

> test_heart_lamp.gd —— 心灯 + 线索双档轮换落盘 测试（Headless，不需要打开编辑器）

- 基类：`SceneTree`；行数 797；私有/内部方法 28 个
- 依赖 Autoload：PersistentMemoryManager
- 信号：无
- 公开方法：无
- 常量：HeartLamp = preload(res://scripts/entities/heart_lamp.gd)；ClueStore = preload(res://scripts/data/clue_store.gd)；MEMORY_SCRIPT = res://scripts/core/persistent_memory_manager.gd；EXPECTED_CHECKS = 173；STORE_FILES = ["user://clue_store.json", "user://clue_store.json.tmp", …

### `res://tests/test_npc_memory.gd`

> 测试：NPC 跨轮记忆（npc_memory.gd）+ 世界状态递进（loop_mutation.gd）—— M1 第③步的唯一空白差异位。

- 基类：`SceneTree`；行数 572；私有/内部方法 15 个
- 依赖 Autoload：PersistentMemoryManager, TimeLoopManager
- 信号：无
- 公开方法：无
- 常量：LoopMutation = preload(res://scripts/entities/loop_mutation.gd)；NpcMemory = preload(res://scripts/entities/npc_memory.gd)；CaseLoader = preload(res://scripts/data/case_loader.gd)；PersistentMemoryManagerScript = preload(res://scripts/core/persistent_memory_manager.gd)；CASE_PATH = res://data/scenarios/case_01_baihu.json；MEMORY_PATH = res://data/npc_memory/case_01_memory.json；EXPECTED_CHECKS = 130

### `res://tests/test_phase1_smoke.gd`

> test_phase1_smoke.gd —— 阶段一冒烟测试（不需要打开编辑器）

- 基类：`SceneTree`；行数 372；私有/内部方法 12 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：TIME_LOOP_SCRIPT = res://scripts/core/time_loop_manager.gd；MEMORY_SCRIPT = res://scripts/core/persistent_memory_manager.gd；TimelineParser = preload(res://scripts/data/npc_timeline_parser.gd)；EXPECTED_CHECKS = 84

### `res://tests/test_runes.gd`

> tests/test_runes.gd —— M1 第 ⑤ 步：辨笔画符（画符输入）的自带断言测试

- 基类：`SceneTree`；行数 1211；私有/内部方法 32 个
- 依赖 Autoload：TimeLoopManager
- 信号：无
- 公开方法：
  - `func prompt_lines_size(input: Node) -> int`
- 内部类：LoopClock, FakeMemory, HasOnly
- 常量：Loader = preload(res://scripts/data/rune_loader.gd)；RuneInput = preload(res://scripts/entities/rune_input.gd)；EXPECTED_CHECKS = 455；RUNE_ID = huizhao_songbei；SIX_CLUES = ["clue_01_four_in_three", "clue_01_half_stroke_cun", "clu…；DRAW_STEP = draw_the_reflection；CHOICE_STEP = no_re_carving；ROOM = baihutai_bei；MIN_LOOP = 8；LOOP_MANAGER_NAME = TimeLoopManager

### `res://tests/test_slice_hud.gd`

> test_slice_hud.gd —— M0 可玩纵切片的无头试玩

- 基类：`SceneTree`；行数 1114；私有/内部方法 31 个
- 依赖 Autoload：PersistentMemoryManager, TimeLoopManager
- 信号：无
- 公开方法：无
- 常量：CaseLoader = preload(res://scripts/data/case_loader.gd)；ClueStore = preload(res://scripts/data/clue_store.gd)；UIPrefs = preload(res://scripts/data/ui_prefs.gd)；HeartLamp = preload(res://scripts/entities/heart_lamp.gd)；SCENE_PATH = res://scenes/main.tscn；STORE_PATH = user://clue_store.json；TMP_PATH = user://clue_store.json.tmp；STORE_PATHS = ["user://clue_store.json", "user://clue_store.json.tmp", …；EXPECTED_CHECKS = 215

### `res://tests/test_title_scene.gd`

> test_title_scene.gd —— 标题界面（scenes/title_scene.tscn）无头测试

- 基类：`SceneTree`；行数 513；私有/内部方法 22 个
- 依赖 Autoload：PersistentMemoryManager, TimeLoopManager
- 信号：无
- 公开方法：无
- 常量：SCENE_PATH = res://scenes/title_scene.tscn；SCRIPT_PATH = res://scripts/ui/title_scene.gd；MAIN_SCENE_PATH = res://scenes/main.tscn；EXPECTED_CHECKS = 57；STORE_PATHS = ["user://clue_store.json", "user://clue_store.json.tmp", …；LAYOUT_SIZES = [(1280, 720), (1600, 900), (960, 540)]

### `res://tests/test_travel.gd`

> test_travel.gd —— 走位耗时自检：map_loader + player_travel + 案一真实数据

- 基类：`SceneTree`；行数 1069；私有/内部方法 33 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：MapLoader = preload(res://scripts/data/map_loader.gd)；PlayerTravel = preload(res://scripts/entities/player_travel.gd)；CaseLoader = preload(res://scripts/data/case_loader.gd)；EXPECTED_CHECKS = 165；MAX_COLLECT_PASSES = 8；VALID_MAP = 
{
  "schema_version": 1,
  "case_id": 1,
  "map_id": "fixture_map",
  "display_name": "夹具地图",
  "rooms": [
    { "room_id": "hall",  "display_name": "厅", "exits": [
      { "to": "ridge", "travel_seconds": 10 },
      { "to": "pond",  "travel_seconds": 40 } ] },
    { "room_id": "ridge", "display_name": "埂", "exits": [
      { "to": "hall",  "travel_seconds": 10 },
      { "to": "pond",  "travel_seconds": 20 } ] },
    { "room_id": "pond",  "display_name": "塘", "exits": [
      { "to": "hall",  "travel_seconds": 40 },
      { "to": "ridge", "travel_seconds": 20 } ] }
  ]
}
；DUPLICATE_ROOM_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 } ] },
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 } ] } ] }
；UNKNOWN_ROOM_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "hal", "travel_seconds": 10 } ] } ] }
；MISSING_EXIT_TO_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "travel_seconds": 10 } ] } ] }
；ZERO_TRAVEL_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 0 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；FRACTIONAL_TRAVEL_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 2.5 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；NEGATIVE_TRAVEL_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": -5 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；SELF_LOOP_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；DUPLICATE_EDGE_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [ { "to": "pond", "travel_seconds": 10 },
                                  { "to": "pond", "travel_seconds": 12 } ] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；NO_EXITS_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m", "rooms": [
  { "room_id": "hall", "exits": [] },
  { "room_id": "pond", "exits": [ { "to": "hall", "travel_seconds": 10 } ] } ] }
；MISSING_ROOMS_MAP = 
{ "schema_version": 1, "case_id": 1, "map_id": "m" }
；WARN_MAP = 
{
  "schema_version": 1,
  "case_id": 1,
  "map_id": "warn_map",
  "rooms": [
    { "room_id": "hall",  "exits": [ { "to": "stub", "travel_seconds": 10 },
                                     { "to": "far",  "travel_seconds": 200 } ] },
    { "room_id": "stub",  "exits": [ { "to": "hall", "travel_seconds": 10 } ] },
    { "room_id": "far",   "exits": [ { "to": "hall", "travel_seconds": 200 } ] },
    { "room_id": "island", "exits": [ { "to": "island2", "travel_seconds": 5 } ] },
    { "room_id": "island2", "exits": [ { "to": "island", "travel_seconds": 5 } ] }
  ]
}


### `res://tools/cli.gd`

> tools/cli.gd —— 项目命令行（工具链第 2 步：状态探针）

- 基类：`SceneTree`；行数 528；私有/内部方法 16 个
- 依赖 Autoload：PersistentMemoryManager, TimeLoopManager
- 信号：无
- 公开方法：无
- 常量：ValidateData = preload(res://tools/validate_data.gd)；Parser = preload(res://scripts/data/npc_timeline_parser.gd)；SCENARIO_DIR = res://data/scenarios；DEFAULT_SCENE = res://scenes/main.tscn；LEGACY_TIMELINE = res://data/npc_timelines.json；GEN_INDEX_SCRIPT = res://tools/gen_index.gd；DEFAULT_SIM_SECONDS = 900.0；SMOKE_TARGET_SECONDS = 3.0；MAX_PROBLEM_LINES = 10

### `res://tools/gen_index.gd`

> tools/gen_index.gd —— 符号索引生成器（工具链第 1 步）

- 基类：`SceneTree`；行数 658；私有/内部方法 21 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：SCAN_ROOTS = ["res://scripts", "res://tools", "res://tests"]；MD_PATH = res://docs/INDEX.md；JSON_PATH = res://docs/index.json；DATA_DIR = res://data；SCENE_DIR = res://scenes

### `res://tools/gen_placeholders.gd`

> gen_placeholders.gd —— 占位图生成器：assets_src/placeholder_manifest.json → PNG

- 基类：`SceneTree`；行数 492；私有/内部方法 23 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：SPEC_DEFAULT = res://assets_src/placeholder_manifest.json；OUT_DIR_DEFAULT = res://assets/placeholder/；TMP_DIR = user://gen_placeholders_check/；README_NAME = README.md；LOG_LIMIT = 18；DRIFT_LIMIT = 10；SIZE_MAX = 2048；BORDER_FACTOR = 0.55；MARKER_DARK_FACTOR = 0.18；MARKER_LIGHT_FACTOR = 1.35

### `res://tools/gen_scene.gd`

> gen_scene.gd —— 场景生成器：场景规格 JSON → .tscn（调用引擎自身的序列化器）

- 基类：`SceneTree`；行数 585；私有/内部方法 22 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：OUT_DIR_DEFAULT = res://scenes/；TMP_PATH = user://gen_scene_check.tscn；LOG_LIMIT = 18；DRIFT_LIMIT = 10

### `res://tools/gen_theme.gd`

> gen_theme.gd —— 主题生成器：assets_src/theme.json → theme/default_theme.tres

- 基类：`SceneTree`；行数 561；私有/内部方法 23 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：无
- 常量：SPEC_DEFAULT = res://assets_src/theme.json；OUT_PATH_DEFAULT = res://theme/default_theme.tres；TMP_PATH = user://gen_theme_check.tres；LOG_LIMIT = 18；DRIFT_LIMIT = 10；FONT_SIZE_MIN = 1；FONT_SIZE_MAX = 512

### `res://tools/shot.gd`

> 表现层截图工具：用【带窗口】的 Godot 跑，把主场景的渲染结果存成 PNG。

- 基类：`SceneTree`；行数 227；私有/内部方法 7 个
- 依赖 Autoload：TimeLoopManager
- 信号：无
- 公开方法：无
- 常量：DEFAULT_SCENE = res://scenes/main.tscn；DEFAULT_OUT = res://.shots/main.png；STORE_PATHS = ["user://clue_store.json", "user://clue_store.json.tmp", …；UIPrefs = preload(res://scripts/data/ui_prefs.gd)；KEY_NAMES（复合值）

### `res://tools/validate_data.gd`

> 数据 schema + 设计不变量校验器（工具链第 4 步）

- 基类：`RefCounted`；行数 884；私有/内部方法 32 个
- 依赖 Autoload：无（完全解耦）
- 信号：无
- 公开方法：
  - `func run() -> Dictionary`
- 常量：Parser = preload(res://scripts/data/npc_timeline_parser.gd)；MapLoader = preload(res://scripts/data/map_loader.gd)；SCENARIO_DIR = res://data/scenarios；CLUE_DIR = res://data/clues；DIALOGUE_DIR = res://data/dialogues；DEDUCTION_DIR = res://data/deduction；RUNE_DIR = res://data/runes；LEGACY_TIMELINE = res://data/npc_timelines.json；ROOM_PATTERN = ^[a-z][a-z0-9_]*$；CLUE_PATTERN = ^(clue|note|sealed)_[a-z0-9]+(_[a-z0-9]+)*$；CASE_FILE_PATTERN = ^case_(\d{2})_[a-z0-9_]+\.json$；MIN_LOOP_SECONDS = 60；MAX_LOOP_SECONDS = 3600

## 3. 数据表

| 文件 | 结构摘要 |
| --- | --- |
| `res://data/npc_timelines.json` | schema=1 map=manor_01 循环=420秒 NPC=2 节点=6 |

## 4. 场景

| 文件 | 根节点 | 节点数 | ext_resource | 生成方式 |
| --- | --- | --- | --- | --- |
| `res://scenes/main.tscn` | `Main` (Node) | 5 | 3 | 生成（勿手改） |
| `res://scenes/title_scene.tscn` | `TitleScene` (Control) | 5 | 1 | 生成（勿手改） |

## 5. 测试

| 测试文件 | 断言数 | 运行命令 |
| --- | --- | --- |
| `res://tests/test_case_loader.gd` | 35 | `godot --headless --path . --script res://tests/test_case_loader.gd` |
| `res://tests/test_deduction.gd` | 263 | `godot --headless --path . --script res://tests/test_deduction.gd` |
| `res://tests/test_dialogue.gd` | 114 | `godot --headless --path . --script res://tests/test_dialogue.gd` |
| `res://tests/test_heart_lamp.gd` | 173 | `godot --headless --path . --script res://tests/test_heart_lamp.gd` |
| `res://tests/test_npc_memory.gd` | 130 | `godot --headless --path . --script res://tests/test_npc_memory.gd` |
| `res://tests/test_phase1_smoke.gd` | 84 | `godot --headless --path . --script res://tests/test_phase1_smoke.gd` |
| `res://tests/test_runes.gd` | 455 | `godot --headless --path . --script res://tests/test_runes.gd` |
| `res://tests/test_slice_hud.gd` | 215 | `godot --headless --path . --script res://tests/test_slice_hud.gd` |
| `res://tests/test_title_scene.gd` | 57 | `godot --headless --path . --script res://tests/test_title_scene.gd` |
| `res://tests/test_travel.gd` | 165 | `godot --headless --path . --script res://tests/test_travel.gd` |

## 6. 工具链命令

| 命令 | 作用 |
| --- | --- |
| `./tools/check.ps1` | 一条命令跑完全部检查（≤20 行输出，全量日志写 `logs/`） |
| `godot --headless --path . --script res://tools/gen_index.gd` | 重新生成本索引（顺带全项目解析检查） |
| `godot --headless --path . --script res://tools/cli.gd -- validate` | 校验数据表（含设计不变量） |
| `godot --headless --path . --script res://tools/cli.gd -- simulate --seconds 420` | 无头模拟整轮循环并输出 JSON |
| `godot --headless --path . --script res://tools/gen_scene.gd -- --spec <规格>` | 由规格重新生成场景 `.tscn` |

