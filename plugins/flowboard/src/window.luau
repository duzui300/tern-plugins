--!strict

local KIND = "flowboard.board"

local function join(directory: string, name: string): string
	local separator = if directory:find("\\", 1, true) then "\\" else "/"
	return directory .. separator .. name
end

local function looks_like_board(path: string): boolean
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return false
	end
	return text:find("##%s+%S") ~= nil and text:find("%-%s+%[[ xX]%]") ~= nil
end

local function find_board(cx: WindowCx): string?
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	if info and info.block == KIND then
		cx.layout:focus(info.pane)
		return nil
	end
	if info and info.kind == "board" and info.path then
		return info.path
	end
	if info and info.path and info.path:match("%.md$") and looks_like_board(info.path) then
		return info.path
	end
	for _, pane in cx.session:panes() do
		if pane.kind == "board" and pane.path then
			return pane.path
		end
	end
	for _, pane in cx.session:panes() do
		if pane.path and pane.path:match("%.md$") and looks_like_board(pane.path) then
			return pane.path
		end
	end
	if info and info.cwd and info.cwd ~= "" then
		for _, name in { "TODO.md", "TASKS.md", "BOARD.md", "KANBAN.md" } do
			local candidate = join(info.cwd, name)
			if tern.fs.exists(candidate) then
				return candidate
			end
		end
	end
	return nil
end

local function open(cx: WindowCx, how: How)
	local path = find_board(cx)
	if path == nil then
		return
	end
	local pane = cx:new_block(KIND, { path }, how)
	if pane == nil then
		cx:toast("error", "Flow Board", "Flow Board isn't loaded on this host.")
	end
end

tern.command({
	id = "open",
	title = "Flow Board: Open board",
	icon = "kanban",
	group = "Flow Board",
	run = function(cx: WindowCx)
		open(cx, "beside")
	end,
})

tern.command({
	id = "open-tab",
	title = "Flow Board: Open board in a tab",
	icon = "kanban",
	group = "Flow Board",
	run = function(cx: WindowCx)
		open(cx, "tab")
	end,
})
