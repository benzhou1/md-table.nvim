if vim.g.loaded_md_table then
  return
end
vim.g.loaded_md_table = true
require("md-table").setup()
