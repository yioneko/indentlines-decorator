local M = {}

local ns = vim.api.nvim_create_namespace("indent_guide")
local augroup = vim.api.nvim_create_augroup("indent_guide", { clear = true })

---@type 'pre_setup' | 'normal' | 'error'
M.status = "pre_setup"

---@class IndentGuideOpts
---@field enabled boolean
---@field shiftwidth number
---@field overscan number
---@field skip_first_indent boolean
---@field char string
---@field char_hl string
---@field show_cursor_scope boolean
---@field cursor_scope_char_hl? string
---@field auto_clear_cursor_scope boolean
---@field priority number
---@field max_increase_level number

---@class IndentGuideGlobalOpts: IndentGuideOpts
---@field get_opts? fun(bufnr:number):IndentGuideOpts?

---@class IndentGuideBufState
---@field opts IndentGuideOpts
---@field indents table<number, number> indent is lazily evaluated based on `lines` (optimize for large fold region)
---@field lines table<number, string>
---@field prev_contain_lnum table<number, number>
---@field next_contain_lnum table<number, number>
---@field cleared boolean? whether indent lines are cleared

---@class IndentGuideWinState
---@field view { leftcol: number }
---@field cursor_scope? { slnum: number, elnum: number, indent: number  }

---@type table<number, IndentGuideBufState>
local buf_decoration_state = {}

---@type table<number, IndentGuideWinState>
local win_decoration_state = {}

---@type IndentGuideGlobalOpts
local global_opts = {
	enabled = false,
	shiftwidth = vim.o.shiftwidth,
	overscan = 100,
	skip_first_indent = false,
	char = "▏",
	char_hl = "LineNr",
	show_cursor_scope = true,
	cursor_scope_char_hl = "Delimiter",
	auto_clear_cursor_scope = true,
	priority = 120,
	max_increase_level = 1,
}

local function first_no_nil(...)
	for _, v in pairs({ ... }) do
		if v ~= nil then
			return v
		end
	end
end

local function round_indent(indent, shiftwidth)
	return math.floor(indent / shiftwidth) * shiftwidth
end

---@param line string
---@param shiftwidth number
local function get_indent_pure(line, shiftwidth)
	if line == "" then
		-- treat blank line as line with inf indent
		return math.huge
	end

	local spaces = line:match("^%s*") or ""
	local indent = 0

	for ch in spaces:gmatch(".") do
		if ch == "\t" then
			indent = indent + shiftwidth
		else
			indent = indent + 1
		end
	end

	return indent
end

local function get_indent(bufnr, lnum)
	local buf_state = buf_decoration_state[bufnr]
	local indents = buf_state.indents
	if indents[lnum] or not buf_state.lines[lnum] then
		return indents[lnum]
	else
		local line = buf_state.lines[lnum]
		local indent = get_indent_pure(line, buf_state.opts.shiftwidth)
		indents[lnum] = indent
		return indent
	end
end

---@param bufnr number
---@return IndentGuideOpts
local function get_opts(bufnr)
	local opts = global_opts.get_opts and global_opts.get_opts(bufnr) or {}

	if not opts.shiftwidth then
		local shiftwidth = vim.bo[bufnr].shiftwidth
		if shiftwidth == 0 then
			shiftwidth = vim.bo[bufnr].tabstop or 0
		end
		opts.shiftwidth = shiftwidth
	end

	local b = vim.b[bufnr]
	local function o(key)
		opts[key] = first_no_nil(b["indent_guide_" .. key], opts[key], global_opts[key])
	end

	o("enabled")
	o("overscan")
	o("skip_first_indent")
	o("char")
	o("char_hl")
	o("show_cursor_scope")
	o("cursor_scope_char_hl")
	o("auto_clear_cursor_scope")
	o("priority")
	o("max_increase_level")

	return opts
end

local function update_lines(bufnr, start_lnum, end_lnum)
	-- TODO: skip folds
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_lnum, end_lnum, false)
	local buf_state_lines = buf_decoration_state[bufnr].lines
	for i, line in ipairs(lines) do
		buf_state_lines[i - 1 + start_lnum] = line
	end
end

