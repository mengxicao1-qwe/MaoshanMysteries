# AGENTS.md —— 项目大脑（改代码前先读这一页）

2D 时间循环推理解密游戏（正式内容《茅山秘录·诡异录》），引擎 **Godot 4.7 + GDScript**；工作目录 `D:\DeepLoopGame`。
一局 = 一轮余页（案一是 **360 秒**，工程默认 420）；玩家在余页里查线索，**线索跨遍永久保留**（品类标配，不是差异化）。
真正的差异点是：心灯（记忆有代价）+ NPC 跨轮记忆/世界状态递进 + 秒级重演；详见 `docs/market/01_立项调研与推荐方案.md`。
所有内容都是数据驱动：NPC 动线、案件、对话、主题、场景树全部来自 JSON。**产品名已改为《茅山秘录·诡异录》（`project.godot` 的 `config/name`），改名已收口；注意 `config/name` 决定 `user://` 目录名，改它会换存档目录。**

## 0. 三条铁律

1. **不许手改生成物。** `scenes/*.tscn`、`theme/*.tres`、`assets/placeholder/*.png` 都是产物。
   要改就改 `scenes_src/*.json` / `assets_src/*.json`，然后重跑 `tools\check.ps1`（本地模式会自动重写）。
2. **不许绕过闸门。** 改完就跑 `tools\check.ps1`，只看最后一行结论。**Godot 的退出码不可信** ——
   GDScript 编译失败时进程照样退出 0（实测踩过，见 README §7.3）。
3. **不许用 PowerShell 的 `Get-Content`/`Set-Content` 读写项目源文件。** 本机只有 Windows PowerShell 5.1，
   它把无 BOM 的 UTF-8 当 ANSI 读 → 中文乱码、文件被毁（`debug_hud.gd`、`test_phase1_smoke.gd` 各毁过一次）。
   必须动文件时用 `[System.IO.File]::ReadAllBytes/WriteAllBytes` 做字节级操作。

## 1. 一条命令验证

```powershell
$env:GODOT_EXE = "$env:TEMP\dsh_godot\Godot_v4.7.2-stable_win64_console.exe"   # 只需给一次
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1            # 本地：自动重写生成物
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1 -Ci        # CI：只校验，漂移即失败
```

18 步 + 1 行结论，退出码 0 才算通过；细节在 `logs\check\<步骤>.log`，**只在失败时才去看**。

## 2. 工具一览（都实现了，别再重造）

| 工具 | 作用 |
| --- | --- |
| `tools/check.ps1` | 18 步闸门（唯一入口），`-Ci` = 只校验 |
| `tools/gen_index.gd` | 生成 `docs/INDEX.md` + `docs/index.json`；`--check` 防过期。**同时是全项目语法检查** |
| `tools/cli.gd` | `validate` / `cases` / `smoke --scene X --frames N [--no-clock]`（`--no-clock` = 标题页这种没有余页钟的场景只验装配）/ `index [--check]` / `dump-state [--start]` / `simulate --seconds N [--clue]` / `new-npc --id X --name Y [--write]` / `help` |
| `tools/validate_data.gd` | 数据 schema + 设计不变量；写错 id 给编辑距离拼写建议（覆盖 scenarios / clues / dialogues / maps / npc_memory / deduction / runes） |
| `tools/gen_scene.gd` | `scenes_src/*.json` → `scenes/*.tscn`（引擎序列化器 + 归一化） |
| `tools/gen_theme.gd` | `assets_src/theme.json` → `theme/default_theme.tres` |
| `tools/gen_placeholders.gd` | `assets_src/placeholder_manifest.json` → `assets/placeholder/*.png` |
| `tools/shot.gd` | **画面截图**（M2 起）：`--scene` / `--out` / `--seconds` / `--room` / `--after` / `--keys` / `--keys2` / `--scale` / `--prefs fresh\|seen` / `--open tutorial\|settlement`（后两个用来拍引导/结算弹窗）；**必须用带窗口的引擎跑**（`--headless` 存出空图），开跑前把 `user://` 的 `clue_store.json` 四件套 + `ui_prefs.json` 做字节快照、结束原样还回去（截图不许动玩家的档） |
| `tools/snapshot.ps1` | **里程碑快照与漂移清单**（本机没有 git、也装不上：`winget install Git.Git` 下载 GitHub 超时 `0x80072efd`）：`-Note "说明"` 把源码/数据/文档/工具打包成 `.backups/snapshot-*.zip` 并写哈希清单 `.backups/last-manifest.txt`（**幂等：只读，不改项目文件**）；`-Diff` 列出相对上一个快照改了/新增/删除哪些文件；`-List` 列快照。大改前先打一份 |
| `tools/gen_index.gd` / `tools/fix-ps1-bom.ps1` | 索引；给 `.ps1` 补 UTF-8 BOM（**编辑过含中文的 .ps1 后必跑** `-All`） |

