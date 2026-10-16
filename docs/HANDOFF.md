# 交接说明：这个项目到底是什么 · 现在在哪 · 接下来三天做什么

> 写给"下一个接手的人或 AI"。目标：**只读这一份，就能明白在做什么、做到哪、下一步怎么干。**
> 最后更新：2026-10-15（由当前会话写下）。配套：`AGENTS.md`（项目大脑/铁律/坑）、`docs/INDEX.md`（全项目符号索引）。

---

## 0. 三十秒版本

* **是什么**：一款**中文民俗志怪推理游戏**，单局是"一轮 360 秒的余页"。玩家在一遍又一遍的 6 分钟里，靠记住 NPC 的**秒级时刻表**、跑到对的地点、问到对的话，把碎片拼成唯一真相；**每重来一遍，都要用"记忆"付账**。
* **本质**：**时刻表谜题（时间 × 地点 × 人物）+ 记忆代价**。不是动作游戏、不是开放世界、没有随机生成、不靠反应速度。可以拿纸笔"算"。
* **卖点三条**（其余是品类标配）：① **心灯**——重开一遍扣 8 点（满 100），余页里每秒再扣 0.02，灯归零会**丢掉一条已到手的线索**；结案 +25，离线现实时间每分钟回 1 点。② **NPC 跨轮记忆 + 世界递进**——第 N 遍里 NPC 记得你之前干过什么，环境痕迹会生长/消退。③ **秒级重演**——走位要花余页里的秒数，上一遍的路线可以一键重演。
* **现状**：核心玩法**全部可玩**（键盘 + 鼠标），10 个测试共 **1695 条断言**、**18 步闸门全绿（约 34 秒）**；**有标题页 + 首次进游戏引导 + 结案结算**（M3 收口），Web（WASM）版已导出到 `dist/web/` 并在浏览器实跑验证；但**没有任何美术资源、没有音频**——画面全是代码画的矢量图元。
* **当前唯一目标（用户 2026-10-15 下的硬指令）**：**3 天内做出"能在浏览器里顺畅玩的干净 Demo"；做不出来就立刻归档封存这个项目。**
  → **Phase 1（Web 端可加载运行）已由用户验收通过；Phase 2/3 四项（标题页 / 30 秒新手引导 / 结案结算 / 清调试痕迹）已落地并随 Web 版重新导出。**

---

## 1. 玩法：一轮余页是怎么运转的

