--!strict

local ui = tern.ui

type Card = {
	text: string,
	done: boolean,
	raw: string?,
}

type Lane = {
	title: string,
	done: boolean,
	cards: { Card },
}

type Editing = {
	kind: "card" | "lane",
	lane: number,
	card: number?,
	at: number?,
	text: string,
	cursor: number,
}

type State = {
	path: string,
	lanes: { Lane },
	cols: number,
	filter: string,
	filter_cursor: number,
	hide_done: boolean,
	view: "board" | "list",
	folded: { [number]: boolean },
	editing: Editing?,
	focus: string?,
	selected: { lane: number, card: number }?,
	undo: { string },
	redo: { string },
	error: string?,
}

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

local function parse(text: string): { Lane }
	local lanes: { Lane } = {}
	local lane: Lane? = nil
	for line in (text .. "\n"):gmatch("(.-)\n") do
		line = line:gsub("\r$", "")
		local title = line:match("^##%s+(.-)%s*$")
		if title then
			lane = { title = title, done = title:lower() == "done", cards = {} }
			table.insert(lanes, lane)
		elseif lane then
			local check, body = line:match("^%-%s+%[([ xX])%]%s+(.*)$")
			if check then
				table.insert(lane.cards, {
					text = body,
					done = check ~= " ",
					raw = line,
				})
			end
		end
	end
	return lanes
end

local function serialize(lanes: { Lane }): string
	local out: { string } = {}
	for index, lane in ipairs(lanes) do
		if index > 1 then
			table.insert(out, "")
		end
		table.insert(out, "## " .. (if lane.title == "" then "Untitled" else lane.title))
		for _, card in ipairs(lane.cards) do
			local line = card.raw
			if line == nil or line == "" then
				line = "- [" .. (if card.done then "x" else " ") .. "] " .. card.text
			else
				line = line:gsub("%[([ xX])%]", if card.done then "[x]" else "[ ]", 1)
			end
			card.raw = line
			table.insert(out, line)
		end
	end
	return table.concat(out, "\n") .. "\n"
end

local function read_board(path: string): ({ Lane }, string?)
	local ok, text = pcall(tern.fs.read, path)
	if not ok then
		return {}, tostring(text)
	end
	return parse(text), nil
end

local function write_board(state: State)
	local ok, message = pcall(tern.fs.write, state.path, serialize(state.lanes))
	if not ok then
		state.error = tostring(message)
	else
		state.error = nil
	end
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
	table.insert(state.lanes, { title = "Done", done = true, cards = {} })
	return #state.lanes
end

local function remember(state: State)
	table.insert(state.undo, serialize(state.lanes))
	if #state.undo > 60 then
		table.remove(state.undo, 1)
	end
	state.redo = {}
end

local function undo(state: State)
	if #state.undo == 0 then
		return
	end
	table.insert(state.redo, serialize(state.lanes))
	local text = table.remove(state.undo) or ""
	state.lanes = parse(text)
	state.selected = nil
	state.editing = nil
	write_board(state)
end

local function redo(state: State)
	if #state.redo == 0 then
		return
	end
	table.insert(state.undo, serialize(state.lanes))
	local text = table.remove(state.redo) or ""
	state.lanes = parse(text)
	state.selected = nil
	state.editing = nil
	write_board(state)