---@param bufnr number
---@param lnum number
---@param state_key "prev_contain_lnum" | "next_contain_lnum"
---@param increment number
---@return number, number?
local function find_contain_line(bufnr, lnum, state_key, increment)
	local state = buf_decoration_state[bufnr]
	local cur_indent = get_indent(bufnr, lnum)
	if not cur_indent then
		-- TODO: how to deal with this?
		return lnum, cur_indent
	end

	local next_lnum = state[state_key][lnum] or lnum + increment
	local next_indent = get_indent(bufnr, next_lnum)

	local indents_stack = { { cur_indent, lnum } }
	while next_indent do
		while #indents_stack > 0 and next_indent < indents_stack[#indents_stack][1] do
			local entry = table.remove(indents_stack, #indents_stack)
			state[state_key][entry[2]] = next_lnum
		end

		if #indents_stack == 0 then
			break
		else
			table.insert(indents_stack, { next_indent, next_lnum })
		end

		if state[state_key][next_lnum] then
			-- fast path: reuse calculated result
			next_lnum = state[state_key][next_lnum]
		else
			next_lnum = next_lnum + increment
		end
		next_indent = get_indent(bufnr, next_lnum)
	end

	if not next_indent then
		for _, entry in pairs(indents_stack) do
			state[state_key][entry[2]] = next_lnum
		end
	end

	return next_lnum, next_indent
end

local function find_prev_contain_lnum(bufnr, lnum)
	return find_contain_line(bufnr, lnum, "prev_contain_lnum", -1)
end

local function find_next_contain_lnum(bufnr, lnum)
	return find_contain_line(bufnr, lnum, "next_contain_lnum", 1)
end

local function find_indent_scope(bufnr, lnum)
	local prev_lnum, prev_indent = find_prev_contain_lnum(bufnr, lnum)
	local next_lnum, next_indent = find_next_contain_lnum(bufnr, lnum)

	-- blank line: refind indent scope
	if get_indent(bufnr, lnum) == math.huge then
		if prev_indent and next_indent then
			if prev_indent >= next_indent then
				return find_indent_scope(bufnr, prev_lnum)
			else
				return find_indent_scope(bufnr, next_lnum)
			end
		elseif prev_indent then
			return find_indent_scope(bufnr, prev_lnum)
		elseif next_indent then
			return find_indent_scope(bufnr, next_lnum)
		end
	end
	return prev_lnum, next_lnum, prev_indent, next_indent
end

---Try to adjust the cursor as if the cursor is on the edge of indent scope before `get_indent_scope`
---@param bufnr number
---@param clnum number
local function find_cursor_scope(bufnr, clnum)
	local buf_state = buf_decoration_state[bufnr]

	local base_line, base_line_indent
	do
		local prev_indent = clnum > 0 and get_indent(bufnr, clnum - 1) or 0
		local next_indent = get_indent(bufnr, clnum + 1) or 0
		local cur_indent = get_indent(bufnr, clnum) or 0

		if prev_indent <= cur_indent and next_indent <= cur_indent then
			-- case 1:
			-- prev
			-- ...cur
			-- next
			base_line, base_line_indent = clnum, cur_indent
		elseif next_indent > cur_indent and (next_indent <= prev_indent or prev_indent <= cur_indent) then
			-- case 2:
			-- ......prev or prev
			-- cur           ...cur
			-- ...next <-    ......next <-
			base_line, base_line_indent = clnum + 1, next_indent
		elseif prev_indent >= cur_indent then
			-- case 3:
			-- ...prev <- or ......prev <-
			-- cur           ...cur
			-- ......next    next
			base_line, base_line_indent = clnum - 1, prev_indent
		end
	end

	if base_line then
		local prev_lnum, next_lnum, prev_indent, next_indent = find_indent_scope(bufnr, base_line)
		-- no valid indent scope, mostly on the first indent level
		if not prev_indent and not next_indent then
			return
		end

		local shiftwidth = buf_state.opts.shiftwidth
		-- check max_increase_level
		if prev_indent and prev_indent + buf_state.opts.max_increase_level * shiftwidth < base_line_indent then
			return {
				slnum = prev_lnum + 1,
				-- Since we prefer prev_indent as higlighted indent level, we should include next_lnum as indent scope
				elnum = next_lnum,
				indent = round_indent(prev_indent, shiftwidth),
			}
		end

		return {
			slnum = prev_lnum + 1,
			elnum = next_lnum - 1,
			indent = round_indent(
				-- still need to check blank line here
				base_line_indent == math.huge and next_indent or math.max(0, base_line_indent - 0.5), -- round base_line_indent to nearest indent level
				shiftwidth
			),
		}
	end
end

local function redraw_cursor_scope(winnr, bufnr, new_scope)
	local win_state = win_decoration_state[winnr]
	local prev_scope = win_state.cursor_scope
	win_state.cursor_scope = new_scope

	if new_scope and prev_scope then
		-- The two ranges are unlikely to intersect, only contain or not contain), try to reduce number of redrawed lines here
		if
			prev_scope.slnum == new_scope.slnum
			and prev_scope.elnum == new_scope.elnum
			and prev_scope.indent == new_scope.indent
		then
			-- fast path: scope not changed, no need to redraw
			return
		end

		if prev_scope.elnum <= new_scope.slnum or prev_scope.slnum >= new_scope.elnum then
			vim.api.nvim__buf_redraw_range(bufnr, prev_scope.slnum, prev_scope.elnum + 1)
			vim.api.nvim__buf_redraw_range(bufnr, new_scope.slnum, new_scope.elnum + 1)
		else
			vim.api.nvim__buf_redraw_range(
				bufnr,
				math.min(new_scope.slnum, prev_scope.slnum),
				math.max(new_scope.elnum, prev_scope.elnum) + 1
			)
		end
	elseif new_scope then
		vim.api.nvim__buf_redraw_range(bufnr, new_scope.slnum, new_scope.elnum + 1)
	elseif prev_scope then
		-- redraw to clear highlight
		vim.api.nvim__buf_redraw_range(bufnr, prev_scope.slnum, prev_scope.elnum + 1)
	end
