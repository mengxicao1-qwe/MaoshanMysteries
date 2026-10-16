# 《茅山秘录·诡异录》Maoshan Mysteries

2D 时间循环推理解密游戏 · **阶段一：项目初始化与核心架构**

引擎：**Godot 4.x（GDScript）** ｜ 玩法：微型封闭空间（1 个庄园）· 6 名 NPC · 固定 **7 分钟（420 秒）** 时间循环
核心驱动：**数据驱动**（NPC 动线 = JSON 数据表；对话树与时空状态后续同理）

> **内容方向提示**：`docs/story/`（由另一个会话产出）把这套核心系统扩写成了正式游戏
> **《茅山秘录·诡异录》**（五卷十案，道士主角「辨笔」查诡异事件）。其中
> `docs/story/09_系统映射与数据规格.md` 是**数据契约**：每案一个 `data/scenarios/case_NN_*.json`，
> 唯一新增玩法组件是 `scripts/entities/heart_lamp.gd`（心灯）。它明确要求不改动
> `scripts/core/` 三件套 —— 也就是说阶段一的代码被直接复用。
>
> **当前进度**：阶段一（庄园晚宴原型）✅ → 工具链 18 步闸门 ✅ → **M0 纵切片**（正式案一《白鹄不举》
> 已落地：`data/scenarios/case_01_baihu.json`：360 秒 / 17 房间 / 8 NPC / 35 节点 / 10 处线索）✅ →
> **M1 玩法层**五步全部接线并通过无头验收：① 对话层（`F` 交谈）② 走位耗时（按地图一段一段走）
> ③ NPC 跨轮记忆与世界状态递进 ④ 推演板与矛盾高亮（`B`）⑤ 画符结案（`G`）→
> **M2 第一版画面层**：`scripts/ui/play_view.gd` 把白鹄台画出来了（房间/路/NPC 棋子/对话框/推演板/画符面板；**v2 自适应网格布局**：牌子按格子排、间距 ≥120px、右侧面板用 VBoxContainer 自动排版、版面跟着窗口大小走），
> **鼠标点房间就走、点同屋的人就说话**；文字 HUD 默认收起（`` ` `` 叫回来）。截图工具 `tools/shot.gd`（产物在 `.shots/`）→
> **M3 可玩 Demo 收口**：启动场景是**标题页**「茅山秘录 · 诡异录 / 第一案 · 白鹄不举 / 【开始推演】」（`scenes/title_scene.tscn`）→
> 首次进游戏弹 30 秒「余页初记」引导（核心规则 + 键位 + 鼠标操作，可关、只看一次）→ 达成结案六环时弹「此案已结」
> 结算（用了几遍 / 余页内耗时 / 心灯 / 入案线索 + 「重新开始」清档重来）；同时清掉全部调试痕迹（删 `debug_hud.gd`、
> 开发日志改走 stdout、拍点提示说人话、遍数一律 1 基）。
> 主场景可直接试玩（`scripts/ui/slice_hud.gd`，215 项无头试玩断言），心灯与崩溃安全落盘 173 项断言（含离线现实时间恢复），标题页 57 项断言。
> 立项结论见 `docs/market/01_立项调研与推荐方案.md`。产品名已改为《茅山秘录·诡异录》（`project.godot` 的 `config/name`；注意它决定 `user://` 目录名 = 存档目录）。

---

## 1. 目录结构

```
DeepLoopGame/
├── project.godot                     # Godot 4 项目配置（含 Autoload 注册、全局主题）
├── icon.svg / .gitignore
├── AGENTS.md                         # ★ 项目大脑：铁律 / 一条命令验证 / 已知坑（改代码前先读）
├── data/                             # ★ 唯一的数据来源
│   ├── npc_timelines.json            # 阶段一示例动线（2 名 NPC × 3 个节点）
│   ├── scenarios/case_01_baihu.json  # ★ 案一《白鹄不举》：360 秒 / 17 房间 / 8 NPC / 35 节点
│   ├── clues/case_01_clues.json      # 线索登记表（14 条）
│   └── dialogues/case_01_dialogues.json  # 对话登记表（38 条）
├── scenes/title_scene.tscn            # ★ 启动场景：标题页（生成物，勿手改）
├── scenes/main.tscn                  # 主场景（生成物，勿手改）
├── scenes_src/main.json              # ★ 主场景的唯一事实来源（Main → PlayView → SliceHUD → OverlayUI）
├── scenes_src/title_scene.json       # ★ 标题页的唯一事实来源（TitleScene → 标题/副标题/小字/【开始推演】）
├── scripts/
│   ├── core/                         # 核心层（已冻结）：time_loop_manager.gd / persistent_memory_manager.gd
│   ├── data/                         # npc_timeline_parser.gd / case_loader.gd（案件）/ clue_store.gd（双档轮换落盘）/ dialogue_loader.gd / map_loader.gd / rune_loader.gd / ui_prefs.gd（引导看过没）
│   ├── entities/                     # heart_lamp.gd（★ 心灯）/ player_travel.gd / loop_mutation.gd / npc_memory.gd / deduction_board.gd / rune_input.gd
│   └── ui/                           # slice_hud.gd（★ M1 玩法层纵切片）/ play_view.gd（M2 画面层）/ overlay_ui.gd（引导+结算弹窗）/ title_scene.gd（标题页）
├── tests/                            # 10 个无头测试：84 + 35 + 173 + 215 + 57 + 114 + 165 + 130 + 263 + 459 项断言
├── tools/                            # 闸门 + 生成器 + 校验器 + CLI（见 §7）
├── docs/INDEX.md + docs/index.json   # 符号索引（生成物）；docs/story、docs/market、docs/business
└── theme/ + assets/placeholder/      # 生成物（来自 assets_src/*.json）
```

