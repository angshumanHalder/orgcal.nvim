local M = {}

local config = { dir = "~/org" }
local sync_timer = nil
local poll_timer = nil
local resolve_ui  -- forward declaration

local function has_upcoming_in_hour()
	local dir = vim.fn.expand(config.dir)
	local now = os.time()
	local horizon = now + 3600
	local files = vim.fn.globpath(dir, "**/*.org", false, true)
	for _, file in ipairs(files) do
		local f = io.open(file, "r")
		if not f then goto continue end
		local content = f:read("*all")
		f:close()
		for y, mo, d, h, mi in content:gmatch("SCHEDULED:%s+<(%d%d%d%d)-(%d%d)-(%d%d)%s+%a+%s+(%d%d):(%d%d)") do
			local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
				hour = tonumber(h), min = tonumber(mi), sec = 0 })
			if t >= now and t <= horizon then return true end
		end
		::continue::
	end
	return false
end

local function schedule_poll()
	if poll_timer then poll_timer:stop(); poll_timer:close(); poll_timer = nil end
	local interval = has_upcoming_in_hour() and (5 * 60 * 1000) or (15 * 60 * 1000)
	poll_timer = vim.uv.new_timer()
	poll_timer:start(interval, 0, vim.schedule_wrap(function()
		run("sync", function(out)
			check_conflicts(out)
			schedule_poll()
		end, true)
	end))
end

local function run(subcmd, cb, silent)
	local cmd = { "orgcal", subcmd, "--dir", config.dir }
	local output = {}
	vim.fn.jobstart(cmd, {
		stdout_buffered = true,
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then table.insert(output, line) end
			end
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then vim.notify("orgcal: " .. line, vim.log.levels.ERROR) end
			end
		end,
		on_exit = function(_, code)
			if code == 0 then
				local msg = table.concat(output, " ")
				if not silent then
					vim.notify("orgcal: " .. (msg ~= "" and msg or subcmd .. " done"), vim.log.levels.INFO)
				end
				if cb then cb(msg) end
				vim.schedule(function() vim.cmd("silent! checktime") end)
			end
		end,
	})
end

local function check_conflicts(output)
	if output and output ~= "" then
		local imported = tonumber(output:match("Imported:%s*(%d+)")) or 0
		local exported = tonumber(output:match("Exported:%s*(%d+)")) or 0
		local deleted  = tonumber(output:match("Deleted:%s*(%d+)"))  or 0
		local conflicts_count = tonumber(output:match("Conflicts:%s*(%d+)")) or 0
		if imported > 0 then
			vim.notify(string.format("orgcal: %d new event(s) from GCal — reopen agenda", imported), vim.log.levels.INFO)
		end
		if exported > 0 then
			vim.notify(string.format("orgcal: %d todo(s) pushed to GCal", exported), vim.log.levels.INFO)
		end
		if deleted > 0 then
			vim.notify(string.format("orgcal: %d event(s) deleted from GCal", deleted), vim.log.levels.INFO)
		end
		if conflicts_count > 0 then
			resolve_ui()
			return
		end
	end
	-- fallback: read conflicts.json directly
	local path = vim.fn.expand("~/.local/share/orgcal/conflicts.json")
	local f = io.open(path, "r")
	if not f then return end
	local data = f:read("*all")
	f:close()
	local ok, cs = pcall(vim.fn.json_decode, data)
	if not ok or type(cs) ~= "table" then return end
	local n = 0
	for _, c in ipairs(cs) do
		if not c.resolution or c.resolution == "" then n = n + 1 end
	end
	if n > 0 then resolve_ui() end
end

local function schedule_sync()
	if sync_timer then
		sync_timer:stop()
		sync_timer:close()
		sync_timer = nil
	end
	sync_timer = vim.uv.new_timer()
	sync_timer:start(2 * 60 * 1000, 0, vim.schedule_wrap(function()
		if sync_timer then sync_timer:close(); sync_timer = nil end
		run("sync", check_conflicts)
	end))
end

