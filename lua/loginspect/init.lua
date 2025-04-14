local M = {}

local history_file = vim.fn.stdpath("data") .. "/loginspect_history.json"

-- Load history from file
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

-- Save history to file
local function save_history(history)
  local f = io.open(history_file, "w")
  if not f then
    vim.notify("Could not save history", vim.log.levels.ERROR)
    return
  end
  f:write(vim.fn.json_encode(history))
  f:close()
end

-- Filter lines
function M.filter_lines()
  vim.ui.input({ prompt = "Enter comma-separated strings: " }, function(input)
    if not input or input == "" then
      return
    end

    local filters = {}
    for str in string.gmatch(input, "([^,]+)") do
      table.insert(filters, vim.trim(str))
    end

    -- Update and save history
    local history = load_history()
    table.insert(history, { timestamp = os.date("%Y-%m-%d %H:%M"), filters = filters })
    save_history(history)

    -- Get lines from current buffer
    local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local result_lines = {}

    for _, line in ipairs(buf_lines) do
      for _, f in ipairs(filters) do
        if string.find(line, f, 1, true) then
          table.insert(result_lines, line)
          break
        end
      end
    end

    -- Create new buffer and set lines
    local new_buf = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_set_current_buf(new_buf)
    vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, result_lines)
  end)
end

-- View history
function M.view_history()
  local history = load_history()
  local lines = {}

  -- Reverse iterate for most recent first
  for i = #history, 1, -1 do
    local entry = history[i]
    local line = entry.timestamp .. ": " .. table.concat(entry.filters, ", ")
    table.insert(lines, line)
  end

  local new_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(new_buf)
  vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
end

-- Clear history
function M.clear_history()
  local f = io.open(history_file, "w")
  if f then
    f:write("[]") -- Write an empty JSON array
    f:close()
    vim.notify("LineFilter history cleared!", vim.log.levels.INFO)
  else
    vim.notify("Failed to clear LineFilter history", vim.log.levels.ERROR)
  end
end

-- Save edited history
function M.save_edited_history()
  if not vim.b.linefilter_history_edit then
    vim.notify("This buffer is not marked as a LineFilter history edit", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local new_history = {}

  for _, line in ipairs(lines) do
    local ok, decoded = pcall(vim.fn.json_decode, line)
    if not ok then
      vim.notify("Invalid JSON in history line: " .. line, vim.log.levels.ERROR)
      return
    end
    table.insert(new_history, decoded)
  end

  save_history(new_history)
  vim.notify("LineFilter history saved!", vim.log.levels.INFO)
end

-- Edit History
function M.edit_history()
  local history = load_history()
  local lines = {}

  for _, entry in ipairs(history) do
    table.insert(lines, vim.fn.json_encode(entry))
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Mark the buffer as a history-editing buffer
  vim.b.linefilter_history_edit = true
  vim.b.linefilter_history_path = history_file

  -- Set autocommand to save when buffer is written
  vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = buf,
    callback = function()
      require("loginspect").save_edited_history()
    end,
    desc = "Auto-save LineFilter history on write",
  })

  vim.notify("Editing LineFilter history. Changes will auto-save on write.", vim.log.levels.INFO)
end

-- Setup commands
function M.setup()
  vim.notify("loginspect: setup")
  vim.api.nvim_create_user_command("LineFilter", M.filter_lines, {})
  vim.api.nvim_create_user_command("LineFilterHistory", M.view_history, {})
  vim.api.nvim_create_user_command("LineFilterClearHistory", M.clear_history, {})
end

return M
