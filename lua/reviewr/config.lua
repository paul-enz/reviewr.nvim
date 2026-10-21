local defaults_mod = require("reviewr.config.defaults")

local M = {}
local cfg = vim.deepcopy(defaults_mod.defaults)

local levels = { debug = 10, info = 20, warn = 30, error = 40 }

local function validate(opts)
  opts = opts or {}
  if opts.baseline_trigger and not vim.tbl_contains({ "open", "first_comment", "manual" }, opts.baseline_trigger) then
    error("reviewr: invalid baseline_trigger " .. tostring(opts.baseline_trigger))
  end
  if opts.send_mode and not vim.tbl_contains({ "queue", "submit" }, opts.send_mode) then
    error("reviewr: invalid send_mode " .. tostring(opts.send_mode))
  end
  if opts.log_level and not levels[opts.log_level] then
    error("reviewr: invalid log_level " .. tostring(opts.log_level))
  end
  if opts.private_ref_prefix then
    if type(opts.private_ref_prefix) ~= "string" or not opts.private_ref_prefix:match("^refs/reviewr") then
      error("reviewr: invalid private_ref_prefix " .. tostring(opts.private_ref_prefix))
    end
  end
  return true
end

function M.merge(user_opts)
  user_opts = user_opts or {}
  validate(user_opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults_mod.defaults), user_opts)
  return cfg
end

function M.get()
  return cfg
end

function M.reset()
  cfg = vim.deepcopy(defaults_mod.defaults)
  return cfg
end

function M.level_value(name)
  return levels[name or "info"] or 20
end

return M