1. **一轮 = 360 秒**（案一数据；工程默认 420）。倒计时归零 = 这一遍结束，或者玩家主动按 `R` 重开。
2. 玩家是茅山弟子**苏景玄**，在**白鹄台村**（17 间房、57 条有向边、8 个 NPC）查一桩"白鹄不举"的旧案。
3. 线索**跨遍永久保留**——这是时间循环品类的标配，不是差异化。
4. 线索的来源只有两个：**走到对的房间**（自动入账）和**跟对的人说话**（选项会 `goto` 接着追问）。4 条线索还有**遍数锁**（第 2/2/3/4 遍才看得见，字段 `loop_min`）。
5. 拿到线索后在**推演板**上把推论拼起来：10 条推论 / 6 组矛盾 / 6 条卡关提示；互相打架的材料会高亮（"对不上 N 处"）。
6. **结案门槛**：集齐 **6 条必需线索（"结案六环"）** + 画完**符文**（3 笔，方向串判定）+ **至少第 8 遍**（`require_min_loop=8`）。结案 +25 点心灯。
7. 心灯是**节奏闸门**：按 120 秒/遍的打法，每遍约 -16 点，满灯能撑 6 遍；所以"算清路线、少走冤枉路"直接等于"能不能活到结案"。
8. 操作（键盘是唯一权威入口，鼠标是等价替代）：
   `TAB/E/Q/1–9` 走去别的房间（按最短路逐段走，**花余页里的秒数**）｜`F` 和同屋的人交谈｜`B` 推演板｜`H` 一键重演上一遍路线｜`G` 画符｜空格快进到下一拍点｜`T` 倍速｜`P` 暂停｜`R` 重开一遍｜`` ` `` 文字 HUD 开关。鼠标：点房间就走、点同屋的人就说话、对话框选项可点。

**体验目标**（做每一处改动时的判据）：把时刻表算明白的智性快感 + "记得越多、选择越难"的取舍焦虑 + 民俗志怪的寒气。**不要**做成需要手速或刷数值的游戏。

---

## 2. 现在做到哪了（能力清单）

| 模块 | 状态 | 关键文件 |
| --- | --- | --- |
| 核心三件套（倒计时/倍速/暂停/线索去重/跨遍保留/只读快照） | ✅ 84 断言 | `scripts/core/time_loop_manager.gd`、`persistent_memory_manager.gd` |
| 案件装载（案一数据 + schema 校验 + 遍数锁） | ✅ 35 + 数据校验 | `scripts/data/case_loader.gd`、`data/scenarios/case_01_baihu.json` |
| 对话层（秒级锚定、选项追问、对话→线索唯一出口） | ✅ 114 | `scripts/data/dialogue_loader.gd`、`data/dialogues/case_01_dialogues.json` |
| 走位图（Dijkstra 最短路 + 走位耗时状态机） | ✅ 165 | `scripts/data/map_loader.gd`、`scripts/entities/player_travel.gd`、`data/maps/case_01_map.json` |
| NPC 跨轮记忆 / 世界递进（台阶式，`loop_reset`） | ✅ 130 | `scripts/entities/npc_memory.gd`、`loop_mutation.gd`、`data/npc_memory/case_01_memory.json` |
| 推演板（推论/矛盾/卡关提示/矛盾高亮） | ✅ 263 | `scripts/entities/deduction_board.gd`、`data/deduction/case_01_deduction.json` |
| 画符仪式（三笔方向串判定 + 三道门槛 + 结案硬门槛） | ✅ 459 | `scripts/data/rune_loader.gd`、`scripts/entities/rune_input.gd`、`data/runes/case_01_runes.json` |
| 心灯（重开 -8 / 每秒 -0.02 / 结案 +25 / 离线恢复 / 归零丢线索） | ✅ 173 | `scripts/entities/heart_lamp.gd` |
| 存档（双档轮换 `.tmp`/`.bak` + 损坏档另存 `.corrupt`） | ✅ | `scripts/data/clue_store.gd` |
| 玩法 HUD（**状态源 + 动作入口**） | ✅ 179 | `scripts/ui/slice_hud.gd` |
| 画面层 v2（自适应网格、鼠标交互、容器面板） | ✅ | `scripts/ui/play_view.gd` |
| 截图管线 | ✅ | `tools/shot.gd` |
| 闸门（唯一验证入口） | ✅ 15/15，约 45 秒 | `tools/check.ps1`（`-Ci` 只校验） |
| **美术 / 音频 / 标题页 / 存档界面 / 手柄 / Web 导出** | ❌ **全都没有** | —— |

**跑起来的命令**（本机 Godot 在 `%TEMP%\dsh_godot\`）：

```powershell
$env:GODOT_EXE = "$env:TEMP\dsh_godot\Godot_v4.7.2-stable_win64_console.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check.ps1        # 18 步闸门（本地，会重写生成物）
& $env:GODOT_EXE --path D:\DeepLoopGame                                    # 直接玩（带窗口）
```

---

## 3. 技术形态与三条铁律（改代码前必读）

* **引擎**：Godot **4.7.2** + GDScript（forward_plus 不可用，本机是 OpenGL 3.3 兼容渲染）。
* **全数据驱动**：NPC 动线、案件、对话、地图、记忆、推演、符文**全部是 `data/**` 的 JSON**；代码只负责装载、校验、表现。**加内容 = 加 JSON**，不是写代码。
* **分层**：`slice_hud.gd` 是**唯一状态源**（`present_state()` 把"这一帧该画什么"整包交出去）和**唯一动作入口**（`request_travel/_talk/_option/_board/_rune/_reset`）。`play_view.gd` 只读它、只调它，**不许自己判玩法**；键盘留给 HUD。
* **三条铁律**：
  1. **不许手改生成物**（`scenes/*.tscn`、`theme/*.tres`、`assets/placeholder/*.png`）——改 `scenes_src/*.json` / `assets_src/*.json` 再跑闸门。
  2. **不许绕过闸门**：改完必须跑 `tools\check.ps1` 并只看最后一行结论。**Godot 的退出码不可信**（GDScript 编译失败也退 0）。
  3. **不许用 PowerShell 的 `Get-Content`/`Set-Content` 读写项目源文件**（本机只有 PS 5.1，会按 ANSI 读中文 → 毁文件）。要动文件用 `[System.IO.File]::ReadAllBytes/WriteAllBytes`。
* **省 token 的开发循环**：读 `docs/INDEX.md`（符号索引）→ 改 → 跑闸门 → 只在失败时读 `logs\check\<步骤>.log` 的相关几行。**不要**挨个 read 源文件。
* **踩过的坑都在 `AGENTS.md` §4**（30+ 条实测，比如：`time_updated` 广播的是**剩余**秒数；`DirAccess.rename_absolute` 在 Windows 上非原子；`canvas_items` 下 `Control.size` 跟着窗口走、版面不许写死常量；`--headless` 截图是空图；跑过的存档会被心灯扣血，测试/截图必须先做存档快照）。
* **版本控制**：本机已装 **Git 2.55**（`C:\Program Files\Git\cmd\git.exe`，**新开的终端**里直接可用；2026-10 之前装不上、当时用 `tools/snapshot.ps1` 顶班，现在它是额外兜底）。首次 `git push` 会弹浏览器登录（自带 Git Credential Manager）。**push 到 `main` 会自动把 `dist/web/` 发到 GitHub Pages**（`.github/workflows/deploy.yml`，地址 `https://<用户名>.github.io/<仓库名>/`，一次性设置见 `README.md` §8）；新 clone 第一次跑闸门前要先 `godot --headless --path . --import`（`.godot/` 不入库）。

---

## 4. 用户的目标（我的理解，务必对齐）

* 用户要的**不是更多系统**，而是**一个能拿出去给人看、能验证"这条路值不值得继续"的成品形态**：干净、能跑、能玩通、**浏览器里点开就能玩**。
* **三天是止损线**：到期做不出来，就说明"继续用这套自研引擎 + 自研玩法往下堆"的性价比不够，**立刻归档封存**，不再投入。
* 所以 Demo 的验收标准是**外人的体验**，不是代码指标：
  1. 浏览器打开 **≤10 秒**进游戏；
  2. **30 秒内**明白"我是谁、我要干什么、按什么键/点什么"；
  3. 能一路玩到**结案**（哪怕要重开 8 遍）；
  4. **1280×720 与更大窗口都不乱**；
  5. **没有调试痕迹、没有占位文字**；
  6. 关掉浏览器再打开，**进度还在**。

---

## 5. 接下来三天的计划（可勾）

**Day 1｜让它在浏览器里跑起来**
1. Web 导出模板就位：**本机 `github.com` 不通**（超时），但官方主机 `downloads.godotengine.org` 可达 ⇒ 用 `tools/fetch_web_templates.py` 做 **HTTP Range 选择性下载**（整包 tpz ~1GB，只取里面的 `templates/web_nothreads_release.zip` 9.7MB），落到 `%APPDATA%\Godot\export_templates\4.7.2.stable\`。引擎版本字符串是 `4.7.2.stable.official.ed1daf0bf`，**模板目录名必须叫 `4.7.2.stable`**。
2. 写 `export_presets.cfg`（Web / **nothreads**（线程关闭就不用 COOP/COEP 头）/ release / 1280×720 / 关闭扩展支持），`--export-release "Web" dist/web/index.html`。
3. `tools/serve_web.ps1`：用 bundled Python 起 `http.server`（`file://` 打不开 `.wasm`，**必须走 http**），固定端口 + 自动开浏览器；在 DSH 侧边栏里直接打开这个地址给你玩。
4. 自检：优先装无头 Chromium（`npmmirror` 可达，可作 playwright 的下载镜像）截图验证；拿不到就由你打开验证，我按你反馈修。

**Day 2｜把它变成"干净 Demo"（对外可看）** ✅ 全部落地（2026-10-16）
1. ✅ **标题页 + 开始按钮**：`scenes/title_scene.tscn`（启动场景，`project.godot` 的 `run/main_scene`）——「茅山秘录 · 诡异录 / 第一案 · 白鹄不举 / 【开始推演】」，点按钮或回车/空格进主场景（浏览器里这一次点击也顺手拿到输入焦点）。
2. ✅ **加载进度条**：用引擎自带 splash 的进度条（首包实测 38.6MB / 12 个文件，`tools/export_web.ps1`）。
3. ✅ **删/藏调试痕迹**：删 `scripts/ui/debug_hud.gd`；「地图读入 / 地图警告 / 数据警告」降级成 stdout `print`（游戏内日志只留玩法事件）；「下一处拍点」改成中文房名并滤掉走不到的页外；遍数一律 1 基；按键提示行不再暴露 `` ` `` 文字 HUD。
4. ✅ **新手引导**：首次进游戏弹「余页初记」（30 秒真实时间自动关 + 「知道了」；四条规则用 `present_state()` 现算数字 + 鼠标/键盘两行键位），只弹一次（`user://ui_prefs.json`）。
5. ✅ **结案页**：「此案已结」结算——用了几遍 / 余页内耗时 / 心灯（熄过几次）/ 入案线索 + 「重新开始」「留在此页」。
6. ✅ **重新开始**：清档（`clue_store` + `ui_prefs`）+ `PersistentMemoryManager.reset_for_new_game()` + `TimeLoopManager.reset_loop_index()` → 重载场景，等于冷启动。

**Day 3｜验证 + 交付**
1. ✅ 1280×720 实拍（桌面版 `.shots/{title,tutorial,main-clean,settlement}.png` + 浏览器版 `.shots/{web-title,web-main}.png`）；1600×900 的版面比例由 `tests/test_title_scene.gd` 三档窗口断言覆盖（未补大图）。
2. ✅ 全流程通关一次（结案结算实拍：第 9 遍 / 余页内耗时 06:0x / 心灯 37 → 结案 +25）；加载时长：headless 软渲染下首包 ~40s，真机 GPU 更快；**帧率未测**。
3. ✅ 交付：`dist/web/`（静态站点）+ `tools/serve_web.ps1`（一键起服务）+ README 顶部"怎么玩这个 Demo"。
4. 打快照 `tools/snapshot.ps1 -Note "Web Demo"`。
5. **若到期未达成** ⇒ 执行第 6 节封存清单。（**未触发**：Demo 已跑起来。）

---

## 6. 如果到期没做出来：归档封存清单

1. `powershell -File tools\snapshot.ps1 -Note "封存"` —— 全项目 zip + 哈希清单进 `.backups/`。
2. `README.md` 顶部加"**本仓库已归档封存，最后状态：M2 画面层 v2，可跑可测，未产出 Web Demo**"+ 日期。
3. 遗产清单：本文件（交接说明）+ `AGENTS.md`（铁律/工具/坑）+ `docs/INDEX.md`（符号索引）+ `docs/market/01`（立项结论与推荐方案）+ `docs/story/09`（数据规格）+ `.backups/*.zip`。
4. 停止开发：不再改代码、不再加内容。

---

## 7. 最先读的三份文件

1. **本文件** —— 是什么 / 在哪 / 下一步。
2. **`AGENTS.md`** —— 项目大脑：三条铁律、工具一览、Godot 4.7 已知坑、分层所有权、当前状态。
3. **`docs/INDEX.md`** —— 全项目符号索引（类/公开方法签名/信号/常量/Autoload 依赖），**省 token 的关键**。

深入看：`README.md`（架构与命令）→ `docs/market/01_立项调研与推荐方案.md`（为什么做这个题材、定价与商业路径）→ `docs/story/09_系统映射与数据规格.md`（数据契约）→ `docs/story/04_心灯与跨案预算.md`（心灯数值为什么是 -8）。
