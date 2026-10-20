local config_mod = require("reviewr.config")
local events = require("reviewr.events")
local log = require("reviewr.log")
local store = require("reviewr.store")
local state = require("reviewr.state")
local scope_mod = require("reviewr.scope")
local git = require("reviewr.git")
local turn = require("reviewr.turn")
local anchor = require("reviewr.anchor")

local M = {}
local setup_done = false

local function root()
  return git.git_root(vim.fn.getcwd()) or vim.fn.getcwd()
end

function M.setup(opts)
  config_mod.merge(opts)
  if setup_done then return M end
  setup_done = true
  log.info("setup")
  -- commands
  vim.api.nvim_create_user_command("ReviewrOpen", function(o) M.open(o.fargs) end, { nargs = "*" })
  vim.api.nvim_create_user_command("ReviewrScope", function(o) M.set_scope(o.args) end, { nargs = "?" })
  vim.api.nvim_create_user_command("ReviewrComment", function(o) M.add_comment({ body = o.args }) end, { nargs = "?" })
  vim.api.nvim_create_user_command("ReviewrTurn", function() M.mark_turn() end, {})
  vim.api.nvim_create_user_command("ReviewrExport", function(o) M.export(o.args ~= "" and o.args or nil) end, { nargs = "?" })
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

function M.open(args)
  if type(args) == "string" then args = vim.split(args, "%s+") end
  if type(args) ~= "table" then args = {} end
  local repo = root()
  local base_ref = args[1] or "HEAD"
  local head_ref = args[2] -- nil => working tree
  local scope_name = args[3] or (head_ref and "branch" or "uncommitted")

  -- changed files
  local diff_args = head_ref and { "diff", "--name-only", base_ref .. "..." .. head_ref } or { "diff", "--name-only", base_ref }
  local r = git.run_sync(diff_args, { cwd = repo })
  local out = r.stdout
  local files = vim.tbl_filter(function(s) return s ~= "" end, out or {})
  if #files == 0 then
    vim.notify("reviewr: no changes found", vim.log.levels.INFO)
    return false
  end
  -- pick file
  local target_file = nil
  local cur = vim.api.nvim_buf_get_name(0)
  if cur ~= "" then
    local rel = cur:sub(#repo + 2)
    for _, f in ipairs(files) do if f == rel then target_file = f; break end end
  end
  target_file = target_file or files[1]

  local ui = require("reviewr.ui")
  local function buf_from_ref(ref, path)
    local buf = vim.api.nvim_create_buf(false, true)
    local lines = {}
    if ref == nil then
      -- working tree: read from disk
      local full = repo .. "/" .. path
      lines = vim.fn.readfile(full)
    else
      local content = git.show(ref .. ":" .. path, repo)
      if type(content) == "table" then lines = content
      elseif type(content) == "string" then lines = vim.split(content, "\n", { plain = true }) end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false
    local ft = vim.filetype.match({ filename = path }) or ""
    if ft ~= "" then vim.bo[buf].filetype = ft end
    return buf
  end

  local left = buf_from_ref(base_ref, target_file)
  local right = buf_from_ref(head_ref, target_file)
  ui.open_diff(left, right, { file = target_file, repo = repo })
  require("reviewr.keymaps").apply(left)
  require("reviewr.keymaps").apply(right)
  ui.set_statusline()

  scope_mod.set({ repo = repo, name = scope_name, ref = head_ref or "WORKTREE" })
  state.ensure()
  local trigger = config_mod.get().baseline_trigger
  if trigger == "open" then turn.mark_turn({ repo = repo, scope = scope_mod.get() }) end
  events.emit("Opened", { repo = repo, scope = scope_mod.get(), file = target_file, files = files })
  log.info("opened " .. repo .. " (" .. #files .. " files)")
  return true
end

function M.set_scope(spec)
  if type(spec) == "string" then spec = { name = spec } end
  local s = scope_mod.set(spec or {})
  state.update(nil, { scope = s })
  events.emit("ScopeChanged", { scope = s })
  return s
end

function M.add_comment(input)
  input = input or {}
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local file = input.file
  if not file then
    local name = vim.api.nvim_buf_get_name(0)
    file = name ~= "" and name or nil
  end
  if file and vim.startswith(file, repo .. "/") then file = file:sub(#repo + 2) end
  if not file then vim.notify("reviewr: no target file for comment", vim.log.levels.WARN); return nil, "no-file" end
  local side = input.side or "right"
  local startl = input.start or vim.fn.line(".")
  local endl = input["end"] or startl
  local hunk = input.hunk_lines
  local rec = {
    repo = repo,
    scope = scope.name,
    file = file,
    side = side,
    start = startl,
    ["end"] = endl,
    body = input.body or input[1] or "",
    orphaned = false,
  }
  rec.hunk_hash = anchor.hash_lines(hunk or {})
  local comment = store.add(rec)
  -- optional highlight placement if buffer provided
  if input.bufnr then
    local id = anchor.place(input.bufnr, rec, anchor.namespace())
    comment.extmark_id = id
  end
  if config_mod.get().baseline_trigger == "first_comment" then
    -- mark turn lazily if no baseline yet
    local sha, _ = turn.last_turn_sha(repo, scope)
    if not sha then turn.mark_turn({ repo = repo, scope = scope }) end
  end
  events.emit("CommentAdded", { comment = comment })
  return comment
end

function M.list_comments(query)
  return store.list(query or {})
end

function M.mark_turn(opts)
  return turn.mark_turn(opts or {})
end

local function valid_comment(c)
  if not c or not c.file or c.file == "" then return false, "missing file" end
  if not c.side then return false, "missing side" end
  if type(c.start) ~= "number" or type(c["end"]) ~= "number" then return false, "missing range" end
  if c.start > c["end"] then return false, "invalid range" end
  if c.orphaned then return false, "orphaned" end
  if (c.body or "") == "" then return false, "empty body" end
  return true
end

function M.export(target)
  local scope = scope_mod.get() or {}
  local repo = scope.repo or root()
  local comments = store.list({ repo = repo, scope = scope.name })
  -- all-or-none validation
  for _, c in ipairs(comments) do
    local ok, reason = valid_comment(c)
    if not ok then
      log.error("export aborted: " .. reason .. " (" .. (c.id or "?") .. ")")
      events.emit("ExportFailed", { reason = reason, comment = c })
      return false, reason
    end
  end
  -- build envelope(s) grouped? one file per export batch
  local lines = {
    "@@REVIEW_BEGIN v1",
    "id: " .. store.gen_id(),
    "source: reviewr",
    "repo: " .. repo,
    "file: " .. (comments[1] and comments[1].file or ""),
    "range: " .. (comments[1] and (comments[1].start .. "-" .. comments[1]["end"]) or ""),
    "created: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    "format: markdown",
    "---",
  }
  for _, c in ipairs(comments) do
    table.insert(lines, string.format("### %s:%d-%d (%s)", c.file, c.start, c["end"], c.side))
    table.insert(lines, c.body)
    table.insert(lines, "")
  end
  table.insert(lines, "@@REVIEW_END")
  local envelope = table.concat(lines, "\n")

  local transport = require("reviewr.transport")
  if target == "clipboard" then
    vim.fn.setreg("+", envelope)
    events.emit("Exported", { target = "clipboard", count = #comments })
    return true, #comments
  end
  if target == "send" or target == "agent" then
    local mode = (config_mod.get().send_mode or "queue")
    local ok, tname, label, res = transport.send(envelope, { repo = repo, mode = mode })
    if ok then events.emit("Exported", { target = tname, label = label, count = #comments, res = res }) end
    return ok, (res or #comments)
  end
  if target == "inbox" or target == "filesystem-inbox" then
    local ok, tname, label, res = transport.send(envelope, { repo = repo, mode = "queue" })
    _ = tname; _ = label
    events.emit("Exported", { target = "filesystem-inbox", path = res, count = #comments })
    return ok, res
  end
  -- default clipboard
  vim.fn.setreg("+", envelope)
  events.emit("Exported", { target = "clipboard", count = #comments })
  return true, #comments
end

function M.clear(query)
  store.clear(query or {})
  events.emit("Cleared", { query = query })
  return true
end

return M