resolve_ui = function()
	local path = vim.fn.expand("~/.local/share/orgcal/conflicts.json")
	local f = io.open(path, "r")
	if not f then
		vim.notify("orgcal: no conflicts pending", vim.log.levels.INFO)
		return
	end
	local data = f:read("*all")
	f:close()

	local ok, conflicts = pcall(vim.fn.json_decode, data)
	if not ok or type(conflicts) ~= "table" then
		vim.notify("orgcal: failed to parse conflicts.json", vim.log.levels.ERROR)
		return
	end

	local pending = {}
	for _, c in ipairs(conflicts) do
		if not c.resolution or c.resolution == "" then
			table.insert(pending, c)
		end
	end
	if #pending == 0 then
		vim.notify("orgcal: no pending conflicts", vim.log.levels.INFO)
		return
	end

	local idx = 1
	local buf = vim.api.nvim_create_buf(false, true)
	local win

	local function render()
		local c = pending[idx]
		local lines = { string.format("  Conflict %d / %d: %s", idx, #pending, c.title), "" }
		for _, field in ipairs(type(c.fields) == "table" and c.fields or {}) do
			table.insert(lines, string.format("  %-12s", field.name))
			table.insert(lines, string.format("    local:  %s", field["local"]))
			table.insert(lines, string.format("    gcal:   %s", field.remote))
		end
		table.insert(lines, "")
		table.insert(lines, "  [l] keep local   [G] keep gcal   [s] skip   [q] quit")
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end

	local function save_and_apply()
		for _, all_c in ipairs(conflicts) do
			for _, p in ipairs(pending) do
				if all_c.gcal_id == p.gcal_id then
					all_c.resolution = p.resolution or ""
				end
			end
		end
		local wf = io.open(path, "w")
		if wf then
			wf:write(vim.fn.json_encode(conflicts))
			wf:close()
		end
		local out = {}
		vim.fn.jobstart({ "orgcal", "resolve" }, {
			stdout_buffered = true,
			on_stdout = function(_, d)
				for _, line in ipairs(d) do
					if line ~= "" then table.insert(out, line) end
				end
			end,
			on_stderr = function(_, d)
				for _, line in ipairs(d) do
					if line ~= "" then vim.notify("orgcal resolve: " .. line, vim.log.levels.ERROR) end
				end
			end,
			on_exit = function(_, code)
				local msg = table.concat(out, " ")
				if code == 0 then
					vim.notify("orgcal: " .. (msg ~= "" and msg or "conflicts resolved") .. " — reopen agenda", vim.log.levels.INFO)
					vim.schedule(function()
						vim.cmd("silent! checktime")
						run("sync", check_conflicts, true)
					end)
				else
					vim.notify("orgcal: resolve failed — " .. msg, vim.log.levels.ERROR)
				end
			end,
		})
	end

	local function resolve(resolution)
		pending[idx].resolution = resolution
		if idx < #pending then
			idx = idx + 1
			render()
		else
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			save_and_apply()
		end
	end

	local opts = { buffer = buf, noremap = true, silent = true }
	vim.keymap.set("n", "l", function() resolve("local") end, opts)
	vim.keymap.set("n", "G", function() resolve("gcal") end, opts)
	vim.keymap.set("n", "s", function() resolve("skip") end, opts)
	vim.keymap.set("n", "q", function()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, opts)

	render()

	local width = math.floor(vim.o.columns * 0.6)
	local height = 12
	win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		border = "single",
		title = " Org Conflicts ",
		title_pos = "center",
	})
end

function M.setup(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})

	schedule_poll()

	vim.api.nvim_create_user_command("OrgCalAuth", function()
		vim.fn.jobstart({ "orgcal", "auth" }, {
			on_exit = function(_, code)
				if code == 0 then vim.notify("orgcal: authenticated", vim.log.levels.INFO) end
			end,
		})
	end, { desc = "Authenticate orgcal with Google Calendar" })

	vim.api.nvim_create_user_command("OrgCalSync", function()
		vim.notify("orgcal: syncing...", vim.log.levels.INFO)
		run("sync", check_conflicts)
	end, { desc = "Bidirectional sync org <-> Google Calendar" })

	vim.api.nvim_create_user_command("OrgCalImport", function()
		vim.notify("orgcal: importing...", vim.log.levels.INFO)
		run("import", nil)
	end, { desc = "Import Google Calendar events to org" })

	vim.api.nvim_create_user_command("OrgCalExport", function()
		vim.notify("orgcal: exporting...", vim.log.levels.INFO)
		run("export", nil)
	end, { desc = "Export org TODOs to Google Calendar" })

	vim.api.nvim_create_user_command("OrgCalResolve", resolve_ui,
		{ desc = "Resolve orgcal conflicts" })

	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = "*.org",
		callback = schedule_sync,
	})
end

return M