测试（全部 `extends SceneTree`、末行唯一 `RESULT:`、自带"执行数不足即 FAIL"守护）：

| 测试 | 覆盖 |
| --- | --- |
| `tests/test_phase1_smoke.gd` | 84 项：核心三件套（倒计时/倍速/暂停/强制重放/线索去重/只读快照/跨遍保留） |
| `tests/test_case_loader.gd` | 35 项：案件装载器（正常/可疑/结构性错误 三组夹具） |
| `tests/test_heart_lamp.gd` | 173 项：心灯（重开 -8、每秒 -0.02、结案 +25、离线每分钟 +1、归零丢一条记忆、熄灯期间重开再划一笔）+ 双档轮换落盘/损坏档恢复/崩溃现场 |
| `tests/test_slice_hud.gd` | 215 项：纵切片试玩（装载/走位耗时/取线索/跨遍保留/遗忘/快速点亮后找回/快进/结案门槛/对话追问/世界递进/跨轮记忆/推演板矛盾高亮/卡关预警/一键重演/画符结案/**画面层接线**/**心灯代价预告**/**观察点遍数锁**/**首次引导弹窗**/**结案结算与重新开始**/**日志不许出现开发信息**），真实例化 `scenes/main.tscn`；**自带干净起跑**（先删 `user://` 存档 + `ui_prefs.json` 再跑，结束时逐字节还原） |
| `tests/test_title_scene.gd` | 57 项：标题界面（装配/文案与字体覆盖/三档窗口版面比例/无写死坐标/源码卫生/回车空格即点击/按钮悬停/真跳主场景 `res://scenes/main.tscn`） |
| `tests/test_dialogue.gd` | 114 项：对话层（解析/查询/锚点与窗口/错误与警告分类/线索交叉引用/两条孤儿线索可达） |
| `tests/test_travel.gd` | 165 项：走位图与耗时（连通性/schema/最短路/走位状态机/精确子集 DP 算"最少几遍"）；顺带断言 `baihutai` 出发的 17 间房连通性（页外 `off_page` 除外） |
| `tests/test_npc_memory.gd` | 130 项：NPC 跨轮记忆与世界状态递进（台阶式规则/`loop_reset` 清理/`grow` 与 `shrink` 两种模式/无头依赖注入） |
| `tests/test_deduction.gd` | 263 项：推演板（10 推论 / 6 矛盾 / 6 卡关提示、卡面中文名、逐步解锁、矛盾点亮与收束排序、`board_lines` 截断、五组错误夹具、深拷贝与 `free()` 卫生） |
| `tests/test_runes.gd` | 459 项：画符输入（真数据装载/线索交叉引用/三道门槛/三笔按数据画对/三条近似笔 hint 原文/退笔/选项不推进/整套仪式完成/`loop_reset` 清状态/5 组错误夹具 + 1 组 warning 夹具） |

## 3. 省 token 的开发循环

1. 读 `docs/INDEX.md`（全项目符号索引：类、公开方法签名、信号、常量、Autoload 依赖）——**不要**挨个 read 源文件。
2. 改代码 / 数据。
3. 跑闸门（一条命令，十行输出）。
4. 只有失败才 `read logs\check\<步骤>.log` 的相关几行。

## 4. Godot 4.7 已知坑（全部实测踩过）

