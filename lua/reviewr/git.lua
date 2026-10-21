-- reviewr.git: git command execution
local config = require("reviewr.config")

local M = {}

-- Output split into lines the way a file reads: bytes kept as they are (CRs,
-- NULs), no empty item for the final newline.
function M.lines(raw)
  if not raw or raw == "" then return {} end
  local out = vim.split(raw, "\n", { plain = true })
  if out[#out] == "" then out[#out] = nil end
  return out
end

-- stdout and stderr come back apart, as lines; raw_stdout keeps the bytes.
function M.run_sync(args, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local timeout = opts.timeout or (config.get().git and config.get().git.timeout_ms) or 20000
  local cmd = { "git", "-C", cwd }
  vim.list_extend(cmd, args or {})
  local ok, res = pcall(function() return vim.system(cmd):wait(timeout) end)
  if not ok then res = { code = -1, stdout = "", stderr = tostring(res) } end
  local code = res.code or -1
  return { ok = code == 0, code = code, stdout = M.lines(res.stdout), stderr = M.lines(res.stderr),
    raw_stdout = res.stdout or "", cwd = cwd }
end

function M.git_root(cwd)
  local r = M.run_sync({ "rev-parse", "--show-toplevel" }, { cwd = cwd })
  if not r.ok or not r.stdout[1] then return nil end
  return r.stdout[1]
end

function M.rev_parse(rev, cwd)
  local r = M.run_sync({ "rev-parse", rev }, { cwd = cwd })
  if not r.ok then return nil end
  return r.stdout[1]
end

function M.show(ref_path, cwd)
  local r = M.run_sync({ "show", ref_path }, { cwd = cwd })
  if not r.ok then return nil, r end
  return r.stdout, r
end

-- A tree of the tracked files as they are in the working tree: committed and
-- staged paths with their current contents, untracked files left out. Built
-- in a copy of the index, so the real index, worktree and refs are untouched.
function M.snapshot(cwd)
  local index = M.run_sync({ "rev-parse", "--git-path", "index" }, { cwd = cwd }).stdout[1]
  if not index then return nil end
  if not index:match("^/") then index = cwd .. "/" .. index end
  local tmp = vim.fn.tempname()
  if vim.fn.filereadable(index) == 1 then vim.uv.fs_copyfile(index, tmp) end
  local env = { GIT_INDEX_FILE = tmp }
  local add = vim.system({ "git", "-C", cwd, "add", "-u" }, { env = env }):wait()
  local tree = add.code == 0 and vim.system({ "git", "-C", cwd, "write-tree" }, { env = env, text = true }):wait()
  os.remove(tmp)
  if not tree or tree.code ~= 0 then return nil end
  return vim.trim(tree.stdout)
end

function M.update_ref(ref, value, cwd)
  return M.run_sync({ "update-ref", ref, value }, { cwd = cwd })
end

function M.head(cwd)
  return M.rev_parse("HEAD", cwd)
end

return M
