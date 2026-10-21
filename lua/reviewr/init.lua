local config_mod = require("reviewr.config")
local events = require("reviewr.events")
local log = require("reviewr.log")
local store = require("reviewr.store")
local state = require("reviewr.state")
local scope_mod = require("reviewr.scope")
local git = require("reviewr.git")
local turn = require("reviewr.turn")

local M = {}
local setup_done = false

local SCOPES = { "uncommitted", "staged", "branch", "turn", "commit" }
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
-- the base branch picked with gb; nil means the default branch
local chosen_base

-- open: mark the turn baseline whenever a review opens; agent: when a
-- watched agent starts working; auto: agent inside Rex, else open
local function baseline_trigger()
  local t = config_mod.get().baseline_trigger
  if t == "auto" then return require("reviewr.rex").available() and "agent" or "open" end
  return t
end

-- The agent this review was opened for (Rex sets vim.g.reviewr_agent when
-- cmd+r is pressed in an agent's terminal), or nil.
local function paired()
  local a = vim.g.reviewr_agent
  return type(a) == "table" and a.block and a or nil
end

-- A paired review keeps its own turn baseline, so other agents working in the
-- same repository don't move it.
local function turn_scope()
  local a = paired()
  return { name = a and ("turn-" .. a.block) or "turn" }
end

-- repos whose stale baselines were pruned this session
local pruned = {}

local ACTIVE = { working = true, blocked = true }
local watch_repo

-- A watched agent's turn starts when it leaves idle for work, and ends when
-- it stops working or waiting on the user.
local function on_agent(new, old, label)
  if ACTIVE[new] and not ACTIVE[old] then
    if baseline_trigger() == "agent" and watch_repo then
      turn.mark_turn({ repo = watch_repo, scope = turn_scope() })
    end
  elseif ACTIVE[old] and not ACTIVE[new] then
    local ui = require("reviewr.ui")
    if config_mod.get().refresh_on_agent and ui.is_open() then
      local here = vim.api.nvim_get_current_tabpage()
      ui.focus_tab()
      M.refresh()
      if vim.api.nvim_tabpage_is_valid(here) then vim.api.nvim_set_current_tabpage(here) end
      vim.notify("reviewr: " .. label .. " finished; review refreshed", vim.log.levels.INFO)
    end
  end
end

local function watch_agent(cand)
  local rex = require("reviewr.rex")
  if cand.transport ~= "rex" or rex.watching(cand.id) then return end
  rex.watch(cand.meta.session, cand.id, { state = cand.state, label = cand.label, cb = on_agent })
end

M._on_agent = on_agent
M.paired = paired

local function root()
  return git.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
end

function M.setup(opts)
  config_mod.merge(opts)
  if setup_done then return M end
  setup_done = true
  log.info("setup")
  require("reviewr.ui").setup()
  vim.api.nvim_create_user_command("ReviewrOpen", function(o) M.open(o.fargs) end, { nargs = "*" })
  vim.api.nvim_create_user_command("ReviewrScope", function(o)
    M.set_scope(o.fargs[1], { commit = o.fargs[2] })
  end, {
    nargs = "+",
    complete = function() return SCOPES end,
  })
  vim.api.nvim_create_user_command("ReviewrComment", function(o)
    M.add_comment({ body = o.args, start = o.line1, ["end"] = o.line2 })
    require("reviewr.ui").redraw()
  end, { nargs = "+", range = true })
  vim.api.nvim_create_user_command("ReviewrTurn", function() M.mark_turn() end, {})
  vim.api.nvim_create_user_command("ReviewrExport", function(o)
    M.export(o.args ~= "" and o.args or nil, function(ok, res, dest)
      vim.notify("reviewr: " .. (ok and (res .. " exported to " .. tostring(dest)) or tostring(res)),
        ok and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end, {
    nargs = "?",
    complete = function() return { "clipboard", "send", "inbox" } end,
  })
  vim.api.nvim_create_user_command("ReviewrClear", function() M.clear() end, {})
  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function(args)
      local tp = tonumber(args.match)
      if tp then state.remove(tp) end
    end,
  })
  events.emit("Setup", { config = config_mod.get() })
  return M
end

-- ref: a commit-ish, ":" for the index, nil for the working tree. source:
-- where the content lives at ref when it differs from path (a rename's old
-- path). Both sides keep the bytes as git has them, CRs and NULs included.
local function buf_from_ref(repo, ref, path, side, source)
  source = source or path
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  if ref == nil then
    local full = repo .. "/" .. source
    local f = vim.fn.filereadable(full) == 1 and io.open(full, "rb")
    if f then
      lines = git.lines(f:read("*a"))
      f:close()
    end
  else
    lines = git.show((ref == ":" and ":" or (ref .. ":")) .. source, repo) or {}
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.b[buf].reviewr_file = path
  vim.b[buf].reviewr_side = side
  local ft = vim.filetype.match({ filename = path }) or ""
  if ft ~= "" then vim.bo[buf].filetype = ft end
  return buf
end

-- Against the working tree, the diff is against a snapshot of its tracked
-- files, so staged new files count and untracked ones don't. Read
-- NUL-separated, so paths come back unquoted; a rename or copy carries its old
-- path, which the left pane reads. Each file also carries its added and
-- deleted line counts (none for a binary file).
local function changed_files(repo, base_ref, head_ref)
  local range
  if head_ref == ":" then
    range = { "--cached", base_ref }
  elseif head_ref then
    range = { base_ref, head_ref }
  else
    range = { base_ref, git.snapshot(repo) }
  end
  local function diff(format)
    local args = { "diff", format, "-z" }
    vim.list_extend(args, range)
    return vim.split(git.run_sync(args, { cwd = repo }).raw_stdout, "\0", { plain = true })
  end
  local counts, n = {}, 1
  local stats = diff("--numstat")
  while stats[n] and stats[n] ~= "" do
    local added, deleted, path = stats[n]:match("^(%S+)\t(%S+)\t(.*)$")
    if not added then break end
    if path == "" then
      path, n = stats[n + 2], n + 3
    else
      n = n + 1
    end
    if path then counts[path] = { tonumber(added), tonumber(deleted) } end
  end
  local fields = diff("--name-status")
  local files, i = {}, 1
  while fields[i] and fields[i] ~= "" and fields[i + 1] do
    local status = fields[i]:sub(1, 1)
    if status == "R" or status == "C" then
      if not fields[i + 2] then break end
      table.insert(files, { status = status, path = fields[i + 2], old = fields[i + 1] })
      i = i + 3
    else
      table.insert(files, { status = status, path = fields[i + 1] })
      i = i + 2
    end
  end
  for _, f in ipairs(files) do
    local c = counts[f.path] or {}
    f.added, f.deleted = c[1], c[2]
  end
  return files
end

local function default_branch(repo)
  local r = git.run_sync({ "rev-parse", "--abbrev-ref", "origin/HEAD" }, { cwd = repo })
  if r.ok and r.stdout[1] and r.stdout[1] ~= "origin/HEAD" then return r.stdout[1] end
  for _, b in ipairs({ "main", "master" }) do
    if git.rev_parse(b, repo) then return b end
  end
  return nil
end

-- The (base, head) pair a scope compares, and how the bar names it.
local function scope_refs(repo, name, opts)
  opts = opts or {}
  if name == "uncommitted" then return "HEAD", nil end
  if name == "staged" then return "HEAD", ":" end
  if name == "turn" then
    local sha = turn.last_turn_sha(repo, turn_scope())
    if not sha then return nil, nil, "no turn marked yet; run :ReviewrTurn" end
    return sha, nil, nil, "last turn"
  end
  if name == "branch" then
    local base = chosen_base or default_branch(repo)
    if not base then return nil, nil, "no default branch found" end
    local mb = git.run_sync({ "merge-base", base, "HEAD" }, { cwd = repo })
    if not (mb.ok and mb.stdout[1]) then return nil, nil, "no merge base with " .. base end
    return mb.stdout[1], nil, nil, "branch vs " .. base
  end
  if name == "commit" then
    local sha = opts.commit and git.rev_parse(opts.commit .. "^{commit}", repo)
    if not sha then return nil, nil, "no such commit: " .. tostring(opts.commit) end
    local parent = git.rev_parse(sha .. "^", repo) or EMPTY_TREE
    return parent, sha, nil, "commit " .. sha:sub(1, 7)
  end
  return nil, nil, "unknown scope " .. tostring(name)
end

function M.open_file(path)
  local s = state.get()
  if not s or not s.files then return false end
  local ui = require("reviewr.ui")
  local old
  for _, f in ipairs(s.files) do if f.path == path then old = f.old; break end end
  local left = buf_from_ref(s.repo, s.base_ref, path, "left", old)
  local right = buf_from_ref(s.repo, s.head_ref, path, "right")
  vim.b[left].reviewr_at, vim.b[right].reviewr_at = s.left_at, s.right_at
  vim.b[left].reviewr_source = old
  ui.show_file(left, right, path)
  local km = config_mod.get().keymaps
  if km then
    local keymaps = require("reviewr.keymaps")
    keymaps.apply(left, type(km) == "table" and km or nil)
    keymaps.apply(right, type(km) == "table" and km or nil)
  end
  ui.redraw(left)
  ui.redraw(right)
  ui.open_files_panel(s.files)
  return true
end

-- What a pane shows, as comments record it: a commit (or tree) id, the index
-- or the working tree.
local function content_at(repo, ref)
  if ref == nil then return "working tree" end
  if ref == ":" then return "index" end
  return git.rev_parse(ref, repo) or ref
end

-- Loads the session's file list (or takes `files`, already read) and shows
-- `prefer` (or the first file). keep_view: reloading the file in view keeps
-- both panes where they were.
local function load(prefer, files, keep_view)
  local s = state.get()
  s.files = files or changed_files(s.repo, s.base_ref, s.head_ref)
  s.left_at, s.right_at = content_at(s.repo, s.base_ref), content_at(s.repo, s.head_ref)
  if #s.files == 0 then
    vim.notify("reviewr: no changes found", vim.log.levels.INFO)
    return false
  end
  local target = s.files[1].path
  for _, f in ipairs(s.files) do if f.path == prefer then target = prefer; break end end
  local ui = require("reviewr.ui")
  local d = ui.panes()
  local views = {}
  if keep_view and ui.is_open() and d.file == target then
    for _, win in ipairs({ d.left_win, d.right_win }) do
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  local active = vim.api.nvim_get_current_win()
  if not M.open_file(target) then return false end
  -- the active pane last, so cursorbind doesn't drag it after the other
  for _, win in ipairs({ d.left_win, d.right_win, active }) do
    if views[win] and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function() vim.fn.winrestview(views[win]) end)
    end
  end
  return true
