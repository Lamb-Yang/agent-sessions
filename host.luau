--!strict
-- Agent Sessions · host half
-- 列出 omp / pi / OpenCode 的历史会话；Tab 切换「本项目 / 全部」，
-- Enter 在旁边新分屏里 resume（经 window 半边的 route 开 pane）。

local ui = tern.ui

type Row = {
	id: string,
	agent: string,
	title: string,
	cwd: string,
	when_ms: number,
	cmd: string,
}

type State = {
	cwd: string,
	mode: string, -- "project" | "all"
	rows: { Row },
	rows_rev: number, -- 每次扫描+1，供界面缓存判断
	tags: { [string]: { string } }, -- 会话 id → 标签列表（tern.kv "tags"）
	tags_rev: number, -- 每次标签增删+1，供界面缓存判断
	filter: string, -- 搜索框文本（输入即显示）
	applied: string, -- 实际用于过滤的文本（输入防抖后同步）
	filter_cursor: number, -- 搜索框光标，UTF-16 单位
	ftimer: any?, -- 过滤防抖定时器
	dialog: { row_id: string, text: string, cursor: number }?, -- 打标签弹窗；cursor 为 UTF-16 单位
	sel: number,
	vis_n: number, -- 当前可见行数（随界面缓存更新）
	now_ms: number, -- 最近一次扫描的 epoch 毫秒，用于相对时间
	loading: boolean,
	err: string?,
	-- 界面缓存：弹窗输入时主列表不变，避免每键重建整棵树
	body_cache: any?,
	body_sig: string?,
}

local HOME = tern.getenv("HOME") or ""
local US = "\31"

-- ---------- 时间 ----------

local function civil_days(y: number, mo: number, d: number): number
	local a = (14 - mo) // 12
	local y2 = y + 4800 - a
	local m2 = mo + 12 * a - 3
	return d + (153 * m2 + 2) // 5 + 365 * y2 + y2 // 4 - y2 // 100 + y2 // 400 - 32045
end

local function days_civil(z: number): (number, number, number)
	z += 32044
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return if m <= 2 then y + 1 else y, m, d
end

