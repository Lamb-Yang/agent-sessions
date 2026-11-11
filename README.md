# agent-sessions

Tern 插件：一个 block，列出本机 omp / pi / OpenCode 的历史会话，
支持「本项目 / 全部」两种视图，回车直接在旁边新分屏里 resume。

## 安装

```sh
tern plugin install github.com/<你的用户名>/tern-agent-sessions
```

本地开发用 `tern plugin link ~/Documents/github/agent-sessions`（保存即热重载）。

## 使用

- 状态栏左侧的 **Sessions** 按钮（可点击段落），或 palette 搜「Agent Sessions」，
  或按 `ctrl+alt+shift+o` 打开列表（下方分屏）
- `↑↓/j/k` 移动 · `Enter` 新分屏恢复该会话（双击行同效）
- `Tab` 本项目 ⇄ 全部；本项目=会话目录与当前目录同目录或互为父子
- 直接输入文字过滤（标题/agent/目录 子串匹配，支持中文与粘贴），`⌫` 删字符，`Esc` 清空
- `⌃R` 立即重扫；平时每 60s 自动刷新

## 数据来源

| Agent | 位置 | 恢复命令 |
| --- | --- | --- |
| omp | `~/.omp/agent/sessions/<路径>/*.jsonl` | `omp --resume=<path>` |
| pi | `~/.pi/agent/sessions/<路径>/*.jsonl` | `pi --session <path>` |
| OpenCode | `~/.local/share/opencode/opencode.db`（sqlite3） | `opencode --session <id>` |

只读扫描（每个 jsonl 只读前 30 行的相关行），不改任何会话数据。