---

## 2. 核心架构

### 2.1 分层与依赖方向

```
        ┌──────────────────────────┐        ┌───────────────────────────┐
        │  表现层 (scripts/ui)      │        │  玩法层 (scripts/entities) │
        │  play_view / overlay_ui  │        │  NPC 控制器 / 玩家         │
        └────────────┬─────────────┘        └─────────────┬─────────────┘
                     │  只允许"向下"依赖：订阅信号 / 调用公开 API
        ┌────────────▼─────────────────────────────────────▼─────────────┐
        │  核心层 (scripts/core)   +   数据层 (scripts/data)             │
        │  TimeLoopManager / PersistentMemoryManager / NPCTimelineParser │
        │  ★ 核心层不引用任何 UI、场景节点、NPC 实例 —— 可无头测试         │
        └────────────────────────────────────────────────────────────────┘
```

* **核心层不反向依赖任何东西**：时间与记忆通过**信号**广播状态，UI/玩法订阅即可。
  因此核心脚本可以脱离场景树单独 `new()` 出来做单元测试（见 `tests/`）。
* **两个 Autoload 脚本刻意不写 `class_name`**：否则会与同名自动加载单例冲突
  （GDScript 报错 `Class "X" hides an autoload singleton`）。解析器是普通类，所以正常用 `class_name`。

### 2.2 TimeLoopManager（时间循环控制器）

| 成员 | 说明 |
| --- | --- |
| `signal time_updated(current_second)` | 每秒回调一次，`current_second` = **剩余秒数**（420 → 0）。高倍速下一帧跨越多秒时会逐秒补发，订阅者不漏拍 |
| `signal loop_reset` | 一轮循环结束。**契约**：触发时时钟已停、剩余秒数已清零，下一轮尚未开始 —— 订阅者在此清理"仅属于上一轮"的世界状态 |
| `signal loop_started(loop_index)` | 新一轮开始，`loop_index` 从 0 递增（可用于第 N 轮剧情差分） |
| `signal loop_timeout` | 时间自然耗尽（区别于玩家死亡等强制重置） |
| `signal pause_changed(is_paused)` | 暂停状态变化 |
| `start_loop()` | 开始/重开当前编号的循环 |
| `trigger_loop_reset()` | **强制清零重置**：清零 → 广播 `loop_reset` → `loop_index += 1` → 新一轮 |
| `tick(delta)` | 推进时钟（`_process` 调用；测试与调试可直接调用，保证逻辑与引擎解耦） |
| `set_time_scale(x)` / `get_time_scale()` / `pause_loop()` / `resume_loop()` / `toggle_pause()` | 时间流速缩放（0 ~ 200 倍，越界自动钳制）与暂停 |
| `get_loop_duration()` | 读取当前循环长度（引导层据数据表设定后可用） |
| `get_remaining_seconds()` / `get_elapsed_seconds()` / `get_progress_ratio()` / `get_loop_index()` | 只读查询 |

> **时间语义**：`remaining` 从 420 → 0（UI 时钟用它）；`elapsed` 从 0 → 420（**NPC 动线 JSON 的 `second` 用它索引**）。
> `time_scale` 只影响游戏内时钟，**不使用** `Engine.time_scale`（后者会连带改变物理与动画速度）。

### 2.3 PersistentMemoryManager（跨循环记忆 / 线索）

| 成员 | 说明 |
| --- | --- |
| `add_clue(clue_id, source_loop := -1) -> bool` | 解锁线索；`true` = 本次新解锁，`false` = 已存在（幂等） |
| `has_clue(clue_id) -> bool` | 是否已解锁（对话选项/交互解锁条件查它） |
| `has_all_clues(ids) -> bool` | 是否集齐一组线索（真相结局判定） |
| `get_clues() -> Array[String]` | 返回**副本**，外部无法篡改内部数据 |
| `get_clue_record(clue_id)` | 元数据（来自第几轮、解锁顺序） |
| `get_save_data()` / `apply_save_data()` | 存档数据转换（字段页，落盘留到后续阶段） |
| `reset_for_new_game()` | **唯一**清空入口，仅开新档/调试可用 |

> ★ **铁律**：该管理器**不订阅**任何循环信号，也**没有**被重置的路径，
> 因此无论循环重置多少次，玩家已获得的线索都不会丢失（`tests/` 有专项断言）。

### 2.4 NPCTimelineParser（数据层）

* `NPCTimelineParser.load_from_file(path := "res://data/npc_timelines.json")` → `ParseResult`
* `NPCTimelineParser.parse_text(text, label)` / `parse_dictionary(dict, label)` → 便于单元测试与存档注入
* 返回的 `ParseResult` 含 `ok / errors / warnings / npcs / npc_order / loop_duration_seconds`；
  **调用方必须检查 `ok`**，错误绝不静默吞掉。
* `ParseResult.npcs[npc_id]` → `NPCSchedule`，其核心方法是
  `node_at(second)` / `room_at(second)` / `node_index_at(second)`：
  **返回最后一个 `second <= 参数` 的节点**（未列出的时段沿用最近一个已生效的状态）。