end

local function start(repo, base_ref, head_ref, scope_name, label)
  -- the left pane shows the merge base, so a moving base branch adds no noise
  if head_ref and head_ref ~= ":" then
    local mb = git.run_sync({ "merge-base", base_ref, head_ref }, { cwd = repo })
    if mb.ok and mb.stdout[1] then base_ref = mb.stdout[1] end
  end
  local files = changed_files(repo, base_ref, head_ref)
  if #files == 0 then
    vim.notify("reviewr: no changes found", vim.log.levels.INFO)
    return false
  end
  local ui = require("reviewr.ui")
  local cur = vim.api.nvim_buf_get_name(0)
  local prefer = vim.startswith(cur, repo .. "/") and cur:sub(#repo + 2) or ui.panes().file
  if ui.is_open() then ui.focus_tab() else ui.open_tab() end
  scope_mod.set({ repo = repo, name = scope_name, label = label, ref = head_ref or "WORKTREE" })
  local s = state.ensure()
  s.repo, s.base_ref, s.head_ref, s.scope = repo, base_ref, head_ref, scope_mod.get()
  if not load(prefer, files) then return false end
  if not pruned[repo] then
    pruned[repo] = true
    local live
    if require("reviewr.rex").available() then
      local terms = require("reviewr.rex").terminals()
      -- an empty list may mean Rex didn't answer: keep every paired baseline
      if #terms > 0 then
        live = {}
        for _, t in ipairs(terms) do live[t.block_id] = true end
      end
    end
    turn.prune(repo, live)
  end
  local trigger = baseline_trigger()
  if trigger == "open" or (trigger == "agent" and not turn.last_turn_sha(repo, turn_scope())) then
    turn.mark_turn({ repo = repo, scope = turn_scope() })
  end
  if require("reviewr.rex").available() then
    watch_repo = repo
    local transport = require("reviewr.transport")
    local agent = paired()
    if agent then
      local cand = transport.rex_candidate(agent.block)
      if cand then watch_agent(cand) end
    else
      for _, c in ipairs(transport.rex_candidates(repo)) do
        if c.conf > 0.6 then watch_agent(c) end
      end
    end
  end
  events.emit("Opened", { repo = repo, scope = scope_mod.get(), file = ui.panes().file, files = s.files })
  log.info("opened " .. repo .. " (" .. #s.files .. " files)")
  return true
end

function M.open(args)
  if type(args) == "string" then args = vim.split(args, "%s+", { trimempty = true }) end
  if type(args) ~= "table" then args = {} end
  local repo = root()
  local base_ref = args[1] or "HEAD"
  local head_ref = args[2] -- nil => working tree
  if args[1] and not head_ref then
    -- everything on this branch, committed or not, against where it left base
    local mb = git.run_sync({ "merge-base", base_ref, "HEAD" }, { cwd = repo })
    if mb.ok and mb.stdout[1] then base_ref = mb.stdout[1] end
  end
  local scope_name = args[3] or (head_ref and "branch" or "uncommitted")
  return start(repo, base_ref, head_ref, scope_name)
end

-- opts.commit: the commit the commit scope shows.
function M.set_scope(name, opts)
  local repo = (state.get() or {}).repo or root()
  local base_ref, head_ref, err, label = scope_refs(repo, name, opts)
  if err then
    vim.notify("reviewr: " .. err, vim.log.levels.WARN)
    return nil, err
  end
  if not start(repo, base_ref, head_ref, name, label) then return nil end
  events.emit("ScopeChanged", { scope = scope_mod.get() })
  return scope_mod.get()
end

-- Picks one of the last 100 commits on HEAD and reviews just that commit.
function M.pick_commit()
  local repo = (state.get() or {}).repo or root()
  local log = git.run_sync({ "log", "-n", "100", "--format=%h%x09%s" }, { cwd = repo }).stdout or {}
  local items = vim.tbl_filter(function(l) return l ~= "" end, log)
  require("reviewr.ui").pick(items, {
    prompt = "Review commit",
    format_item = function(l) return (l:gsub("\t", "  ")) end,
  }, function(choice)
    if choice then M.set_scope("commit", { commit = choice:match("^(%S+)") }) end
  end)
end

-- Picks the branch the branch scope compares against, then shows it.
function M.pick_base()
  local repo = (state.get() or {}).repo or root()
  local refs = git.run_sync({ "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" },
    { cwd = repo }).stdout or {}
  local current = git.run_sync({ "branch", "--show-current" }, { cwd = repo }).stdout[1]
  local items = vim.tbl_filter(function(r)
    return r ~= "" and r ~= current and not r:match("/HEAD$") and r ~= "origin"
  end, refs)
  require("reviewr.ui").pick(items, { prompt = "Compare the branch against" }, function(choice)
    if not choice then return end
    chosen_base = choice
    M.set_scope("branch")
  end)
end

function M.refresh()
  if not state.get() or not state.get().files then return false end
  return load(require("reviewr.ui").panes().file, nil, true)
end

function M.add_comment(input)
  input = input or {}
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local file = input.file or vim.b.reviewr_file
  if not file then
    local name = vim.api.nvim_buf_get_name(0)
    if vim.startswith(name, repo .. "/") then file = name:sub(#repo + 2) end
  end
  if not file then vim.notify("reviewr: no target file for comment", vim.log.levels.WARN); return nil, "no-file" end
  local startl = input.start or vim.fn.line(".")
  local comment = store.add({
    repo = repo,
    scope = scope.name,
    file = file,
    side = input.side or vim.b.reviewr_side or "right",
    at = input.at or (not input.file and vim.b.reviewr_at) or nil,
    source = input.source or (not input.file and vim.b.reviewr_source) or nil,
    start = startl,
    ["end"] = input["end"] or startl,
    body = input.body or "",
  })
  if baseline_trigger() == "first_comment" and not turn.last_turn_sha(repo, turn_scope()) then
    turn.mark_turn({ repo = repo, scope = turn_scope() })
  end
  events.emit("CommentAdded", { comment = comment })
  return comment
end

function M.list_comments(query)
  return store.list(query or {})
end

function M.mark_turn(opts)
  opts = opts or {}
  opts.scope = opts.scope or turn_scope()
  return turn.mark_turn(opts)
end

local function valid_comment(c)
  if not c or not c.file or c.file == "" then return false, "missing file" end
  if not c.side then return false, "missing side" end
  if type(c.start) ~= "number" or type(c["end"]) ~= "number" then return false, "missing range" end
  if c.start > c["end"] then return false, "invalid range" end
  if (c.body or "") == "" then return false, "empty body" end
  return true
end

function M.delete_comment(id)
  local c = id and store.get(id) or nil
  if not c then return nil, "no-comment" end
  store.remove(id)
  events.emit("CommentDeleted", { comment = c })
  return c
end

function M.edit_comment(id, body)
  local c = id and store.get(id) or nil
  if not c then return nil, "no-comment" end
  if not body or body == "" then return nil, "empty" end
  store.update(id, { body = body, sent = false })
  events.emit("CommentEdited", { comment = c })
  return c
end

function M.jump_comment(dir)
  local here = vim.fn.line(".")
  local ordered = store.shown(vim.b.reviewr_file, vim.b.reviewr_side, vim.b.reviewr_at)
  local target
  if dir > 0 then
    for _, c in ipairs(ordered) do
      if (c.start or 0) > here then target = c; break end
    end
    target = target or ordered[1]
  else
    for i = #ordered, 1, -1 do
      if (ordered[i].start or 0) < here then target = ordered[i]; break end
    end
    target = target or ordered[#ordered]
  end
  if target then vim.fn.cursor(target.start, 1) end
  return target
end

function M.jump_file(dir)
  local s = state.get()
  if not s or not s.files or #s.files == 0 then return nil end
  local cur = require("reviewr.ui").panes().file
  local idx = 1
  for i, f in ipairs(s.files) do if f.path == cur then idx = i; break end end
  local nxt = s.files[((idx - 1 + dir) % #s.files) + 1].path
  M.open_file(nxt)
  return nxt
end

-- The side, and the content it showed: "left, commit 1a2b3c4d5e6f",
-- "right, working tree".
local function where(c)
  if not c.at then return c.side end
  if c.at == "working tree" or c.at == "index" then return c.side .. ", " .. c.at end
  if c.at == EMPTY_TREE then return c.side .. ", empty" end
  return c.side .. ", commit " .. c.at:sub(1, 12)
end

local function envelope(repo, comments)
  local files = {}
  for _, c in ipairs(comments) do
    if not vim.tbl_contains(files, c.file) then table.insert(files, c.file) end
  end
  local lines = {
    "@@REVIEW_BEGIN v1",
    "id: " .. store.gen_id(),
    "source: reviewr.nvim",
    "repo: " .. repo,
  }
  if #files == 1 then table.insert(lines, "file: " .. files[1]) end
  if #comments == 1 then table.insert(lines, "range: " .. comments[1].start .. "-" .. comments[1]["end"]) end
  vim.list_extend(lines, { "created: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"), "format: markdown", "---" })
  for _, c in ipairs(comments) do
    table.insert(lines, string.format("### %s:%d-%d (%s)", c.source or c.file, c.start, c["end"], where(c)))
    table.insert(lines, c.body)
    table.insert(lines, "")
  end
  table.insert(lines, "@@REVIEW_END")
  return table.concat(lines, "\n")
end

-- Exports every comment, or none. Reports ok, the count (or the failure
-- reason) and where the comments went, through cb and, when delivery
-- finishes at once, the return values.
-- opts.pick: choose the agent even when the review is paired with one.
function M.export(target, cb, opts)
  opts = opts or {}
  local result
  local function finish(...)
    result = { ... }
    if cb then cb(...) end
    return ...
  end
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local comments = store.ordered({ repo = repo })
  if #comments == 0 then return finish(false, "no comments to export") end
  for _, c in ipairs(comments) do
    local ok, reason = valid_comment(c)
    if not ok then
      log.error("export aborted: " .. reason .. " (" .. (c.id or "?") .. ")")
      events.emit("ExportFailed", { reason = reason, comment = c })
      return finish(false, reason)
    end
  end
  local text = envelope(repo, comments)
  local function delivered(tname, label, cand)
    if not tname then return finish(false, label) end
    if cand then watch_repo = repo; watch_agent(cand) end
    for _, c in ipairs(comments) do c.sent = true end
    events.emit("Exported", { target = tname, label = label, count = #comments })
    return finish(true, #comments, label)
  end
  local transport = require("reviewr.transport")
  if target == "send" or target == "agent" then
    local agent = not opts.pick and paired() or nil
    local target_cand = agent and transport.rex_candidate(agent.block)
    if agent and not target_cand then
      vim.notify("reviewr: " .. agent.name .. " is no longer running in its terminal; choose an agent",
        vim.log.levels.WARN)
    end
    transport.send(text, { repo = repo, mode = config_mod.get().send_mode, target = target_cand, pick = opts.pick },
      delivered)
  elseif target == "inbox" or target == "filesystem-inbox" then
    transport.send(text, { repo = repo, inbox_only = true }, delivered)
  else
    require("reviewr.clipboard").copy(text)
    delivered("clipboard", "clipboard")
  end
  if result then return unpack(result) end
  return true, #comments, "pending"
end

function M.clear(query)
  store.clear(query or {})
  events.emit("Cleared", { query = query })
  require("reviewr.ui").redraw()
  return true
end

function M.close()
  store.clear()
  require("reviewr.rex").unwatch_all()
  -- a Neovim started only for this review (cmd+r in Rex) has nothing left to show
  if vim.g.reviewr_standalone then return vim.cmd("qall!") end
  require("reviewr.ui").close_diff()
end

return M
