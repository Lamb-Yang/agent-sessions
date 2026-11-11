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
	filter: string,
	sel: number,
	loading: boolean,
	err: string?,
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
	return string.format("%02d-%02d %02d:%02d", mo, d, rem // 3600000, (rem % 3600000) // 60000)
		.. (if y < 2026 then string.format(" '%02d", y % 100) else "")
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
	return awk .. "\n" .. sql
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

local function collect(out: { Row }, stdout: string)
	local byFile: { [string]: any } = {}
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
	local fl = string.lower(s.filter)
	for _, r in s.rows do
		if s.mode == "all" or under(r.cwd, s.cwd) or under(s.cwd, r.cwd) then
			if fl == "" or string.find(string.lower(r.agent .. " " .. r.title .. " " .. r.cwd), fl, 1, true) then
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

local function scan(cx, s: State)
	s.loading, s.err = true, nil
	tern.process.run({ "sh", "-c", scan_script() }, { timeout_ms = 15000 }, function(r)
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
		local rows: { Row } = {}
		pcall(collect, rows, r.stdout)
		table.sort(rows, function(a, b)
			return a.when_ms > b.when_ms
		end)
		s.rows = rows
		cx:render()
	end)
end

local function resume(row: Row, cx)
	tern.kv.set("resume", { cmd = row.cmd, cwd = if tern.fs.exists(row.cwd) then row.cwd else HOME })
	cx:open("agent-sessions://resume")
end

-- ---------- block ----------

local sessions: BlockDef<State> = {
	init = function(cx, args, saved)
		local cwd = (args and args[1] and args[1] ~= "") and args[1] or (cx.cwd or HOME)
		if cwd == "" then
			cwd = HOME
		end
		local s: State = {
			cwd = cwd,
			mode = if saved and saved.mode == "all" then "all" else "project",
			rows = {},
			filter = if saved then tostring(saved.filter or "") else "",
			sel = if saved then math.max(tonumber(saved.sel) or 1, 1) else 1,
			loading = false,
			err = nil,
		}
		tern.kv.set("resume", nil)
		scan(cx, s)
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
		local vis = visible(s)
		if s.sel > #vis then
			s.sel = math.max(#vis, 1)
		end

		local cols: { { [string]: any } } = {
			{ id = "when", head = "时间", mono = true, priority = 3 },
			{ id = "agent", head = "Agent", priority = 2 },
			{ id = "title", head = "标题", grow = 1, truncate = "end" },
		}
		if s.mode == "all" then
			table.insert(cols, { id = "cwd", head = "目录", grow = 1, truncate = "middle", priority = 4 })
		end

		local rows: { any } = {}
		for i, r in vis do
			local cur = i == s.sel
			local cells: { any } = {
				{ ui.span(ms_to_short(r.when_ms), if cur then "num strong" else "num muted") },
				{ ui.span(r.agent, if cur then "strong" else "accent") },
				if r.title ~= "" then r.title else { ui.span("(无标题)", "muted") },
			}
			if s.mode == "all" then
				table.insert(cells, { ui.span(r.cwd, "muted") })
			end
			rows[i] = { id = r.id, cells = cells }
		end

		local table_node = ui.table(cols, rows, {
			selectable = true,
			selected = if vis[s.sel] then vis[s.sel].id else nil,
			empty = { ui.span("没有匹配的会话（r 重扫，Tab 看全部）", "muted") },
		})
		local tp: { [string]: any } = table_node.p or {}
		tp.key = "t"
		table_node.p = tp

		local head_items: { any } = {}
		local function push(node: any)
			if node ~= nil then
				table.insert(head_items, node)
			end
		end
		push(ui.badge(if s.mode == "project" then "本项目" else "全部", "accent"))
		push(ui.text({ ui.span(if s.mode == "project" then s.cwd else "所有目录", "muted") }))
		push(ui.text({ ui.span(#vis .. " 条", "muted num") }))
		if s.loading then
			push(ui.badge("扫描中…", "pending"))
		elseif s.err then
			push(ui.badge(s.err, "error"))
		end
		if s.filter ~= "" then
			push(ui.badge("过滤 " .. clip(s.filter, 30), "info"))
		end

		return {
			main = ui.col({ ui.row(head_items), table_node }),
			dock = ui.col({
				ui.text({ ui.span("↑↓ 移动 · Enter 新分屏恢复 · Tab 本项目/全部 · ⌃R 刷新 · 直接输入过滤（支持中文/粘贴） · Esc 清除", "muted") }),
			}),
		}
	end,

	key = function(s, key, cx)
		local n = math.max(#visible(s), 1)
		if key.name == "up" or (key.name == "k" and s.filter == "") then
			s.sel = math.max(s.sel - 1, 1)
		elseif key.name == "down" or (key.name == "j" and s.filter == "") then
			s.sel = math.min(s.sel + 1, n)
		elseif key.name == "page_up" then
			s.sel = math.max(s.sel - 15, 1)
		elseif key.name == "page_down" then
			s.sel = math.min(s.sel + 15, n)
		elseif key.name == "home" then
			s.sel = 1
		elseif key.name == "end" then
			s.sel = n
		elseif key.name == "enter" then
			local r = visible(s)[s.sel]
			if r then
				resume(r, cx)
			end
		elseif key.name == "tab" then
			s.mode = if s.mode == "project" then "all" else "project"
			s.sel = 1
		elseif key.name == "escape" then
			if s.filter == "" then
				return false
			end
			s.filter = ""
		elseif key.name == "backspace" then
			s.filter = string.sub(s.filter, 1, -2)
		elseif key.name == "paste" and key.text then
			-- 粘贴：取首个非空行进过滤
			local first = string.match(key.text, "[^\r\n]+")
			if first and trim(first) ~= "" then
				s.filter = trim(first)
				s.sel = 1
			end
		elseif key.name == "r" and key.ctrl then
			scan(cx, s) -- 刷新走 ⌃R，字母 r 留给搜索
		elseif key.text and #key.text > 0 and not key.ctrl and not key.meta and not key.alt then
			-- 单键（含中文等多字节字符）直接进过滤
			s.filter ..= key.text
			s.sel = 1
		else
			return false
		end
		return true
	end,

	event = function(s, ev, cx)
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

tern.block.define("sessions", sessions)