---

## 3. 数据表格式（data/npc_timelines.json）

```jsonc
{
  "meta": {
    "schema_version": 1,
    "map_id": "manor_01",
    "loop_duration_seconds": 420,          // 权威循环长度，引导层据此设定 TimeLoopManager
    "rooms": ["hall", "kitchen", "..."]     // 已知房间 ID：未知房间只报警告
  },
  "npcs": [{
    "npc_id": "npc_01_butler",             // 唯一 ID（重复会报错并保留首个）
    "display_name": "执事·塞巴斯",
    "default_room": "hall",                // 首个节点生效前的位置
    "timeline": [{
      "second": 0,                         // 本轮已流逝秒数，0 <= second < loop_duration
      "room": "kitchen",                   // 必填
      "action": "prep_wine",               // 行为标识，由 NPC 控制器解释执行
      "facing": "east",                    // 可选，表现层用
      "dialogue_id": "butler_00_prep_wine",// 可选，对话树入口（后续阶段的 dialogue JSON）
      "clue_id": "",                       // 可选，首次目击解锁的线索 ID
      "note": "策划备注"                    // 可选，运行时不用
    }]
  }]
}
```

**开发期校验规则**（`errors` 会让 `ok = false`，`warnings` 只提示）：
缺 `npc_id` / `npcs` 为空 / `timeline` 为空 / `second` 越界或为负 / 同一 NPC 同一秒重复 / `room` 缺失 /
`schema_version` 高于解析器支持版本 → **错误**；节点未按 `second` 升序（会自动重排）/ 房间不在 `meta.rooms` /
首个节点不在第 0 秒 → **警告**。

---

## 4. 如何在 Godot 4 中导入并测试

### 4.1 编辑器导入

1. 打开 **Godot 4.x** → 项目管理器 → **导入(Import)** → 选择 `D:\DeepLoopGame` 目录下的 `project.godot`。
2. 首次导入会生成 `.godot/` 缓存目录（已被 `.gitignore` 忽略），等待右下角导入进度结束。
3. 确认 **项目设置 → 自动加载(Autoload)** 中已存在：
   `TimeLoopManager` 与 `PersistentMemoryManager`（配置已在 `project.godot` 里写好）。
4. 按 **F5**（运行项目）即可看到调试 HUD：时钟从 `07:00` 开始倒计时，
   NPC 位置随秒数变化（数据驱动动线生效）。

### 4.2 主场景上的操作（M2 画面层 + M1 玩法层）

主场景现在是两层：**`scripts/ui/play_view.gd` 画面层**（白鹄台画出来了，吃鼠标）+ **`scripts/ui/slice_hud.gd` 玩法层**（键盘 + 状态源）。
**鼠标**：点画面上的房间牌子就走过去（按地图最短路、要花秒数）；点同屋 NPC 的棋子就和他说话；对话框里的选项直接点。
**键盘**（都还是这套）：

| 按键 | 作用 |
| --- | --- |
| `TAB` / `E` / `Q` / `1`–`9` | 走去别的房间：**按最短路一段一段走，路上要花余页里的秒数**（暂停就走不动、快进就一起快进）；走不到的房间不进列表 |
| `F` | 和同屋的人交谈（对话是线索的第二个来源；案一有 2 条线索只能这么拿，选项带 `goto` 会自动接着追问） |
| `B` | 摊开**推演板**：线索拼成的推论、已经"对不上"的地方（矛盾高亮）、还差哪一步；顶栏会把最该注意的那处矛盾顶到眼前 |
| `H` | **重演上一遍走过的路线**（已经解锁过的动作不该让玩家再手动点一遍） |
| `G` | **画符（结案仪式）**：把阙文照回原样。方向键描一笔（斜向用小键盘 `1/3/7/9`）、`回车`落笔/推进、`退格`退一个方向（空了退整笔）、`1`–`5` 在要拿主意的那一步选一个 |
| `空格` | **快进到下一个拍点**（60x，到点自动降回 1x）——秒级重演的雏形 |
| `R` | 强制重开一遍（心灯 -8、线索保留；人回到这一遍的入口） |
| `T` / `P` | 倍速 1x/10x/60x / 暂停 |
| `` ` `` | 文字 HUD 开关（默认收起：开局就是"看画面"；调试或想读全文时叫回来） |

线索**到点自动入账**（站对房间即可，不需要按键）。画面上：顶栏（余页时钟 / 心灯条 / 结案进度）、
白鹄台地图（17 间房 + 57 条路，玩家棋子 + NPC 棋子挂在所在房间下）、右侧面板（已入录线索 ★ 标必需、
推演板对不上、卡关提示、余页杂讯与记忆阶）、左下日志、对话框、画符面板、底部按键提示。
按 `` ` `` 叫回文字 HUD 时，一屏显示：案名、遍数、案卷规模、余页 mm:ss、心灯条、所在房间与在场 NPC（含走位进度）、
对话提示、**世界状态递进**、**NPC 跨轮记忆阶**、**推演板矛盾与卡关提示**、画符提示、线索列表、已遗忘列表、
下一处拍点、最近日志、按键提示。