* `JSON.get_error_column()` **不存在** → 用 `get_error_line()`（0 基，要 +1）+ `get_error_message()`。
* `RegEx.compile()` 返回的是 `Error` 枚举 → 不能链式 `re.compile(p).search(s)`（`Parse Error: Cannot call function on enum value.`）。
* `var x := <Variant 表达式>` 是**编译错误**（4.7 默认把 `INFERENCE_ON_VARIANT` 当错误）→ 写 `var x: Variant = …`。
* 全局 `class_name` 依赖编辑器生成的类缓存 → 刚 clone、没开过编辑器时不可用。工具与测试一律 `preload()`。
* 内部类（`ParseResult` 等）做参数/返回值时，反射只报原生基类 `RefCounted` → 索引工具改为从源码文本取声明类型。
* **`JSON.parse` 把所有数字都解析成 float**：读一份 `420`/`25` 再 stringify 回磁盘会变成 `420.0`/`25.0`（整表假 diff）。
  任何 JSON 往返落盘前必须过 `cli.gd` 里的 `_ints_back()`（整数值的 float 还原成 int，真浮点如 `0.05` 保留）。
* **`time_updated(current_second)` 广播的是【剩余】秒数**（倒计时口径 360 → 0，`_last_second = ceili(_remaining)`），
  不是已过秒数。表现层要"现在是第几秒"一律用 `TimeLoopManager.get_elapsed_seconds()` ——
  拿信号参数当绝对秒比拍点，会导致**永远取不到线索**（M0 试玩实测抓出来的）。
* **`--check-only --script` 对引用 Autoload 的脚本会误报**：报 `Identifier not found: PersistentMemoryManager` /
  `TimeLoopManager`（该模式不注册 Autoload）。`--check-only` 只适合不引用 Autoload 的工具/测试脚本；
  表现层脚本必须"真跑场景"（闸门第 4 步 smoke 或 `tests/test_slice_hud.gd`）才算验证。
* **`DirAccess.rename_absolute()` 在 Windows 上不是原子的**：Godot 的 `DirAccessWindows::rename` 对已存在的目标
  先 `remove(new_path)` 再 `MoveFileW` ⇒ 两步之间崩溃/掉电会**整档丢失**。任何存档都不许"自己 rename 覆盖"，
  一律走 `scripts/data/clue_store.gd` 的双档轮换（写 `.tmp` → 主档转 `.bak` → `.tmp` 转主档；读取时主档 → `.tmp` → `.bak`，
  主档损坏先另存 `.corrupt`）。
* **`edit` 工具改 `.ps1` 会抹掉 UTF-8 BOM** ⇒ 每次改完 `tools\*.ps1` 都要跑 `tools\fix-ps1-bom.ps1 -All` 确认（报告 `0 file(s) repaired` 才算干净）；README/AGENTS 是 `.md`，没关系。
* **函数缩进错一层 = 整个脚本 Parse Error**：`rune_loader.gd` 里一个 `func` 被多缩进了一个 tab，报的却是
  `Parse Error: Standalone lambdas cannot be accessed`（不是"缩进错误"），连锁让 `preload` 它的脚本全挂、
  表现层跟着 Parse error。改完大文件先跑 `--check-only`（约 300ms），比等闸门快得多。
* **删除"注释与 `func` 之间的空行"会把函数变成注释**：`edit` 时若把 `## 说明。` 与 `func x():` 并成一行，
  报的是 `Function "x()" not found in base self` / `Cannot return value of type "null"` 之类**连锁错误**，
  罪魁却是那一行。改完大文件同样先 `--check-only`。
* **SceneTree 工具脚本里 `add_child()` 不会立刻触发 `_ready()`**（要等第一帧）⇒ 脚本里 `add_child(scene)` 之后
  立刻 `hud.call("request_travel", …)` 或改倍速，表现层还没装配完，调用会静默落空（`_travel == null` 时走的是
  "没有地图就瞬移"的调试兜底）。**必须在 `add_child()` 之后先 `await process_frame` 两次**（见 `tools/shot.gd`）。
* **`@onready` 变量在兄弟节点 `_ready()` 里还是 null**：`play_view.gd` 在 `_ready()` 里调
  `slice_hud.set_text_hud_visible(false)` 时，SliceHUD 的 `@onready var _label` 还没赋值 ⇒ setter 静默无效。
  跨节点初始化要**延到第一帧再确认生效**（`_process()` 里"没生效就再设一次"，生效后停手，别每帧抢用户的开关）。
