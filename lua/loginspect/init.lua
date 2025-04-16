local M = {}

local history_file = vim.fn.stdpath("state") .. "/loginspect_history.json"

local function escape_lua_pattern(str)
  return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

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

--- Filter the given buffer.
--- @param buffer integer Buffer id, or 0 for current buffer.
--- @param filters string[] Filters to apply, any line that matches any filter will be present in the output.
function M._do_filter(buffer, filters)
  if buffer == 0 then
    buffer = vim.api.nvim_get_current_buf()
  end

  -- Add to history
  local new_history = { { timestamp = os.date("%Y-%m-%d %H:%M:%S"), filters = filters } }
  for _, entry in ipairs(load_history()) do
    if not vim.deep_equal(entry.filters, filters) then
      table.insert(new_history, entry)
    end
  end
  save_history(new_history)

  -- Filter lines
  local orig_lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local result_lines = {}
  for _, line in ipairs(orig_lines) do
    for _, f in ipairs(filters) do
      -- TODO: make sure every string can contain complex chars
      -- TODO: make case sensitivity configurable, maybe use smart case
      local pattern = escape_lua_pattern(f)
      if string.find(line:lower(), pattern:lower(), 1, true) then
        table.insert(result_lines, line)
        break
      end
    end
  end

  -- Open new buffer with filtered lines.
  -- TODO: Add title to window
  local new_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, result_lines)
  local _ = vim.api.nvim_open_win(new_buf, true, {
    relative = "editor",
    width = vim.o.columns - 2,
    height = vim.o.lines - 2,
    row = 0,
    col = 1,
    style = "minimal",
    border = "rounded",
  })

  -- Save filter session state to the new buffer
  vim.b.linefilter_is_filtered = true
  vim.b.linefilter_filters = filters
  vim.b.linefilter_source_buf = buffer

  -- 'q' to quit without action
  vim.api.nvim_buf_set_keymap(new_buf, "n", "q", "<cmd>bd!<CR>", { noremap = true, silent = true })
  -- '<leader>e' to edit current filters
  vim.api.nvim_buf_set_keymap(
    new_buf,
    "n",
    "<leader>e",
    ":lua require('loginspect').edit_active_filters() <cr>",
    { noremap = true, silent = true }
  )
end

--- @param initial_filters string[] Filters to apply, any line that matches any filter will be present in the output.
--- @param source_buffer integer Buffer id.
function M._open_filter_window(initial_filters, source_buffer)
  local filter_buf = vim.api.nvim_create_buf(false, true) -- false: not listed, true: scratch
  vim.api.nvim_buf_set_lines(filter_buf, 0, -1, false, initial_filters)

  -- Open the buffer in a floating window
  -- TODO: Display help / keybinds as virtual text
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

  local current_buffer = nil
  if vim.b.linefilter_is_filtered then
    current_buffer = vim.api.nvim_get_current_buf()
  end

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
    if current_buffer then
      vim.api.nvim_buf_delete(current_buffer, { force = true })
    end

    -- Apply new filters to source buffer.
    M._do_filter(source_buffer, new_filters)
  end, { buffer = filter_buf, noremap = true, silent = true })

  -- Automatically enter insert mode at the end.
  vim.cmd("startinsert!")
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

--- Setup commands
function M.setup(_)
  vim.api.nvim_create_user_command("LineFilter", M.filter_lines, {})
  vim.api.nvim_create_user_command("LineFilterHistory", M.filter_from_history, {})
  vim.api.nvim_create_user_command("LineFilterClearHistory", M.clear_filter_history, {})
end

return M