> 玩法要点：每条线索只在**某位 NPC 停留在某房间的某段时间**里可观测（数据里的 `second` + `clue_id`）。
> 站对房间到点才能拿到；拿到就落盘（双档轮换 + 崩溃恢复），**重开一遍不丢**。
> **结案**要满足数据里写的全部条件：案一是「6 条线索 + 第 8 遍之后 + 做完仪式」（`require_min_loop` 与
> `require_ritual`，HUD 会如实写还差什么）；**仪式就是 `G` 画符**——线索齐、遍数够、仪式做完，三条齐了才结案。
> **心灯**每走一遍 -8、余页之内每秒 -0.02（M2 平衡：原 0.05 会让"正常玩"9 遍额外扣 -54，叠上重开的 -64 必然熄灯、`require_min_loop: 8` 的案子永远结不了）；归零 = 永久划掉一条记忆，**灯灭期间重新查获也找不回来**，
> 重新点亮（结案 +25 或余页之外的现实时间恢复）之后才能重新记起。
> 阶段一的 `scripts/ui/debug_hud.gd`（`R`/`C`/`P`/`T` 那套）**已删除**（M3 清调试痕迹）；它的 `T`/`P`/`R` 能力由 `scripts/ui/slice_hud.gd` 接手（TAB/E/Q/1-9 走位、F 交谈、B 推演板、H 重演、G 画符、空格快进、T 倍速、P 暂停、R 重开）。

### 4.3 无头自动测试（推荐，可作为 CI）

```bash
godot --headless --path . --script res://tests/test_phase1_smoke.gd     # 84 项：核心三件套
godot --headless --path . --script res://tests/test_case_loader.gd      # 35 项：案件装载器
godot --headless --path . --script res://tests/test_heart_lamp.gd       # 173 项：心灯 + 崩溃安全落盘 + 离线恢复
godot --headless --path . --script res://tests/test_slice_hud.gd        # 215 项：纵切片真跑一遍（走位/对话/遍数锁/跨轮记忆/推演板/画符结案/画面层接线/引导弹窗/结案结算）
godot --headless --path . --script res://tests/test_title_scene.gd      # 57 项：标题页（文案/字体覆盖/三档版面比例/回车即点击/真跳主场景）
godot --headless --path . --script res://tests/test_dialogue.gd         # 114 项：对话层（解析/查询/线索交叉引用）
godot --headless --path . --script res://tests/test_travel.gd           # 165 项：走位图与耗时（含"最少几遍"的精确算）
godot --headless --path . --script res://tests/test_npc_memory.gd       # 130 项：NPC 跨轮记忆与世界状态递进
godot --headless --path . --script res://tests/test_deduction.gd        # 263 项：推演板（推论/矛盾高亮/卡关提示）
godot --headless --path . --script res://tests/test_runes.gd            # 459 项：画符（仪式数据 + 输入层，笔数/笔顺判定）

# 更省事：一条命令跑完全部 18 步（含上面 10 个测试 + 索引/校验/生成物漂移）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1
```

第一阶段核心三件套共 **84 项断言**，覆盖：JSON 解析（含非法输入必须报错而不是崩溃）、
倒计时 / 流速缩放与钳制 / 暂停 / 强制重置 / 自然超时、线索解锁去重与只读快照、
**多次循环重置后线索仍然保留**、重置重入保护。

> 测试末尾有一条"执行数量守护"断言：如果中途因 GDScript 运行时错误中断，
> 实际执行数会少于 `EXPECTED_CHECKS`，从而**报红**——因为 GDScript 的运行时错误
> 本身不会让进程退出码变红，不兜底就会出现"假绿"。

### 4.4 编辑器内自查清单

- [ ] 项目能打开，无脚本解析错误（编辑器底部无红色报错）
- [ ] F5 运行：HUD 显示 `循环 #0  剩余 07:00 ... 流速 x1.0  运行中`
- [ ] HUD 中两名 NPC 的位置随时间变化（0–25 秒执事在 kitchen，25 秒后到 hall，50 秒后到 dining_room）
- [ ] 按 `C` 解锁线索后，按 `R` 重置循环 → **线索数量不变**（跨循环保留）
- [ ] 按 `T` 切到 `60x` → 约 7 秒内看到一次自然超时重置（循环编号 +1）

### 4.5 本阶段实测记录（Godot 4.7.2.stable）

