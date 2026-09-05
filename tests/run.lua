-- Run from the plugin repository:
-- nvim --headless -u NONE -i NONE -n -c 'luafile tests/run.lua'
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local data = require("md-table.data")
local checks = 0
local function eq(actual, expected, label)
  checks = checks + 1
  assert(
    vim.deep_equal(actual, expected),
    (label or "check") .. ": " .. vim.inspect(actual) .. " != " .. vim.inspect(expected)
  )
end

local ok, err = xpcall(function()
  eq(data.cells("| left | right |"), { "left", "right" }, "outer pipes")
  eq(data.cells("left | right"), { "left", "right" }, "optional outer pipes")
  eq(data.cells([[| `a\|b` | c\\| d |]]), { [[`a\|b`]], [[c\\]], "d" }, "odd/even escapes")
  eq(data.cells("| | value |"), { "", "value" }, "empty cell")
  eq(data.cells("| value | |"), { "value", "" }, "empty last cell")
  eq(data.cells("not a table"), nil)
  eq(data.cells("    | code |"), nil, "indented code")
  local parsed = data.parse({
    "```markdown",
    "| fake | table |",
    "| - | - |",
    "```",
    "",
    "~~~",
    "| fake | table |",
    "| - | - |",
    "~~~",
    "",
    "a | b",
    ":- | -:",
    "x | y | ignored",
    "| short |",
    "",
    "| empty | table |",
    "| - | - |",
    "",
    "| wrong | count |",
    "| - |",
    "",
    "| singleton |",
    "| --- |",
    "| value |",
  })
  eq(#parsed, 3, "fences and mismatched delimiter rejected")
  eq(parsed[1].start, 11)
  eq(parsed[1].finish, 14)
  eq(parsed[1].rows[2].cells[2], "", "short rows padded")
  eq(#parsed[2].rows, 0, "header-only table")
  eq(parsed[3].rows[1].cells[1], "value", "single column")
  local source = vim.fn.readfile("examples/demo.md")
  local tables = data.parse(source)
  eq(#tables, 2, "both example tables")
  eq(#tables[1].headers, 5)
  eq(#tables[1].rows, 18)
  eq(#tables[2].rows, 5)
  eq(tables[1].rows[1].cells[1], "DX-01")
  local row = tables[1].rows[1]
  eq(source[row.line]:sub(row.starts[2] + 1, row.starts[2] + 9), "Read long", "source byte position")

  eq(data.wrap("one two three", 7), { "one two", "three" })
  eq(data.wrap("abcdefghijk", 4), { "abcd", "efgh", "ijk" }, "long token")
  eq(data.wrap("a<br>b<BR />c", 10), { "a", "b", "c" }, "HTML line breaks")
  eq(data.wrap("one two three", 7, 1), { "one tw…" }, "visible truncation")
  eq(data.wrap("界界界", 4), { "界界", "界" }, "wide Unicode")
  eq(data.wrap("ééé", 2), { "éé", "é" }, "combining marks")
  eq(data.wrap(vim.fn.nr2char(133), 2), { "<8", "5>" }, "non-printable characters cannot stall wrapping")
  eq(data.clip("界界界", 4), "界…")
  for _, width in ipairs({ 28, 58, 78, 118, 178 }) do
    local widths = data.widths(tables[1], { 1, 2, 3, 4, 5 }, width)
    if widths then
      local total = 12
      for col, w in ipairs(widths) do
        total = total + w
        for _, r in ipairs(tables[1].rows) do
          for _, line in ipairs(data.wrap(r.cells[col], w)) do
            assert(vim.fn.strdisplaywidth(line) <= w, "wrapped cell overflow")
          end
        end
      end
      assert(total <= width, "table overflow")
      eq(widths[1], 5, "short ID column stays compact")
    else
      assert(width < 57, "unexpected row-reader fallback")
    end
  end

  -- Exercise actual buffers, windows, mappings and lifecycle; no plugin dependencies.
  vim.o.columns, vim.o.lines = 120, 45
  local src = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(src, 0, -1, false, source)
  local source_win = api.nvim_get_current_win()
  local original = api.nvim_buf_get_lines(src, 0, -1, false)
  local original_tick = api.nvim_buf_get_changedtick(src)
  vim.cmd("runtime plugin/md-table.lua")
  eq(vim.fn.exists(":MdTable"), 2, "native runtime registers command without setup")
  api.nvim_set_hl(0, "MdTableCell", { fg = "#aabbcc", bg = "#112233" })
  require("md-table").setup()
  eq(api.nvim_get_hl(0, { name = "MdTableCell" }).fg, 0xaabbcc, "setup preserves colorscheme highlight")
  vim.cmd("highlight clear MdTableSeparator")
  api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  eq(api.nvim_get_hl(0, { name = "MdTableSeparator" }).link, "FloatBorder", "colorscheme fallback restored")
  eq(api.nvim_get_hl(0, { name = "MdTableCell" }).bg, 0x112233, "colorscheme callback preserves custom highlight")
  eq(#api.nvim_get_autocmds({ group = "MdTableHighlights" }), 1, "setup is idempotent")
  api.nvim_win_set_cursor(source_win, { row.line, row.starts[2] })
  vim.cmd.MdTable()
  local reader, reader_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local function key(lhs)
    for _, mapping in ipairs(api.nvim_buf_get_keymap(reader, "n")) do
      if mapping.lhs == lhs then
        mapping.callback()
        return
      end
    end
    error("Missing mapping " .. lhs)
  end
  local function text()
    return table.concat(api.nvim_buf_get_lines(reader, 0, -1, false), "\n")
  end
  local function fits()
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      local buf = api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "mdtable" then
        for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
          assert(vim.fn.strdisplaywidth(line) <= api.nvim_win_get_width(win), "reader overflow: " .. line)
        end
      end
    end
    checks = checks + 1
  end
  eq(vim.bo[reader].modifiable, false, "reader is read-only")
  eq(vim.bo[reader].filetype, "mdtable", "independent from Markdown rendering")
  assert(vim.wo[reader_win].winhighlight:find("Normal:MdTableNormal", 1, true), "reader uses named highlights")
  local groups = {}
  for _, extmark in
    ipairs(api.nvim_buf_get_extmarks(reader, api.nvim_create_namespace("md-table"), 0, -1, { details = true }))
  do
    groups[extmark[4].hl_group or extmark[4].line_hl_group or ""] = true
  end
  for _, group in ipairs({ "MdTableCell", "MdTableRow", "MdTableSeparator", "MdTableTruncated" }) do
    eq(groups[group], true, "rendered " .. group)
  end
  assert(text():find("…", 1, true), "compact previews")
  fits()
  key("y")
  eq(vim.fn.getreg('"'), row.cells[2], "complete selected cell copied")
  key("<CR>")
  local expanded_lines = api.nvim_buf_line_count(reader)
  key("<CR>")
  assert(api.nvim_buf_line_count(reader) < expanded_lines, "row collapses")
  key("w")
  assert(not text():find("…", 1, true), "full wrapping has no truncation")
  fits()
  key("c")
  assert(text():find("…", 1, true), "column cutoff")
  key("R")
  key("f")
  assert(not text():find("A release", 1, true), "focus hides unrelated columns")
  fits()
  key("a")
  key("v")
  assert(text():find("Challenge", 1, true), "row reader has labels")
  assert(text():find("A release checklist", 1, true), "row reader exposes whole field")
  assert(not text():find("…", 1, true), "row reader never truncates")
  key("j")
  assert(text():find("DX-02", 1, true), "row navigation")
  key("k")
  key("x")
  assert(not text():find("Challenge", 1, true), "selected column hidden")
  local old_select = vim.ui.select
  vim.ui.select = function(items, _, callback)
    callback(items[1])
  end
  key("u")
  vim.ui.select = old_select
  assert(text():find("Challenge", 1, true), "restore hidden column")
  key("g")
  eq(api.nvim_get_current_win(), source_win)
  eq(api.nvim_win_get_cursor(source_win), { row.line, row.starts[2] }, "jump to exact source cell")
  eq(api.nvim_buf_is_valid(reader), false, "scratch buffer wiped")
  eq(#api.nvim_tabpage_list_wins(0), 1, "both reader windows closed")
  eq(api.nvim_buf_get_lines(src, 0, -1, false), original, "source unchanged")
  eq(api.nvim_buf_get_changedtick(src), original_tick, "source undo history untouched")

  -- Resize into automatic row mode and back, including terminal-height changes.
  vim.cmd.MdTable()
  reader, reader_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  vim.o.columns, vim.o.lines = 40, 25
  vim.cmd.redraw()
  api.nvim_exec_autocmds("VimResized", {})
  fits()
  assert(text():find("Challenge", 1, true), "automatic row mode in narrow window")
  vim.o.columns, vim.o.lines = 140, 50
  vim.cmd.redraw()
  api.nvim_exec_autocmds("VimResized", {})
  fits()
  assert(text():find("│", 1, true), "table layout restored after resize")
  api.nvim_win_close(reader_win, true)
  eq(#api.nvim_tabpage_list_wins(0), 1, "manual :close cleans up header")

  -- Table picker and stale-source protection.
  api.nvim_win_set_cursor(source_win, { 1, 0 })
  vim.ui.select = function(items, _, callback)
    callback(items[2])
  end
  vim.cmd.MdTable()
  vim.ui.select = old_select
  reader, reader_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  assert(text():find("readable", 1, true), "second table selected")
  api.nvim_buf_set_lines(src, 0, 0, false, { "new line" })
  key("g")
  eq(api.nvim_get_current_win(), reader_win, "stale source jump rejected")
  key("q")
  eq(#api.nvim_tabpage_list_wins(0), 1)

  api.nvim_buf_set_lines(src, 0, -1, false, { "| empty | table |", "| - | - |" })
  vim.o.columns = 22
  vim.cmd.redraw()
  vim.cmd.MdTable()
  reader = api.nvim_get_current_buf()
  fits()
  key("v")
  fits()
  key("q")
  vim.o.columns = 120
  vim.cmd.redraw()
end, debug.traceback)

if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(("md-table: %d checks passed"):format(checks))
vim.cmd("qa!")
