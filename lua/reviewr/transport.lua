-- reviewr.nvim transport layer: mux-agnostic delivery of review envelopes.
local config = require("reviewr.config")

local M = {}

M.AGENTS = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" }

local function in_path(bin)
  return vim.fn.executable(bin) == 1
end

local function run(args, input)
  local out = vim.fn.system(args, input)
  return vim.v.shell_error == 0, out
end

local function run_json(args, input)
  local ok, out = run(args, input)
  if not ok then return nil end
  local decoded_ok, decoded = pcall(vim.json.decode, out)
  return decoded_ok and decoded or nil
end

local function basename(s)
  return type(s) == "string" and vim.fn.fnamemodify(s, ":t") or nil
end

local function is_agent(name)
  return name ~= nil and vim.tbl_contains(M.AGENTS, name)
end

-- The agent named by a command line: its program, or the script an
-- interpreter runs (`node /path/to/claude`).
local function agent_in_args(args)
  local words = vim.split(vim.trim(args or ""), "%s+")
  for i = 1, math.min(2, #words) do
    local name = basename(words[i])
    if is_agent(name) then return name end
  end
  return nil
end

-- The first known agent among the processes attached to a terminal device.
function M.agent_on_tty(tty)
  if type(tty) ~= "string" or tty == "" then return nil end
  local ok, out = run({ "ps", "-t", (tty:gsub("^/dev/", "")), "-o", "args=" })
  if not ok then return nil end
  for _, line in ipairs(vim.split(out, "\n", { plain = true })) do
    local name = agent_in_args(line)
    if name then return name end
  end
  return nil
end

local function in_repo(path, repo_root)
  if repo_root == nil then return true end
  return type(path) == "string" and (path == repo_root or vim.startswith(path, repo_root .. "/"))
end

local function bracketed(payload)
  return "\27[200~" .. payload .. "\27[201~"
end

-- ---------- detection ----------

local function nvim_terminal_candidates()
  local cands = {}
  for _, ch in ipairs(vim.api.nvim_list_chans()) do
    if ch.mode == "terminal" and ch.pty then
      local name = M.agent_on_tty(ch.pty)
      if name then
        table.insert(cands, { id = ch.id, transport = "neovim-terminal", label = name .. " (nvim terminal)", conf = 0.9 })
      end
    end
  end
  return cands
end

local function tmux_candidates(repo_root)
  local ok, out = run({ "tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_tty}\t#{pane_current_path}" })
  if not ok then return {} end
  local cands = {}
  for _, l in ipairs(vim.split(out, "\n", { trimempty = true })) do
    local pane, tty, path = l:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if pane and pane ~= vim.env.TMUX_PANE and in_repo(path, repo_root) then
      local name = M.agent_on_tty(tty)
      if name then
        table.insert(cands, { id = pane, transport = "tmux", label = name .. " @ tmux " .. pane, conf = 0.85 })
      end
    end
  end
  return cands
end

-- Every agent in Neovim's own Rex session, wherever it works, and agents in
-- other sessions that work in the repo.
function M.rex_candidates(repo_root)
  local cands = {}
  for _, t in ipairs(require("reviewr.rex").terminals()) do
    local fg = t.foreground or {}
    local name
    for _, n in ipairs({ fg.argv0, fg.name, fg.invoked_path }) do
      if is_agent(basename(n)) then name = basename(n); break end
    end
    local own = t.session_id == vim.env.REX_SESSION
    local here = in_repo(fg.cwd, repo_root)
    if name and t.block_id ~= vim.env.REX_BLOCK and (own or here) then
      local title = (t.title and t.title ~= "") and t.title or t.block_label or t.block_id
      table.insert(cands, {
        id = t.block_id,
        transport = "rex",
        label = string.format("%s — %s (%s)", name, title, t.session_label or t.session_id),
        conf = here and (own and 0.88 or 0.86) or 0.6,
        state = t.state,
        meta = { session = t.session_id },
      })
    end
  end
  return cands
end

local function wezterm_candidates(repo_root)
  local panes = run_json({ "wezterm", "cli", "list", "--format", "json" })
  if type(panes) ~= "table" then return {} end
  local cands = {}
  for _, p in ipairs(panes) do
    local id = tostring(p.pane_id)
    local cwd = type(p.cwd) == "string" and p.cwd:gsub("^file://[^/]*", "") or nil
    if id ~= vim.env.WEZTERM_PANE and in_repo(cwd, repo_root) then
      local name = M.agent_on_tty(p.tty_name)
      if name then
        table.insert(cands, { id = id, transport = "wezterm", label = name .. " @ wezterm " .. id, conf = 0.7 })
      end
    end
  end
  return cands
end

function M.detect(repo_root)
  local cands = {}
  vim.list_extend(cands, nvim_terminal_candidates())
  if vim.env.TMUX and in_path("tmux") then vim.list_extend(cands, tmux_candidates(repo_root)) end
  if require("reviewr.rex").available() then vim.list_extend(cands, M.rex_candidates(repo_root)) end
  if (vim.env.WEZTERM_UNIX_SOCKET or vim.env.WEZTERM_PANE) and in_path("wezterm") then
    vim.list_extend(cands, wezterm_candidates(repo_root))
  end
  table.sort(cands, function(a, b) return a.conf > b.conf end)
  return cands
end

-- ---------- delivery ----------

-- Each transport pastes the envelope, and can bring its terminal forward.
local adapters = {
  ["neovim-terminal"] = {
    send = function(cand, payload, mode)
      vim.api.nvim_chan_send(cand.id, bracketed(payload) .. (mode == "submit" and "\r" or ""))
    end,
    focus = function(cand)
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(win)].channel == cand.id then
          vim.api.nvim_set_current_win(win)
          return
        end
      end
    end,
  },
  ["tmux"] = {
    send = function(cand, payload, mode)
      assert(run({ "tmux", "load-buffer", "-b", "reviewr", "-" }, payload), "tmux load-buffer failed")
      assert(run({ "tmux", "paste-buffer", "-p", "-d", "-b", "reviewr", "-t", cand.id }), "tmux paste-buffer failed")
      if mode == "submit" then run({ "tmux", "send-keys", "-t", cand.id, "Enter" }) end
    end,
    focus = function(cand)
      run({ "tmux", "select-window", "-t", cand.id })
      run({ "tmux", "select-pane", "-t", cand.id })
    end,
  },
  ["rex"] = {
    send = function(cand, payload, mode)
      local rex = require("reviewr.rex")
      assert(rex.write(cand.meta.session, cand.id, bracketed(payload)), "rex write failed for " .. cand.id)
      if mode == "submit" then rex.write(cand.meta.session, cand.id, "\r") end
    end,
    focus = function(cand)
      require("reviewr.rex").focus(cand.meta.session, cand.id)
    end,
  },
  ["wezterm"] = {
    send = function(cand, payload, mode)
      assert(run({ "wezterm", "cli", "send-text", "--pane-id", cand.id }, payload), "wezterm send-text failed")
      if mode == "submit" then run({ "wezterm", "cli", "send-text", "--pane-id", cand.id, "--no-paste" }, "\r") end
    end,
    focus = function(cand)
      run({ "wezterm", "cli", "activate-pane", "--pane-id", cand.id })
    end,
  },
}