在本机用官方 Godot 4.7.2 无头跑过以下三件事，全部通过：

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| 资源导入 | `godot --headless --path . --import` | 无 ERROR / Parse Error；全局类 `NPCTimelineParser` 注册成功 |
| 冒烟测试 | `godot --headless --path . --script res://tests/test_phase1_smoke.gd` | **84 / 84 通过，退出码 0**，无对象泄漏告警 |
| 主场景整轮跑通 | `godot --headless --path . --fixed-fps 60 --quit-after 26000`（≈433 秒游戏时间） | HUD 打印「第 0 轮循环开始(420 秒)」→「循环重置（线索保留：0 条）」→「第 1 轮循环开始」，**零脚本错误** |
| 案一数据校验 | `cli.gd -- validate` / `-- cases` | 0 错误 0 警告；`案1.0《白鹄不举》 余页360.0s 房间17 NPC8 节点35 线索10` |
| 心灯与落盘 | `tests/test_heart_lamp.gd` | **173 / 173 通过**（重开 -8、每秒 -0.02、结案 +25、离线每分钟 +1、归零丢一条记忆、熄灯期间重开再划一笔、双档轮换 + 损坏档另存 `.corrupt` + 崩溃现场不污染主档） |
| M0/M1/M2 纵切片试玩 | `tests/test_slice_hud.gd` | **179 / 179 通过**：装载 → 走位耗时 → 到点取线索 → 落盘 → 按 R 重开（线索不丢、心灯 -8）→ **遍数锁**（站对房间、等对秒数，遍数不到就是看不见）→ 归零遗忘（灯灭期间找不回）→ 重新点亮后找回 → 快进 → 对话追问拿到 2 条只有对话才给的线索（含表现层"点选项"这条路）→ 世界递进与 NPC 记忆阶 → 推演板矛盾高亮/卡关预警/一键重演 → **线索齐+遍数够+画符仪式做完才结案 +25** → **画面层真的接到了状态源**（读到 17 间房/57 条边、每帧取状态、真的在画、`request_travel` 与文字 HUD 开关）→ **布局不变量**（牌子中心距 ≥120px、零重叠、右侧面板是真容器、NPC 棋子挂在自己格子里） |
| 画面截图 | `tools/shot.gd`（带窗口引擎） | 产物在 `.shots/`：开局、甘阿婆对话、推演板摊开三张；**截图前后逐字节还原存档**（截图不该把玩家的心灯跑掉） |
| 里程碑快照 | `tools/snapshot.ps1` | `-Note "说明"` 打包到 `.backups/`（120 个文件≈674 KB）+ 哈希清单；`-Diff` 看相对上一个快照改了哪些文件；`-List` 列快照。本机没有 git（winget 下载 GitHub 超时 `0x80072efd`），这就是版本控制的兜底 |
| 18 步闸门 | `tools\check.ps1` / `-Ci` | **18/18 通过，0 跳过，退出码 0（≈34s）**；本地模式（自动重写产物）与 `-Ci`（只校验）双模式均绿 |

> 版本提示：本项目语法刻意保持在 Godot 4.0+ 通用范围内（不使用 4.4+ 才有的类型化字典
> `Dictionary[K, V]`），但上述实测是在 4.7.2 上完成的；更老的 4.0–4.3 未做实测。

---

## 5. 阶段一验收对照

| 需求 | 落地位置 |
| --- | --- |
| 7 分钟（420 秒）倒计时 + 流速缩放 | `time_loop_manager.gd`（`DEFAULT_LOOP_DURATION = 420`、`set_time_scale()`） |
| `signal time_updated(current_second)` | `time_loop_manager.gd` |
| `signal loop_reset` | `time_loop_manager.gd` |
| `trigger_loop_reset()` 强制清零重置 | `time_loop_manager.gd` |
| 跨循环线索 `Array[String]`，重置不清空 | `persistent_memory_manager.gd` |
| `add_clue()` / `has_clue()` | `persistent_memory_manager.gd` |
| 读取 `data/npc_timelines.json` 并结构化为对象 | `npc_timeline_parser.gd` |
| 2 名 NPC × 前 60 秒各 3 个节点 | `data/npc_timelines.json` |
| 核心不掺杂 UI/画面代码 | 核心层零 UI 引用；表现层独立在 `scripts/ui/` |

---

## 6. 已知边界与下一阶段建议

* **本阶段线索不落盘**：`PersistentMemoryManager` 只提供 `get_save_data()/apply_save_data()`，真正的存档读写
  （`user://` 下的 JSON）留给存档系统阶段。
* **`scripts/entities/` 尚为空**：NPC 控制器（读取 `NPCSchedule` 驱动移动/动画）与玩家控制器是阶段二内容。
* **对话树数据未建立**：`dialogue_id` 字段已在数据表中预留，下一阶段新增 `data/dialogues.json` 与对话解析器。
* ~~**调试 HUD 是临时脚手架**~~ ✅ **已删**（M3）：`scripts/ui/debug_hud.gd` 与 `scenes/main.tscn` 的引用都已清掉，现在表现层只有 `slice_hud.gd`（状态源+键盘）/ `play_view.gd`（画面+鼠标）/ `overlay_ui.gd`（弹窗）/ `title_scene.gd`（标题页）。
* 若后续跨系统事件变多（门锁、音效、字幕等），可再引入一个 `EventBus` 单例做解耦；
  当前阶段用各系统的信号已经足够，不提前抽象。

---

## 7. AI 提效工具链（本仓库的"一条命令验证"）

做这个工具链的目的很直接：**让"改代码 → 知道有没有坏"这件事只需要一条命令、十来行输出**。
人（和 AI）都不该为了确认一次改动去读几十个文件、翻几百行日志 —— 那是 token 和注意力的双重浪费。

### 7.1 一条命令

```powershell
# 引擎路径只需给一次（之后记在 tools/godot_exe.txt）
$env:GODOT_EXE = "$env:TEMP\dsh_godot\Godot_v4.7.2-stable_win64_console.exe"

powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1        # 本地：自动重写生成物
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1 -Ci    # CI：只校验，任何漂移=失败
```

输出就是 18 行 + 1 行结论，退出码 0/1。全量日志落在 `logs\check\<步骤>.log`，只有失败时才需要看：

