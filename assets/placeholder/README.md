# 占位素材（自动生成，请勿手工编辑）

本目录下的 PNG 全部由 `tools/gen_placeholders.gd` 依据 `assets_src/placeholder_manifest.json` 生成：
纯色填充 + 1px 深色描边，左上角 3x3 深色块与右下角 2x2 亮色块用于辨认方向（任一翻转或旋转都会立刻看出来）。
需要改动尺寸或配色时请编辑清单 JSON，然后重新执行
`godot --headless --path . --script res://tools/gen_placeholders.gd --`；
只想确认磁盘内容与清单是否一致，加 `--check`（不一致时退出码 1）。
**不要手工编辑这里的 PNG**：下一次生成会直接覆盖，改动会丢失。
