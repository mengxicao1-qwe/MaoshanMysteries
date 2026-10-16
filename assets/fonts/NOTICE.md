# 中文字体（随包）

`NotoSansSC-subset.ttf` —— 由 `tools/gen_font.py` 自动生成的**子集字体**，只含本游戏实际用到的字符
（约 1100 个汉字/符号，288 KB）。**不要手改这个文件**，改文案后重新跑工具。

## 为什么要随包带字体

Godot 在浏览器（Web 导出）和任何没装中文字体的机器上，**拿不到系统字体**：内置默认字体只有拉丁字形，
所有中文会渲染成豆腐块（▯）。实测：Web 包不装字体时整个界面全是方框（截图见 `.shots/`），
所以中文字体必须进包。

全量 Noto Sans SC 有 10+ MB，而本作一局用到的字不到 2500 个 ⇒ 按"项目实际用到的字符"做子集。

## 怎么来的

```powershell
python tools\gen_font.py            # 收集字符 → 取子集 → 合并 → 写 assets/fonts/NotoSansSC-subset.ttf
python tools\gen_font.py --check    # 只校验：现有字体是否覆盖当前项目的全部字符（改完文案跑这个）
```

数据来源是 Google Fonts 的 `css2` 接口（`text=` 参数直接返回精确子集），本机可达；
`github.com` 不通，所以不走"下载全量字体再裁"的老路。汉字字体缺的符号（`▸ ✗` 等）会自动从
`Noto Sans Symbols 2` 补进来再合并。

**什么时候要重跑**：任何界面/数据文案加了新汉字之后（`tools/gen_font.py --check` 会告诉你缺不缺字），
以及导出 Web 包之前。字体变了必须**重新导出** `dist/web`。

## 授权

* Noto Sans SC —— SIL Open Font License 1.1（`https://fonts.google.com/noto/specimen/Noto+Sans+SC`）。
* Noto Sans Symbols 2 —— SIL Open Font License 1.1。
* OFL 允许随商业软件嵌入分发（字体本身不得单独出售）；本项目只在包里嵌入子集，属于允许用法。
  发行时本文件连同 `licenses/OFL.txt`（若做正式发行）一起放进 about 页即可。