* **截图必须用带窗口的引擎**：`--headless` 没有渲染器，`root.get_texture().get_image()` 存出来是空图。
  带窗口跑会真的开一个窗口（本机 OpenGL 3.3 可用），产物放 `.shots/`（不进闸门）。
* **跑过的存档会被心灯扣血**：`tools/shot.gd` 与 `tests/test_slice_hud.gd` 都必须自己做存档字节快照并在结束时还原；
  测试还要**先删档再跑**（否则玩家自己玩过的档会让断言漂移 —— 实测踩到"灯只剩 7 点"导致 3 条断言假红）。
* 工具脚本约定：`extends SceneTree` + `_initialize()` + `quit(code)`，**不写 `class_name`**，最后一行打印唯一一行 `RESULT: ...`。
* **`stretch/mode="canvas_items"` 下 `Control.size` 会跟着窗口走**（不是永远 1280×720）：本机实测 `--resolution 1600x900` 时 PlayView 的 `size` 就是 1600×900 ⇒ **表现层版面不许写死常量**，一律按 `size` 现算（v1 的坑：右侧面板固定在 x=940，1600 宽的窗口里就停在屏幕中间）。
* 快速语法检查：`godot --headless --path . --check-only --script res://tools/xxx.gd`（约 300ms）。

## 5. 场景规格（`scenes_src/*.json`）约定

* 节点：`{type, name, script?, props?, children?}`；`type` 必须过 `ClassDB.class_exists()`，拼错直接报错退出。
* `props` 的键原样交给 `Node.set()`，所以 `theme_override_font_sizes/font_size` 这类子路径天然可用。
* 值：JSON 原生类型直接用；字符串若能被 `str_to_var()` 解析成非 String 的 Variant（`"Color(0.92,0.94,1,1)"`、
  `"Vector2(10,20)"`、`"NodePath(\"../X\")"`）就用解析结果，否则保持字符串（中文安全）。
* `--check` 在 `user://` 里生成并与磁盘逐字节比对：`uid="uid://…"`、`unique_id=` 被剥离，`ext_resource` id 归一化成
  `1_0/1_1`…… ⇒ **同一份规格产出同一份字节**，uid churn 不会误报漂移。
* 闸门里的场景路径是硬编码的（`tools/check.ps1`：`res://scenes/main.tscn` + `res://scenes_src/main.json`，
  以及标题页那两步 `res://scenes/title_scene.tscn` + `res://scenes_src/title_scene.json`），
  换表现层脚本不用动闸门；但 smoke 跑在重生成之前 ⇒ **改了场景规格要连跑两次本地闸门**。
* **启动场景是 `res://scenes/title_scene.tscn`**（`project.godot` 的 `run/main_scene`）：`TitleScene` → 标题/副标题/小字/「【开始推演】」
  四行（版面按 `size` 现算，字号取基准比例 + 上下限），点按钮或回车/空格 `change_scene_to_file()` 进主场景。
* 主场景 `res://scenes/main.tscn` = `Main` → `PlayView`（M2 画面层，`mouse_filter 0` 吃鼠标）→ `SliceHUD`（`mouse_filter 2`，文字层 + `InfoLabel`）
  → `OverlayUI`（弹窗层，根本身 `mouse_filter 2`，只有弹窗开着时才用全屏 `ColorRect` 吃鼠标）。
  PlayView 必须排在 SliceHUD **前面**（后画的在上）；OverlayUI 排最后（弹窗盖住一切）。

## 6. 分层与所有权（不要越界）

* `scripts/core/`（`time_loop_manager.gd`、`persistent_memory_manager.gd`）与 `scripts/data/npc_timeline_parser.gd`
  **已冻结**：接口见 README §2；核心层**零 UI/场景引用**，不许用 `Engine.time_scale`，不许删线索接口。
