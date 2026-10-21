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

-- A commit of the tracked files as they are now in the working tree, without
-- touching the worktree, index or refs.
function M.current_sha(repo)
  repo = repo or (scope_mod.repo() or vim.fn.getcwd())
  local tree = git.snapshot(repo)
  if not tree then return nil end
  local r = git.run_sync({ "commit-tree", tree, "-p", "HEAD", "-m", "reviewr turn" }, { cwd = repo })
  if r.code ~= 0 then return nil end
  return r.stdout[1]
end

function M.last_turn_sha(repo, scope)
  local ref = M.ref_name(repo, scope)
  local sha = git.rev_parse(ref, repo or (scope_mod.repo() or vim.fn.getcwd()))
  return sha, ref
end

-- Deletes baselines nothing will use again: those of worktrees that are gone
-- and, given the terminals still open (live_blocks: block id -> true), those
-- paired with a terminal that has closed. Only private refs are touched.
function M.prune(repo, live_blocks)
  local prefix = config.get().private_ref_prefix
  local wt = git.run_sync({ "worktree", "list", "--porcelain" }, { cwd = repo })
  if not wt.ok then return end
  local repos = { [slug(repo)] = true }
  for _, l in ipairs(wt.stdout) do
    local path = l:match("^worktree (.+)$")
    if path then repos[slug(path)] = true end
  end
  local blocks
  if live_blocks then
    blocks = {}
    for id in pairs(live_blocks) do blocks[slug(id)] = true end
  end
  local refs = git.run_sync({ "for-each-ref", "--format=%(refname)", prefix }, { cwd = repo })
  for _, ref in ipairs(refs.stdout) do
    local r, name = ref:sub(#prefix + 2):match("^([^/]+)/(.+)$")
    local block = name and name:match("^turn%-(.+)$")
    if r and (not repos[r] or (blocks and block and not blocks[block])) then
      git.run_sync({ "update-ref", "-d", ref }, { cwd = repo })
      log.info("turn: pruned " .. ref)
    end
  end
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
