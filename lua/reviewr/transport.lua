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

local function rex_candidates(repo_root)
  local listing = run_json({ "rex", "ls", "--json" })
  if not listing then return {} end
  local cands = {}
  for _, sess in ipairs(listing.sessions or {}) do
    local blocks = run_json({ "rex", "block", "ls", "-s", sess.session_id, "--json" }) or {}
    for _, b in ipairs(blocks.blocks or {}) do
      if b.block_id ~= vim.env.REX_BLOCK then
        local proc = run_json({ "rex", "block", "call", "-s", sess.session_id, "-b", b.block_id, "process", "{}" })
        local fg = proc and proc.foreground or {}
        local name
        for _, n in ipairs({ fg.argv0, fg.name, fg.invoked_path }) do
          if is_agent(basename(n)) then name = basename(n); break end
        end
        if name and in_repo(fg.cwd, repo_root) then
          table.insert(cands, {
            id = b.block_id,
            transport = "rex",
            label = name .. " @ " .. (sess.label or sess.session_id),
            conf = sess.session_id == vim.env.REX_SESSION and 0.88 or 0.86,
            meta = { session = sess.session_id },
          })
        end
      end
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
  if vim.env.REX_SESSION and in_path("rex") then vim.list_extend(cands, rex_candidates(repo_root)) end
  if (vim.env.WEZTERM_UNIX_SOCKET or vim.env.WEZTERM_PANE) and in_path("wezterm") then
    vim.list_extend(cands, wezterm_candidates(repo_root))
  end
  table.sort(cands, function(a, b) return a.conf > b.conf end)
  return cands
end

-- ---------- delivery ----------

local adapters = {
  ["neovim-terminal"] = function(cand, payload, mode)
    vim.api.nvim_chan_send(cand.id, bracketed(payload) .. (mode == "submit" and "\r" or ""))
  end,
  ["tmux"] = function(cand, payload, mode)
    assert(run({ "tmux", "load-buffer", "-b", "reviewr", "-" }, payload), "tmux load-buffer failed")
    assert(run({ "tmux", "paste-buffer", "-p", "-d", "-b", "reviewr", "-t", cand.id }), "tmux paste-buffer failed")
    if mode == "submit" then run({ "tmux", "send-keys", "-t", cand.id, "Enter" }) end
  end,
  ["rex"] = function(cand, payload, mode)
    local function write(data)
      local res = run_json({ "rex", "block", "call", "-s", cand.meta.session, "-b", cand.id, "write", "-" },
        vim.json.encode({ data = data }))
      assert(res, "rex write failed for " .. cand.id)
    end
    write(bracketed(payload))
    if mode == "submit" then write("\r") end
  end,
  ["wezterm"] = function(cand, payload, mode)
    assert(run({ "wezterm", "cli", "send-text", "--pane-id", cand.id }, payload), "wezterm send-text failed")
    if mode == "submit" then run({ "wezterm", "cli", "send-text", "--pane-id", cand.id, "--no-paste" }, "\r") end
  end,
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

-- Delivers the envelope to the best running agent, else the inbox, else the
-- clipboard. Returns the transport used and a human label for it.
function M.send(envelope, opts)
  opts = opts or {}
  local mode = opts.mode or "queue"
  if not opts.inbox_only then
    for _, c in ipairs(M.detect(opts.repo)) do
      if enabled(c.transport) then
        local ok = pcall(adapters[c.transport], c, envelope, mode)
        if ok then return c.transport, c.label end
      end
    end
  end
  if opts.repo and enabled("filesystem-inbox") then
    local ok, path = pcall(M.write_inbox, opts.repo, envelope)
    if ok then return "filesystem-inbox", path end
  end
  vim.fn.setreg("+", envelope)
  return "clipboard", "clipboard"
end

return M