* `scripts/data/case_loader.gd` = 案件装载器（`CaseData` / `NPCSchedule` / `TimelineNode` + 查询与校验），M0 已用（`TimelineNode.loop_min` = **观察点遍数锁**：站在对的地方、时辰也对，遍数不到就是看不见；数据在 `data/scenarios/*.json` 的节点上写，闸门用 `tools/validate_data.gd` 校验）。
* `scripts/data/dialogue_loader.gd` = 对话层（M1 ①）：读 `data/dialogues/case_01_dialogues.json`，
  **秒级锚定只认场景节点 `npcs[].timeline[].{second, dialogue_id}`**（条目自己没有 `second`）；
  `speaker` 是中文显示名，按场景的 `display_name ↔ npc_id` 解析；`add_clue` 是"对话→线索"的唯一出口，
  **去重责任在 `heart_lamp.add_clue()` / `PersistentMemoryManager`（`clue_store.gd` 只管落盘）** —— 这三条是 ① 的契约裁定。
  注意 `is_active_at()` 是**严格窗口**（只认锚点那一秒），表现层要"这个人待在这间屋的整段时间"得自己按下一个拍点算宽窗口
  （HUD 的 `_talk_windows()` 就是这么做的，裁定见 `docs/story/09` §9.1）。
* `scripts/data/map_loader.gd` = 走位图（M1 ②，`RoomMap` 内部类 + Dijkstra 最短路）；`data/maps/case_01_map.json`
  是有向边、整数秒、每间房带 `"pos": [x, y]`（表现层画台子用）；`"external": true` 的房间（案一 `off_page`）**故意走不到**，不算漏边。
* `scripts/data/rune_loader.gd` = 仪式数据装载（M1 ⑤）：`RuneTable` / `RuneEntry` / `RuneStep` / `RuneStroke` / `RuneNearMiss` / `RuneOption`；
  一笔 = 一串 8 向 token，判定只比**笔数与每笔方向串**（不比手速/长度/曲线）⇒ 键鼠与手柄同一套数据。
* `scripts/entities/` = 玩法组件（都不引用 Autoload，靠注入，便于无头测试）：
  `heart_lamp.gd`（心灯：重开 -8、余页内每秒 -0.02、结案 +25；数值随 `clue_store.gd` 的 `save_lamp_state()/load_lamp_state()` 落盘，含 `seen_unix` ⇒ 离线现实时间每分钟 +1 由 `apply_offline_recovery()` 补，规格见 `docs/story/09:175`）、
  `player_travel.gd`（走位耗时状态机：`start_move()`/`tick(delta)`，由余页时钟驱动而非帧 delta）、
  `loop_mutation.gd`（余页异变：每遍环境痕迹 `grow`/`shrink`）、`npc_memory.gd`（NPC 跨轮记忆台阶，`get_effects()` 的 `extra_dialogue_id`/`reveal_clue_id` 由表现层执行）、
  `deduction_board.gd`（推演板：推论/矛盾/卡关提示；`board_lines(n)` 截断后恰好 n 行）、
  `rune_input.gd`（画符状态机 idle/step/drawing/done；`commit_stroke()` 判一笔、`choose_option()` 选项、`advance()` 推进。
  **draw 步三笔全对后不自动推进，要表现层调 `advance()`**；喂 token 前必须处于 drawing（表现层用"没在 drawing 就先 `begin_stroke()`"兜住）；
  choice 步选对后才放行 `advance()`；`can_start()`/`start_rune()` 每次现算线索，别拿旧快照）。
  `scripts/data/clue_store.gd` = 崩溃安全落盘（双档轮换 `.tmp`/`.bak` + 损坏档另存 `.corrupt`，**不要绕过它自己写存档**，理由见 §4 的 rename 坑）。
