--!strict

local ui = tern.ui

type Card = {
	id: number,
	text: string,
	done: boolean,
	raw: string?,
	home: number?,
}

type Lane = {
	id: number,
	title: string,
	done: boolean,
	cards: { Card },
	extras: { [number]: { string } },
	heading_raw: string?,
}

type Editing = {
	kind: "card" | "lane",
	lane: number,
	card: number?,
	at: number?,
	text: string,
	cursor: number,
	new_lane: boolean?,
	base_text: string?,
}

type Doc = {
	lanes: { Lane },
	preamble: { string },
	newline: string,
	final_newline: boolean,
}

type State = {
	path: string,
	lanes: { Lane },
	preamble: { string },
	newline: string,
	final_newline: boolean,
	disk_text: string?,
	conflict: boolean,
	cols: number,
	filter: string,
	filter_cursor: number,
	hide_done: boolean,
	view: "board" | "list",
	folded: { [number]: boolean },
	editing: Editing?,
	focus: string?,
	selected: { lane: number, card: number }?,
	pending_delete_lane: number?,
	undo: { string },
	redo: { string },
	error: string?,
}

local DONE_MARKER = "<!-- flowboard:done -->"

local function with(node: Node, props: { [string]: any }): Node
	local merged: { [string]: any } = node.p or {}
	for name, prop in props do
		merged[name] = prop
	end
	node.p = merged
	return node
end

local function trim(text: string): string
	return (text:match("^%s*(.-)%s*$")) or ""
end

local function join(directory: string, name: string): string
	local separator = if directory:find("\\", 1, true) then "\\" else "/"
	return directory .. separator .. name
end

local function basename(path: string): string
	return path:match("[^\\/]+$") or path
end

