# agent-sessions

Tern 插件：在新 tab 里列出本机 omp / pi / OpenCode 的历史会话，
支持「本项目 / 全部」两种视图，`Enter` 在新 tab 里恢复会话。

## 安装

```sh
tern plugin install github.com/<你的用户名>/tern-agent-sessions
```

本地开发用 `tern plugin link ~/Documents/github/agent-sessions`（保存即热重载）。

## 使用

- 状态栏左侧的 **Sessions** 按钮（可点击段落），或 palette 搜「Agent Sessions」，
  或按 `ctrl+alt+shift+o` 打开会话列表（新 tab）
- 列表每项两行：第一行 `agent + 会话文件创建时间 + 会话标题`，第二行 `缩略路径 + #标签`；悬停时间或路径可看完整内容，标签最多显示 3 个，剩余显示 `+N`
- `↑↓/j/k` 移动 · `Enter` 在新 tab 恢复该会话（双击行同效）
- `Tab` 本项目 ⇄ 全部；本项目=会话目录在当前目录内或与之相同（父目录的会话只在「全部」里）
- 「全部」视图按完整目录分组，点击目录标题展开或收起；搜索时自动展开匹配目录，清空搜索后恢复手动展开状态。
- 顶部搜索框：直接输入即搜索（标题/agent/目录 子串匹配，支持中文与粘贴），`←→` 移动光标、`⌫` 按字符删除（中文/emoji 不会乱码），`Esc` 清空
- `⌃T` 给选中会话打标签：弹出打标签弹窗（含已有标签，点一下即移除），输入框里用中英文逗号分隔可一次保存多个标签，`Enter` 保存、`Esc` 取消；右键行也可加/移除
- 输入 `#标签名` 只看带该标签的会话（单独 `#` 看所有带标签的），列表里的标签以 `#标签` 展示
- `⌃R` 或表头「刷新」按钮立即重扫；平时每 60s 自动刷新

## 数据来源

| Agent | 位置 | 恢复命令 |
| --- | --- | --- |
| omp | `~/.omp/agent/sessions/<路径>/*.jsonl` | `omp --resume=<path>` |
| pi | `~/.pi/agent/sessions/<路径>/*.jsonl` | `pi --session <path>` |
| OpenCode | `~/.local/share/opencode/opencode.db`（sqlite3） | `opencode --session <id>` |

只读扫描（每个 jsonl 只读前 30 行的相关行），不改任何会话数据。

## 缓存

插件常驻后台：daemon 运行期间每 60s 自动扫描一次，把会话列表写入
`tern.kv` 缓存。打开列表时先用缓存秒显（表头显示「刷新中…」），随后静默刷新；
标签数据同存于 `tern.kv`，跨窗口、重启保留。