end

---This will adjust blank line to surrounding indent
---@param bufnr number
---@param lnum number
---@return number
local function get_display_indent(bufnr, lnum)
	local cur_indent = get_indent(bufnr, lnum)

	if cur_indent == math.huge then
		local _, next_indent = find_next_contain_lnum(bufnr, lnum)
		if next_indent and next_indent ~= math.huge then
			return next_indent
		else
			return 0
		end
	else
		local _, prev_indent = find_prev_contain_lnum(bufnr, lnum)
		return math.min(
			(prev_indent or math.huge)
				+ buf_decoration_state[bufnr].opts.shiftwidth * buf_decoration_state[bufnr].opts.max_increase_level,
			cur_indent or 0
		)
	end
end

local function on_line(_, winnr, bufnr, lnum)
	local buf_state = buf_decoration_state[bufnr]
	if not buf_state or not buf_state.opts.enabled then
		return
	end

	local win_state = win_decoration_state[winnr]

	local shiftwidth = buf_state.opts.shiftwidth
	local skip_first_indent = buf_state.opts.skip_first_indent

	local leftcol = win_state.view.leftcol

	local indent = get_indent(bufnr, lnum)
	-- botline guess is wrong
	if indent == nil then
		update_lines(bufnr, lnum, lnum + buf_state.opts.overscan)
		indent = get_indent(bufnr, lnum)
	end

	local is_blank_line = indent == math.huge
	local displayed_indent = get_display_indent(bufnr, lnum)

	local in_cursor_scope = buf_state.opts.show_cursor_scope
		and win_state.cursor_scope
		and lnum >= win_state.cursor_scope.slnum
		and lnum <= win_state.cursor_scope.elnum
	do
		local guide_col = 0
		if skip_first_indent or (is_blank_line and displayed_indent == 0) then
			guide_col = shiftwidth
		end
		-- round up
		guide_col = math.max(guide_col, round_indent(leftcol + shiftwidth - 1, shiftwidth))

		while (is_blank_line and guide_col <= displayed_indent) or guide_col < displayed_indent do
			local is_cursor_scope_guide = in_cursor_scope and guide_col == win_state.cursor_scope.indent
			local hl = is_cursor_scope_guide and buf_state.opts.cursor_scope_char_hl or buf_state.opts.char_hl

			vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
				virt_text = { { buf_state.opts.char, hl } },
				virt_text_pos = "overlay",
				virt_text_win_col = guide_col - leftcol,
				hl_mode = "combine",
				priority = buf_state.opts.priority,
				ephemeral = true,
			})

			guide_col = guide_col + shiftwidth
		end
	end