```
[1/18] 索引+解析检查   OK   RESULT: OK res://docs/INDEX.md + res://docs/index.json modules=36 (1415ms)
[2/18] 数据表校验      OK   RESULT: OK 数据 schema 与设计不变量通过（0 错误, 0 警告）
[3/18] 冒烟测试        OK   结果：通过 84 项 / 失败 0 项（共 84 项）
[4/18] 场景运行 smoke  OK   RESULT: OK scene=res://scenes/main.tscn frames=2 游戏内=8.00s 节点=54 HUD="案 01《白鹄不举》   ·   第 1 遍余…
[5/18] 场景规格漂移    OK   RESULT: OK res://scenes/main.tscn nodes=5
[6/18] 标题场景 smoke  OK   RESULT: OK scene=res://scenes/title_scene.tscn frames=4 游戏内=0.00s 节点=5 HUD="茅山秘录·诡异录"（无余页钟场景：只验装配）
[7/18] 标题场景漂移    OK   RESULT: OK res://scenes/title_scene.tscn nodes=5
[8/18] 主题漂移        OK   RESULT: OK res://theme/default_theme.tres colors=5 font_sizes=2 constants=4
[9/18] 占位资产漂移    OK   RESULT: OK res://assets/placeholder/ images=9 bytes=1773
[10/18] 纵切片试玩     OK   RESULT: OK slice_hud 试玩 215 项断言全部通过（装载/走位耗时/取线索/…/画符结案/引导弹窗/结案结算）
[11/18] 标题页与弹窗   OK   RESULT: OK 标题界面 57 项断言全部通过（装配/文案/字体覆盖/三档版面自适应/源码卫生/回车空格点击/悬停反馈/真跳主场景）
[12/18] 心灯与落盘     OK   RESULT: OK 心灯/落盘 173 项断言全部通过（重开-8、每秒-0.02、结案+25、离线每分钟+1、归零丢一条记忆、双档轮换不丢档）
[13/18] 案件装载器     OK   RESULT: OK case_loader 自检通过 35 项
[14/18] 对话层         OK   RESULT: OK dialogue_loader 对话层 114 项断言全部通过（…两条孤儿线索可达）
[15/18] 走位耗时       OK   RESULT: OK travel 自检通过 165 项；走位耗时下最少 8 遍集齐 6 条线索（第 9 遍，loop_index 8），同遍即可结案
[16/18] 跨轮记忆与世界状态  OK   RESULT: PASS
[17/18] 推演板与矛盾高亮    OK   RESULT: OK 推演板 263 项断言全过（案一 10 推论 / 6 矛盾 / 6 提示）
[18/18] 画符输入       OK   RESULT: OK 画符输入 459 项断言全过（案一 1 道符 / 5 步 / 3 笔 / 3 条近似笔）
结论: 全部通过 (18/18 执行, 0 跳过)  用时 34.8s
```

### 7.2 四件工具（按 ROI 排序，第 1 件是闸门本身）

| # | 工具 | 解决什么 | 怎么用 |
| --- | --- | --- | --- |
| 1 | `tools/check.ps1` | 把"验证"压缩成一条命令 | 见上；`-Ci` 用于 CI |
| 2 | `tools/gen_index.gd` | 把"读 N 个源文件"压缩成读 1 个 `docs/INDEX.md` | `--script res://tools/gen_index.gd [--check]` |
| | | **顺带**：`load()` 失败即记为解析失败 ⇒ 一次扫描同时完成全项目语法检查 | |
| 3 | `tools/cli.gd` + `tools/validate_data.gd` | 数据写错时给出**带拼写建议**的错误，而不是等运行时崩；另附状态探针 | `cli.gd -- validate / cases / smoke / index / dump-state / simulate / new-npc` |
| 4 | `tools/gen_scene.gd` / `gen_theme.gd` / `gen_placeholders.gd` | 生成物一律由**规格 JSON + 引擎自身序列化器**产出，禁止手写 | 改 `scenes_src/*.json`、`assets_src/*.json` 后重跑 |

三条设计决定值得记下来：

* **生成物不许手改**：`scenes/main.tscn`、`theme/default_theme.tres`、`assets/placeholder/*.png` 都是产物。
  手写 `.tscn` 会踩 uid 漂移与格式脆弱；用 `PackedScene.pack() + ResourceSaver.save()` 再**归一化**
  （删 `unique_id`、`uid`，把随机 `ext_resource` id 改写成 `1_0/1_1`…）之后，**同一份规格 ⇒ 同一份字节**，
  所以 `--check` 才能做到逐字节漂移检测。
* **错误绝不静默**：数据校验器对写错的 NPC/房间/线索 id 给出编辑距离拼写建议；`gen_scene` 对拼错的属性名、
  不存在的节点类型直接报错退出（比引擎默默忽略好得多）。
* **`docs/INDEX.md` 不含生成时间/引擎版本**：否则每次生成都有假 diff，`--check` 会永远报漂移。

### 7.3 一个必须记住的坑：Godot 的"假绿"

**GDScript 编译失败不会改变 Godot 进程的退出码。** 实测：`tools/cli.gd` 因为一个 `Parse Error`
根本没编译成功，进程照样退出 0，最早的闸门版本把它报成 OK —— 这比没有闸门更危险。
现在闸门做了三件事兜底：

1. 扫描输出文本里的 `SCRIPT ERROR | Parse Error | Failed to load script | Failed to compile | Compilation failed | Failed to load resource` → 一律 FAIL；
2. 工具类步骤**必须**打印 `RESULT:` 行，否则 FAIL（"未输出 RESULT 行（脚本可能未运行或未编译）"）；
3. `RESULT:` 正则**不锚定行首** —— Godot 把结论写到 stderr 时，PowerShell 会在行首加 `Godot_....exe : ` 前缀。

### 7.4 本工具链的实测记录（Godot 4.7.2.stable，本机无头）