local function iso_ms(iso: string): number
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return 0
	end
	return (civil_days(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
		+ (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number)) * 1000
end

local function ms_to_short(ms: number): string
	if ms <= 0 then
		return "?"
	end
	local days, rem = ms // 86400000, ms % 86400000
	local y, mo, d = days_civil(days)
	return string.format("%04d-%02d-%02d %02d:%02d", y, mo, d, rem // 3600000, (rem % 3600000) // 60000)
end

local function relative_time(when_ms: number, now_ms: number): string
	if when_ms <= 0 or now_ms <= 0 then
		return ms_to_short(when_ms)
	end
	local delta = math.max(now_ms - when_ms, 0)
	if delta < 60000 then
		return "刚刚"
	elseif delta < 3600000 then
		return tostring(delta // 60000) .. " 分钟前"
	elseif delta < 86400000 then
		return tostring(delta // 3600000) .. " 小时前"
	elseif delta < 7 * 86400000 then
		return tostring(delta // 86400000) .. " 天前"
	end
	return ms_to_short(when_ms)
end

local function short_path(p: string): string
	local parent, leaf = string.match(p, "/([^/]+)/([^/]+)$")
	return if parent and leaf then "…/" .. parent .. "/" .. leaf else p
end

-- ---------- 工具 ----------

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or s
end

local function clip(s: string, n: number): string
	s = trim(s)
	if #s > n then
		return string.sub(s, 1, n - 1) .. "…"
	end
	return s
end

local function decode_obj(line: string): any
	local ok, v = pcall(tern.json.decode, line)
	if ok then
		return v
	end
	return nil
end

-- ---------- 扫描 ----------

local function scan_script(): string
	-- 每个会话 jsonl 只取前 30 行里需要的类型行；session_info（pi 重命名）全文扫描；OpenCode 走 sqlite3。
	local awk = string.format(
		[[awk '{ si = ($0 ~ /"type": *"session_info"/); pi_ = (FILENAME ~ "/.pi/"); if (si || (FNR<=30 && ($0 ~ /"type": *"(title|session)"/ || (pi_ && $0 ~ /"type": *"message"/)))) print "F%s" FILENAME "%s" substr($0,1,800) }' %s %s 2>/dev/null]],
		US, US, HOME .. "/.omp/agent/sessions/*/*.jsonl", HOME .. "/.pi/agent/sessions/*/*.jsonl")
	local sql = string.format(
		[[sqlite3 -json %s "select id, ifnull(title,'') as title, directory, time_updated from session_v2" 2>/dev/null | awk '{print "D%s" $0}']],
		HOME .. "/.local/share/opencode/opencode.db", US)
	local now = [[date +%s | awk '{print "N]] .. US .. [[" $0 "000"}']]
	return awk .. "\n" .. sql .. "\n" .. now
end

-- pi 的 message.content 可能是字符串，也可能是 [{type="text", text=…}, …]
local function content_text(m: any): string
	local c = m["content"]
	if type(c) == "string" then
		return trim(c)
	end
	if type(c) == "table" then
		local parts: { string } = {}
		for _, part in c do
			if type(part) == "table" and part["type"] == "text" and type(part["text"]) == "string" then
				table.insert(parts, part["text"])
			end
		end
		return trim(table.concat(parts, " "))
	end
	return ""
end

local function collect(out: { Row }, stdout: string): number
	local byFile: { [string]: any } = {}
	local now_ms = 0
	for line in string.gmatch(stdout, "[^\r\n]+") do
		local tag = string.sub(line, 1, 1)
		if tag == "F" then
			local path, body = string.match(line, "^F" .. US .. "([^" .. US .. "]*)" .. US .. "(.*)$")
			if path and body then
				local f = byFile[path]
				if not f then
					f = {}
					byFile[path] = f
				end
				local o = decode_obj(body)
				if type(o) == "table" then
					local t = o["type"]
					if t == "session" and f.session == nil then
						f.session = o
					elseif t == "title" and f.title == nil and type(o["title"]) == "string" then
						f.title = o["title"]
					elseif t == "session_info" and f.title == nil and type(o["name"]) == "string" then
						f.title = o["name"] -- pi 里 --name / 重命名存的显示名（优先于 user 文本）
					elseif t == "message" and f.user == nil then
						local m = o["message"]
						if type(m) == "table" and m["role"] == "user" then
							-- 与 pi cli 一致：标题取首条 user 消息（命名标题已优先于它）
							local txt = content_text(m)
							if txt ~= "" then
								f.user = txt
							end
						end
					end
				end
			end
		elseif tag == "N" then
			now_ms = tonumber(string.sub(line, 3)) or 0
		elseif tag == "D" then
			local arr = decode_obj(string.sub(line, 3))
			if type(arr) == "table" then
				for _, o in arr do
					if type(o) == "table" and type(o["id"]) == "string" then
						local title = if type(o["title"]) == "string" and o["title"] ~= "" then o["title"] else o["id"]
						table.insert(out, {
							id = "opencode:" .. o["id"],
							agent = "opencode",
							title = clip(title, 90),
							cwd = if type(o["directory"]) == "string" then o["directory"] else HOME,
							when_ms = tonumber(o["time_updated"]) or 0,
							cmd = "opencode --session " .. o["id"],
						})
					end
				end
			end
		end
	end
	for path, f in byFile do
		local sess = f.session
		if type(sess) == "table" and type(sess["cwd"]) == "string" then
			local agent = if string.find(path, "/.pi/", 1, true) then "pi" else "omp"
			local iso = if type(sess["timestamp"]) == "string" then sess["timestamp"] else ""
			table.insert(out, {
				id = agent .. ":" .. path,
				agent = agent,
				title = clip(f.title or f.user or tostring(sess["id"] or path), 90),
				cwd = sess["cwd"],
				when_ms = iso_ms(iso),
				cmd = if agent == "pi" then "pi --session " .. path else "omp --resume=" .. path,
			})
		end
	end
	return now_ms
end

-- ---------- 标签 ----------

-- 持久存储在 tern.kv 的 "tags" 键：{ [会话id] = { 标签… } }
local function load_tags(): { [string]: { string } }
	local t = tern.kv.get("tags")
	return if type(t) == "table" then t else {}
end

-- input 字段的 cursor 按 UTF-16 单位计（BMP 1 单元，emoji 等增补平面 2 单元）；
-- 下面把字节偏移与 UTF-16 偏移互转。
local function char_len(s: string, p: number): number
	local c = string.byte(s, p) or 0
	return if c < 0x80 then 1 elseif c < 0xE0 then 2 elseif c < 0xF0 then 3 else 4
end

local function cp_units(s: string, p: number): number
	return if char_len(s, p) == 4 then 2 else 1
end

local function u16_to_byte(s: string, units: number): number
	local p, u = 1, 0
	while p <= #s do
		local w = cp_units(s, p)
		if u + w > units then
			break
		end
		u += w
		p += char_len(s, p)
	end
	return p - 1
end

local function byte_to_u16(s: string, bytes: number): number
	local p, u = 1, 0
	while p < bytes do
		u += cp_units(s, p)
		p += char_len(s, p)
	end
	return u
end

local function u16_len(s: string): number
	return byte_to_u16(s, #s + 1)
end

-- 在 cursor（UTF-16）处插入文本，返回新文本与新光标
local function ins_text(t: string, cur: number, txt: string): (string, number)
	local b = u16_to_byte(t, cur)
	return string.sub(t, 1, b) .. txt .. string.sub(t, b + 1), cur + u16_len(txt)
end

-- 删除 cursor 前一个字符（按 UTF-8 字符边界回退，中文/emoji 不会乱码）
local function del_back(t: string, cur: number): (string, number)
	if cur <= 0 then
		return t, cur
	end
	local b = u16_to_byte(t, cur)
	local p = b - 1
	while p > 1 and (string.byte(t, p) or 0) >= 0x80 and (string.byte(t, p) or 0) < 0xC0 do
		p -= 1
	end
	local w = byte_to_u16(string.sub(t, p, b), b - p + 1)
	return string.sub(t, 1, p - 1) .. string.sub(t, b + 1), cur - w
end

-- 删除 cursor 处一个字符
local function del_fwd(t: string, cur: number): (string, number)
	local b = u16_to_byte(t, cur)
	if b >= #t then
		return t, cur
	end
	local p = b + 1
	return string.sub(t, 1, b) .. string.sub(t, p + char_len(t, p)), cur
end

-- 中英文逗号分隔多个标签，去首尾空白，丢弃空项
local function split_tags(text: string): { string }
	local out: { string } = {}
	for part in string.gmatch(string.gsub(text, "，", ","), "[^,]+") do
		part = trim(part)
		if part ~= "" then
			table.insert(out, part)
		end
	end
	return out
end

-- 添加（重复忽略）；移除走 remove_tag
local function add_tags(s: State, row_id: string, list: { string })
	if #list == 0 then
		return
	end
	local tags = load_tags()
	local cur = tags[row_id] or {}
	local dirty = false
	for _, tg in list do
		local dup = false
		for _, have in cur do
			if have == tg then
				dup = true
				break
			end
		end
		if not dup then
			table.insert(cur, tg)
			dirty = true
		end
	end
	if dirty then
		tags[row_id] = cur
		tern.kv.set("tags", tags)
		s.tags = tags
		s.tags_rev += 1
	end
end

local function remove_tag(s: State, row_id: string, tag: string)
	local tags = load_tags()
	local list = tags[row_id]
	if not list then
		return
	end
	for i, tg in list do
		if tg == tag then
			table.remove(list, i)
			tags[row_id] = if #list > 0 then list else nil
			tern.kv.set("tags", tags)
			s.tags = tags
			s.tags_rev += 1
			return
		end
	end
end

-- ---------- 过滤 ----------

-- macOS 把 /tmp、/var 等真实路径变成 /private/tmp：两边都去掉 /private 前缀再比。
local function norm(p: string): string
	return (string.gsub(p, "^/private/", "/"))
end

local function under(a: string, b: string): boolean
	a, b = norm(a), norm(b)
	return a == b or string.sub(a, 1, #b + 1) == b .. "/"
end

local function visible(s: State): { Row }
	local out: { Row } = {}
	local fl = string.lower(s.applied)
	-- "#标签名" 前缀：只看带匹配标签的会话；单独 "#" 看所有带标签的
	local tagq = if string.sub(fl, 1, 1) == "#" then string.sub(fl, 2) else nil
	for _, r in s.rows do
		if s.mode == "all" or under(r.cwd, s.cwd) or under(s.cwd, r.cwd) then
			local hit: boolean
			if tagq then
				hit = false
				for _, tg in s.tags[r.id] or {} do
					if tagq == "" or string.find(string.lower(tg), tagq, 1, true) then
						hit = true
						break
					end
				end
			else
				hit = fl == "" or string.find(string.lower(r.agent .. " " .. r.title .. " " .. r.cwd), fl, 1, true) ~= nil
			end
			if hit then
				table.insert(out, r)
			end
		end
	end
	return out
end

local function pane_alive(cx): boolean
	for _, p in tern.pane.list() do
		if p.pane == cx.pane then
			return true
		end
	end
	return false
end

local SEARCH_ID = "main.q"

-- 把焦点交给某个字段（等 view 发出后，光标与 IME 才画得出来）
local function focus_field(cx, id: string)
	tern.timer(40, function()
		if pane_alive(cx) then
			cx:frame({ { "focus", id } })
		end
	end)
end

-- 搜索输入防抖：打字只更新输入框，稍后再重算列表
local function schedule_filter(s: State, cx)
	if s.ftimer then
		s.ftimer.cancel()
	end
	s.ftimer = tern.timer(120, function()
		if not pane_alive(cx) then
			return
		end
		s.ftimer = nil
		s.applied = s.filter
		s.sel = 1
		cx:render()
	end)
end

-- ---------- 打标签弹窗 ----------

-- 弹窗的 input 节点 id（子节点 id 用 key 连接）
local FIELD_ID = "layer.tags.field"

local function open_dialog(s: State, row_id: string, cx)
	s.dialog = { row_id = row_id, text = "", cursor = 0 }
	-- 等 view 渲染出弹窗后再把焦点给输入框（光标与中文 IME 组合窗都画在字段上）
	tern.timer(50, function()
		if pane_alive(cx) then
			cx:frame({ { "focus", FIELD_ID } })
		end
	end)
end

local function close_dialog(s: State)
	s.dialog = nil
end

local function save_dialog(s: State)
	local d = s.dialog
	if d then
		add_tags(s, d.row_id, split_tags(d.text))
	end
	close_dialog(s)
end

-- 跑一次扫描：解析+排序后回调 (rows, raw)。供 block 刷新与后台循环共用。
local function fetch_rows(cb: (rows: { Row }, r: any, now_ms: number) -> ())
	tern.process.run({ "sh", "-c", scan_script() }, { timeout_ms = 15000 }, function(r)
		local rows: { Row } = {}
		local now_ms = 0
		pcall(function()
			now_ms = collect(rows, r.stdout)
		end)
		table.sort(rows, function(a, b)
			return a.when_ms > b.when_ms
		end)
		cb(rows, r, now_ms)
	end)
end

-- 清掉已消失会话的标签条目，并把结果写入 kv 缓存（后台/打开共用）
local function persist_scan(rows: { Row }, now_ms: number)
	local tags = load_tags()
	local alive: { [string]: boolean } = {}
	for _, row in rows do
		alive[row.id] = true
	end
	local dirty = false
	for id in tags do
		if not alive[id] then
			tags[id] = nil
			dirty = true
		end
	end
	if dirty then
		tern.kv.set("tags", tags)
	end
	tern.kv.set("cache", { rows = rows, now_ms = now_ms, at = tern.now() })
end

local function scan(cx, s: State)
	s.loading, s.err = true, nil
	fetch_rows(function(rows, r, now_ms)
		if not pane_alive(cx) then
			return
		end
		s.loading = false
		if r.status ~= 0 and r.stdout == "" then
			s.err = clip(trim(r.stderr), 80)
			if s.err == "" then
				s.err = "exit " .. tostring(r.status)
			end
		end
		s.rows = rows
		s.now_ms = now_ms
		s.rows_rev += 1
		persist_scan(rows, now_ms)
		local tags = load_tags()
		s.tags = tags
		s.tags_rev += 1
		cx:render()
	end)
end

local function resume(row: Row, cx)
	tern.kv.set("resume", { cmd = row.cmd, cwd = if tern.fs.exists(row.cwd) then row.cwd else HOME })
	cx:open("agent-sessions://resume")
end

-- ---------- block ----------

-- ---------- 列表主体 ----------

local function with_props(node: any, props: { [string]: any }): any
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- 两行式行：第一行 [agent 徽标] 时间 标题；第二行 路径 + #标签
local AGENT_TONE: { [string]: string } = { omp = "accent", pi = "info", opencode = "success" }

local function row_node(s: State, r: Row, cur: boolean, idx: number): any
	local menu: { string } = { "加标签…" }
	for _, tg in s.tags[r.id] or {} do
		table.insert(menu, 1, "移除:" .. tg)
	end
	local acts = { click = "sel", dblclick = "open", menu = menu }

	local agent = with_props(ui.badge(r.agent, AGENT_TONE[r.agent] or "neutral"), { role = "as-agent", actions = acts })
	local exact_time = ms_to_short(r.when_ms)
	local time = with_props(ui.node("text", {
		role = "as-time",
		title = exact_time,
		spans = { ui.span(relative_time(r.when_ms, s.now_ms)) },
		truncate = "end",
	}), { actions = acts })
	local title = with_props(ui.node("text", {
		role = "as-title",
		grow = 1,
		truncate = "end",
		spans = { ui.span(if r.title ~= "" then (string.gsub(r.title, "[\r\n]+", " ")) else "(无标题)", if r.title ~= "" then "" else "muted") },
	}), { actions = acts })
	local l1 = with_props(ui.node("row", { key = "l1", gap = "sm" }, { agent, time, title }), { actions = acts })

	local l2_items: { any } = {
		with_props(ui.node("text", {
			role = "as-path",
			title = r.cwd,
			grow = 1,
			truncate = "end",
			spans = { ui.span(short_path(r.cwd), "path") },
		}), { actions = acts }),
	}
	local tags = s.tags[r.id] or {}
	local shown = math.min(#tags, 3)
	for i = 1, shown do
		table.insert(l2_items, with_props(ui.badge("#" .. tags[i], "neutral"), { role = "as-tag", actions = acts }))
	end
	if #tags > shown then
		table.insert(l2_items, with_props(ui.badge("+" .. tostring(#tags - shown), "neutral"), {
			role = "as-tag-more",
			title = table.concat(tags, "  "),
			actions = acts,
		}))
	end
	local l2 = with_props(ui.node("row", { key = "l2", gap = "sm" }, l2_items), { role = "as-l2", actions = acts })

	return ui.node("col", {
		key = "r" .. idx,
		gap = "xs",
		role = "as-row",
		tone = if cur then "accent" else nil,
		mark = if cur then "pick" else nil,
		actions = acts,
	}, { l1, l2 })
end

local function build_body(s: State, vis: { Row }): any
	s.vis_n = #vis
	local nodes: { any } = {}
	if #vis == 0 then
		table.insert(nodes, with_props(ui.text({ ui.span("没有匹配的会话（r 重扫，Tab 看全部）", "muted") }), { role = "as-empty" }))
	else
		for i, r in vis do
			nodes[i] = row_node(s, r, i == s.sel, i)
		end
	end

	local head_items: { any } = {}
	local function push(node: any)
		if node ~= nil then
			table.insert(head_items, node)
		end
	end
	push(with_props(ui.badge(if s.mode == "project" then "本项目" else "全部", "accent"), { role = "as-mode" }))
	push(ui.node("text", { role = "as-dir", truncate = "end", grow = 1, spans = { ui.span(if s.mode == "project" then s.cwd else "所有目录", "muted path") } }))
	push(ui.node("text", { role = "as-count", spans = { ui.span(#vis .. " 条", "mono") } }))
	if s.loading then
		push(ui.badge("扫描中…", "pending"))
	elseif s.err then
		push(ui.badge(s.err, "error"))
	end
	if s.filter ~= "" then
		push(ui.badge(if string.sub(s.filter, 1, 1) == "#" then "标签 " .. clip(s.filter, 30) else "过滤 " .. clip(s.filter, 30), "info"))
	end

	return {
		main = with_props(ui.col({
			ui.node("row", { key = "head", gap = "sm", role = "as-head" }, head_items),
			ui.node("col", { key = "list", gap = "xs" }, nodes),
		}), { key = "body" }),
		dock = ui.col({
			ui.text({
				ui.span("输入", "muted"), ui.span(" 搜索    ", "muted"),
				ui.span("↑↓", "muted"), ui.span(" 移动    ", "muted"),
				ui.span("enter", "key"), ui.span(" 恢复    ", "muted"),
				ui.span("tab", "key"), ui.span(" 本项目/全部    ", "muted"),
				ui.span("ctrl+t", "key"), ui.span(" 打标签    ", "muted"),
				ui.span("#标签", "code"), ui.span(" 只看该标签    ", "muted"),
				ui.span("ctrl+r", "key"), ui.span(" 刷新    ", "muted"),
				ui.span("esc", "key"), ui.span(" 清除", "muted"),
			}),
		}),
		vis = vis,
	}
end

local sessions: BlockDef<State> = {
	font = "sans",
	init = function(cx, args, saved)
		local cwd = (args and args[1] and args[1] ~= "") and args[1] or (cx.cwd or HOME)
		if cwd == "" then
			cwd = HOME
		end
		local s: State = {
			cwd = cwd,
			mode = if saved and saved.mode == "all" then "all" else "project",
			rows = (function()
				local c = tern.kv.get("cache")
				return if type(c) == "table" and type(c.rows) == "table" and #c.rows > 0 then c.rows else {}
			end)(),
			rows_rev = 0,
			tags = load_tags(),
			tags_rev = 0,
			filter = if saved then tostring(saved.filter or "") else "",
			applied = if saved then tostring(saved.filter or "") else "",
			filter_cursor = 0,
			ftimer = nil,
			dialog = nil,
			sel = if saved then math.max(tonumber(saved.sel) or 1, 1) else 1,
			vis_n = 0,
			now_ms = (function()
				local c = tern.kv.get("cache")
				return if type(c) == "table" then tonumber(c.now_ms) or 0 else 0
			end)(),
			loading = false,
			err = nil,
		}
		tern.kv.set("resume", nil)
		s.filter_cursor = u16_len(s.filter)
		scan(cx, s)
		focus_field(cx, SEARCH_ID)
		local function again()
			tern.timer(60000, function()
				if pane_alive(cx) then
					scan(cx, s)
					again()
				end
			end)
		end
		again()
		return s
	end,

	title = function(_s)
		return "Agent Sessions"
	end,

	view = function(s, _cx)
		-- 主列表按状态签名缓存：弹窗打字不改变列表，直接复用上次构建的节点
		local function sig_of(): string
			return string.format("%s\1%s\1%d\1%d\1%d\1%s\1%s", s.mode, s.applied, s.sel, s.rows_rev, s.tags_rev, tostring(s.loading), s.err or "")
		end
		local sig = sig_of()
		local body = s.body_cache
		if s.body_sig ~= sig or body == nil then
			local vis = visible(s)
			if s.sel > #vis then
				s.sel = math.max(#vis, 1)
				sig = sig_of()
			end
			body = build_body(s, vis)
			s.body_cache, s.body_sig = body, sig
		end

		-- ⌃T 弹窗：打标签。overlay 不抢键盘，键在 key 里按状态路由。
		local layer
		local d = s.dialog
		if d then
			local row: Row? = nil
			for _, r in s.rows do
				if r.id == d.row_id then
					row = r
					break
				end
			end
			local have = s.tags[d.row_id] or {}
			local chips: { any } = {}
			if #have == 0 then
				table.insert(chips, ui.badge("还没有标签", "muted"))
			else
				for _, tg in have do
					local b = ui.badge("#" .. tg, "accent")
					local bp: { [string]: any } = b.p or {}
					bp.key = "tg" .. tg
					bp.role = "as-chip"
					bp.actions = { click = "untag=" .. tg }
					b.p = bp
					table.insert(chips, b)
				end
			end
			layer = ui.col({
				ui.node("overlay", {
					key = "tags",
					icon = "terminal",
					head = { ui.span("打标签") },
					meta = { ui.span(if row then clip(row.title, 24) else "", "muted") },
					size = "sm",
					modal = true,
					foot = "layer.tags.foot",
				}, {
					ui.node("row", { key = "have", gap = "sm" }, chips),
					ui.node("input", {
						key = "field",
						text = d.text,
						cursor = d.cursor,
						placeholder = "输入标签，逗号分隔可一次加多个，回车保存",
					}),
					ui.node("row", { key = "foot", gap = "sm", justify = "end" }, {
						ui.button("取消", { variant = "quiet", keys = { "esc" }, actions = { click = "close-dialog" } }),
						ui.button("保存", { keys = { "enter" }, actions = { click = "save-dialog" } }),
					}),
				}),
			})
		end

		return {
			main = ui.col({
				ui.node("input", {
					key = "q",
					role = "as-search",
					text = s.filter,
					cursor = s.filter_cursor,
					placeholder = "搜索标题 / agent / 目录；#标签 只看该标签",
				}),
				body.main,
			}),
			layer = layer,
			dock = body.dock,
		}
	end,

	key = function(s, key, cx)
		-- ⌃T 弹窗开着：所有键先喂输入框（input 的文本由程序拥有）。
		-- 走在 visible 全表扫描之前；显式 render + return false 跳过每键的块状态落盘。
		local d = s.dialog
		if d then
			if key.name == "escape" then
				close_dialog(s)
				focus_field(cx, SEARCH_ID)
			elseif key.name == "enter" then
				save_dialog(s)
				focus_field(cx, SEARCH_ID)
			elseif key.name == "left" then
				d.cursor = math.max(d.cursor - 1, 0)
			elseif key.name == "right" then
				d.cursor = math.min(d.cursor + 1, u16_len(d.text))
			elseif key.name == "home" then
				d.cursor = 0
			elseif key.name == "end" then
				d.cursor = u16_len(d.text)
			elseif key.name == "backspace" then
				d.text, d.cursor = del_back(d.text, d.cursor)
			elseif key.name == "delete" then
				d.text, d.cursor = del_fwd(d.text, d.cursor)
			elseif key.name == "paste" and key.text then
				d.text, d.cursor = ins_text(d.text, d.cursor, string.gsub(key.text, "[\r\n]+", " "))
			elseif key.text and #key.text > 0 and not key.ctrl and not key.meta and not key.alt then
				d.text, d.cursor = ins_text(d.text, d.cursor, key.text)
			end
			cx:render()
			return false
		end
		local n = math.max(s.vis_n, 1)
		if key.name == "t" and key.ctrl then
			local r = visible(s)[s.sel]
			if r then
				open_dialog(s, r.id, cx)
				return true
			end
			return false
		end
		if key.name == "up" then
			s.sel = math.max(s.sel - 1, 1)
		elseif key.name == "down" then
			s.sel = math.min(s.sel + 1, n)
		elseif key.name == "page_up" then
			s.sel = math.max(s.sel - 15, 1)
		elseif key.name == "page_down" then
			s.sel = math.min(s.sel + 15, n)
		elseif key.name == "enter" then
			local r = visible(s)[s.sel]
			if r then
				resume(r, cx)
			end
		elseif key.name == "tab" then
			s.mode = if s.mode == "project" then "all" else "project"
			s.sel = 1
		elseif key.name == "r" and key.ctrl then
			scan(cx, s) -- 刷新走 ⌃R
		elseif key.name == "escape" then
			if s.filter == "" then
				return false
			end
			if s.ftimer then
				s.ftimer.cancel()
				s.ftimer = nil
			end
			s.filter, s.filter_cursor, s.applied, s.sel = "", 0, "", 1
		-- 搜索框：文本由程序拥有，光标右移/退格都按字符（UTF-16）走
		elseif key.name == "left" then
			s.filter_cursor = math.max(s.filter_cursor - 1, 0)
		elseif key.name == "right" then
			s.filter_cursor = math.min(s.filter_cursor + 1, u16_len(s.filter))
		elseif key.name == "home" then
			s.filter_cursor = 0
		elseif key.name == "end" then
			s.filter_cursor = u16_len(s.filter)
		elseif key.name == "backspace" then
			if s.filter_cursor > 0 then
				s.filter, s.filter_cursor = del_back(s.filter, s.filter_cursor)
				schedule_filter(s, cx)
			end
		elseif key.name == "delete" then
			if s.filter_cursor < u16_len(s.filter) then
				s.filter, s.filter_cursor = del_fwd(s.filter, s.filter_cursor)
				schedule_filter(s, cx)
			end
		elseif key.name == "paste" and key.text then
			local first = string.match(key.text, "[^\r\n]+")
			if first and trim(first) ~= "" then
				s.filter, s.filter_cursor = ins_text(s.filter, s.filter_cursor, trim(first))
				schedule_filter(s, cx)
			end
		elseif key.text and #key.text > 0 and not key.ctrl and not key.meta and not key.alt then
			s.filter, s.filter_cursor = ins_text(s.filter, s.filter_cursor, key.text)
			schedule_filter(s, cx)
		else
			return false
		end
		return true
	end,

	event = function(s, ev, cx)
		if ev.ev == "focus" then
			-- 点击搜索框：把焦点交给它（其余字段如弹窗输入框，打开时已设）
			if ev.id == SEARCH_ID then
				focus_field(cx, SEARCH_ID)
			end
			return
		end
		if ev.ev == "error" then
			-- Tern 拒绝了 view/op：显示到表头，否则完全静默（日志里有）
			s.err = "视图错误: " .. clip(tostring(ev.msg or ""), 60)
			return
		end
		if ev.ev == "action" then
			local act = ev.act or ""
			-- 弹窗内：已有标签 badge 点击移除；取消/保存按钮
			if string.match(act, "^untag=") then
				if s.dialog then
					remove_tag(s, s.dialog.row_id, string.sub(act, 7))
				end
				return
			elseif act == "close-dialog" then
				close_dialog(s)
				focus_field(cx, SEARCH_ID)
				return
			elseif act == "save-dialog" then
				save_dialog(s)
				focus_field(cx, SEARCH_ID)
				return
			end
			-- 列表行：节点 id 形如 main.list.r3（或其子节点 main.list.r3.1）
			local idx = tonumber(string.match(ev.id or "", "%.r(%d+)"))
			local vis = s.body_cache and s.body_cache.vis or visible(s)
			local r = if idx then vis[idx] else nil
			if not r then
				return
			end
			if act == "sel" then
				s.sel = idx :: number
			elseif act == "open" then
				s.sel = idx :: number
				resume(r, cx)
			elseif act == "加标签…" then
				s.sel = idx :: number
				open_dialog(s, r.id, cx)
			else
				local tag = string.match(act, "^移除:(.+)$")
				if tag then
					remove_tag(s, r.id, tag)
				end
			end
			return
		end
		if ev.ev ~= "select" and ev.ev ~= "activate" then
			return
		end
		local vis = visible(s)
		for i, r in vis do
			if r.id == ev.item then
				s.sel = i
				if ev.ev == "activate" then
					resume(r, cx)
				end
				break
			end
		end
	end,

	save = function(s)
		return { mode = s.mode, filter = s.filter, sel = s.sel }
	end,
}

-- ---------- 后台自动更新 ----------
-- daemon 常驻期间每 60s 扫描一次（与打开 block 无关），结果写 kv 缓存；
-- 打开列表时先用缓存秒显，再静默刷新。reload 换 VM 时旧循环随之消亡。

local function bg_tick()
	fetch_rows(function(rows, _r, now_ms)
		persist_scan(rows, now_ms)
	end)
end

local function bg_loop()
	tern.timer(60000, function()
		bg_tick()
		bg_loop()
	end)
end
tern.timer(2000, function()
	bg_tick()
	bg_loop()
end)

tern.block.define("sessions", sessions)