local function enabled(name)
  return vim.tbl_contains(config.get().adapters or {}, name)
end

function M.write_inbox(repo, payload)
  local dir = repo .. "/.reviewr"
  local inbox = dir .. "/inbox"
  vim.fn.mkdir(inbox, "p")
  if vim.fn.filereadable(dir .. "/.gitignore") == 0 then vim.fn.writefile({ "*" }, dir .. "/.gitignore") end
  local path = string.format("%s/%s-%d.md", inbox, os.date("!%Y%m%dT%H%M%S"), math.random(1000, 9999))
  vim.fn.writefile(vim.split(payload, "\n", { plain = true }), path)
  return path
end

-- Delivers the envelope to the running agent, asking which one when there
-- are several (most likely first); else the inbox, else the clipboard. Calls
-- cb(transport, label, candidate), or cb(nil, "cancelled") when the choice is
-- dismissed.
function M.send(envelope, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  local function fallback()
    if opts.repo and enabled("filesystem-inbox") then
      local ok, path = pcall(M.write_inbox, opts.repo, envelope)
      if ok then return cb("filesystem-inbox", path) end
    end
    require("reviewr.clipboard").copy(envelope)
    return cb("clipboard", "clipboard")
  end
  if opts.inbox_only then return fallback() end
  local cands = vim.tbl_filter(function(c) return enabled(c.transport) end, M.detect(opts.repo))
  if #cands == 0 then return fallback() end
  local function deliver(c)
    local adapter = adapters[c.transport]
    if not pcall(adapter.send, c, envelope, opts.mode or "queue") then return fallback() end
    if config.get().focus_agent then pcall(adapter.focus, c) end
    return cb(c.transport, c.label, c)
  end
  if #cands == 1 then return deliver(cands[1]) end
  vim.ui.select(cands, { prompt = "Send review to", format_item = function(c) return c.label end }, function(c)
    if c then deliver(c) else cb(nil, "cancelled") end
  end)
end

return M
