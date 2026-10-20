if vim.g.loaded_reviewr then return end
vim.g.loaded_reviewr = 1

local ok, reviewr = pcall(require, "reviewr")
if ok then
  reviewr.setup({})
end