* `scripts/ui/` = 表现层：
  * `slice_hud.gd` = **M0 纵切片 → M1 玩法层**（键盘唯一入口：TAB/E/Q/1–9 走去别的房间——**按 `data/maps` 的最短路一段一段走，要花余页里的秒数**；
    `F` 和同屋的人交谈（对话是线索第二个来源，选项带 `goto` 自动接着追问）；`B` 推演板（矛盾高亮与卡关提示）；`H` 一键重演上一遍路线；
    `G` 画符（方向键描一笔、斜向小键盘 1/3/7/9、回车落笔/推进、退格退、`1`–`5` 选一个）；空格快进到下一拍点、T 倍速、P 暂停、R 重开一遍；
    `` ` `` 文字 HUD 开关；线索到点自动入账，无需按键）。
    它同时是**表现层的状态源**：`present_state()` 把这一帧该画什么整包交出去，`request_travel(_talk/_option/_board/_rune/_reset)` 是外部唯一允许的动作入口。
  * `play_view.gd` = **M2 画面层 v2：自适应网格布局**（纯渲染 + 鼠标，没有用任何 PNG 美术）：
    版面**全部按 `size` 现算**（1280×720 只是基准 —— v1 把 `STAGE_W/PANEL_X` 写死，窗口一变右侧面板就停在屏幕中间、中心几间房糊成一团）；
    房间牌子不再直接用 `data/maps` 的 `pos`，而是"种子 → 网格吸附 → 逐个占格"（`_pick_grid()` / `_nearest_free_cell()`）：每间房独占一格、格子按房间数与画布现算，
    构造上保证相邻牌子中心距 ≥ `MIN_GAP`(120px) 且零重叠；连线先画（等价 z_index 更小），画面上所有文字过 `_text_chip()` 带半透明黑底；
    画顶栏（余页时钟/心灯/结案进度）、右侧面板（线索/推演板/卡关提示/记忆阶）、左下日志、对话框（选项可点）、画符面板、按键提示。
    右侧面板是**真容器**（`PanelContainer > ScrollContainer > VBoxContainer > Label`，自动换行、超高可滚），字号 `F_TINY 11 / F_SMALL 12 / F_BODY 14 / F_TITLE 16 / F_HERO 22`。
    **它不许自己判玩法**：只读 `present_state()`、只调 `request_*`；键盘一律留给 SliceHUD（它只吃鼠标）。
    布局不变量由 `debug_info()` 的 `min_gap`/`overlaps`/`cols`/`rows`/`chips`/`side_panel` 兜底（`tests/test_slice_hud.gd` 第 13 节断言）。
  * `overlay_ui.gd` = **弹窗层**（M3 起，`OverlayUI` 节点）：首次进游戏的「余页初记」引导（30 秒真实时间自动关，不再弹）
    与达成结案六环后的「此案已结」结算（用了几遍 / 余页内耗时 / 心灯 / 入案线索 + 「重新开始」「留在此页」）。
    弹窗**一律用真 Control**（`PanelContainer > VBoxContainer > Label/Button`）——真节点能白拿项目默认主题的中文字体与自动换行。
    动作只走 `hud.call("request_restart_case")` 这一个入口；引导的 30 秒倒计时走 `_process` 的真实时间、**不暂停余页钟**。
  * `title_scene.gd` = **标题页**（`scenes/title_scene.tscn`，启动场景）：不引用任何 Autoload、不跑余页钟，
    只在点「【开始推演】」时 `change_scene_to_file("res://scenes/main.tscn")`；背景与朱砂印都是 `_draw()` 图元。
  * `debug_hud.gd`（阶段一调试 HUD）**已删除**（Phase 3 清调试痕迹，全项目无引用）。
* `data/**` = 唯一的数据来源；正式案件数据契约见 `docs/story/09_系统映射与数据规格.md`（§9 = M1 实现期定下的接口口径：对话秒级锚定 / 线索入账幂等责任 / 画符输入）。

## 7. 当前状态与下一步

* 立项结论（2026-09 调研，已定稿）：`docs/market/01_立项调研与推荐方案.md`（推荐：**中文民俗志怪 + 短篇叙事解谜，首作一案、3–4 小时、¥38、9 个月**；不建议以西式庄园时间循环作首作）
  与 `docs/business/一人公司Steam商业路径.md`（定价/愿望单转化/退款与 AI 披露风险）。改玩法或换题材前先读这两份。
* 已完成：阶段一核心三件套（84/84）+ 工具链 + 案一数据（`validate` 0 错误 0 警告）+ 心灯与落盘（173/173，含离线现实时间恢复）+ M0 可玩纵切片。
* **M1 玩法层五步全部落地，闸门 18/18 本地与 `-Ci` 双通过（≈34s）**：
  * ① 对话层 ✅ `scripts/data/dialogue_loader.gd`（114 项）+ HUD `F` 交谈接线（案一 2 条只能靠对话拿的线索已可达）。
  * ② 走位耗时 ✅ `scripts/data/map_loader.gd` + `scripts/entities/player_travel.gd`（165 项）+ HUD 走位接线
    （17 间房 57 条有向边；**走位耗时不是瓶颈**，但必需线索有遍数锁：6 条里 4 条要第 2–4 遍才看得见（`loop_min`），再叠加 `require_min_loop=8`）。
  * ③ 跨轮记忆与世界状态 ✅ `scripts/entities/loop_mutation.gd` + `scripts/entities/npc_memory.gd` + `data/npc_memory/case_01_memory.json`（130 项）+ HUD 显示与 `reveal_clue_id` 落地。
  * ④ 推演板与矛盾高亮 ✅ `scripts/entities/deduction_board.gd` + `data/deduction/case_01_deduction.json`（263 项）+ HUD `B` 摊开、
    未收束的矛盾自动置顶、`H` 一键重演上一遍路线（对应 `docs/market/01` §2.5 的"死法 1 / 死法 3"）。
  * ⑤ 画符输入 ✅ `scripts/data/rune_loader.gd` + `scripts/entities/rune_input.gd` + `data/runes/case_01_runes.json`（459 项）+
    HUD `G` 画符；`require_ritual` 从"只显示"变成**结案硬门槛**（数据读不进来时放行，不锁死玩家，对应"死法 5"）。
  * 纵切片试玩 **215/215** 把五步串成一条真流程（走位 → 对话追问 → 跨轮记忆 → 推演板 → 画符结案 +25），并断言画面层真的接到了状态源、**布局不变量成立**（牌子中心距 ≥120px、零重叠、右侧面板是真容器）。
* **M2 第一版：画面层已落地**（`scripts/ui/play_view.gd` + `tools/shot.gd` 截图管线）——房间/路/人画在图上了，
  鼠标点房间就走、点同屋的人就说话、对话框选项可点；文字 HUD 默认收起（`` ` `` 叫回来）。截图产物在 `.shots/`。
* **M3 可玩 Demo 收口（Phase 2/3）**：标题页 `scenes/title_scene.tscn`（启动场景）✅、首次进游戏 30 秒引导「余页初记」✅、
  结案六环达成后的「此案已结」结算（用了几遍 / 余页内耗时 / 心灯 / 入案线索 + 重新开始＝清档重载场景）✅、
  调试痕迹清理 ✅（删 `debug_hud.gd`；「地图读入/地图警告/数据警告」降级为 stdout `print`，游戏内日志只留玩法事件；
  下一处拍点改中文房名、滤掉走不到的页外；遍数一律 1 基；按键提示行不再暴露 `` ` `` 文字 HUD）。
  画面层实拍 + 浏览器（WASM）实跑均已验证。
* **M2 平衡与节奏**：心灯 `DRAIN_PER_SECOND` 0.05 → 0.02（重开 -8 不动，`docs/story/04:1056` 的跨案预算原样有效）；观察点遍数锁进数据（`loop_min`：四字位 2、拓本残纸 2、半笔寸 3、灰布袋 4）。
* 下一步（M2 候选，尚未排期）：正式美术/UI 与音频接入（现在全是 `_draw()` 图元）、NPC 立绘与 2D 走位实体、
  存档与设置界面、案一以外内容量、`docs/market/01` §3 里程碑表。
* **版本控制**：本机没有 git（`winget install Git.Git` 卡在 GitHub 下载 `0x80072efd`，装不上）⇒ 用 `tools/snapshot.ps1` 打里程碑快照 + `-Diff` 看漂移；当前绿状态已快照 `.backups/snapshot-20261016-084932-M3_标题页_新手引导_结案结算_清调试痕迹.zip`（139 个文件 / 926 KB，18/18 闸门本地与 `-Ci` 双绿）。CI 就是闸门的 `-Ci` 模式（只校验、漂移即失败），日志在 `logs\check\`。
  产品名已改为《茅山秘录·诡异录》（2026-10 收口）。
