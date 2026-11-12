--!strict
-- Agent Sessions · window half
-- palette 命令打开列表 block；route.link 接 host 侧的 resume 请求，开新分屏。

local KIND = "agent-sessions.sessions"

local function project_cwd(cx): string
	local focused = cx.session:focused()
	local any: string? = nil
	for _, p in cx.session:panes() do
		local cwd = p.cwd
		if cwd and cwd ~= "" then
			if p.pane == focused then
				return cwd
			end
			if any == nil then
				any = cwd
			end
		end
	end
	return any or (tern.getenv("HOME") or "/")
end

tern.command({
	id = "open",
	title = "Agent Sessions: 本项目会话列表",
	icon = "terminal",
	keys = { "ctrl+alt+shift+o" },
	run = function(cx)
		for _, p in cx.session:panes() do
			if p.program == KIND then
				cx.layout:focus(p.pane)
				return
			end
		end
		local pane = cx:new_block(KIND, { project_cwd(cx) }, "tab")
		if pane == nil then
			cx:toast("error", "Agent Sessions", "无法打开会话列表 block")
		end
	end,
})

tern.route.link(function(link, cx)
	if link.url ~= "agent-sessions://resume" then
		return nil
	end
	local job = tern.kv.get("resume")
	tern.kv.set("resume", nil)
	if type(job) ~= "table" or type(job.cmd) ~= "string" then
		return { handled = true }
	end
	local launch = {
		cwd = if type(job.cwd) == "string" and job.cwd ~= "" then job.cwd else nil,
		command = job.cmd,
	}
	-- 恢复的会话一律开新 tab
	local pane = cx.layout:new_tab(launch)
	if pane then
		cx.layout:focus(pane)
	else
		cx:toast("error", "Agent Sessions", "无法为该会话打开分屏")
	end
	return { handled = true }
end)

-- 状态栏入口：点击打开会话列表
tern.chrome.status(function(_pane)
	return { { text = "Sessions", icon = "terminal", tone = "accent", command = "plugin.agent-sessions.open" } }
end)
