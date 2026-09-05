-- Timed real keystrokes for asciinema; run from the plugin root.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.laststatus = 2
vim.o.showtabline = 0
vim.o.showmode = false
vim.o.showcmd = false
vim.o.ruler = false
vim.o.cmdheight = 1
vim.o.shortmess = "atIF"
vim.o.wrap = false
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.fillchars = "eob: "
vim.o.mouse = ""
local theme = vim.env.MD_TABLE_THEME_ROOT
if theme then
  vim.opt.rtp:append(theme)
  require("kalisi-modern").setup()
else
  vim.cmd.colorscheme("default")
end
vim.cmd("runtime plugin/md-table.lua")
vim.cmd.edit("examples/demo.md")
vim.api.nvim_win_set_cursor(0, { 3, 0 })

local steps = {
  { 1800, "", "A prose-heavy table, wider than this terminal" },
  { 700, ":MdTable", ":MdTable  ·  Open the table under the cursor" },
  { 1800, "<CR>", "Adaptive widths  ·  Compact previews  ·  Fixed headers" },
  { 900, "l", "h / l  ·  Choose a column" },
  { 1100, "2j", "j / k  ·  Move between records" },
  { 1800, "<CR>", "Enter  ·  Read every line of this record" },
  { 900, "<CR>", "Enter  ·  Collapse it again" },
  { 1500, "c", "c  ·  Cut one column to a single line" },
  { 1600, "x", "x  ·  Hide a column and redistribute its width" },
  { 900, "a", "a  ·  Restore all columns" },
  { 600, "l", "Choose the field you want to read" },
  { 1900, "f", "f  ·  Focus this field alongside its identifier" },
  { 1100, "j", "j  ·  Compare the next record" },
  { 800, "a", "a  ·  Show the complete table again" },
  { 2000, "v", "v  ·  Read a record as full-width paragraphs" },
  { 1300, "l", "Tab or l  ·  Jump to the next field" },
  { 1400, "j", "j  ·  Keep the same field in the next record" },
  { 1600, "g", "g  ·  Return to the exact source cell" },
  { 1600, "", "Source unchanged  ·  :MdTable" },
}
local index = 0
local function next_step()
  index = index + 1
  local step = steps[index]
  if not step then
    vim.cmd("qa!")
    return
  end
  vim.o.statusline = " " .. step[3] .. "%="
  if step[2] ~= "" then
    vim.api.nvim_input(vim.api.nvim_replace_termcodes(step[2], true, false, true))
  end
  vim.defer_fn(next_step, step[1])
end
vim.defer_fn(next_step, 300)