local function dirname(path: string): string
	local name = basename(path)
	return path:sub(1, #path - #name):gsub("[\\/]+$", "")
end

local function utf16_len(text: string): number
	local length = 0
	for _, codepoint in utf8.codes(text) do
		length += if codepoint > 0xFFFF then 2 else 1
	end
	return length
end

local function u16_to_byte(text: string, index: number): number
	if index <= 0 then
		return 1
	end
	local units = 0
	local byte = 1
	while byte <= #text do
		if units >= index then
			return byte
		end
		local codepoint = utf8.codepoint(text, byte)
		local width = if codepoint > 0xFFFF then 2 else 1
		if units + width > index then
			return byte
		end
		units += width
		local next_byte = utf8.offset(text, 2, byte)
		byte = next_byte or (#text + 1)
	end
	return #text + 1
end

local function splice16(text: string, from: number, to: number, insert: string): string
	local start = u16_to_byte(text, from)
	local stop = u16_to_byte(text, to)
	return text:sub(1, start - 1) .. insert .. text:sub(stop)
end

local function previous16(text: string, cursor: number): number
	if cursor <= 0 then
		return 0
	end
	local before = u16_to_byte(text, cursor - 1)
	local at = u16_to_byte(text, cursor)
	return if before == at then math.max(0, cursor - 2) else cursor - 1
end

local function next16(text: string, cursor: number): number
	local at = u16_to_byte(text, cursor)
	local after = u16_to_byte(text, cursor + 1)
	return if after == at then math.min(utf16_len(text), cursor + 2) else math.min(utf16_len(text), cursor + 1)
end

local last_card_id = 0
local last_lane_id = 0

local function new_card_id(): number
	last_card_id += 1
	return last_card_id
end

local function new_lane_id(): number
	last_lane_id += 1
	return last_lane_id
end


local function split_lines(text: string): { string }
	local lines: { string } = {}
	if text == "" then
		return lines
	end
	local pos = 1
	while pos <= #text do
		local nl = text:find("\n", pos, true)
		if nl then
			table.insert(lines, text:sub(pos, nl - 1))
			pos = nl + 1
		else
			table.insert(lines, text:sub(pos))
			break
		end
	end
	return lines
end

local function fence_mark(line: string): string?
	local ticks = line:match("^%s*(```+)")
	if ticks then
		return ticks:sub(1, 3)
	end
	local tildes = line:match("^%s*(~~~+)")
	if tildes then
		return tildes:sub(1, 3)
	end
	return nil
end

local function parse(text: string): Doc
	local newline = if text:find("\r\n", 1, true) then "\r\n" else "\n"
	local normalized = text:gsub("\r\n", "\n")
	local doc: Doc = {
		lanes = {},
		preamble = {},
		newline = newline,
		final_newline = normalized == "" or normalized:sub(-1) == "\n",
	}
	local lane: Lane? = nil
	local card_index = 0
	local fence: string? = nil
	local function add_raw(line: string)
		if lane then
			local bucket = lane.extras[card_index]
			if bucket == nil then
				bucket = {}
				lane.extras[card_index] = bucket
			end
			table.insert(bucket, line)
		else
			table.insert(doc.preamble, line)
		end
	end
	for _, line in ipairs(split_lines(normalized)) do
		local mark = fence_mark(line)
		if fence then
			add_raw(line)
			if mark == fence then
				fence = nil
			end
		elseif mark then
			add_raw(line)
			fence = mark
		else
			local title = line:match("^##%s+(.-)%s*$")
			if title then
				lane = {
					id = new_lane_id(),
					title = title,
					done = title:lower() == "done",
					cards = {},
					extras = { [0] = {} },
					heading_raw = line,
				}
				table.insert(doc.lanes, lane)
				card_index = 0
			elseif lane then
				local check, body = line:match("^%-%s+%[([ xX])%]%s+(.*)$")
				if check then
					table.insert(lane.cards, {
						id = new_card_id(),
						text = body,
						done = check ~= " ",
						raw = line,
					})
					card_index = #lane.cards
					lane.extras[card_index] = {}
				elseif trim(line) == DONE_MARKER then
					lane.done = true
				else
					add_raw(line)
				end
			else
				add_raw(line)
			end
		end
	end
	return doc
end

local function serialize(state: State): string
	local out: { string } = {}
	local function emit(line: string)
		table.insert(out, line)
	end
	for _, line in ipairs(state.preamble) do
		emit(line)
	end
	for index, lane in ipairs(state.lanes) do
		emit(lane.heading_raw or ("## " .. (if lane.title == "" then "Untitled" else lane.title)))
		if lane.done and lane.title:lower() ~= "done" then
			emit(DONE_MARKER)
		end
		local function emit_extras(anchor: number)
			for _, line in ipairs(lane.extras[anchor] or {}) do
				if trim(line) ~= DONE_MARKER then
					emit(line)
				end
			end
		end
		emit_extras(0)
		for card_index, card in ipairs(lane.cards) do
			local line = card.raw
			if line == nil or line == "" then
				line = "- [" .. (if card.done then "x" else " ") .. "] " .. card.text
			else
				line = line:gsub("%[([ xX])%]", if card.done then "[x]" else "[ ]", 1)
			end
			card.raw = line
			emit(line)
			emit_extras(card_index)
		end
		if index < #state.lanes then
			if out[#out] ~= "" then
				emit("")
			end
		end
	end
	if #out == 0 then
		return ""
	end
	local text = table.concat(out, state.newline)
	if state.final_newline then
		text = text .. state.newline
	end
	return text
end

local function read_board(path: string): (Doc?, string?, string?)
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return nil, nil, tostring(text)
	end
	return parse(text), text, nil
end

local function apply_doc(state: State, doc: Doc, text: string)
	state.lanes = doc.lanes
	state.preamble = doc.preamble
	state.newline = doc.newline
	state.final_newline = doc.final_newline
	state.disk_text = text
end

local function write_board(state: State, force: boolean?): boolean
	local text = serialize(state)
	local ok, current = pcall(tern.fs.read, state.path)
	if not ok then
		if state.disk_text ~= nil and not force then
			state.conflict = true
			state.error = "The board file is missing or unreadable. Reload from disk, or overwrite it."
			return false
		end
	elseif state.disk_text ~= nil and current ~= state.disk_text and not force then
		state.conflict = true
		state.error = "The file changed on disk. Reload from disk, or use Overwrite file on disk."
		return false
	end
	if ok and current == text then
		state.disk_text = current
		state.conflict = false
		state.error = nil
		return true
	end
	local wrote, message = pcall(tern.fs.write, state.path, text)
	if not wrote then
		state.error = tostring(message)
		return false
	end
	state.disk_text = text
	state.conflict = false
	state.error = nil
	return true
end

local function counts(lanes: { Lane }): (number, number)
	local open, done = 0, 0
	for _, lane in ipairs(lanes) do
		for _, card in ipairs(lane.cards) do
			if card.done then
				done += 1
			else
				open += 1
			end
		end
	end
	return open, done
end

local LANE_CELLS = 34

local function estimated(lane: Lane, state: State): number
	local height = 4.5 + 2.75 + 1
	local query = state.filter:lower()
	for _, card in ipairs(lane.cards) do
		if not (state.hide_done and card.done) and (query == "" or card.text:lower():find(query, 1, true) ~= nil) then
			local chars = utf8.len(card.text) or #card.text
			local lines = math.max(1, math.ceil(chars / 32))
			height += 4.25 + (lines - 1) * 2.3 + 0.5
		end
	end
	return height
end

local function packed_columns(state: State, lanes: { Lane }, cols: number): { { Lane } }
	local count = math.max(1, math.min(#lanes, math.floor(math.max(LANE_CELLS, cols) / LANE_CELLS)))
	if count <= 1 or #lanes == 0 then
		return { lanes }
	end
	local prefix: { number } = { 0 }
	for index, lane in ipairs(lanes) do
		prefix[index + 1] = prefix[index] + estimated(lane, state)
	end
	local dp: { { number } } = {}
	local cut: { { number } } = {}
	for column = 1, count do
		dp[column] = {}
		cut[column] = {}
	end
	for index = 1, #lanes do
		dp[1][index] = prefix[index + 1]
	end
	for column = 2, count do
		for index = 1, #lanes do
			dp[column][index] = math.huge
			for split = column - 1, index - 1 do
				local cost = math.max(dp[column - 1][split], prefix[index + 1] - prefix[split + 1])
				if cost < dp[column][index] then
					dp[column][index] = cost
					cut[column][index] = split
				end
			end
		end
	end
	local groups: { { Lane } } = {}
	local index = #lanes
	for column = count, 2, -1 do
		local split = cut[column][index]
		local group: { Lane } = {}
		for lane_index = split + 1, index do
			table.insert(group, lanes[lane_index])
		end
		table.insert(groups, 1, group)
		index = split
	end
	local first: { Lane } = {}
	for lane_index = 1, index do
		table.insert(first, lanes[lane_index])
	end
	table.insert(groups, 1, first)
	return groups
end

local function done_lane(state: State): number
	for index, lane in ipairs(state.lanes) do
		if lane.done then
			return index
		end
	end
	for index, lane in ipairs(state.lanes) do
		if lane.title:lower() == "done" then
			lane.done = true
			return index
		end
	end
	table.insert(state.lanes, {
		id = new_lane_id(),
		title = "Done",
		done = true,
		cards = {},
		extras = { [0] = {} },
		heading_raw = nil,
	})
	return #state.lanes
end

local function push_undo(state: State, text: string)
	table.insert(state.undo, text)
	if #state.undo > 60 then
		table.remove(state.undo, 1)
	end
	state.redo = {}
end

local function remember(state: State)
	push_undo(state, serialize(state))
end

local function restore_text(state: State, text: string)
	local doc = parse(text)
	state.lanes = doc.lanes
	state.preamble = doc.preamble
	state.newline = doc.newline
	state.final_newline = doc.final_newline
	state.selected = nil
	state.editing = nil
	state.pending_delete_lane = nil
end

local function undo(state: State, cx: BlockCx?)
	if #state.undo == 0 then
		return
	end
	local clear_focus = state.focus == "editor"
	table.insert(state.redo, serialize(state))
	local text = table.remove(state.undo) or ""
	restore_text(state, text)
	if clear_focus then
		state.focus = nil
		if cx then cx:frame({ { "focus", nil } }) end
	end
	write_board(state)
end

local function redo(state: State, cx: BlockCx?)
	if #state.redo == 0 then
		return
	end
	local clear_focus = state.focus == "editor"
	table.insert(state.undo, serialize(state))
	local text = table.remove(state.redo) or ""
	restore_text(state, text)
	if clear_focus then
		state.focus = nil
		if cx then cx:frame({ { "focus", nil } }) end
	end
	write_board(state)
end

local function take_card(lane: Lane, index: number): (Card, { string })
	local card = lane.cards[index]
	local notes = lane.extras[index] or {}
	local count = #lane.cards
	table.remove(lane.cards, index)
	for k = index + 1, count do
		lane.extras[k - 1] = lane.extras[k]
	end
	lane.extras[count] = nil
	return card, notes
end

local function put_card(lane: Lane, at: number, card: Card, notes: { string }?)
	local count = #lane.cards
	at = math.max(1, math.min(count + 1, at))
	for k = count, at, -1 do
		lane.extras[k + 1] = lane.extras[k]
	end
	table.insert(lane.cards, at, card)
	lane.extras[at] = notes or {}
	lane.extras[0] = lane.extras[0] or {}
end

local function remove_card(lane: Lane, index: number)
	local count = #lane.cards
	local notes = lane.extras[index] or {}
	local previous = lane.extras[index - 1] or {}
	for _, line in ipairs(notes) do
		table.insert(previous, line)
	end
	lane.extras[index - 1] = previous
	table.remove(lane.cards, index)
	for k = index + 1, count do
		lane.extras[k - 1] = lane.extras[k]
	end
	lane.extras[count] = nil
end

local function focus_later(cx: BlockCx?, id: string)
	if not cx then
		return
	end
	tern.timer(0, function()
		pcall(function()
			cx:frame({ { "focus", id } })
		end)
	end)
end

local function clear_editing(state: State, cx: BlockCx?)
	state.editing = nil
	if state.focus == "editor" then
		state.focus = nil
		if cx then
			cx:frame({ { "focus", nil } })
		end
	end
end

local editor_id: (State, string, number) -> string

local function selected_card(state: State): (Lane?, Card?, number?)
	local selected = state.selected
	if selected == nil then
		return nil, nil, nil
	end
	local lane = state.lanes[selected.lane]
	local card = lane and lane.cards[selected.card]
	return lane, card, selected.card
end

local function toggle_card(state: State, lane_index: number, card_index: number, checked: boolean)
	local lane = state.lanes[lane_index]
	if lane == nil then
		return
	end
	local card = lane.cards[card_index]
	if card == nil then
		return
	end
	if checked == card.done and ((checked and lane.done) or (not checked and not lane.done)) then
		return
	end
	remember(state)
	local notes
	card, notes = take_card(lane, card_index)
	card.raw = nil
	card.done = checked
	if checked then
		if not lane.done then
			card.home = lane.id
		end
		local target = done_lane(state)
		local destination = state.lanes[target]
		put_card(destination, #destination.cards + 1, card, notes)
		state.selected = { lane = target, card = #destination.cards }
	else
		local target: number? = nil
		if card.home then
			for index, candidate in ipairs(state.lanes) do
				if candidate.id == card.home and not candidate.done then
					target = index
					break
				end
			end
		end
		if target == nil and not lane.done then
			target = lane_index
		end
		if target == nil then
			for index, candidate in ipairs(state.lanes) do
				if not candidate.done then
					target = index
					break
				end
			end
		end
		if target then
			local destination = state.lanes[target]
			put_card(destination, #destination.cards + 1, card, notes)
			state.selected = { lane = target, card = #destination.cards }
		else
			local at = math.min(card_index, #lane.cards + 1)
			put_card(lane, at, card, notes)
			state.selected = { lane = lane_index, card = at }
		end
		card.home = nil
	end
	write_board(state)
end

local commit_editor: (State) -> ()

local function start_card_edit(state: State, cx: BlockCx, lane_index: number, card_index: number?, at: number?)
	if state.editing and state.editing.kind == "lane" then
		commit_editor(state)
	end
	local lane = state.lanes[lane_index]
	if lane == nil then
		return
	end
	local text = ""
	local cursor = 0
	if card_index then
		local card = lane.cards[card_index]
		if card then
			text = card.text
			cursor = utf16_len(text)
		end
	end
	state.editing = {
		kind = "card",
		lane = lane_index,
		card = card_index,
		at = at or (#lane.cards + 1),
		text = text,
		cursor = cursor,
	}
	state.focus = "editor"
	state.selected = if card_index then { lane = lane_index, card = card_index } else nil
	state.folded[lane.id] = nil
	focus_later(cx, editor_id(state, "card", lane_index))
end

local function start_lane_edit(state: State, cx: BlockCx, lane_index: number)
	if state.editing then
		commit_editor(state)
	end
	local lane = state.lanes[lane_index]
	if lane == nil then
		return
	end
	state.editing = {
		kind = "lane",
		lane = lane_index,
		text = lane.title,
		cursor = utf16_len(lane.title),
	}
	state.focus = "editor"
	state.folded[lane.id] = nil
	focus_later(cx, editor_id(state, "lane", lane_index))
end

commit_editor = function(state: State)
	local editing = state.editing
	if editing == nil then
		return
	end
	local text = trim(editing.text)
	if editing.kind == "card" then
		if text == "" then
			state.editing = nil
			state.focus = nil
			return
		end
		local lane = state.lanes[editing.lane]
		if lane == nil then
			state.editing = nil
			state.focus = nil
			return
		end
		remember(state)
		if editing.card then
			local card = lane.cards[editing.card]
			if card then
				card.text = text
				card.raw = nil
			end
		else
			local at = math.max(1, math.min(#lane.cards + 1, editing.at or (#lane.cards + 1)))
			put_card(lane, at, { id = new_card_id(), text = text, done = false, raw = nil }, {})
			state.selected = { lane = editing.lane, card = at }
		end
	else
		local lane = state.lanes[editing.lane]
		if lane then
			if editing.new_lane then
				push_undo(state, editing.base_text or serialize(state))
			else
				remember(state)
			end
			if text == "" then
				text = "New lane"
			end
			local was_done = lane.done
			lane.title = text
			lane.done = was_done or text:lower() == "done"
			lane.heading_raw = nil
		end
	end
	state.editing = nil
	state.focus = nil
	write_board(state)
end

local function cancel_editor(state: State, cx: BlockCx?)
	local editing = state.editing
	if editing and editing.kind == "lane" and editing.new_lane then
		local index = editing.lane
		if state.lanes[index] then
			table.remove(state.lanes, index)
			if state.selected and state.selected.lane > index then
				state.selected.lane -= 1
			end
		end
	end
	state.editing = nil
	state.focus = nil
	if cx then
		cx:frame({ { "focus", nil } })
	end
end

local function insert_lane(state: State, cx: BlockCx, after: number?)
	if state.editing then
		commit_editor(state)
	end
	local base_text = serialize(state)
	local at = if after then math.min(#state.lanes + 1, after + 1) else #state.lanes + 1
	local lane: Lane = {
		id = new_lane_id(),
		title = "New lane",
		done = false,
		cards = {},
		extras = { [0] = {} },
		heading_raw = nil,
	}
	table.insert(state.lanes, at, lane)
	state.selected = nil
	state.pending_delete_lane = nil
	start_lane_edit(state, cx, at)
	if state.editing then
		state.editing.new_lane = true
		state.editing.base_text = base_text
		state.editing.text = ""
		state.editing.cursor = 0
	end
end

local function card_menu(state: State, lane_index: number, card_index: number): { any }
	local items: { any } = {
		{ id = "edit_card:" .. lane_index .. ":" .. card_index, label = "Edit card", icon = "pencil" },
		{ id = "new_card_after:" .. lane_index .. ":" .. card_index, label = "New card below", icon = "plus" },
	}
	local moves: { any } = {}
	for index, lane in ipairs(state.lanes) do
		if index ~= lane_index then
			moves[#moves + 1] = {
				id = "move_card:" .. lane_index .. ":" .. card_index .. ":" .. index,
				label = "Move to " .. lane.title,
				icon = if lane.done then "check" else "arrow-right",
			}
		end
	end
	if #moves > 0 then
		items[#items + 1] = "-"
		for _, move in moves do
			items[#items + 1] = move
		end
	end
	items[#items + 1] = "-"
	items[#items + 1] = { id = "delete_card:" .. lane_index .. ":" .. card_index, label = "Delete card", icon = "trash", danger = true }
	return items
end

local function card_row(state: State, lane_index: number, card_index: number, card: Card): Node
	local selected = state.selected
	local is_selected = selected ~= nil and selected.lane == lane_index and selected.card == card_index
	local id = card.id
	if id == nil then
		id = new_card_id()
		card.id = id
	end
	return ui.el("div", {
		key = "card:" .. id,
		class = "fb-card"
			.. (if card.done then " fb-done" else "")
			.. (if is_selected then " fb-selected" else ""),
		role = "flowboard.card",
		actions = { menu = card_menu(state, lane_index, card_index) },
	}, {
		ui.el("input", {
			type = "checkbox",
			name = "toggle:" .. id,
			checked = card.done,
		}),
		ui.el("div", {
			class = "fb-card-text",
			actions = {
				click = "select:" .. lane_index .. ":" .. card_index,
				dblclick = "edit_card:" .. lane_index .. ":" .. card_index,
				menu = card_menu(state, lane_index, card_index),
			},
		}, {
			ui.el("div", { class = "fb-card-title", text = card.text, actions = { menu = card_menu(state, lane_index, card_index) } }),
		}),
	})
end

local function lane_menu(state: State, lane_index: number): { any }
	local lane = state.lanes[lane_index]
	local named_done = lane.title:lower() == "done"
	local delete_label = if state.pending_delete_lane == lane_index then "Confirm delete lane" else "Delete lane"
	return {
		{ id = "lane_new_card:" .. lane_index, label = "New card" },
		{ id = "rename_lane:" .. lane_index, label = "Rename lane…" },
		{ id = "new_lane_after:" .. lane_index, label = "New lane" },
		{ id = "move_lane_left:" .. lane_index, label = "Move lane left", disabled = lane_index <= 1 },
		{ id = "move_lane_right:" .. lane_index, label = "Move lane right", disabled = lane_index >= #state.lanes },
		{ id = "done_lane:" .. lane_index, label = "Done lane", checked = lane.done, disabled = named_done },
		{ id = "delete_lane:" .. lane_index, label = delete_label, danger = true },
	}
end

local function board_menu(state: State): { any }
	local items: { any } = {
		{ id = "new_card_below", label = "New card below", keys = { "o" } },
		{ id = "new_lane", label = "New lane" },
		"-",
		{ id = "undo", label = "Undo board change", keys = { "ctrl", "z" }, disabled = #state.undo == 0 },
		{ id = "redo", label = "Redo board change", keys = { "ctrl", "y" }, disabled = #state.redo == 0 },
		"-",
		{ id = "hide_done", label = "Hide done cards", keys = { "shift", "x" }, checked = state.hide_done },
		{ id = "switch_view", label = "Switch board/list view", keys = { "v" } },
		"-",
		{ id = "refresh", label = "Reload from disk" },
	}
	if state.conflict then
		table.insert(items, { id = "force_write", label = "Overwrite file on disk", danger = true })
	end
	table.insert(items, "-")
	table.insert(items, { id = "open_markdown", label = "Open as Markdown" })
	table.insert(items, { id = "reveal", label = "Open folder" })
	table.insert(items, { id = "copy_path", label = "Copy path" })
	table.insert(items, "-")
	table.insert(items, { id = "close", label = "Close board" })
	return items
end

local function lane_view(state: State, lane_index: number, lane: Lane): Node?
	local query = state.filter:lower()
	local visible = 0
	if query ~= "" then
		for _, card in ipairs(lane.cards) do
			if not (state.hide_done and card.done) and card.text:lower():find(query, 1, true) ~= nil then
				visible += 1
			end
		end
		if visible == 0 and not (state.editing and state.editing.lane == lane_index) then
			return nil
		end
	end

	local editing_lane = state.editing ~= nil and state.editing.kind == "lane" and state.editing.lane == lane_index
	local head: { Node } = {}
	if state.view == "list" then
		head[#head + 1] = with(ui.button("", {
			icon = if state.folded[lane.id] then "chev-r" else "chev",
			size = "sm",
			variant = "quiet",
			title = if state.folded[lane.id] then "Expand lane" else "Fold lane",
		}), { actions = { click = "fold:" .. lane_index } })
	end
	if editing_lane and state.editing then
		head[#head + 1] = ui.el("div", { key = "editor", class = "fb-lane-title" }, {
			ui.node("input", {
				key = "lane-editor",
				text = state.editing.text,
				cursor = state.editing.cursor,
				placeholder = "Lane name",
				aria = "Lane name",
			}),
		})
	else
		head[#head + 1] = ui.el("div", { class = "fb-lane-title" }, {
			ui.text({ ui.span(lane.title, "strong") }),
		})
	end
	head[#head + 1] = ui.el("span", { class = "fb-lane-count" }, {
		ui.text({ ui.span(tostring(#lane.cards), "muted") }),
	})
	head[#head + 1] = ui.node("row", { key = "spacer", grow = 1 })
	head[#head + 1] = with(ui.button("", {
		icon = "plus",
		size = "sm",
		variant = "quiet",
		title = "New card at the top",
	}), { actions = { click = "new_card_top:" .. lane_index } })
	head[#head + 1] = ui.node("menu", {
		key = "lane-menu",
		text = "•••",
		size = "sm",
		title = "Lane menu",
		trigger = "quiet",
		align = "end",
		items = lane_menu(state, lane_index),
	})

	local body: { Node } = {}
	local editing_card = state.editing ~= nil and state.editing.kind == "card" and state.editing.lane == lane_index
	local editing_existing = editing_card and state.editing and state.editing.card ~= nil
	local new_at = if editing_card and state.editing and state.editing.card == nil
		then (state.editing.at or (#lane.cards + 1))
		else nil
	local function editor_node(): Node
		return ui.el("div", { key = "editor", class = "fb-editor" }, {
			ui.node("input", {
				key = "card-editor",
				text = state.editing and state.editing.text or "",
				cursor = state.editing and state.editing.cursor or 0,
				placeholder = "Card title",
				aria = "Card title",
			}),
		})
	end
	local editor_added = false
	local function add_editor()
		if not editor_added then
			body[#body + 1] = editor_node()
			editor_added = true
		end
	end
	if new_at == 1 then
		add_editor()
	end
	for card_index, card in ipairs(lane.cards) do
		local matches = query == "" or card.text:lower():find(query, 1, true) ~= nil
		local is_editing = editing_existing and state.editing and state.editing.card == card_index
		if is_editing then
			body[#body + 1] = editor_node()
		elseif matches and not (state.hide_done and card.done) then
			body[#body + 1] = card_row(state, lane_index, card_index, card)
		end
		if new_at == card_index + 1 then
			add_editor()
		end
	end
	if new_at ~= nil and new_at > #lane.cards then
		add_editor()
	end
	body[#body + 1] = with(ui.button("Add card", {
		icon = "plus",
		size = "sm",
		variant = "quiet",
	}), { actions = { click = "add_card:" .. lane_index } })

	local folded = state.view == "list" and state.folded[lane.id] == true
	return ui.el("div", {
		key = "lane" .. lane.id,
		class = "fb-lane" .. (if folded then " fb-folded" else ""),
		role = "flowboard.lane",
	}, {
		ui.el("div", { key = "head", class = "fb-lane-head" }, head),
		ui.el("div", { key = "body", class = "fb-lane-body" }, body),
	})
end

editor_id = function(state: State, kind: string, lane_index: number): string
	local lane = state.lanes[lane_index]
	local lane_key = if lane then "lane" .. lane.id else "lane" .. lane_index
	local lane_path = lane_key
	if state.view == "board" and lane then
		local groups = packed_columns(state, state.lanes, state.cols)
		local found = false
		for _, group in ipairs(groups) do
			for _, candidate in ipairs(group) do
				if candidate.id == lane.id then
					lane_path = "col" .. group[1].id .. "." .. lane_key
					found = true
					break
				end
			end
			if found then
				break
			end
		end
	end
	local prefix = "main.root.content." .. lane_path
	if kind == "lane" then
		return prefix .. ".head.editor.lane-editor"
	end
	return prefix .. ".body.editor.card-editor"
end

local function toolbar(state: State): Node
	local open, done = counts(state.lanes)
	local title = ui.el("div", { class = "fb-title" }, {
		ui.text({ ui.span(basename(state.path), "strong") }),
		ui.el("span", { class = "fb-path" }, {
			ui.text({ ui.span(dirname(state.path), "muted") }),
		}),
	})
	local count = ui.el("span", { class = "fb-count" }, {
		ui.text({ ui.span(tostring(open) .. " open · " .. tostring(done) .. " done", "muted") }),
	})
	local filter = ui.el("div", { class = "fb-filter" }, {
		ui.node("input", {
			key = "filter",
			text = state.filter,
			cursor = state.filter_cursor,
			placeholder = "Filter",
			aria = "Filter cards",
			icon = "search",
			clear = true,
		}),
	})
	local hide = with(ui.button("", {
		icon = if state.hide_done then "eye-off" else "eye",
		on = state.hide_done,
		title = "Hide done cards  Shift X",
	}), { actions = { click = "hide_done" } })
	local tabs = ui.node("tabs", {
		key = "view",
		variant = "segmented",
		active = state.view,
		items = {
			{ id = "board", label = "Board" },
			{ id = "list", label = "List" },
		},
	})
	local menu = ui.node("menu", {
		key = "board-menu",
		icon = "more",
		title = "Board menu",
		trigger = "quiet",
		align = "end",
		items = board_menu(state),
	})
	return ui.el("div", { key = "toolbar", class = "fb-toolbar" }, {
		title,
		ui.node("row", { key = "spacer", grow = 1 }),
		count,
		filter,
		hide,
		tabs,
		menu,
	})
end

local function view(state: State, _cx: BlockCx): Node
	local content: Node
	if state.view == "board" then
		local packed = packed_columns(state, state.lanes, state.cols)
		local groups: { { key: string, lanes: { Node } } } = {}
		for _, group in ipairs(packed) do
			local key = "col" .. group[1].id
			local lanes: { Node } = {}
			for _, lane in ipairs(group) do
				for index, candidate in ipairs(state.lanes) do
					if candidate == lane then
						local node = lane_view(state, index, lane)
						if node then
							lanes[#lanes + 1] = node
						end
						break
					end
				end
			end
			if #lanes > 0 then
				groups[#groups + 1] = { key = key, lanes = lanes }
			end
		end
		if #groups == 0 then
			groups[1] = { key = "col0", lanes = {} }
		end
		local last = groups[#groups]
		last.lanes[#last.lanes + 1] = ui.el("div", { class = "fb-add" }, {
			with(ui.button("Add lane", {
				icon = "plus",
				variant = "quiet",
			}), { actions = { click = "new_lane" } }),
		})
		local columns: { Node } = {}
		for _, group in ipairs(groups) do
			columns[#columns + 1] = ui.el("div", { key = group.key, class = "fb-col" }, group.lanes)
		end
		content = ui.el("div", { key = "content", class = "fb-cols" }, columns)
	else
		local lanes: { Node } = {}
		for index, lane in ipairs(state.lanes) do
			local node = lane_view(state, index, lane)
			if node then
				table.insert(lanes, node)
			end
		end
		lanes[#lanes + 1] = with(ui.button("Add lane", {
			icon = "plus",
			variant = "quiet",
		}), { actions = { click = "new_lane" } })
		content = ui.el("div", { key = "content", class = "fb-lanes fb-list" }, lanes)
	end
	local children: { Node } = { toolbar(state) }
	if state.error then
		children[#children + 1] = ui.el("div", { key = "error", class = "fb-error" }, {
			ui.text({ ui.span(state.error, "error") }),
		})
	end
	if state.conflict then
		children[#children + 1] = ui.node("row", { key = "conflict", gap = "sm" }, {
			with(ui.button("Reload from disk", { size = "sm" }), { actions = { click = "refresh" } }),
			with(ui.button("Overwrite", { size = "sm", variant = "danger" }), { actions = { click = "force_write" } }),
		})
	end
	children[#children + 1] = content
	return ui.el("div", { key = "root", class = "fb-root" }, children)
end

local function edit_key(state: State, target: string, key: Key, cx: BlockCx): boolean
	if target == "editor" and state.editing == nil then
		state.focus = nil
		cx:frame({ { "focus", nil } })
		return true
	end
	local text = if target == "filter" then state.filter else (state.editing and state.editing.text) or ""
	local cursor = if target == "filter" then state.filter_cursor else (state.editing and state.editing.cursor) or 0
	local handled = true
	if key.name == "backspace" then
		local previous = previous16(text, cursor)
		text = splice16(text, previous, cursor, "")
		cursor = previous
	elseif key.name == "delete" then
		local following = next16(text, cursor)
		text = splice16(text, cursor, following, "")
	elseif key.name == "left" then
		cursor = previous16(text, cursor)
	elseif key.name == "right" then
		cursor = next16(text, cursor)
	elseif key.name == "home" then
		cursor = 0
	elseif key.name == "end" then
		cursor = utf16_len(text)
	elseif key.name == "enter" then
		if target == "editor" then
			commit_editor(state)
		else
			state.focus = nil
		end
		cx:frame({ { "focus", nil } })
		return true
	elseif key.name == "escape" then
		if target == "editor" then
			cancel_editor(state, cx)
		else
			state.focus = nil
			cx:frame({ { "focus", nil } })
		end
		return true
	elseif key.text and not key.ctrl and not key.meta and not key.alt then
		text = splice16(text, cursor, cursor, key.text)
		cursor += utf16_len(key.text)
	else
		handled = false
	end
	if target == "filter" then
		state.filter = text
		state.filter_cursor = cursor
	elseif state.editing then
		state.editing.text = text
		state.editing.cursor = cursor
	end
	return handled
end

local function first_card_lane(state: State, from: number, step: number): number?
	local index = from
	while index >= 1 and index <= #state.lanes do
		if #state.lanes[index].cards > 0 then
			return index
		end
		index += step
	end
	return nil
end

local function move_selection(state: State, direction: string)
	if #state.lanes == 0 then
		return
	end
	local selected = state.selected
	if selected == nil then
		local first = first_card_lane(state, 1, 1)
		if first then
			state.selected = { lane = first, card = 1 }
		end
		return
	end
	local lane = state.lanes[selected.lane]
	if lane == nil or #lane.cards == 0 then
		local first = first_card_lane(state, math.min(selected.lane, #state.lanes), 1)
			or first_card_lane(state, #state.lanes, -1)
		if first then
			state.selected = { lane = first, card = 1 }
		else
			state.selected = nil
		end
		return
	end
	local card = math.max(1, math.min(selected.card, #lane.cards))
	if direction == "up" then
		state.selected = { lane = selected.lane, card = math.max(1, card - 1) }
	elseif direction == "down" then
		state.selected = { lane = selected.lane, card = math.min(#lane.cards, card + 1) }
	elseif direction == "left" then
		local target = first_card_lane(state, selected.lane - 1, -1)
		if target then
			state.selected = { lane = target, card = math.min(card, #state.lanes[target].cards) }
		end
	elseif direction == "right" then
		local target = first_card_lane(state, selected.lane + 1, 1)
		if target then
			state.selected = { lane = target, card = math.min(card, #state.lanes[target].cards) }
		end
	end
end

local function swap_lanes(state: State, left: number, right: number)
	state.lanes[left], state.lanes[right] = state.lanes[right], state.lanes[left]
	if state.selected then
		if state.selected.lane == left then
			state.selected.lane = right
		elseif state.selected.lane == right then
			state.selected.lane = left
		end
	end
	if state.editing then
		if state.editing.lane == left then
			state.editing.lane = right
		elseif state.editing.lane == right then
			state.editing.lane = left
		end
	end
end

local function handle_action(state: State, act: string, checked: boolean?, cx: BlockCx)
	local pending_lane = state.pending_delete_lane
	state.pending_delete_lane = nil

	if act == "hide_done" then
		state.hide_done = if checked ~= nil then checked else not state.hide_done
		return
	end
	if act == "switch_view" or act == "view_board" or act == "view_list" then
		if state.editing then
			commit_editor(state)
		end
		if act == "view_board" then
			state.view = "board"
		elseif act == "view_list" then
			state.view = "list"
		else
			state.view = if state.view == "board" then "list" else "board"
		end
		return
	end
	if act == "undo" then
		undo(state, cx)
		return
	end
	if act == "redo" then
		redo(state, cx)
		return
	end
	if act == "new_lane" then
		insert_lane(state, cx, nil)
		return
	end
	if act == "refresh" then
		local doc, text, error = read_board(state.path)
		if doc then
			apply_doc(state, doc, text or "")
			state.undo, state.redo, state.selected = {}, {}, nil
			state.editing, state.focus = nil, nil
			state.conflict = false
			state.error = nil
		else
			state.error = error
		end
		return
	end
	if act == "force_write" then
		write_board(state, true)
		return
	end
	if act == "clear" then
		state.filter, state.filter_cursor = "", 0
		return
	end
	if act == "open_markdown" then
		cx:open(state.path)
		return
	end
	if act == "reveal" then
		cx:open(dirname(state.path))
		return
	end
	if act == "copy_path" then
		cx:copy(state.path)
		return
	end
	if act == "close" then
		cx:exit(0)
		return
	end
	if act == "new_card_below" then
		local lane_index = if state.selected then state.selected.lane else 1
		local lane = state.lanes[lane_index]
		if lane == nil then
			return
		end
		local at = if state.selected then state.selected.card + 1 else #lane.cards + 1
		start_card_edit(state, cx, lane_index, nil, at)
		return
	end
	local fold_index = act:match("^fold:(%d+)$")
	if fold_index then
		local index = tonumber(fold_index)
		local lane = state.lanes[index]
		if lane then
			state.folded[lane.id] = not (state.folded[lane.id] == true)
		end
		return
	end
	local lane_index, card_index = act:match("^select:(%d+):(%d+)$")
	if lane_index then
		state.selected = { lane = tonumber(lane_index), card = tonumber(card_index) }
		return
	end
	lane_index = act:match("^new_card_top:(%d+)$")
	if lane_index then
		start_card_edit(state, cx, tonumber(lane_index), nil, 1)
		return
	end
	lane_index = act:match("^add_card:(%d+)$")
	if lane_index then
		start_card_edit(state, cx, tonumber(lane_index), nil, nil)
		return
	end
	lane_index = act:match("^lane_new_card:(%d+)$")
	if lane_index then
		start_card_edit(state, cx, tonumber(lane_index), nil, nil)
		return
	end
	lane_index, card_index = act:match("^edit_card:(%d+):(%d+)$")
	if lane_index then
		start_card_edit(state, cx, tonumber(lane_index), tonumber(card_index), nil)
		return
	end
	lane_index, card_index = act:match("^new_card_after:(%d+):(%d+)$")
	if lane_index then
		local lane = state.lanes[tonumber(lane_index)]
		local index = tonumber(card_index)
		if lane and lane.cards[index] then
			start_card_edit(state, cx, tonumber(lane_index), nil, index + 1)
		end
		return
	end
	local from_lane, to_lane
	from_lane, card_index, to_lane = act:match("^move_card:(%d+):(%d+):(%d+)$")
	if from_lane then
		local source_index = tonumber(from_lane)
		local target_index = tonumber(to_lane)
		local index = tonumber(card_index)
		local source = state.lanes[source_index]
		local target = state.lanes[target_index]
		local card = source and source.cards[index]
		if source and target and card and source ~= target then
			remember(state)
			local moved, notes = take_card(source, index)
			moved.done = target.done
			moved.raw = nil
			moved.home = if target.done and not source.done then source.id else nil
			put_card(target, #target.cards + 1, moved, notes)
			state.selected = { lane = target_index, card = #target.cards }
			clear_editing(state, cx)
			write_board(state)
		end
		return
	end
	lane_index, card_index = act:match("^delete_card:(%d+):(%d+)$")
	if lane_index then
		local lane = state.lanes[tonumber(lane_index)]
		local index = tonumber(card_index)
		if lane and lane.cards[index] then
			remember(state)
			remove_card(lane, index)
			state.selected = nil
			clear_editing(state, cx)
			write_board(state)
		end
		return
	end
	lane_index = act:match("^rename_lane:(%d+)$")
	if lane_index then
		start_lane_edit(state, cx, tonumber(lane_index))
		return
	end
	local after = act:match("^new_lane_after:(%d+)$")
	if after then
		insert_lane(state, cx, tonumber(after))
		return
	end
	lane_index = act:match("^move_lane_left:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		if index > 1 then
			remember(state)
			swap_lanes(state, index, index - 1)
			write_board(state)
		end
		return
	end
	lane_index = act:match("^move_lane_right:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		if index < #state.lanes then
			remember(state)
			swap_lanes(state, index, index + 1)
			write_board(state)
		end
		return
	end
	lane_index = act:match("^done_lane:(%d+)$")
	if lane_index then
		local lane = state.lanes[tonumber(lane_index)]
		if lane and lane.title:lower() ~= "done" then
			remember(state)
			lane.done = if checked ~= nil then checked else not lane.done
			write_board(state)
		end
		return
	end
	lane_index = act:match("^delete_lane:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		local lane = state.lanes[index]
		if lane then
			if pending_lane ~= index then
				state.pending_delete_lane = index
				return
			end
			remember(state)
			local carried: { string } = {}
			for anchor = 0, #lane.cards do
				for _, line in ipairs(lane.extras[anchor] or {}) do
					if trim(line) ~= DONE_MARKER then
						table.insert(carried, line)
					end
				end
			end
			if #carried > 0 then
				if index > 1 then
					local previous = state.lanes[index - 1]
					local anchor = #previous.cards
					local bucket = previous.extras[anchor] or {}
					for _, line in ipairs(carried) do
						table.insert(bucket, line)
					end
					previous.extras[anchor] = bucket
				else
					for _, line in ipairs(carried) do
						table.insert(state.preamble, line)
					end
				end
			end
			table.remove(state.lanes, index)
			if state.selected then
				if state.selected.lane == index then
					state.selected = nil
				elseif state.selected.lane > index then
					state.selected.lane -= 1
				end
			end
			if state.editing then
				if state.editing.lane == index then
					clear_editing(state, cx)
				elseif state.editing.lane > index then
					state.editing.lane -= 1
				end
			end
			write_board(state)
		end
		return
	end
end

tern.block.define("board", {
	features = { "edit", "undo" },
	font = "sans",

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local path = args[1] or (if saved and type(saved.path) == "string" then saved.path else nil)
		if path == nil then
			path = join(cx.cwd or "", "TODO.md")
		end
		local doc, text, error = read_board(path)
		if doc == nil then
			doc = { lanes = {}, preamble = {}, newline = "\n", final_newline = true }
		end
		return {
			path = path,
			lanes = doc.lanes,
			preamble = doc.preamble,
			newline = doc.newline,
			final_newline = doc.final_newline,
			disk_text = text,
			conflict = false,
			cols = cx.cols,
			filter = "",
			filter_cursor = 0,
			hide_done = false,
			view = "board",
			folded = {},
			editing = nil,
			focus = nil,
			selected = nil,
			pending_delete_lane = nil,
			undo = {},
			redo = {},
			error = error,
		}
	end,

	title = function(state: State): string?
		return basename(state.path) .. " · Flow Board"
	end,

	resize = function(state: State, cols: number, _rows: number, _cx: BlockCx)
		state.cols = cols
	end,

	view = function(state: State, cx: BlockCx): BlockView
		return { main = ui.col({ view(state, cx) }) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if state.focus == "filter" then
			return edit_key(state, "filter", key, cx)
		end
		if state.focus == "editor" then
			return edit_key(state, "editor", key, cx)
		end
		if key.ctrl and key.name == "z" then
			undo(state, cx)
			return true
		end
		if key.ctrl and key.name == "y" then
			redo(state, cx)
			return true
		end
		if key.shift and key.name == "x" then
			state.hide_done = not state.hide_done
			return true
		end
		if key.text == "v" then
			if state.editing then
				commit_editor(state)
			end
			state.view = if state.view == "board" then "list" else "board"
			return true
		end
		if key.text == "o" then
			local lane_index = if state.selected then state.selected.lane else 1
			local lane = state.lanes[lane_index]
			if lane == nil then
				return false
			end
			local at = if state.selected then state.selected.card + 1 else #lane.cards + 1
			start_card_edit(state, cx, lane_index, nil, at)
			return true
		end
		if key.name == "space" then
			local lane, card, card_index = selected_card(state)
			if lane and card and card_index and state.selected then
				toggle_card(state, state.selected.lane, card_index, not card.done)
				return true
			end
		end
		if key.name == "enter" then
			local lane, card, card_index = selected_card(state)
			if lane and card and card_index and state.selected then
				start_card_edit(state, cx, state.selected.lane, card_index, nil)
				return true
			end
		end
		if key.name == "up" or key.name == "down" or key.name == "left" or key.name == "right" then
			move_selection(state, key.name)
			return true
		end
		if key.name == "escape" then
			state.selected = nil
			return true
		end
		if key.name == "delete" then
			local lane, card, card_index = selected_card(state)
			if lane and card and card_index and state.selected then
				remember(state)
				remove_card(lane, card_index)
				state.selected = nil
				clear_editing(state, cx)
				write_board(state)
				return true
			end
		end
		return false
	end,

	event = function(state: State, event: UiEvent, cx: BlockCx)
		if event.ev == "action" and event.act == "viewport" then
			local cols = tonumber(tostring(event.value))
			if cols and cols > 0 then
				state.cols = cols
			end
			return
		end
		if event.ev == "action" then
			local act = tostring(event.act or "")
			local had_editor = state.focus == "editor"
			if state.focus == "filter" and act ~= "clear" then
				state.focus = nil
				cx:frame({ { "focus", nil } })
			end
			handle_action(state, act, event.checked, cx)
			if had_editor and state.focus ~= "editor" then
				cx:frame({ { "focus", nil } })
			end
			return
		end
		if event.ev == "change" then
			local card_id = tostring(event.name or ""):match("^toggle:(%d+)$")
			if card_id then
				if state.editing then
					commit_editor(state)
				end
				local id = tonumber(card_id)
				for lane_index, lane in ipairs(state.lanes) do
					for card_index, card in ipairs(lane.cards) do
						if card.id == id then
							toggle_card(state, lane_index, card_index, event.checked == true)
							return
						end
					end
				end
			end
			return
		end
		if event.ev == "select" then
			if event.item == "board" or event.item == "list" then
				if state.editing then
					commit_editor(state)
					cx:frame({ { "focus", nil } })
				end
				state.view = event.item
			end
			return
		end
		if event.ev == "focus" then
			local id = tostring(event.id or "")
			if id:match("%.filter$") then
				if state.editing then
					commit_editor(state)
				end
				state.focus = "filter"
			elseif id:match("%.card%-editor$") or id:match("%.lane%-editor$") then
				state.focus = "editor"
			end
			cx:frame({ { "focus", event.id } })
			return
		end
		if event.ev == "edit" then
			local id = tostring(event.id or "")
			local current = if id:match("%.filter$") then state.filter else (state.editing and state.editing.text) or ""
			local len = tonumber(event.len)
			if len ~= nil and len ~= utf16_len(current) then
				return
			end
			local from = tonumber(event.from) or 0
			local to = tonumber(event.to) or from
			local insert = tostring(event.text or "")
			local cursor = tonumber(event.cursor) or from
			if id:match("%.filter$") then
				state.filter = splice16(state.filter, from, to, insert)
				state.filter_cursor = cursor
			elseif state.editing then
				state.editing.text = splice16(state.editing.text, from, to, insert)
				state.editing.cursor = cursor
			end
			return
		end
		if event.ev == "undo" then
			local id = tostring(event.id or "")
			if not id:match("%.filter$") then
				undo(state, cx)
			end
		end
	end,

	save = function(state: State)
		return { path = state.path }
	end,
})
