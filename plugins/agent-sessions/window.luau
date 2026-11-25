-- Agent Sessions: browse Claude Code / Antigravity / Pi / omp / Carly history.
-- Aliases and tags live in this plugin's own SQLite; session files are never written.

local ui = tern.ui
local DIR = tern.plugin.dir

local S = {
	rows = {},
	tags = {},
	collapsed = {},
	hidden = {},
	show_hidden = false,
	filter = { agent = nil, folder = nil, tag = nil, q = nil },
	group = "agent",
	detail = nil,
	transcript = nil,
	selecting = false,
	selected = {},
	loading = false,
	pane = nil,
	scanning = false,
	page = 0,
	warned = {},
	render_error = nil,
}

local AGENT_ORDER = { claude = 1, antigravity = 2, omp = 3, pi = 4, carly = 5 }
local PAGE_SIZE = 80
local SAFE_ID = "^[%w%-_%.]+$"

local function trim(s)
	return (s or ""):match("^%s*(.-)%s*$")
end

local function cut_chars(t, maxc)
	t = t or ""
	if utf8.len(t) <= maxc then return t end
	local off = utf8.offset(t, maxc + 1)
	if not off then return t end
	return t:sub(1, off - 1) .. "…"
end

local function agent_icon(a)
	if a == "claude" then return "app-claude" end
	if a == "pi" then return "pi-mark" end
	if a == "omp" then return "app-omp" end
	if a == "antigravity" then return "provider-google" end
	if a == "carly" then return "sparkle" end
	return "puzzle"
end

local function key_of(s)
	return s.agent .. ":" .. s.id
end

local function tags_of(s)
	return S.tags[key_of(s)] or { alias = "", tags = {} }
end

local function label_of(s)
	local a = tags_of(s).alias
	if a and trim(a) ~= "" then return a end
	local title = s.title or ""
	if trim(title) == "" then return "(untitled)" end
	return title
end

