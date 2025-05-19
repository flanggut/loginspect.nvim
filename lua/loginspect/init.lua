local M = {}

local loginspect_namespace_id = vim.api.nvim_create_namespace("loginspect")

local history_file = vim.fn.stdpath("state") .. "/loginspect_history.json"

local active_filter_window = nil
local marked_lines = {}

--- Load filter history from file.
local function load_history()
  local f = io.open(history_file, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.fn.json_decode, content)
  return ok and decoded or {}
end

--- Save filter history to file.
local function save_history(history)
  -- TODO: proper type annotations.
  -- TODO: only load history once from disk
  local f = io.open(history_file, "w")
  if not f then
    vim.notify("Could not save history", vim.log.levels.ERROR)
    return
  end
  f:write(vim.fn.json_encode(history))
  f:close()
end

local function escape_lua_pattern(str)
  return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

--- Function to check if line matches any pattern in a list
local function matches_any(line, patterns)
  for _, pat in ipairs(patterns) do
    -- TODO: make sure every string can contain complex chars
    -- TODO: make case sensitivity configurable, maybe use smart case
    local pattern = escape_lua_pattern(pat)
    if string.find(line:lower(), pattern:lower(), 1, true) then
      return true
    end
  end
  return false
end

--- Filter the given buffer.
--- @param buffer integer Buffer id, or 0 for current buffer.
--- @param filters string[] Filters to apply, any line that matches any filter will be present in the output.
function M._do_filter(buffer, filters)
  if buffer == 0 then
    buffer = vim.api.nvim_get_current_buf()
  end
  local filename = vim.api.nvim_buf_get_name(buffer)

  -- Add to history
  local new_history = { { timestamp = os.date("%Y-%m-%d %H:%M:%S"), filters = filters } }
  for _, entry in ipairs(load_history()) do
    if not vim.deep_equal(entry.filters, filters) then
      table.insert(new_history, entry)
    end
  end
  save_history(new_history)

  -- Split filters into regular and inverse
  local parsed_filters = { filters = {}, inverse_filters = {} }
  for _, filter in ipairs(filters) do
    if filter:match("^!") then
      table.insert(parsed_filters.inverse_filters, filter:sub(2))
    else
      table.insert(parsed_filters.filters, filter)
    end
  end

  -- Filter lines
  local orig_lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local result_lines = {}
  for _, line in ipairs(orig_lines) do
    if matches_any(line, parsed_filters.filters) and not matches_any(line, parsed_filters.inverse_filters) then
      table.insert(result_lines, line)
    end
  end

  -- Open new buffer with filtered lines.
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, result_lines)
  vim.bo[new_buf].modifiable = false
  vim.bo[new_buf].readonly = true
  active_filter_window = vim.api.nvim_open_win(new_buf, true, {
    relative = "editor",
    width = vim.o.columns - 2,
    height = vim.o.lines - 2,
    row = 0,
    col = 1,
    style = "minimal",
    border = "rounded",
    title = "Filtered: " .. filename,
  })

  -- Save filter session state to the new buffer
  vim.b.linefilter_is_filtered = true
  vim.b.linefilter_filters = filters
  vim.b.linefilter_source_buf = buffer

  -- 'K' to toggle highlight in the the current line
  vim.keymap.set("n", "K", function()
    local row = (vim.api.nvim_win_get_cursor(0))[1] - 1 -- 0 based index for row
    if marked_lines[row] then
      vim.api.nvim_buf_clear_namespace(new_buf, loginspect_namespace_id, row, row + 1)
      marked_lines[row] = nil
    else
      -- Get exact line length to work around https://github.com/neovim/neovim/issues/19511
      local line = vim.api.nvim_get_current_line()
      vim.hl.range(new_buf, loginspect_namespace_id, "CursorLine", { row, 0 }, { row, #line }, { inclusive = true })
      marked_lines[row] = true
    end
  end, { buffer = new_buf, noremap = true, silent = true, desc = "Toggle highlight of current line." })

  -- '<leader>e' to edit current filters
  vim.keymap.set("n", "<leader>e", M.edit_active_filters, { buffer = new_buf, noremap = true, silent = true })
  -- 'q' to quit without action
  vim.api.nvim_buf_set_keymap(new_buf, "n", "q", "<cmd>bd!<CR>", { noremap = true, silent = true })
end

--- @param initial_filters string[] Filters to apply, any line that matches any filter will be present in the output.
--- @param source_buffer integer Buffer id.
function M._open_filter_window(initial_filters, source_buffer)
  local filter_buf = vim.api.nvim_create_buf(false, true) -- false: not listed, true: scratch
  vim.api.nvim_buf_set_lines(filter_buf, 0, -1, false, initial_filters)

  -- Open the buffer in a floating window
  local width = math.floor(vim.o.columns * 0.6)
  local height = #initial_filters + 5
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local _ = vim.api.nvim_open_win(filter_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = "Active Filters",
    title_pos = "center",
  })

  vim.api.nvim_buf_set_extmark(filter_buf, vim.api.nvim_create_namespace("help_ns"), 0, 0, {
    virt_text = {
      { " 'enter' → apply changes,  'q' → close.", "Comment" },
    },
    virt_text_pos = "right_align", -- or "eol", "right_align"
  })

  -- 'q' to quit without action
  vim.api.nvim_buf_set_keymap(filter_buf, "n", "q", "<cmd>bd!<CR>", { noremap = true, silent = true })

  -- <Enter> to apply new filters and close
  vim.keymap.set("n", "<CR>", function()
    -- Get all lines from the buffer
    local lines = vim.api.nvim_buf_get_lines(filter_buf, 0, -1, false)
    -- Filter out empty lines
    local new_filters = {}
    for _, line in ipairs(lines) do
      if line:match("%S") then -- matches any non-whitespace character
        table.insert(new_filters, line)
      end
    end
    -- Close the filter buffer (and its window)
    vim.api.nvim_buf_delete(filter_buf, { force = true })
    -- Close the filtered buffer
    if active_filter_window then
      vim.api.nvim_win_close(active_filter_window, true)
      active_filter_window = nil
    end

    -- Apply new filters to source buffer.
    M._do_filter(source_buffer, new_filters)
  end, { buffer = filter_buf, noremap = true, silent = true })
end

--- Filter lines
function M.filter_lines()
  M._open_filter_window({}, vim.api.nvim_get_current_buf())
end

--- Edit currently applied filters
function M.edit_active_filters()
  if not vim.b.linefilter_is_filtered then
    vim.notify("This buffer was not generated by LineFilter.", vim.log.levels.WARN)
    return
  end
  local filters = vim.b.linefilter_filters or {}
  local source_buffer = vim.b.linefilter_source_buf
  M._open_filter_window(filters, source_buffer)
end

--- View history.
function M.filter_from_history()
  local history = load_history()
  local lines = {}

  -- Show filters as comma separated list
  for _, entry in ipairs(history) do
    local line = table.concat(entry.filters, ", ")
    table.insert(lines, line)
  end

  vim.ui.select(lines, { prompt = "Select filters from history:" }, function(_, idx)
    if idx then
      M._do_filter(0, history[idx].filters)
    end
  end)
end

--- Clear history.
function M.clear_filter_history()
  local f = io.open(history_file, "w")
  if f then
    f:write("[]") -- Write an empty JSON array
    f:close()
    vim.notify("LineFilter history cleared!", vim.log.levels.INFO)
  else
    vim.notify("Failed to clear LineFilter history", vim.log.levels.ERROR)
  end
end

function M.run_async_command(cmd)
  -- Create a new scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_buf_set_name(buf, "Async Command Output")

  -- Open the buffer in a new split window
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)

  -- Start the command using uv.spawn
  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  local handle
  local buffer_is_closed = false
  local command_is_stopped = false

  ---@diagnostic disable-next-line: missing-fields
  handle = vim.uv.spawn(cmd[1], {
    args = vim.list_slice(cmd, 2),
    stdio = { nil, stdout, stderr },
  }, function(code, signal) -- on_exit function
    -- Close pipes and handle
    if stdout then
      stdout:close()
    end
    if stderr then
      stderr:close()
    end
    handle:close()

    -- Write the exit code
    vim.schedule(function()
      if not buffer_is_closed and vim.api.nvim_buf_is_valid(buf) and not command_is_stopped then
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
          "",
          string.format("Process exited with code %d, signal %d", code, signal),
        })
      end
    end)
  end)

  local function on_read(err, data)
    if err then
      vim.schedule(function()
        if not buffer_is_closed and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "ERROR: " .. err })
        end
      end)
    end
    if data then
      local lines = vim.split(data, "\n", { plain = true })
      if #lines > 0 and lines[#lines] == "" then
        table.remove(lines, #lines)
      end
      vim.schedule(function()
        if not buffer_is_closed and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
        end
      end)
    end
  end

  -- Read stdout and stderr
  ---@diagnostic disable-next-line: param-type-mismatch
  vim.uv.read_start(stdout, on_read)
  ---@diagnostic disable-next-line: param-type-mismatch
  vim.uv.read_start(stderr, on_read)

  -- Watch for buffer deletion or unload
  vim.api.nvim_buf_attach(buf, false, {
    on_detach = function()
      buffer_is_closed = true
      if handle and not handle:is_closing() then
        handle:kill("sigkill")
      end
    end,
  })

  -- Buffer-local keybind: press 'q' to stop the command
  vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = function()
      if handle and not handle:is_closing() then
        handle:kill("sigterm")
        command_is_stopped = true
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "Process stopped manually (SIGTERM)" })
      end
    end,
    desc = "Stop async command",
  })
end

--- Setup commands
function M.setup(_)
  vim.api.nvim_create_user_command("LineFilter", M.filter_lines, {})
  vim.api.nvim_create_user_command("LineFilterHistory", M.filter_from_history, {})
  vim.api.nvim_create_user_command("LineFilterClearHistory", M.clear_filter_history, {})
  vim.api.nvim_create_user_command("LineFilterRun", function(opts)
    -- Split the arguments like a shell command line
    local args = vim.fn.split(opts.args)
    if #args == 0 then
      print("Usage: :LineFilterRun <command>")
      return
    end
    M.run_async_command(args)
  end, {
    nargs = "+", -- Requires at least one argument
    complete = "shellcmd", -- Tab-complete like shell commands
  })
end

return M