end

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
	local card = lane and lane.cards[card_index]
	if card == nil then
		return
	end
	if checked == card.done and ((checked and lane.done) or (not checked and not lane.done)) then
		return
	end
	remember(state)
	table.remove(lane.cards, card_index)
	card.raw = nil
	card.done = checked
	if checked then
		local target = done_lane(state)
		local destination = state.lanes[target]
		table.insert(destination.cards, card)
		state.selected = { lane = target, card = #destination.cards }
	else
		local target = nil
		for index, candidate in ipairs(state.lanes) do
			if not candidate.done then
				target = index
				break
			end
		end
		if target then
			table.insert(state.lanes[target].cards, card)
			state.selected = { lane = target, card = #state.lanes[target].cards }
		else
			table.insert(lane.cards, card_index, card)
			state.selected = { lane = lane_index, card = card_index }
		end
	end
	write_board(state)
end

local function start_card_edit(state: State, lane_index: number, card_index: number?, at: number?)
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
end

local function start_lane_edit(state: State, lane_index: number)
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
end

local function commit_editor(state: State)
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
			table.insert(lane.cards, at, { text = text, done = false, raw = nil })
			state.selected = { lane = editing.lane, card = at }
		end
	else
		local lane = state.lanes[editing.lane]
		if lane then
			remember(state)
			if text == "" then
				text = "New lane"
			end
			lane.title = text
			lane.done = text:lower() == "done"
		end
	end
	state.editing = nil
	state.focus = nil
	write_board(state)
end

local function cancel_editor(state: State)
	state.editing = nil
	state.focus = nil
end

local function insert_lane(state: State, after: number?)
	remember(state)
	local lane: Lane = { title = "New lane", done = false, cards = {} }
	local at = if after then math.min(#state.lanes + 1, after + 1) else #state.lanes + 1
	table.insert(state.lanes, at, lane)
	state.selected = nil
	start_lane_edit(state, at)
	write_board(state)
end

local function card_row(state: State, lane_index: number, card_index: number, card: Card): Node
	local selected = state.selected
	local is_selected = selected ~= nil and selected.lane == lane_index and selected.card == card_index
	return ui.el("div", {
		class = "fb-card"
			.. (if card.done then " fb-done" else "")
			.. (if is_selected then " fb-selected" else ""),
		role = "flowboard.card",
	}, {
		ui.el("input", {
			type = "checkbox",
			name = "toggle:" .. lane_index .. ":" .. card_index,
			checked = card.done,
		}),
		ui.el("div", {
			class = "fb-card-text",
			actions = {
				click = "select:" .. lane_index .. ":" .. card_index,
				dblclick = "edit_card:" .. lane_index .. ":" .. card_index,
			},
		}, {
			ui.el("div", { class = "fb-card-title", text = card.text }),
		}),
	})
end

local function lane_menu(state: State, lane_index: number): { any }
	return {
		{ id = "lane_new_card:" .. lane_index, label = "New card" },
		{ id = "rename_lane:" .. lane_index, label = "Rename lane…" },
		{ id = "new_lane_after:" .. lane_index, label = "New lane" },
		{ id = "move_lane_left:" .. lane_index, label = "Move lane left", disabled = lane_index <= 1 },
		{ id = "move_lane_right:" .. lane_index, label = "Move lane right", disabled = lane_index >= #state.lanes },
		{ id = "done_lane:" .. lane_index, label = "Done lane", checked = state.lanes[lane_index].done },
		{ id = "delete_lane:" .. lane_index, label = "Delete lane", danger = true },
	}
end

local function board_menu(state: State): { any }
	return {
		{ id = "new_card_below", label = "New card below", keys = { "o" } },
		{ id = "new_lane", label = "New lane" },
		"-",
		{ id = "undo", label = "Undo board change", keys = { "ctrl", "z" }, disabled = #state.undo == 0 },
		{ id = "redo", label = "Redo board change", keys = { "ctrl", "y" }, disabled = #state.redo == 0 },
		"-",
		{ id = "hide_done", label = "Hide done cards", keys = { "shift", "x" }, checked = state.hide_done },
		{ id = "switch_view", label = "Switch board/list view", keys = { "v" } },
		"-",
		{ id = "open_markdown", label = "Open as Markdown" },
		{ id = "reveal", label = "Reveal in Finder" },
		{ id = "copy_path", label = "Copy path" },
		"-",
		{ id = "close", label = "Close board" },
	}
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
			icon = if state.folded[lane_index] then "chev-r" else "chev",
			size = "sm",
			variant = "quiet",
			title = if state.folded[lane_index] then "Expand lane" else "Fold lane",
		}), { actions = { click = "fold:" .. lane_index } })
	end
	if editing_lane and state.editing then
		head[#head + 1] = ui.el("div", { class = "fb-lane-title" }, {
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
		title = "New card at the top",
	}), { actions = { click = "new_card_top:" .. lane_index } })
	head[#head + 1] = ui.node("menu", {
		key = "lane-menu",
		icon = "more",
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
		return ui.el("div", { class = "fb-editor" }, {
			ui.node("input", {
				key = "card-editor",
				text = state.editing and state.editing.text or "",
				cursor = state.editing and state.editing.cursor or 0,
				placeholder = "Card title",
				aria = "Card title",
			}),
		})
	end
	if new_at == 1 then
		body[#body + 1] = editor_node()
	end
	for card_index, card in ipairs(lane.cards) do
		local matches = query == "" or card.text:lower():find(query, 1, true) ~= nil
		if matches and not (state.hide_done and card.done) then
			if editing_existing and state.editing and state.editing.card == card_index then
				body[#body + 1] = editor_node()
			else
				body[#body + 1] = card_row(state, lane_index, card_index, card)
			end
		end
		if new_at == card_index + 1 then
			body[#body + 1] = editor_node()
		end
	end
	if new_at ~= nil and new_at > #lane.cards then
		body[#body + 1] = editor_node()
	end
	body[#body + 1] = with(ui.button("Add card", {
		icon = "plus",
		size = "sm",
		variant = "quiet",
	}), { actions = { click = "add_card:" .. lane_index } })

	local folded = state.view == "list" and state.folded[lane_index] == true
	return ui.el("div", {
		class = "fb-lane" .. (if folded then " fb-folded" else ""),
		role = "flowboard.lane",
	}, {
		ui.el("div", { class = "fb-lane-head" }, head),
		ui.el("div", { class = "fb-lane-body" }, body),
	})
end

local LANE_CELLS = 34

local function estimated(lane: Lane): number
	-- Rows: 36px header (4.5), 22px Add card (2.75), 8px padding (1);
	-- a card row is 34px (4.25), each extra wrapped line about 18px (2.3).
	local height = 4.5 + 2.75 + 1
	for _, card in ipairs(lane.cards) do
		local lines = math.max(1, math.ceil(#card.text / 32))
		height += 4.25 + (lines - 1) * 2.3 + 0.5
	end
	return height
end

local function packed_columns(lanes: { Lane }, cols: number): { { Lane } }
	local count = math.max(1, math.min(#lanes, math.floor(math.max(LANE_CELLS, cols) / LANE_CELLS)))
	if count <= 1 or #lanes == 0 then
		return { lanes }
	end
	local prefix: { number } = { 0 }
	for index, lane in ipairs(lanes) do
		prefix[index + 1] = prefix[index] + estimated(lane)
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
	return ui.el("div", { class = "fb-toolbar" }, {
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
		local packed = packed_columns(state.lanes, state.cols)
		local groups: { { Node } } = {}
		for _, group in ipairs(packed) do
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
			groups[#groups + 1] = lanes
		end
		if #groups == 0 then
			groups[1] = {}
		end
		groups[#groups][#groups[#groups] + 1] = ui.el("div", { class = "fb-add" }, {
			with(ui.button("Add lane", {
				icon = "plus",
				variant = "quiet",
			}), { actions = { click = "new_lane" } }),
		})
		local columns: { Node } = {}
		for _, lanes in ipairs(groups) do
			columns[#columns + 1] = ui.el("div", { class = "fb-col" }, lanes)
		end
		content = ui.el("div", { class = "fb-cols" }, columns)
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
		content = ui.el("div", { class = "fb-lanes fb-list" }, lanes)
	end
	local children: { Node } = { toolbar(state) }
	if state.error then
		children[#children + 1] = ui.el("div", { class = "fb-error" }, {
			ui.text({ ui.span(state.error, "error") }),
		})
	end
	children[#children + 1] = content
	return ui.el("div", { class = "fb-root" }, children)
end

local function edit_key(state: State, target: string, key: Key, cx: BlockCx): boolean
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
			cx:frame({ { "focus", nil } })
		end
		return true
	elseif key.name == "escape" then
		if target == "editor" then
			cancel_editor(state)
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

local function move_selection(state: State, direction: string)
	local lane_count = #state.lanes
	if lane_count == 0 then
		return
	end
	local selected = state.selected
	if selected == nil then
		local first = state.lanes[1]
		if #first.cards > 0 then
			state.selected = { lane = 1, card = 1 }
		end
		return
	end
	local lane = state.lanes[selected.lane]
	if lane == nil then
		state.selected = nil
		return
	end
	if direction == "up" then
		state.selected = { lane = selected.lane, card = math.max(1, selected.card - 1) }
	elseif direction == "down" then
		state.selected = { lane = selected.lane, card = math.min(#lane.cards, selected.card + 1) }
	elseif direction == "left" then
		local target = math.max(1, selected.lane - 1)
		state.selected = { lane = target, card = math.min(selected.card, math.max(1, #state.lanes[target].cards)) }
	elseif direction == "right" then
		local target = math.min(lane_count, selected.lane + 1)
		state.selected = { lane = target, card = math.min(selected.card, math.max(1, #state.lanes[target].cards)) }
	end
end

local function handle_action(state: State, act: string, checked: boolean?, cx: BlockCx)
	if act == "hide_done" then
		state.hide_done = if checked ~= nil then checked else not state.hide_done
		return
	end
	if act == "switch_view" then
		state.view = if state.view == "board" then "list" else "board"
		return
	end
	if act == "view_board" then
		state.view = "board"
		return
	end
	if act == "view_list" then
		state.view = "list"
		return
	end
	if act == "undo" then
		undo(state)
		return
	end
	if act == "redo" then
		redo(state)
		return
	end
	if act == "new_lane" then
		insert_lane(state, nil)
		return
	end
	if act == "refresh" then
		local lanes, error = read_board(state.path)
		state.lanes, state.error = lanes, error
		state.undo, state.redo, state.selected = {}, {}, nil
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
		start_card_edit(state, lane_index, nil, at)
		return
	end
	local fold_index = act:match("^fold:(%d+)$")
	if fold_index then
		local index = tonumber(fold_index)
		state.folded[index] = not (state.folded[index] == true)
		return
	end
	local lane_index, card_index = act:match("^select:(%d+):(%d+)$")
	if lane_index then
		state.selected = { lane = tonumber(lane_index), card = tonumber(card_index) }
		return
	end
	lane_index = act:match("^new_card_top:(%d+)$")
	if lane_index then
		start_card_edit(state, tonumber(lane_index), nil, 1)
		return
	end
	lane_index = act:match("^add_card:(%d+)$")
	if lane_index then
		start_card_edit(state, tonumber(lane_index), nil, nil)
		return
	end
	lane_index = act:match("^lane_new_card:(%d+)$")
	if lane_index then
		start_card_edit(state, tonumber(lane_index), nil, nil)
		return
	end
	lane_index, card_index = act:match("^edit_card:(%d+):(%d+)$")
	if lane_index then
		start_card_edit(state, tonumber(lane_index), tonumber(card_index), nil)
		return
	end
	lane_index = act:match("^rename_lane:(%d+)$")
	if lane_index then
		start_lane_edit(state, tonumber(lane_index))
		return
	end
	local after = act:match("^new_lane_after:(%d+)$")
	if after then
		insert_lane(state, tonumber(after))
		return
	end
	lane_index = act:match("^move_lane_left:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		if index > 1 then
			remember(state)
			state.lanes[index], state.lanes[index - 1] = state.lanes[index - 1], state.lanes[index]
			write_board(state)
		end
		return
	end
	lane_index = act:match("^move_lane_right:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		if index < #state.lanes then
			remember(state)
			state.lanes[index], state.lanes[index + 1] = state.lanes[index + 1], state.lanes[index]
			write_board(state)
		end
		return
	end
	lane_index = act:match("^done_lane:(%d+)$")
	if lane_index then
		local lane = state.lanes[tonumber(lane_index)]
		if lane then
			remember(state)
			lane.done = if checked ~= nil then checked else not lane.done
			write_board(state)
		end
		return
	end
	lane_index = act:match("^delete_lane:(%d+)$")
	if lane_index then
		local index = tonumber(lane_index)
		if state.lanes[index] then
			remember(state)
			table.remove(state.lanes, index)
			state.selected = nil
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
		local lanes, error = read_board(path)
		return {
			path = path,
			lanes = lanes,
			cols = cx.cols,
			filter = "",
			filter_cursor = 0,
			hide_done = false,
			view = "board",
			folded = {},
			editing = nil,
			focus = nil,
			selected = nil,
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
			undo(state)
			return true
		end
		if key.ctrl and key.name == "y" then
			redo(state)
			return true
		end
		if key.shift and key.name == "x" then
			state.hide_done = not state.hide_done
			return true
		end
		if key.text == "v" then
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
			start_card_edit(state, lane_index, nil, at)
			return true
		end
		if key.name == "space" then
			local lane, _, card_index = selected_card(state)
			if lane and card_index and state.selected then
				local card = lane.cards[card_index]
				toggle_card(state, state.selected.lane, card_index, not card.done)
				return true
			end
		end
		if key.name == "enter" then
			local lane, card, card_index = selected_card(state)
			if lane and card and card_index and state.selected then
				start_card_edit(state, state.selected.lane, card_index, nil)
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
		if key.name == "delete" or key.name == "backspace" then
			local lane, _, card_index = selected_card(state)
			if lane and card_index and state.selected then
				remember(state)
				table.remove(lane.cards, card_index)
				state.selected = nil
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
			if state.focus == "filter" and act ~= "clear" then
				state.focus = nil
				cx:frame({ { "focus", nil } })
			end
			handle_action(state, act, event.checked, cx)
			return
		end
		if event.ev == "change" then
			local lane_index, card_index = tostring(event.name or ""):match("^toggle:(%d+):(%d+)$")
			if lane_index then
				toggle_card(state, tonumber(lane_index), tonumber(card_index), event.checked == true)
			end
			return
		end
		if event.ev == "select" then
			if event.item == "board" or event.item == "list" then
				state.view = event.item
			end
			return
		end
		if event.ev == "focus" then
			local id = tostring(event.id or "")
			if id:match("%.filter$") then
				state.focus = "filter"
			elseif id:match("%.card%-editor$") or id:match("%.lane%-editor$") then
				state.focus = "editor"
			end
			cx:frame({ { "focus", event.id } })
			return
		end
		if event.ev == "edit" then
			local id = tostring(event.id or "")
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
			undo(state)
		end
	end,

	save = function(state: State)
		return { path = state.path }
	end,
})