| 验证 | 命令 | 结果 |
| --- | --- | --- |
| 闸门（本地模式） | `tools\check.ps1` | **18/18 通过，0 跳过，退出码 0**，用时 ~35s |
| 闸门（CI 模式） | `tools\check.ps1 -Ci` | **18/18 通过，退出码 0**；索引/场景/主题/占位资产五项均报 `CLEAN`（无漂移） |
| 符号索引 | `gen_index.gd` | `modules=36` → `docs/INDEX.md` + `docs/index.json` |
| 数据校验 | `cli.gd validate` | 0 错误 / 0 警告（案一已落地：1 案 / 10 NPC / 41 节点 / 10 条线索引用 / 14 条已登记线索 / 38 条已登记对话 / 1 道符（5 步 3 笔）） |
| 场景生成 | `gen_scene.gd --spec res://scenes_src/main.json` | `scenes/main.tscn` 5 节点（Main → PlayView → SliceHUD → InfoLabel → OverlayUI）；`--check` 逐字节无漂移 |
| 标题页生成 | `gen_scene.gd --spec res://scenes_src/title_scene.json` | `scenes/title_scene.tscn` 5 节点（TitleScene → 标题/副标题/小字/【开始推演】）；**启动场景** |
| 全局主题 | `gen_theme.gd` + `project.godot` 的 `gui/theme/custom` | 已接线，5 色 / 2 字号 / 4 常量 |
| 占位资产 | `gen_placeholders.gd` | 9 张 PNG，共 1773 字节 |
| 纵切片试玩 | `tests/test_slice_hud.gd`（闸门第 10 步） | 215/215：真例化主场景、合成按键，走位/对话/遍数锁/跨轮记忆/推演板/画符结案/画面层接线/**引导弹窗**/**结案结算与重新开始**全链路 |
| 标题页与弹窗 | `tests/test_title_scene.gd`（闸门第 11 步） | 57/57：文案与字体覆盖（46 字逐个 `Font.has_char`）、三档窗口版面比例一致（不写死坐标）、回车/空格即点击、真跳主场景 |
| 心灯与落盘 | `tests/test_heart_lamp.gd`（闸门第 12 步） | 173/173：重开 -8、每秒 -0.02、结案 +25、离线每分钟 +1、熄灯永久遗忘、双档轮换与损坏档恢复 |
| 案件装载器 | `tests/test_case_loader.gd`（闸门第 13 步） | 35/35：三组夹具（正常 / 可疑 / 结构性错误） |
| 对话层 | `tests/test_dialogue.gd`（闸门第 14 步） | 114/114：解析/查询/错误与警告分类/线索交叉引用/两条孤儿线索可达 |
| 走位耗时 | `tests/test_travel.gd`（闸门第 15 步） | 165/165：17 间房 57 条有向边、整数秒、最短路；精确子集 DP 证明"最少 8 遍集齐 6 条线索" |
| 跨轮记忆与世界状态 | `tests/test_npc_memory.gd`（闸门第 16 步） | 130/130：6 名 NPC / 11 条规则、阶数现算、`loop_reset` 清上一遍状态 |
| 推演板与矛盾高亮 | `tests/test_deduction.gd`（闸门第 17 步） | 263/263：10 条推论 / 6 处对不上 / 6 条卡关提示、排序与截断、五组错误夹具 |
| 画符输入 | `tests/test_runes.gd`（闸门第 18 步） | 459/459：仪式数据装载（真数据 0 错 0 警）、笔数与笔顺判定、三条 `near_miss` 原文交代、退笔、选择步不推进、整套仪式完成、`loop_reset` 清状态 |

> 已知小瑕疵：`tools/*.gd` 里给内部类（如 `ParseResult`）标注的返回类型，反射只能拿到原生基类
> `RefCounted` —— 索引工具已改为从源码文本取作者写的类型来规避。

### 7.5 无头试玩抓到的两个真坑（值得单独记）

1. **`time_updated` 是倒计时口径**：`scripts/core/time_loop_manager.gd` 的
   `signal time_updated(current_second)` 广播的是**剩余**秒数（360 → 0），不是已过秒数。
   表现层若把它当"现在第几秒"去比对数据里的绝对拍点，就会**永远取不到线索**（静默、无报错）。
   取"第几秒"一律用 `TimeLoopManager.get_elapsed_seconds()`。
2. **`--check-only` 对引用 Autoload 的脚本会误报**：`godot --headless --path . --check-only --script res://scripts/ui/slice_hud.gd`
   会报 `Identifier not found: PersistentMemoryManager`（该模式不注册 Autoload），把好脚本判成坏的。
   `--check-only` 只适合工具/测试脚本；**表现层脚本必须真跑场景**才算验证 —— 这就是第 8 步试玩存在的理由。

### 7.6 纵切片（M0 → M2）的已知边界（诚实清单，别当成 bug 反复查）

