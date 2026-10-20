-- reviewr.nvim transport layer: mux-agnostic delivery of review envelopes.
local M = {}
local uv = vim.uv or vim.loop

local AGENTS = { "claude", "codex", "opencode", "aider", "goose", "cline", "pi" }

local function in_path(bin)
  return vim.fn.executable(bin) == 1
end

local function run(cmd, args)
  local out = vim.fn.systemlist(vim.list_extend({ cmd }, args or {}))
  local ok = (vim.v.shell_error == 0)
  return ok, out
end

function M.detect(repo_root)
  local cands = {}
  -- 1. Neovim terminal channels
  for _, ch in ipairs(vim.api.nvim_list_chans()) do
    if ch.mode == "terminal" and ch.pty then
      local bufs = vim.api.nvim_list_bufs()
      for _, b in ipairs(bufs) do
        local ok, job = pcall(vim.api.nvim_buf_get_var, b, "terminal_job_id")
        if ok and job == ch.id then
          local cwd = vim.fn.getcwd(-1, vim.api.nvim_win_get_number(0)) or ""
          if repo_root == nil or (cwd ~= "" and cwd:find(repo_root, 1, true)) then
            table.insert(cands, { id = ch.id, transport = "neovim-terminal", label = "nvim term", conf = 0.9, meta = { buf = b } })
          end
        end
      end
    end
  end
  -- 2. tmux
  if vim.env.TMUX then
    local ok, out = run("tmux", { "list-panes", "-F", "#{pane_id}\t#{pane_current_command}\t#{pane_current_path}" })
    if ok then
      for _, l in ipairs(out) do
        local pid, cmd, path = l:match("([^\t]+)\t([^\t]+)\t([^\t]+)")
        for _, a in ipairs(AGENTS) do
          if cmd and cmd:find(a, 1, true) and path and path:find(repo_root or "", 1, true) then
            table.insert(cands, { id = pid, transport = "tmux", label = a .. " @ " .. pid, conf = 0.85, meta = { cmd = cmd, path = path } })
          end
        end
      end
    end
  end
  -- 3. wezterm
  if vim.env.WEZTERM_UNIX_SOCKET or vim.env.WEZTERM_PANE then
    local ok, out = run("wezterm", { "cli", "list", "--format", "json" })
    if ok then
      -- best effort: trust env pane
      table.insert(cands, { id = vim.env.WEZTERM_PANE, transport = "wezterm", label = "wezterm pane", conf = 0.7, meta = {} })
    end
  end
  -- 4. process-tree fallback (pgrep)
  if in_path("pgrep") then
    local ok, out = run("pgrep", { "-af", "claude|codex|opencode|aider|goose|cline" })
    if ok then
      for _, l in ipairs(out) do
        if l:find(repo_root or "", 1, true) then
          local pid = l:match("^(%d+)")
          table.insert(cands, { id = pid, transport = "process", label = l:sub(1, 60), conf = 0.5, meta = { line = l } })
        end
      end
    end
  end
  table.sort(cands, function(a, b) return a.conf > b.conf end)
  return cands
end

local function bracketed(payload)
  return "\27[200~" .. payload .. "\27[201~"
end

local function adapters()
  return {
    ["neovim-terminal"] = {
      health = function() return true end,
      send = function(cand, payload, mode)
        local bytes = (mode == "submit") and (bracketed(payload) .. "\r") or bracketed(payload)
        vim.api.nvim_chan_send(cand.id, bytes)
        return true
      end,
    },
    ["tmux"] = {
      health = function() return in_path("tmux") end,
      send = function(cand, payload, mode)
        local tmp = vim.fn.tempname()
        vim.fn.writefile(vim.split(payload, "\n", { plain = true }), tmp)
        run("tmux", { "load-buffer", tmp })
        run("tmux", { "paste-buffer", "-t", cand.id })
        if mode == "submit" then run("tmux", { "send-keys", "-t", cand.id, "Enter" }) end
        os.remove(tmp)
        return true
      end,
    },
    ["wezterm"] = {
      health = function() return in_path("wezterm") end,
      send = function(cand, payload, mode)
        local tmp = vim.fn.tempname()
        vim.fn.writefile(vim.split(payload, "\n", { plain = true }), tmp)
        run("wezterm", { "cli", "send-text", "--pane-id", cand.id, "--no-paste", "@" .. tmp })
        os.remove(tmp)
        return true, (mode == "submit")
      end,
    },
    ["filesystem-inbox"] = {
      health = function(repo) return type(repo) == "string" end,
      send = function(_, payload, _, ctx)
        local inbox = (ctx.repo or "") .. "/.reviewr/inbox"
        vim.fn.mkdir(inbox, "p")
        local id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
        local path = inbox .. "/" .. id .. ".md"
        vim.fn.writefile(vim.split(payload, "\n", { plain = true }), path)
        return true, path
      end,
    },
    ["generic-clipboard"] = {
      health = function() return true end,
      send = function(_, payload)
        vim.fn.setreg("+", payload)
        vim.fn.setreg("*", payload)
        return true
      end,
    },
  }
end

function M.send(envelope, opts)
  opts = opts or {}
  local repo = opts.repo
  local mode = opts.mode or "queue"
  local cands = M.detect(repo)
  local A = adapters()
  -- try candidate transports first
  for _, c in ipairs(cands) do
    local ad = A[c.transport]
    if ad and ad.health(repo) then
      local ok, res = pcall(ad.send, c, envelope, mode, { repo = repo })
      if ok then
        return true, c.transport, c.label, res
      end
    end
  end
  -- filesystem inbox
  if A["filesystem-inbox"].health(repo) then
    local ok, res = pcall(A["filesystem-inbox"].send, nil, envelope, mode, { repo = repo })
    if ok then return true, "filesystem-inbox", "inbox", res end
  end
  -- clipboard fallback
  A["generic-clipboard"].send(nil, envelope)
  return true, "clipboard", "clipboard", nil
end

function M.envelope(meta, body)
  local id = tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
  local lines = {
    "@@REVIEW_BEGIN v1",
    "id: " .. id,
    "source: reviewr.nvim",
    "repo: " .. (meta.repo or ""),
    "file: " .. (meta.file or ""),
    "range: " .. (meta.range or ""),
    "created: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
    "format: markdown",
    "---",
  }
  for _, l in ipairs(vim.split(body or "", "\n", { plain = true })) do table.insert(lines, l) end
  table.insert(lines, "@@REVIEW_END")
  return table.concat(lines, "\n"), id
end

return M

