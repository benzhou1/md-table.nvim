local M = {}
local api = vim.api
local data = require("md-table.data")
local ns = api.nvim_create_namespace("md-table")
local active
local config = {}

local function highlights()
  for group, link in pairs({
    MdTableNormal = "NormalFloat",
    MdTableBorder = "FloatBorder",
    MdTableTitle = "FloatTitle",
    MdTableSummary = "Comment",
    MdTableHeader = "Title",
    MdTableHeaderActive = "IncSearch",
    MdTableSeparator = "FloatBorder",
    MdTableRow = "CursorLine",
    MdTableCell = "Visual",
    MdTableLabel = "Title",
    MdTableTruncated = "NonText",
  }) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local function notify(message)
  vim.notify(message, vim.log.levels.INFO, { title = "md-table" })
end

local function write(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function scratch()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "mdtable"
  return buf
end

local function window(buf, enter, config)
  config.relative, config.style, config.border = "win", "minimal", "rounded"
  config.zindex = 50
  local win = api.nvim_open_win(buf, enter, config)
  for key, value in pairs({ wrap = false, cursorline = false, scrolloff = 0, sidescrolloff = 0, winblend = 0 }) do
    vim.wo[win][key] = value
  end
  vim.wo[win].winhighlight = table.concat({
    "Normal:MdTableNormal",
    "NormalNC:MdTableNormal",
    "NormalFloat:MdTableNormal",
    "EndOfBuffer:MdTableNormal",
    "FloatBorder:MdTableBorder",
    "FloatTitle:MdTableTitle",
    "FloatFooter:MdTableSummary",
  }, ",")
  return win
end

local function close(s)
  if s.closing then
    return
  end
  s.closing = true
  if s.group then
    api.nvim_del_augroup_by_id(s.group)
  end
  for _, win in ipairs({ s.win, s.header_win, s.edit_win }) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  if active == s then
    active = nil
  end
end

local function visible_columns(s)
  local cols = {}
  for col = 1, #s.t.headers do
    if not s.hidden[col] then
      cols[#cols + 1] = col
    end
  end
  if not vim.tbl_contains(cols, s.col) then
    s.col = cols[1]
  end
  return cols
end

local function mark(buf, line, start, finish, group)
  api.nvim_buf_set_extmark(buf, ns, line - 1, start, { end_col = finish, hl_group = group, priority = 100 })
end

local function header(s)
  local count = #s.t.rows
  local summary = (" %s · Row %d/%d · %d/%d columns · %s"):format(
    s.cards and "ROW" or "TABLE",
    count == 0 and 0 or s.row,
    count,
    #s.visible,
    #s.t.headers,
    s.t.headers[s.col]
  )
  local lines = { data.clip(summary, s.width) }
  local spans = {}
  if s.cards then
    lines[2] = data.clip(" j/k rows   h/l fields   v table   ? help", s.width)
  else
    for n = 1, 2 do
      local parts = {}
      for index, col in ipairs(s.visible) do
        local text = data.wrap(s.t.headers[col], s.widths[index], 2)[n] or ""
        parts[#parts + 1] = text .. string.rep(" ", s.widths[index] - vim.fn.strdisplaywidth(text))
      end
      lines[n + 1] = table.concat(parts, " │ ")
      local byte = 0
      for index, part in ipairs(parts) do
        if s.visible[index] == s.col then
          spans[#spans + 1] = { n + 1, byte, byte + #part }
        end
        byte = byte + #part + #" │ "
      end
    end
  end
  write(s.header_buf, lines)
  api.nvim_buf_clear_namespace(s.header_buf, ns, 0, -1)
  for line, text in ipairs(lines) do
    mark(s.header_buf, line, 0, #text, line == 1 and "MdTableSummary" or "MdTableHeader")
  end
  for _, span in ipairs(spans) do
    mark(s.header_buf, span[1], span[2], span[3], "MdTableHeaderActive")
  end
end

local function selection(s)
  api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for line, meta in pairs(s.meta) do
    if not s.cards and #meta.cells == 0 and #s.t.rows > 0 then
      mark(s.buf, line, 0, #s.lines[line], "MdTableSeparator")
    end
    if meta.heading then
      mark(s.buf, line, 0, #s.lines[line], "MdTableLabel")
    end
    if meta.row == s.row and #meta.cells > 0 then
      api.nvim_buf_set_extmark(s.buf, ns, line - 1, 0, {
        end_col = #s.lines[line],
        hl_group = "MdTableRow",
        hl_eol = true,
        priority = 90,
      })
    end
    for index, cell in ipairs(meta.cells) do
      local next_cell = meta.cells[index + 1]
      if next_cell then
        mark(s.buf, line, cell.finish, next_cell.start, "MdTableSeparator")
      end
      if meta.row == s.row and cell.col == s.col then
        mark(s.buf, line, cell.start, cell.finish, "MdTableCell")
      end
    end
    local offset = 1
    while true do
      local first, last = s.lines[line]:find("…", offset, true)
      if not first then
        break
      end
      mark(s.buf, line, first - 1, last, "MdTableTruncated")
      offset = last + 1
    end
  end
  header(s)
end

local function render(s)
  if s.closing then
    return
  end
  s.rendering = true
  s.visible = visible_columns(s)
  s.widths = data.widths(s.t, s.visible, s.width)
  s.cards = s.mode == "row" or not s.widths
  local lines, meta, row_lines, targets = {}, {}, {}, {}
  local function add(text, row, cells, heading)
    lines[#lines + 1] = text
    meta[#lines] = { row = row, cells = cells or {}, heading = heading }
    row_lines[row] = row_lines[row] or #lines
  end
  if #s.t.rows == 0 then
    add(data.clip("This table has no data rows.", s.width), 1)
  elseif s.cards then
    for _, col in ipairs(s.visible) do
      targets[col] = #lines + 1
      local label = data.wrap(s.t.headers[col], s.width)
      for _, text in ipairs(label) do
        add(text, s.row, { { col = col, start = 0, finish = #text } }, true)
      end
      for _, text in ipairs(data.wrap(s.t.rows[s.row].cells[col], s.width)) do
        add(text, s.row, { { col = col, start = 0, finish = #text } })
      end
      add("", s.row)
    end
  else
    -- ponytail: render all rows; virtualize if tables with thousands of rows become a real workload.
    for row_index, row in ipairs(s.t.rows) do
      local cells, height = {}, 1
      for index, col in ipairs(s.visible) do
        local limit = not s.expanded[row_index] and (s.cut[col] and 1 or (not s.full and 3)) or nil
        cells[index] = data.wrap(row.cells[col], s.widths[index], limit or nil)
        height = math.max(height, #cells[index])
      end
      for n = 1, height do
        local parts, spans, byte = {}, {}, 0
        for index, col in ipairs(s.visible) do
          local text = cells[index][n] or ""
          local part = text .. string.rep(" ", s.widths[index] - vim.fn.strdisplaywidth(text))
          parts[#parts + 1] = part
          spans[#spans + 1] = { col = col, start = byte, finish = byte + #part }
          byte = byte + #part + #" │ "
        end
        add(table.concat(parts, " │ "), row_index, spans)
      end
      local parts = {}
      for _, width in ipairs(s.widths) do
        parts[#parts + 1] = string.rep("─", width)
      end
      add(table.concat(parts, "─┼─"), row_index)
    end
  end
  s.lines, s.meta, s.row_lines, s.targets = lines, meta, row_lines, targets
  write(s.buf, lines)
  local line = s.cards and (targets[s.col] or 1) or (row_lines[s.row] or 1)
  local byte = 0
  for _, cell in ipairs(meta[line].cells) do
    if cell.col == s.col then
      byte = cell.start
    end
  end
  api.nvim_win_set_cursor(s.win, { line, byte })
  selection(s)
  s.rendering = false
end

local function resize(s)
  if not api.nvim_win_is_valid(s.source_win) or api.nvim_win_get_buf(s.source_win) ~= s.source_buf then
    close(s)
    return
  end
  local width, height = api.nvim_win_get_width(s.source_win) - 2, api.nvim_win_get_height(s.source_win) - 7
  if width < 20 or height < 3 then
    close(s)
    notify("Table reader needs a window at least 22 columns wide and 10 lines tall.")
    return
  end
  if s.width == width and s.height == height then
    return
  end
  s.width, s.height = width, height
  api.nvim_win_set_config(
    s.header_win,
    { relative = "win", win = s.source_win, row = 0, col = 0, width = width, height = 3 }
  )
  api.nvim_win_set_config(
    s.win,
    { relative = "win", win = s.source_win, row = 5, col = 0, width = width, height = height }
  )
  render(s)
end

local function apply_edit(s, lines)
  local t, buf = s.t, s.source_buf
  if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_changedtick(buf) ~= s.tick then
    notify("Source changed. Close and reopen the reader before editing.")
    return
  end
  local value = vim.trim(table.concat(lines, "<br>")):gsub("|", "\\|")
  t.rows[s.row].cells[s.col] = value
  local old = api.nvim_buf_get_lines(buf, t.start - 1, t.finish, false)
  api.nvim_buf_set_lines(buf, t.start - 1, t.finish, false, data.format(t, old))
  for _, new in ipairs(data.parse(api.nvim_buf_get_lines(buf, 0, -1, false))) do
    if new.start == t.start then
      t.headers, t.rows, t.finish = new.headers, new.rows, new.finish
    end
  end
  s.tick = api.nvim_buf_get_changedtick(buf)
  render(s)
end

local function show(t, source_buf, source_win)
  if active then
    close(active)
  end
  if not api.nvim_win_is_valid(source_win) or api.nvim_win_get_buf(source_win) ~= source_buf then
    return
  end
  local width, height = api.nvim_win_get_width(source_win) - 2, api.nvim_win_get_height(source_win) - 7
  if width < 20 or height < 3 then
    notify("Table reader needs a window at least 22 columns wide and 10 lines tall.")
    return
  end
  local s = {
    t = t,
    source_buf = source_buf,
    source_win = source_win,
    tick = api.nvim_buf_get_changedtick(source_buf),
    row = 1,
    col = 1,
    mode = "table",
    hidden = {},
    cut = {},
    expanded = {},
    full = config.auto_expand == true,
    buf = scratch(),
    header_buf = scratch(),
    width = width,
    height = height,
  }
  local cursor = api.nvim_win_get_cursor(source_win)
  for index, row in ipairs(t.rows) do
    if row.line == cursor[1] then
      s.row = index
      for col, start in ipairs(row.starts) do
        if col <= #t.headers and start <= cursor[2] then
          s.col = col
        end
      end
    end
  end
  s.header_win = window(s.header_buf, false, {
    win = source_win,
    row = 0,
    col = 0,
    width = width,
    height = 3,
    title = " md-table ",
    title_pos = "center",
    focusable = false,
  })
  s.win = window(s.buf, true, {
    win = source_win,
    row = 5,
    col = 0,
    width = width,
    height = height,
    footer = data.clip(" ? help · v row · Enter expand · q close ", width),
    footer_pos = "center",
  })
  active = s
  local function map(keys, desc, callback)
    for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set("n", key, callback, { buffer = s.buf, silent = true, nowait = true, desc = desc })
    end
  end
  local function move_row(delta)
    s.row = math.max(1, math.min(math.max(1, #t.rows), s.row + delta * vim.v.count1))
    render(s)
  end
  local function move_col(delta)
    local index = 1
    for i, col in ipairs(s.visible) do
      if col == s.col then
        index = i
      end
    end
    s.col = s.visible[(index - 1 + delta) % #s.visible + 1]
    render(s)
  end
  local actions = {}
  function actions.close()
    close(s)
  end
  function actions.next_row()
    move_row(1)
  end
  function actions.prev_row()
    move_row(-1)
  end
  function actions.prev_col()
    move_col(-1)
  end
  function actions.next_col()
    move_col(1)
  end
  function actions.toggle_row_mode()
    s.mode = s.mode == "row" and "table" or "row"
    render(s)
  end
  function actions.toggle_expand()
    s.expanded[s.row] = not s.expanded[s.row]
    render(s)
  end
  function actions.toggle_wrap()
    s.full = not s.full
    render(s)
  end
  function actions.toggle_cut()
    s.cut[s.col] = not s.cut[s.col]
    render(s)
  end
  function actions.hide_col()
    if #s.visible > 1 then
      s.hidden[s.col] = true
      render(s)
    end
  end
  function actions.restore_col()
    local hidden = {}
    for col = 1, #t.headers do
      if s.hidden[col] then
        hidden[#hidden + 1] = col
      end
    end
    if #hidden == 0 then
      notify("No hidden columns.")
      return
    end
    vim.ui.select(hidden, {
      prompt = "Restore column",
      format_item = function(col)
        return t.headers[col]
      end,
    }, function(col)
      if col and not s.closing then
        s.hidden[col], s.col = nil, col
        render(s)
      end
    end)
  end
  function actions.focus_col()
    for col = 1, #t.headers do
      s.hidden[col] = col ~= 1 and col ~= s.col
    end
    render(s)
  end
  function actions.show_all()
    s.hidden = {}
    render(s)
  end
  function actions.reset()
    s.hidden, s.cut, s.expanded, s.full, s.mode = {}, {}, {}, config.auto_expand == true, "table"
    render(s)
  end
  function actions.yank()
    if t.rows[s.row] then
      vim.fn.setreg(vim.v.register, t.rows[s.row].cells[s.col])
      notify("Copied complete cell: " .. t.headers[s.col])
    end
  end
  function actions.goto_source()
    if
      not api.nvim_win_is_valid(source_win)
      or api.nvim_win_get_buf(source_win) ~= source_buf
      or api.nvim_buf_get_changedtick(source_buf) ~= s.tick
    then
      notify("Source changed. Close and reopen the reader before jumping to a cell.")
      return
    end
    local row = t.rows[s.row]
    close(s)
    if api.nvim_win_is_valid(source_win) then
      api.nvim_set_current_win(source_win)
      api.nvim_win_set_cursor(source_win, { row and row.line or t.start, row and row.starts[s.col] or 0 })
    end
  end
  function actions.edit_cell()
    if not t.rows[s.row] then
      notify("This table has no data rows.")
      return
    end
    if s.edit_win and api.nvim_win_is_valid(s.edit_win) then
      api.nvim_set_current_win(s.edit_win)
      return
    end
    local ebuf = scratch()
    vim.bo[ebuf].buftype = "acwrite"
    api.nvim_buf_set_name(ebuf, "md-table://cell/" .. ebuf)
    local text = vim.split(data.text(t.rows[s.row].cells[s.col]), "\n", { plain = true })
    api.nvim_buf_set_lines(ebuf, 0, -1, false, text)
    vim.bo[ebuf].modified = false
    local ewin = window(ebuf, true, {
      win = s.win,
      row = 2,
      col = 2,
      width = s.width - 4,
      height = math.max(1, math.min(8, s.height - 2)),
      title = " Edit: " .. t.headers[s.col] .. " ",
      title_pos = "center",
      footer = " <CR>/:w save · q cancel ",
      footer_pos = "center",
    })
    s.edit_win = ewin
    vim.wo[ewin].wrap = true
    local function finish()
      if api.nvim_win_is_valid(ewin) then
        api.nvim_win_close(ewin, true)
      end
      if api.nvim_win_is_valid(s.win) then
        api.nvim_set_current_win(s.win)
      end
    end
    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = ebuf,
      callback = function()
        apply_edit(s, api.nvim_buf_get_lines(ebuf, 0, -1, false))
        vim.bo[ebuf].modified = false
        vim.schedule(finish)
      end,
    })
    local opts = { buffer = ebuf, silent = true, nowait = true }
    vim.keymap.set("n", "q", finish, vim.tbl_extend("force", opts, { desc = "Cancel cell edit" }))
    vim.keymap.set("n", "<CR>", "<cmd>write<cr>", vim.tbl_extend("force", opts, { desc = "Save cell edit" }))
  end
  function actions.help()
    vim.ui.select({
      "j/k: next/previous row (counts work); h/l or Tab: select column",
      "Enter: expand/collapse selected row; w: full wrap for all rows",
      "c: one-line cutoff for selected column; x: hide column; u: restore column",
      "f: focus selected + first column; a: show all columns; R: reset layout",
      "v: full-width row reader; Ctrl-d/Ctrl-u: scroll long content",
      "/: search visible text; use w or v to expose truncated text first",
      "y: yank complete source cell (registers supported); g: jump to source",
      "e: edit selected cell (Enter or :w saves to source buffer, q cancels)",
      "q/Esc: close; reopen to refresh",
    }, { prompt = "md-table · keys" }, function() end)
  end
  map({ "q", "<Esc>" }, "Close table reader", actions.close)
  map({ "j", "<Down>" }, "Next row", actions.next_row)
  map({ "k", "<Up>" }, "Previous row", actions.prev_row)
  map({ "h", "<Left>", "<S-Tab>" }, "Previous column", actions.prev_col)
  map({ "l", "<Right>", "<Tab>" }, "Next column", actions.next_col)
  map("v", "Toggle full-width row reader", actions.toggle_row_mode)
  map("<CR>", "Expand/collapse this row", actions.toggle_expand)
  map("w", "Toggle full wrapping for all rows", actions.toggle_wrap)
  map("c", "Toggle one-line cutoff for this column", actions.toggle_cut)
  map("x", "Hide this column", actions.hide_col)
  map("u", "Restore a hidden column", actions.restore_col)
  map("f", "Focus this column alongside the first column", actions.focus_col)
  map("a", "Show all columns", actions.show_all)
  map("R", "Reset table layout", actions.reset)
  map("y", "Yank the complete source cell", actions.yank)
  map("g", "Go to this cell in the Markdown source", actions.goto_source)
  map("e", "Edit this cell", actions.edit_cell)
  map("?", "Table reader help", actions.help)
  if config.on_attach then
    config.on_attach(s.buf, actions)
  end
  s.group = api.nvim_create_augroup("MdTableReader" .. s.buf, { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = s.group,
    buffer = s.buf,
    callback = function()
      if s.rendering or s.closing then
        return
      end
      local pos = api.nvim_win_get_cursor(s.win)
      local meta = s.meta[pos[1]]
      if not meta then
        return
      end
      s.row = meta.row
      for _, cell in ipairs(meta.cells) do
        if pos[2] >= cell.start and pos[2] <= cell.finish then
          s.col = cell.col
          break
        end
      end
      selection(s)
    end,
  })
  api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = s.group,
    callback = function()
      if not s.closing then
        resize(s)
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    callback = function(event)
      local win = tonumber(event.match)
      if win == s.win or win == s.header_win or win == s.source_win then
        close(s)
      end
    end,
  })
  render(s)
end

function M.open()
  if active and api.nvim_get_current_buf() == active.buf then
    return
  end
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local tables = data.parse(api.nvim_buf_get_lines(buf, 0, -1, false))
  local line = api.nvim_win_get_cursor(win)[1]
  for _, t in ipairs(tables) do
    if line >= t.start and line <= t.finish then
      show(t, buf, win)
      return
    end
  end
  if #tables == 0 then
    notify("No Markdown pipe tables found in this buffer.")
  elseif #tables == 1 then
    show(tables[1], buf, win)
  else
    local tick = api.nvim_buf_get_changedtick(buf)
    vim.ui.select(tables, {
      prompt = "Read table",
      format_item = function(t)
        return ("Line %d · %d rows · %s"):format(t.start, #t.rows, table.concat(t.headers, " / "))
      end,
    }, function(t)
      if t and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_changedtick(buf) == tick then
        show(t, buf, win)
      end
    end)
  end
end

function M.setup(opts)
  config = opts or {}
  highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("MdTableHighlights", { clear = true }),
    callback = highlights,
  })
  api.nvim_create_user_command(
    "MdTable",
    M.open,
    { desc = "Read a Markdown table at the current window width", force = true }
  )
end

return M