end

local function reset_buf_state(bufnr)
	buf_decoration_state[bufnr].indents = {}
	buf_decoration_state[bufnr].lines = {}
	buf_decoration_state[bufnr].next_contain_lnum = {}
	buf_decoration_state[bufnr].prev_contain_lnum = {}
end

local function on_win(_, winnr, bufnr, topline, botline)
	local buf_opts = get_opts(bufnr)
	local buf_state = buf_decoration_state[bufnr]
	if buf_state and not buf_opts.enabled then
		if not buf_state.cleared then
			pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
			buf_state.cleared = true
		end
		-- we need to assign buf_opts to skip on_line
		buf_state.opts = buf_opts
		return false
	end

	if not buf_state then
		buf_state = {}
		buf_decoration_state[bufnr] = buf_state
		reset_buf_state(bufnr)
	end
	buf_state.opts = buf_opts

	if not buf_opts.enabled then
		return false
	else
		buf_state.cleared = false
	end

	if not win_decoration_state[winnr] then
		win_decoration_state[winnr] = {}
	end
	win_decoration_state[winnr].view = vim.api.nvim_win_call(winnr, vim.fn.winsaveview)

	local start_lnum = math.max(0, topline - 1 - buf_opts.overscan)
	local end_lnum = botline + buf_opts.overscan
	-- prefetch lines before on_line: this is more efficient than fetching line one by one, but
	-- might fetch redundant lines because of fold ranges
	-- TODO: batch fetch in on_line
	update_lines(bufnr, start_lnum, end_lnum)

	local cur_win = vim.api.nvim_get_current_win()
	if cur_win == winnr then
		local cursor = vim.api.nvim_win_get_cursor(cur_win)
		local clnum = cursor[1] - 1

		-- botline guess is wrong
		if clnum >= botline then
			update_lines(bufnr, clnum, clnum + buf_opts.overscan)
		end

		if buf_opts.show_cursor_scope then
			local new_scope = find_cursor_scope(bufnr, clnum)
			redraw_cursor_scope(winnr, bufnr, new_scope)
		else
			-- clear on toggled
			redraw_cursor_scope(winnr, bufnr, nil)
		end
	elseif buf_opts.auto_clear_cursor_scope or not buf_opts.show_cursor_scope then
		redraw_cursor_scope(winnr, bufnr, nil)
	end
end

local function on_buf(_, bufnr)
	-- on buf change
	if buf_decoration_state[bufnr] and get_opts(bufnr).enabled then
		reset_buf_state(bufnr)
	end
end

local function safe_call(func, context, ...)
	xpcall(func, function(msg)
		local msg_with_stack = context .. debug.traceback(msg)
		if M.status == "error" then
			return
		else
			print("[indent-guide]: An error occurs and following report will be suppressed. " .. msg_with_stack)
			M.status = "error"
		end
	end, ...)
end

function M.setup(opts)
	global_opts = vim.tbl_extend("force", global_opts, opts or {})

	if M.status ~= "pre_setup" then
		return
	end

	vim.api.nvim_set_decoration_provider(ns, {
		on_buf = function(event, bufnr)
			safe_call(on_buf, "[buf " .. bufnr .. " ]", event, bufnr)
		end,
		on_win = function(event, winid, bufnr, topline, botline_guess)
			safe_call(on_win, "[win " .. winid .. "]", event, winid, bufnr, topline, botline_guess)
		end,
		on_line = function(event, winid, bufnr, row)
			safe_call(on_line, string.format("[win %d line %d]", winid, row), event, winid, bufnr, row)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = augroup,
		callback = function(args)
			win_decoration_state[args.match] = nil
		end,
		desc = "clear win state",
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			buf_decoration_state[args.buf] = nil
		end,
		desc = "clear buf state",
	})

	M.status = "normal"
end

return M