| 边界 | 现状 | 归属 |
| --- | --- | --- |
| 画面层（M2 v2） | **已完成**：`scripts/ui/play_view.gd` 用 `_draw()` 图元自画白鹄台；**布局改成自适应网格**（房间牌子"种子→网格吸附→逐个占格"，间距 ≥120px、零重叠；右侧面板改真容器；连线画在牌子之下；所有文字带半透明黑底）—— 修的是"窗口一大（如 1600×900）就错位、中心几间房糊成一团"这个 bug：v1 把 `STAGE_W/PANEL_X` 写死成 1280×720 的坐标（17 间房 / 57 条路 / NPC 棋子 / 玩家棋子）、顶栏、右侧面板、日志、对话框（选项可点）、画符面板；鼠标点房间就走、点同屋的人就说话。**没有用任何美术资源**（占位图里只有西式庄园的 4 张，案一用不上），也**没有 NPC 立绘/行走动画/音频** | 完成（待美术） |
| 文字 HUD | 仍在（`slice_hud.gd`）且默认收起，按 `` ` `` 叫回来：它是**键盘唯一入口**与**表现层状态源**（`present_state()` / `request_*`），M2 画面层只读它、不自己判玩法 | 设计如此 |
| 2 条线索的出处 | **已修（M1 ①）**：`scripts/data/dialogue_loader.gd` + HUD 的 `F` 交谈接上了 `clue_01_double_knot`（`qdm_02_bag` → 追问链 `qdm_03_admit` → `qdm_04_ningque`）与 `clue_01_keep_stele_motive`；`dialogues_giving(clue_id)` 可查任意线索的对话出处 | 完成 |
| 房间可以直跳 | **已修（M1 ②）**：`TAB/E/Q/1–9` 一律按 `data/maps/case_01_map.json` 的最短路**一段一段走**，路上要花余页里的秒数（暂停就走不动、快进一起快进）；`1`–`9` 只是"去第 N 间"的快捷入口，同样要走路 | 完成 |
| 页外房间 | `off_page`（郑守录在页外的录房）在地图数据里标 `"external": true`：**故意走不到**，他那通电话只能从 `phone` 听见（依据 `docs/story/04`） | 设计如此 |
| 跨轮的"世界状态"与 NPC 记忆 | **已完成（M1 ③）**：`scripts/entities/loop_mutation.gd`（每遍多出来的痕迹，案一 = grow）+ `scripts/entities/npc_memory.gd`（6 名 NPC / 11 条规则，阶数按"遍数 + 手上线索"现算）；HUD 有两行实时显示 | 完成 |
| 推演板与矛盾高亮 | **已完成（M1 ④）**：`scripts/entities/deduction_board.gd`（10 条推论 / 6 处对不上 / 6 条卡关提示），`B` 摊开、顶栏把最该注意的"对不上"顶到眼前；连着几遍没有新线索时主动给落点提示 | 完成 |
| 画符（结案仪式） | **已完成（M1 ⑤）**：`data/runes/case_01_runes.json` + `scripts/data/rune_loader.gd` + `scripts/entities/rune_input.gd`，`G` 画符（方向键 + 小键盘斜向 + 回车/退格）；`require_ritual` 从"只显示"变成**硬门槛**（线索齐 + 遍数够 + 仪式做完才结案） | 完成 |
| 心灯数值与离线恢复 | 数值随线索一起落盘（`clue_store.gd` 的 `lamp_value` + `seen_unix` 键）；**离线现实时间每分钟 +1 点**已按 `docs/story/09:175` 实现（`heart_lamp.gd` 的 `apply_offline_recovery()`，HUD 会写"[+] 离线恢复：心灯回了 N 点"）。没有这条恢复，案一在数值上通不了关：每遍固定烧 26 点、要走第 8 遍，熄灯后唯一重新点亮的途径是结案＝自锁 | 完成 |
| 结案门槛 | 已按数据契约判定 `require_clues` + `require_min_loop` + `require_ritual`（案一是 6 条线索 + 第 8 遍之后 + 回照诵碑）。**遍数不只是门槛**：观察点自带遍数锁（`data/scenarios` 的 `loop_min`，依据 `docs/story/04` 的"获得方式"—— 四字位第 2 遍、半笔"寸"第 3 遍、灰布袋第 4 遍），走位耗时从来不是瓶颈（`tests/test_travel.gd` 用精确子集 DP 算过一遍能走遍全图） | 完成 |
| 心灯代价预告 | 顶栏心灯条下面直接写清楚："照这样跑满每遍约 -26 点，还能撑 N 遍（结案 +25）"；撑不住那几遍会转红警告；灯灭时写明"余页之外真实时间每分钟回 1 点" —— 玩家不该自己一头撞上"永久划掉一条记忆" | 完成 |
| 心灯数值平衡 | **已定（M2，2026-10）**：重开消耗 `DRAIN_PER_LOOP_RESET` **保持 8**（`docs/story/04:1056` 的跨案预算表就是按它算的：案一 8 次重开 -64、案二 6 次 -48、卷一 -112 + 结案 25 ⇒ 收卷余 ~13 的"卷末低谷"），把 `DRAIN_PER_SECOND` **0.05 → 0.02**（旧值下正常玩 9 遍额外 -54 ⇒ 与 -64 叠加必然熄灯；新值每遍每秒开销 ≈ -1.7，跨案预算与低谷设计原样保留，而"每遍跑满 360 秒"9 遍 ≈ -137 仍会熄灯、惩罚还在）。已同步 `tests/test_heart_lamp.gd`（173 项，且断言改读常量）与 `docs/story/09:174` | 已完成 |

> 2026-10 的独立验收还发现两处**存档安全**问题（Windows 上 Godot 的 rename 会先删目标再移动 ⇒ 崩溃/掉电可能整档丢失；损坏档会被下一次存档覆盖），修复与回归测试见 `scripts/data/clue_store.gd` 顶部注释与 `tests/test_heart_lamp.gd`。