local function short_title(s)
	local t = (s or ""):gsub("%s+", " ")
	t = t:match("^%s*(.-)%s*$")
	if t == "" then return "(untitled)" end
	local words, n = {}, 0
	for w in t:gmatch("%S+") do
		n = n + 1
		words[#words + 1] = w
		if n >= 8 then break end
	end
	local out = table.concat(words, " ")
	local truncated = out ~= t
	if utf8.len(out) > 44 then
		local off = utf8.offset(out, 45)
		if off then out = out:sub(1, off - 1) end
		truncated = true
	end
	if truncated then out = out .. "…" end
	return out
end

local function split_key(k)
	local a, id = k:match("^([^:]+):(.+)$")
	return a, id
end

local function find_session(k)
	local a, id = split_key(k)
	if not a then return nil end
	for _, s in ipairs(S.rows) do
		if s.agent == a and s.id == id then return s end
	end
	return nil
end

local function short_cwd(s)
	if not s.cwd or s.cwd == "" then return "" end
	return s.cwd:match("[^\\/]+$") or s.cwd
end

-- Resume commands start with approvals already answered: Claude Code bypasses the
-- permission prompts, and Antigravity and omp run in their full bypass mode, so a
-- resumed session behaves like the agents launched from Tern here.
local function safe_id(id)
	if type(id) == "string" and id ~= "" and id ~= "." and id ~= ".." and id:match(SAFE_ID) then return id end
	return nil
end

local function resume_cmd(s)
	local id = safe_id(s.id)
	if not id then return nil end
	if s.agent == "claude" then return "claude --resume " .. id .. " --dangerously-skip-permissions" end
	if s.agent == "pi" then return "pi --session " .. id end
	if s.agent == "omp" then return "omp --resume " .. id .. " --approval-mode=yolo" end
	if s.agent == "antigravity" then return "agy --conversation " .. id .. " --dangerously-skip-permissions" end
	return nil
end

local function matches(s)
	if S.hidden[key_of(s)] and not S.show_hidden then return false end
	local f = S.filter
	if f.agent and s.agent ~= f.agent then return false end
	if f.folder and s.cwd ~= f.folder then return false end
	local t = tags_of(s)
	if f.tag then
		local hit = false
		for _, x in ipairs(t.tags or {}) do
			if x == f.tag then hit = true; break end
		end
		if not hit then return false end
	end
	if f.q and f.q ~= "" then
		local hay = ((t.alias or "") .. " " .. (s.title or "") .. " " .. (s.cwd or "") .. " " .. table.concat(t.tags or {}, " ")):lower()
		if not hay:find(f.q:lower(), 1, true) then return false end
	end
	return true
end

local function group_of(s)
	if S.group == "folder" then
		return (s.cwd and s.cwd ~= "") and s.cwd or "(no folder)"
	end
	if S.group == "tag" then
		local t = tags_of(s).tags
		if t and #t > 0 then return t[1] end
		return "(untagged)"
	end
	return s.agent
end

local function group_label(g)
	if g == "(no folder)" or g == "(untagged)" then return g end
	if g:find("[\\/]") then
		local parts = {}
		for seg in g:gmatch("[^\\/]+") do parts[#parts + 1] = seg end
		if #parts > 2 then
			return "…\\" .. parts[#parts - 1] .. "\\" .. parts[#parts]
		end
	end
	return cut_chars(g, 52)
end

local function action_button(icon, label, act)
	return ui.button(nil, { icon = icon, title = label, size = "sm", actions = { click = act } })
end

local function warn_once(cx, key, level, text, sub)
	if S.warned[key] then return end
	S.warned[key] = true
	cx:toast(level, text, sub)
end

local function selected_count()
	local n = 0
	for _ in pairs(S.selected) do n = n + 1 end
	return n
end

local function clear_selection()
	S.selected = {}
end

local function select_box(s)
	local k = key_of(s)
	local on = S.selected[k] == true
	return ui.button(nil, {
		icon = on and "check" or "box",
		title = on and "Deselect" or "Select",
		size = "sm",
		variant = "quiet",
		on = on,
		actions = { click = "mark:" .. k },
	})
end

local function with_props(node, props)
	node.p = node.p or {}
	for k, v in pairs(props) do
		node.p[k] = v
	end
	return node
end

local function meta_row(s)
	local t = tags_of(s)
	local nodes = {}
	local c = short_cwd(s)
	if c ~= "" then
		nodes[#nodes + 1] = ui.text({ ui.span(c, "muted") })
	end
	if label_of(s) == "(untitled)" and s.id and s.id ~= "" then
		nodes[#nodes + 1] = ui.text({ ui.span(s.id:sub(1, 8), "muted") })
	end
	local shown = 0
	for _, tag in ipairs(t.tags or {}) do
		if shown >= 3 then
			nodes[#nodes + 1] = ui.badge("+" .. tostring(#t.tags - 3))
			break
		end
		nodes[#nodes + 1] = ui.badge("#" .. cut_chars(tag, 16))
		shown = shown + 1
	end
	if #nodes == 0 then
		nodes[1] = ui.text({ ui.span(" ", "muted") })
	end
	return ui.node("row", { gap = "xs", wrap = true }, nodes)
end

local function group_open(g)
	return S.collapsed[g] == false
end

local function group_head(g, n)
	local icon = "folder"
	if S.group == "agent" then
		icon = agent_icon(g)
	elseif S.group == "tag" then
		icon = "tag"
	end
	local row = ui.node("row", { gap = "sm", align = "center", wrap = true }, {
		ui.node("icon", { name = group_open(g) and "chev" or "chev-r" }),
		ui.node("icon", { name = icon }),
		ui.text({ ui.span(group_label(g), "strong") }),
		ui.badge(tostring(n)),
	})
	return ui.node("col", { gap = "xs" }, {
		with_props(row, { actions = { click = "group:" .. g } }),
		ui.rule(),
	})
end

local function session_actions(s)
	local acts = {}
	local cmd = resume_cmd(s)
	if cmd then
		acts[#acts + 1] = action_button("play", "Resume this session", "resume:" .. key_of(s))
		acts[#acts + 1] = action_button("copy", "Copy the resume command", "copy:" .. key_of(s))
	elseif s.path and s.path ~= "" then
		acts[#acts + 1] = action_button("copy", "Copy the transcript path", "copy:" .. key_of(s))
	end
	acts[#acts + 1] = action_button("pen", "Rename", "rename:" .. key_of(s))
	acts[#acts + 1] = action_button("tag", "Edit tags", "tag:" .. key_of(s))
	acts[#acts + 1] = S.hidden[key_of(s)] and action_button("eye", "Restore to list", "restore:" .. key_of(s)) or action_button("trash", "Hide or delete", "delete:" .. key_of(s))
	return acts
end

local function session_row(s)
	local k = key_of(s)
	local kids = {}
	if S.selecting then
		kids[#kids + 1] = select_box(s)
	end
	kids[#kids + 1] = ui.node("icon", { name = agent_icon(s.agent) })
	kids[#kids + 1] = ui.node("col", { gap = "xs", grow = 1, shrink = 1, min = { w = 0 } }, {
		with_props(ui.text(short_title(label_of(s))), {
			title = label_of(s),
			actions = { click = (S.selecting and "mark:" or "select:") .. k },
		}),
		meta_row(s),
	})
	if not S.selecting then
		kids[#kids + 1] = ui.node("row", { gap = "xs", shrink = 0, basis = "content" }, session_actions(s))
	end
	return ui.node("row", { key = k, gap = "sm", align = "start" }, kids)
end

local function toolbar(all_open)
	if S.selecting then
		local chosen = selected_count()
		local total = 0
		for _, s in ipairs(S.rows) do
			if matches(s) then total = total + 1 end
		end
		local all = total > 0 and chosen >= total
		local nodes = {
			ui.button("Done", { size = "sm", variant = "quiet", icon = "x", actions = { click = "select-mode" } }),
			ui.button(all and "Clear all" or "Select all", { size = "sm", icon = "list-checks", actions = { click = "select-all" } }),
		}
		if chosen > 0 then
			nodes[#nodes + 1] = ui.text({ ui.span(tostring(chosen) .. " selected", "accent") })
		end
		nodes[#nodes + 1] = ui.button("Delete selected…", {
			size = "sm", variant = "danger", icon = "trash",
			disabled = chosen == 0, actions = { click = "delete-selected" },
		})
		return ui.node("row", { gap = "sm", wrap = true }, nodes)
	end
	return ui.node("row", { gap = "sm", wrap = true }, {
		action_button("folder", "Filter by folder", "pick:folder"),
		action_button("tag", "Filter by tag", "pick:tag"),
		action_button("search", "Search", "pick:search"),
		ui.button("Group: " .. S.group, { size = "sm", actions = { click = "group" } }),
		action_button(all_open and "shrink" or "expand", all_open and "Collapse all" or "Expand all", "toggle-all"),
		action_button(S.show_hidden and "eye" or "eye-off", "Show hidden sessions", "toggle-hidden"),
		action_button("repeat", "Rescan", "rescan"),
		action_button("list-checks", "Select sessions", "select-mode"),
	})
end

local function filter_summary()
	local chips = {}
	if S.filter.folder then
		chips[#chips + 1] = ui.badge("folder: " .. cut_chars(S.filter.folder, 36))
	end
	if S.filter.tag then
		chips[#chips + 1] = ui.badge("#" .. cut_chars(S.filter.tag, 24))
	end
	if S.filter.q then
		chips[#chips + 1] = ui.badge('"' .. cut_chars(S.filter.q, 24) .. '"')
	end
	if #chips == 0 then return nil end
	chips[#chips + 1] = ui.button("Clear filters", {
		size = "sm", variant = "quiet", icon = "x", actions = { click = "clear-filters" },
	})
	return ui.node("row", { gap = "xs", wrap = true, align = "center" }, chips)
end

local function build_list()
	local items = {}
	for _, s in ipairs(S.rows) do
		if matches(s) then items[#items + 1] = s end
	end

	local groups, order = {}, {}
	for _, s in ipairs(items) do
		local g = group_of(s)
		if not groups[g] then
			groups[g] = {}
			order[#order + 1] = g
		end
		table.insert(groups[g], s)
	end
	if S.group == "agent" then
		table.sort(order, function(a, b) return (AGENT_ORDER[a] or 9) < (AGENT_ORDER[b] or 9) end)
	else
		table.sort(order)
	end

	local entries = {}
	for _, g in ipairs(order) do
		entries[#entries + 1] = { head = g, n = #groups[g] }
		if group_open(g) then
			for _, s in ipairs(groups[g]) do
				entries[#entries + 1] = { row = s }
			end
		end
	end
	local pages = math.max(1, math.ceil(#entries / PAGE_SIZE))
	local page = math.min(S.page or 0, pages - 1)
	S.page = page
	local from = page * PAGE_SIZE + 1
	local to = math.min(#entries, from + PAGE_SIZE - 1)

	local hidden_count = 0
	for _ in pairs(S.hidden) do hidden_count = hidden_count + 1 end
	local status
	if S.selecting then
		status = { ui.span(tostring(selected_count()), "strong num"), ui.span(" selected  ·  " .. tostring(#items) .. " shown", "muted") }
	else
		status = { ui.span(tostring(#items), "strong num"), ui.span(" sessions", "muted") }
		if hidden_count > 0 and not S.show_hidden then
			status[#status + 1] = ui.span("  ·  " .. hidden_count .. " hidden", "muted")
		end
	end
	if pages > 1 then
		status[#status + 1] = ui.span("  ·  page " .. tostring(page + 1) .. "/" .. tostring(pages), "muted")
	end

	local any_open = false
	for _, g in ipairs(order) do
		if group_open(g) then
			any_open = true
			break
		end
	end
	local kids = { toolbar(any_open), ui.text(status) }
	local summary = filter_summary()
	if summary then kids[#kids + 1] = summary end
	if pages > 1 then
		kids[#kids + 1] = ui.node("row", { gap = "sm", align = "center" }, {
			action_button("arrow-left", "Previous page", "page-prev"),
			ui.text({ ui.span("Page " .. tostring(page + 1) .. " of " .. tostring(pages), "muted") }),
			action_button("arrow-right", "Next page", "page-next"),
		})
	end
	kids[#kids + 1] = ui.rule()

	if #items == 0 then
		kids[#kids + 1] = ui.node("empty", { icon = "search", title = "No sessions", text = "Try another filter or rescan." })
		return ui.node("col", { gap = "lg" }, kids)
	end

	local block = {}
	if entries[from] and entries[from].row then
		local g = group_of(entries[from].row)
		block[#block + 1] = group_head(g, #groups[g])
	end
	for i = from, to do
		local e = entries[i]
		if e.head then
			block[#block + 1] = group_head(e.head, e.n)
		else
			block[#block + 1] = session_row(e.row)
			if i < to and entries[i + 1] and entries[i + 1].row then
				block[#block + 1] = ui.rule()
			end
		end
	end
	kids[#kids + 1] = ui.node("col", { gap = "xs" }, block)
	return ui.node("col", { gap = "lg" }, kids)
end

local function build_detail()
	local s = S.detail
	local t = tags_of(s)
	local head = ui.node("row", { gap = "sm", wrap = true, align = "center" }, {
		ui.node("icon", { name = agent_icon(s.agent) }),
		action_button("arrow-left", "Back", "back"),
		with_props(ui.text({ ui.span(short_title(label_of(s)), "title") }), {
			grow = 1,
			shrink = 1,
			min = { w = 0 },
			title = label_of(s),
		}),
		ui.badge(s.agent),
	})
	local buttons = {}
	local cmd = resume_cmd(s)
	if cmd then
		buttons[#buttons + 1] = ui.button("Resume", { size = "sm", variant = "primary", actions = { click = "resume:" .. key_of(s) } })
		buttons[#buttons + 1] = ui.button("Copy", { size = "sm", variant = "quiet", actions = { click = "copy:" .. key_of(s) } })
	end
	if s.path and s.path ~= "" then
		buttons[#buttons + 1] = ui.button("Copy path", { size = "sm", variant = "quiet", actions = { click = "copypath:" .. key_of(s) } })
	end
	buttons[#buttons + 1] = ui.button("Rename", { size = "sm", variant = "quiet", actions = { click = "rename:" .. key_of(s) } })
	buttons[#buttons + 1] = ui.button("Tags", { size = "sm", variant = "quiet", actions = { click = "tag:" .. key_of(s) } })
	local actions = ui.node("row", { gap = "sm", wrap = true }, buttons)
	local meta_nodes = { ui.text({ ui.span(s.cwd or "?", "muted") }) }
	for _, tag in ipairs(t.tags or {}) do
		meta_nodes[#meta_nodes + 1] = ui.badge("#" .. cut_chars(tag, 16))
	end
	local meta = ui.node("row", { gap = "xs", wrap = true }, meta_nodes)
	local body
	if S.loading then
		body = ui.text({ ui.span("Loading transcript…", "muted") })
	else
		body = ui.md(S.transcript or "_(no messages)_")
	end
	local kids = { head, ui.rule(), actions }
	if s.agent == "carly" then
		kids[#kids + 1] = ui.text({ ui.span("Carly transcripts can't be resumed here. Copy path puts the JSONL file on the clipboard so another agent can pick the conversation up.", "muted") })
	end
	kids[#kids + 1] = meta
	kids[#kids + 1] = ui.rule()
	kids[#kids + 1] = body
	return ui.node("col", { gap = "sm" }, kids)
end

local function render(cx)
	if not S.pane then return end
	local v = S.detail and build_detail() or build_list()
	local ok, err = pcall(function()
		cx.canvas:set(S.pane, { view = v })
	end)
	if ok then
		S.render_error = nil
		return
	end
	local alive = false
	pcall(function()
		alive = cx.canvas:get(S.pane) ~= nil
	end)
	if not alive then
		S.pane = nil
		return
	end
	local message = tostring(err):sub(1, 200)
	if S.render_error ~= message then
		S.render_error = message
		cx:toast("error", "Agent Sessions: could not render", message)
	end
end

local function run_node(argv, timeout, cb)
	local full = { "node", DIR .. "/" .. argv[1] }
	for i = 2, #argv do
		full[#full + 1] = argv[i]
	end
	local ok, err = pcall(function()
		tern.process.run(full, { timeout_ms = timeout or 30000 }, cb)
	end)
	return ok, err
end

local function load_tags(cx, then_)
	local function done(cx2)
		local ok2, e2 = run_node({ "tags.js", "hidden" }, 10000, function(r2, cx3)
			if r2.status == 0 then
				local ok3, list = pcall(tern.json.decode, r2.stdout)
				if ok3 and type(list) == "table" then
					local set = {}
					for _, k in ipairs(list) do set[k] = true end
					S.hidden = set
				end
			else
				warn_once(cx3, "tags:sqlite", "error", "Agent Sessions: tags unavailable", (r2.stderr or ""):sub(1, 200))
			end
			if then_ then then_(cx3) end
		end)
		if not ok2 then
			if then_ then then_(cx2) end
		end
	end
	local ok, err = run_node({ "tags.js", "get" }, 10000, function(r, cx2)
		if r.status == 0 then
			local ok2, t = pcall(tern.json.decode, r.stdout)
			if ok2 and type(t) == "table" then
				S.tags = t
			end
		else
			warn_once(cx2, "tags:sqlite", "error", "Agent Sessions: tags unavailable", (r.stderr or ""):sub(1, 200))
		end
		done(cx2)
	end)
	if not ok then
		warn_once(cx, "node:missing", "error", "Agent Sessions: node not found", tostring(err):sub(1, 200))
		if then_ then then_(cx) end
	end
end

local function scan(cx)
	if S.scanning then return end
	S.scanning = true
	local ok, err = run_node({ "scan.js" }, 60000, function(r, cx2)
		S.scanning = false
		if r.stderr and r.stderr ~= "" then
			local warning = r.stderr:match("warning:[^\n]*")
			if warning then
				warn_once(cx2, "scan:" .. warning, "error", "Agent Sessions", warning:sub(1, 240))
			end
		end
		if r.status ~= 0 then
			if r.timed_out then
				cx2:toast("error", "Session scan timed out")
			else
				cx2:toast("error", "Session scan failed", (r.stderr or ""):sub(1, 200))
			end
			return
		end
		local ok2, rows = pcall(tern.json.decode, r.stdout)
		if not ok2 or type(rows) ~= "table" then
			cx2:toast("error", "Session scan returned bad JSON")
			return
		end
		table.sort(rows, function(a, b) return (a.time or 0) > (b.time or 0) end)
		S.rows = rows
		local live = {}
		for _, s in ipairs(rows) do live[key_of(s)] = true end
		for k in pairs(S.selected) do
			if not live[k] then S.selected[k] = nil end
		end
		S.page = 0
		render(cx2)
	end)
	if not ok then
		S.scanning = false
		warn_once(cx, "node:missing", "error", "Agent Sessions: node not found", tostring(err):sub(1, 200))
	end
end

local function refresh(cx)
	load_tags(cx, function(cx2)
		scan(cx2)
	end)
end

local function find_canvas(cx)
	for _, c in ipairs(cx.canvas:list()) do
		if c.owner == tern.plugin.id then return c.pane end
	end
	return nil
end

local function open_dashboard(cx)
	local pane = find_canvas(cx)
	if pane then
		S.pane = pane
		cx.layout:focus(pane)
		pcall(function()
			cx.canvas:set(pane, { about = "Session history for Claude Code, Antigravity, Pi, omp and Carly. Resume or copy a command; aliases and tags live in this plugin's own database and never touch the session files." })
		end)
		refresh(cx)
		return
	end
	local p, err = cx.canvas:open({
		title = "Agent Sessions",
		about = "Session history for Claude Code, Antigravity, Pi, omp and Carly. Resume or copy a command; aliases and tags live in this plugin's own database and never touch the session files.",
		view = ui.node("col", { gap = "sm" }, { ui.text("Scanning sessions…") }),
	})
	if not p then
		cx:toast("error", "Could not open Agent Sessions", tostring(err))
		return
	end
	S.pane = p
	refresh(cx)
end

local function resume(cx, s)
	if not safe_id(s.id) then
		cx:toast("error", "This session id can't be resumed safely", tostring(s.id))
		return
	end
	local cmd = resume_cmd(s)
	if not cmd then
		cx:toast("error", "No resume command for " .. s.agent)
		return
	end
	local spec = { name = s.agent .. " resume", launch = { command = cmd } }
	if s.cwd and s.cwd ~= "" then
		spec.cwd = s.cwd
	end
	local tab, err = cx.layout:tab(spec)
	if not tab then
		cx:toast("error", "Could not open the resume tab", tostring(err):sub(1, 200))
	end
end

local function shell_quote_dir(shell, cwd)
	local base = ((shell or ""):match("[^\\/]+$") or shell or ""):lower()
	if base:find("cmd", 1, true) then
		return 'cd /d "' .. cwd .. '"'
	elseif base:find("pwsh", 1, true) or base:find("powershell", 1, true) then
		return "Set-Location -LiteralPath '" .. cwd:gsub("'", "''") .. "'"
	end
	return "cd '" .. cwd:gsub("'", "'\\''") .. "'"
end

local function copy_payload(cx, s)
	local cmd = resume_cmd(s)
	if not cmd then
		if s.path and s.path ~= "" then
			cx:copy(s.path)
			cx:toast("info", "Copied transcript path", s.path)
		end
		return
	end
	local cwd = s.cwd or ""
	local cd = ""
	if cwd ~= "" then
		local shell = tostring(cx.settings:get("shell") or "")
		cd = shell_quote_dir(shell, cwd) .. "\n"
	end
	cx:copy(cd .. cmd)
	cx:toast("info", "Copied resume command", cmd)
end

local function open_detail(cx, s)
	local key = key_of(s)
	S.detail = s
	S.transcript = nil
	S.loading = true
	render(cx)
	local ok, err = run_node({ "transcript.js", "--agent", s.agent, "--path", s.path or "", "--id", s.id }, 30000, function(r, cx2)
		if not S.detail or key_of(S.detail) ~= key then return end
		S.loading = false
		if r.status == 0 and r.stdout ~= "" then
			S.transcript = r.stdout
		else
			S.transcript = "_Could not read this transcript._\n\n```\n" .. (r.stderr or ""):sub(1, 800) .. "\n```"
		end
		render(cx2)
	end)
	if not ok then
		if not S.detail or key_of(S.detail) ~= key then return end
		S.loading = false
		S.transcript = "_node is not available._"
		render(cx)
		cx:toast("error", "Agent Sessions: node not found", tostring(err):sub(1, 200))
	end
end

local function rename(cx, s)
	local t = tags_of(s)
	cx:prompt({ value = t.alias or "", placeholder = "session name" }):next(function(line, err, cx2)
		if line == nil then return end
		line = trim(line)
		local key = key_of(s)
		local old = S.tags[key]
		local old_copy = old and { alias = old.alias or "", tags = old.tags or {} } or nil
		S.tags[key] = { alias = line, tags = t.tags or {} }
		local ok, e = run_node({ "tags.js", "set", s.agent, s.id, line, tern.json.encode(t.tags or {}) }, 10000, function(r, cx3)
			if r.status ~= 0 then
				S.tags[key] = old_copy
				cx3:toast("error", "Could not save name", (r.stderr or ""):sub(1, 200))
			end
			render(cx3)
		end)
		if not ok then
			S.tags[key] = old_copy
			cx2:toast("error", "Could not save name", tostring(e):sub(1, 200))
		end
		render(cx2)
	end)
end

local function edit_tags(cx, s)
	local t = tags_of(s)
	cx:prompt({ value = table.concat(t.tags or {}, ", "), placeholder = "tag1, tag2" }):next(function(line, err, cx2)
		if line == nil then return end
		local tags = {}
		for x in line:gmatch("[^,]+") do
			x = trim(x)
			if x ~= "" then tags[#tags + 1] = x end
		end
		local key = key_of(s)
		local old = S.tags[key]
		local old_copy = old and { alias = old.alias or "", tags = old.tags or {} } or nil
		S.tags[key] = { alias = t.alias or "", tags = tags }
		local ok, e = run_node({ "tags.js", "set", s.agent, s.id, t.alias or "", tern.json.encode(tags) }, 10000, function(r, cx3)
			if r.status ~= 0 then
				S.tags[key] = old_copy
				cx3:toast("error", "Could not save tags", (r.stderr or ""):sub(1, 200))
			end
			render(cx3)
		end)
		if not ok then
			S.tags[key] = old_copy
			cx2:toast("error", "Could not save tags", tostring(e):sub(1, 200))
		end
		render(cx2)
	end)
end

local function pick_folder(cx)
	local seen, items = {}, { { label = "(any folder)", detail = "" } }
	for _, s in ipairs(S.rows) do
		local c = s.cwd or ""
		if c ~= "" and not seen[c] then
			seen[c] = true
			items[#items + 1] = { label = short_cwd(s), detail = c }
		end
	end
	table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
	cx:pick({ items = items }):next(function(item, err, cx2)
		if not item then return end
		S.filter.folder = (item.detail ~= "" and item.detail) or nil
		S.page = 0
		render(cx2)
	end)
end

local function pick_tag(cx)
	local seen, items = {}, { { label = "(any tag)", detail = "" } }
	for _, s in ipairs(S.rows) do
		for _, t in ipairs(tags_of(s).tags or {}) do
			if not seen[t] then
				seen[t] = true
				items[#items + 1] = { label = "#" .. t, detail = t }
			end
		end
	end
	table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
	cx:pick({ items = items }):next(function(item, err, cx2)
		if not item then return end
		S.filter.tag = (item.detail ~= "" and item.detail) or nil
		S.page = 0
		render(cx2)
	end)
end

local function pick_search(cx)
	cx:prompt({ value = S.filter.q or "", placeholder = "search title, folder or tag" }):next(function(line, err, cx2)
		if line == nil then return end
		line = trim(line)
		S.filter.q = line ~= "" and line or nil
		S.page = 0
		render(cx2)
	end)
end

local function remove_row(s)
	for i, x in ipairs(S.rows) do
		if x.agent == s.agent and x.id == s.id then
			table.remove(S.rows, i)
			break
		end
	end
	S.tags[key_of(s)] = nil
	S.hidden[key_of(s)] = nil
	if S.detail and key_of(S.detail) == key_of(s) then
		S.detail = nil
		S.transcript = nil
	end
end

local function hide_session(cx, s)
	local key = key_of(s)
	local old = S.hidden[key]
	S.hidden[key] = true
	local ok, err = run_node({ "tags.js", "hide", s.agent, s.id }, 10000, function(r, cx2)
		if r.status ~= 0 then
			S.hidden[key] = old
			cx2:toast("error", "Could not hide session", (r.stderr or ""):sub(1, 200))
		end
		render(cx2)
	end)
	if not ok then
		S.hidden[key] = old
		cx:toast("error", "Could not hide session", tostring(err):sub(1, 200))
	end
	render(cx)
end

local function restore_session(cx, s)
	local key = key_of(s)
	local old = S.hidden[key]
	S.hidden[key] = nil
	local ok, err = run_node({ "tags.js", "unhide", s.agent, s.id }, 10000, function(r, cx2)
		if r.status ~= 0 then
			S.hidden[key] = old
			cx2:toast("error", "Could not restore session", (r.stderr or ""):sub(1, 200))
		end
		render(cx2)
	end)
	if not ok then
		S.hidden[key] = old
		cx:toast("error", "Could not restore session", tostring(err):sub(1, 200))
	end
	render(cx)
end

local function delete_one(cx, s, cb)
	local started, why = run_node({ "delete.js", "--agent", s.agent, "--id", s.id, "--path", s.path or "" }, 30000, function(r, cx3)
		local ok, errors, warnings = false, {}, {}
		if r.status == 0 then
			local okj, parsed = pcall(tern.json.decode, r.stdout)
			if okj and parsed and parsed.ok then
				ok = true
				warnings = parsed.warnings or {}
			elseif okj and parsed and parsed.errors then
				errors = parsed.errors
				warnings = parsed.warnings or {}
			else
				errors = { (r.stderr or "delete failed"):sub(1, 200) }
			end
		else
			errors = { (r.stderr or ""):sub(1, 200) }
		end
		if ok then
			remove_row(s)
			run_node({ "tags.js", "set", s.agent, s.id, "", "[]" }, 10000, function() end)
			run_node({ "tags.js", "unhide", s.agent, s.id }, 10000, function() end)
			render(cx3)
		end
		cb(ok, errors, warnings, cx3)
	end)
	if not started then
		tern.timer(0, function(fresh)
			cb(false, { tostring(why) }, {}, fresh)
		end)
	end
end

local function confirm_delete(cx, s)
	cx:pick({ items = {
		{ label = "Delete permanently", detail = "id " .. s.id },
		{ label = "Cancel" },
	} }):next(function(item, err, cx2)
		if not item or item.label ~= "Delete permanently" then return end
		delete_one(cx2, s, function(ok, errors, warnings, cx3)
			local c = cx3 or cx2
			if ok then
				c:toast("success", "Session deleted", s.id)
				if #warnings > 0 then
					c:toast("info", "Some cleanup failed", table.concat(warnings, "; "):sub(1, 240))
				end
			else
				c:toast("error", "Could not delete session", table.concat(errors, "; "):sub(1, 240))
			end
			render(c)
		end)
	end)
end

local function delete_selected(cx)
	local keys = {}
	for k in pairs(S.selected) do
		if find_session(k) then keys[#keys + 1] = k end
	end
	table.sort(keys)
	if #keys == 0 then return end
	cx:pick({ items = {
		{ label = "Delete " .. tostring(#keys) .. (#keys == 1 and " session" or " sessions") .. " permanently", detail = "cannot be undone" },
		{ label = "Cancel" },
	} }):next(function(item, err, cx2)
		if not item or item.label:sub(1, 6) ~= "Delete" then return end
		local deleted, failed, cleanup, index = 0, {}, {}, 1
		local function step(cx3)
			while index <= #keys do
				local s = find_session(keys[index])
				index = index + 1
				if s then
					delete_one(cx3, s, function(ok, errors, warnings, cx4)
						if ok then
							deleted = deleted + 1
							for _, w in ipairs(warnings) do
								cleanup[#cleanup + 1] = s.id .. ": " .. tostring(w)
							end
						else
							failed[#failed + 1] = s.id .. ": " .. table.concat(errors, "; "):sub(1, 120)
						end
						step(cx4 or cx3)
					end)
					return
				end
			end
			S.selecting = false
			S.selected = {}
			render(cx3)
			if #failed > 0 then
				cx3:toast("error", "Deleted " .. deleted .. " of " .. (deleted + #failed) .. " sessions", table.concat(failed, "; "):sub(1, 240))
			else
				cx3:toast("success", "Deleted " .. deleted .. (deleted == 1 and " session" or " sessions"))
			end
			if #cleanup > 0 then
				cx3:toast("info", "Some cleanup failed", table.concat(cleanup, "; "):sub(1, 240))
			end
		end
		step(cx2)
	end)
end

local function delete_session(cx, s)
	cx:pick({ items = {
		{ label = "Hide from this list", detail = "keeps the session files" },
		{ label = "Delete from disk…", detail = "permanent, cannot be undone" },
	} }):next(function(item, err, cx2)
		if not item then return end
		if item.label == "Hide from this list" then
			hide_session(cx2, s)
		elseif item.label == "Delete from disk…" then
			confirm_delete(cx2, s)
		end
	end)
end

tern.command({
	id = "open",
	title = "Agent sessions",
	icon = "history",
	group = "Agents",
	run = function(cx)
		open_dashboard(cx)
	end,
})

tern.on("window_start", function(cx)
	local pane = find_canvas(cx)
	if pane then
		S.pane = pane
		refresh(cx)
	end
end)

tern.on("canvas_action", function(ev, cx)
	local act = ev.act or ""
	if act == "back" then
		S.detail = nil
		S.transcript = nil
		render(cx)
		return true
	elseif act == "group" then
		S.group = (S.group == "agent" and "folder") or (S.group == "folder" and "tag") or "agent"
		S.page = 0
		render(cx)
		return true
	elseif act == "rescan" then
		refresh(cx)
		return true
	elseif act == "toggle-hidden" then
		S.show_hidden = not S.show_hidden
		S.page = 0
		render(cx)
		return true
	elseif act == "pick:folder" then
		pick_folder(cx)
		return true
	elseif act == "pick:tag" then
		pick_tag(cx)
		return true
	elseif act == "pick:search" then
		pick_search(cx)
		return true
	elseif act == "toggle-all" then
		local collapse = false
		for _, s in ipairs(S.rows) do
			if matches(s) and group_open(group_of(s)) then
				collapse = true
				break
			end
		end
		for _, s in ipairs(S.rows) do
			if matches(s) then
				S.collapsed[group_of(s)] = collapse
			end
		end
		S.page = 0
		render(cx)
		return true
	elseif act == "select-mode" then
		S.selecting = not S.selecting
		clear_selection()
		render(cx)
		return true
	elseif act == "clear-filters" then
		S.filter.folder, S.filter.tag, S.filter.q = nil, nil, nil
		S.page = 0
		if S.selecting then clear_selection() end
		render(cx)
		return true
	elseif act == "page-prev" then
		if (S.page or 0) > 0 then
			S.page = S.page - 1
			render(cx)
		end
		return true
	elseif act == "page-next" then
		S.page = (S.page or 0) + 1
		render(cx)
		return true
	elseif act == "select-all" then
		local any, all = false, true
		for _, s in ipairs(S.rows) do
			if matches(s) then
				any = true
				if not S.selected[key_of(s)] then all = false; break end
			end
		end
		local target = not (any and all)
		for _, s in ipairs(S.rows) do
			if matches(s) then
				S.selected[key_of(s)] = target or nil
			end
		end
		render(cx)
		return true
	elseif act == "delete-selected" then
		delete_selected(cx)
		return true
	end

	if act:sub(1, 6) == "group:" then
		local g = act:sub(7)
		S.collapsed[g] = group_open(g)
		render(cx)
		return true
	end

	local op, key = act:match("^(%a+):(.+)$")
	if op and key then
		local s = find_session(key)
		if not s then return false end
		if op == "select" then
			open_detail(cx, s)
			return true
		elseif op == "mark" then
			local k = key_of(s)
			if S.selected[k] then
				S.selected[k] = nil
			else
				S.selected[k] = true
			end
			render(cx)
			return true
		elseif op == "resume" then
			resume(cx, s)
			return true
		elseif op == "copy" then
			copy_payload(cx, s)
			return true
		elseif op == "copypath" then
			if s.path and s.path ~= "" then
				cx:copy(s.path)
				cx:toast("info", "Copied transcript path", s.path)
			end
			return true
		elseif op == "rename" then
			rename(cx, s)
			return true
		elseif op == "tag" then
			edit_tags(cx, s)
			return true
		elseif op == "delete" then
			delete_session(cx, s)
			return true
		elseif op == "restore" then
			restore_session(cx, s)
			return true
		end
	end
	return false
end)
