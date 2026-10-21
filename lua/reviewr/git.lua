-- reviewr.git: git command execution (sync/async) behind a plenary/fallback backend
local config = require("reviewr.config")

local M = {}

local function plenary_job()
  local c = config.get()
  if not (c.git and c.git.use_plenary) then return nil end
  local ok, Job = pcall(require, "plenary.job")
  if not ok then return nil end
  return Job
end

local function prepare(args, opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()
  local cmd_args = { "-C", cwd }
  vim.list_extend(cmd_args, args or {})
  return cmd_args, cwd, (opts.timeout or (config.get().git and config.get().git.timeout_ms) or 20000)
end

local function new_result(code, stdout, stderr, cwd)
  return { ok = (code or 0) == 0, code = code or 0, stdout = stdout or {}, stderr = stderr or {}, cwd = cwd }
end

function M.run_sync(args, opts)
  opts = opts or {}
  local a, cwd, timeout = prepare(args, opts)
  local Job = plenary_job()
  if Job then
    local stdout, stderr = {}, {}
    local job = Job:new({
      command = "git",
      args = a,
      on_stdout = function(_, d) table.insert(stdout, d) end,
      on_stderr = function(_, d) table.insert(stderr, d) end,
    })
    job:sync(timeout)
    return new_result(job.code, stdout, stderr, cwd)
  end

  local res = vim.fn.systemlist({ "git", unpack(a) })
  return new_result(vim.v.shell_error, res or {}, {}, cwd)
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

-- A tree of the working tree as it is now: tracked edits and untracked files
-- that .gitignore doesn't exclude. Built in a private index kept in the git
-- directory (seeded from the real one), so the real index, worktree and refs
-- are untouched, and later snapshots only rehash files that changed.
function M.snapshot(cwd)
  local paths = M.run_sync({ "rev-parse", "--absolute-git-dir", "--git-path", "index" }, { cwd = cwd }).stdout
  if not paths or not paths[2] then return nil end
  local index = paths[2]:match("^/") and paths[2] or (cwd .. "/" .. paths[2])
  local private = paths[1] .. "/reviewr-index"
  if vim.fn.filereadable(private) == 0 and vim.fn.filereadable(index) == 1 then
    vim.uv.fs_copyfile(index, private)
  end
  local env = { GIT_INDEX_FILE = private }
  local add = vim.system({ "git", "-C", cwd, "add", "-A" }, { env = env }):wait()
  if add.code ~= 0 then return nil end
  local tree = vim.system({ "git", "-C", cwd, "write-tree" }, { env = env, text = true }):wait()
  if tree.code ~= 0 then return nil end
  return vim.trim(tree.stdout)
end

function M.update_ref(ref, value, cwd)
  return M.run_sync({ "update-ref", ref, value }, { cwd = cwd })
end

function M.head(cwd)
  return M.rev_parse("HEAD", cwd)
end

return M
