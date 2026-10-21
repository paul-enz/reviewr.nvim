local config = require("reviewr.config")
local git = require("reviewr.git")
local log = require("reviewr.log")
local scope_mod = require("reviewr.scope")

local M = {}

local function slug(s)
  s = tostring(s or "")
  s = s:gsub("[^%w%._-]", "_")
  return s
end

function M.ref_name(repo, scope)
  repo = repo or (scope_mod.repo() or vim.fn.getcwd())
  scope = scope or scope_mod.get() or {}
  local scope_name = scope.name or scope.ref or "default"
  return string.format("%s/%s/%s", config.get().private_ref_prefix, slug(repo), slug(scope_name))
end

-- A commit of the working tree as it is now (tracked files), without touching
-- the worktree, index or stash list; HEAD when nothing is modified.
function M.current_sha(repo)
  repo = repo or (scope_mod.repo() or vim.fn.getcwd())
  local snap = git.run_sync({ "stash", "create" }, { cwd = repo })
  if snap.ok and snap.stdout[1] and snap.stdout[1] ~= "" then return snap.stdout[1] end
  local r = git.run_sync({ "rev-parse", "HEAD" }, { cwd = repo })
  if r.code ~= 0 then return nil end
  return r.stdout[1]
end

function M.last_turn_sha(repo, scope)
  local ref = M.ref_name(repo, scope)
  local sha = git.rev_parse(ref, repo or (scope_mod.repo() or vim.fn.getcwd()))
  return sha, ref
end

function M.mark_turn(opts)
  opts = opts or {}
  local repo = opts.repo or scope_mod.repo() or git.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
  local scope = opts.scope or scope_mod.get()
  local sha = opts.sha or M.current_sha(repo)
  if not sha then
    log.error("turn: could not resolve HEAD")
    return nil, "no-sha"
  end
  local ref = M.ref_name(repo, scope)
  local r = git.update_ref(ref, sha, repo)
  if r.code ~= 0 then
    log.error("turn: update-ref failed " .. table.concat(r.stderr, " "))
    return nil, "update-ref-failed"
  end
  log.info("turn marked " .. ref .. " -> " .. sha)
  local events = require("reviewr.events")
  events.emit("TurnMarked", { repo = repo, ref = ref, sha = sha })
  return ref, sha
end

return M
