-- reviewr.rex: Rex integration: every terminal in one round trip, focus,
-- input, and the program status agents report while they work.
local M = {}

-- Runs inside Rex (`rex do -`): every terminal's foreground process, title and
-- root status, across all sessions.
local LIST_SCRIPT = [[
local out = {}
local sessions = rex.call("session.list", {})
for _, s in ipairs(sessions.sessions or {}) do
  local blocks = rex.call("session.list_blocks", { session_id = s.session_id })
  for _, b in ipairs(blocks.blocks or {}) do
    local function call(method)
      local ok, res = pcall(rex.call, "block.method",
        { session_id = s.session_id, block_id = b.block_id, method = method })
      return ok and type(res) == "table" and res or {}
    end
    local state
    for _, r in ipairs(call("program_status").records or {}) do
      if r.id == nil or r.id == "" then state = r.state end
    end
    out[#out + 1] = {
      session_id = s.session_id,
      session_label = s.label,
      block_id = b.block_id,
      block_label = b.label,
      window_id = b.window_id,
      foreground = call("process").foreground,
      title = call("title").title,
      state = state,
    }
  end
end
return out
]]

function M.available()
  return vim.env.REX_SESSION ~= nil and vim.env.REX_SESSION ~= "" and vim.fn.executable("rex") == 1
end

local function json(args, input)
  local out = vim.fn.system(args, input)
  if vim.v.shell_error ~= 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, out)
  return ok and decoded or nil
end

function M.terminals()
  local list = json({ "rex", "do", "-" }, LIST_SCRIPT)
  return type(list) == "table" and list or {}
end

function M.write(session_id, block_id, data)
  return json({ "rex", "block", "call", "-s", session_id, "-b", block_id, "write", "-" },
    vim.json.encode({ data = data })) ~= nil
end

function M.focus(session_id, block_id)
  return json({ "rex", "api", "call", "session.focus_block", "-" },
    vim.json.encode({ session_id = session_id, block_id = block_id })) ~= nil
end

-- ---------- program status ----------

local streams = {} -- session_id -> job id
local watched = {} -- block_id -> { session, state, label, cb }

-- One line of `rex events --json`: calls the watcher of a block whose root
-- status record changed state.
function M.handle_event(line)
  local ok, ev = pcall(vim.json.decode, line)
  if not ok or type(ev) ~= "table" then return end
  local inner = ev.payload and ev.payload.event
  local p = inner and inner.type == "block_event" and inner.payload
  if not p or p.name ~= "program_status_changed" then return end
  local status = p.payload or {}
  if (status.id or "") ~= "" then return end
  local w = watched[p.block_id]
  if not w then return end
  local state = (status.record or {}).state or "idle"
  local prev = w.state
  w.state = state
  if state ~= prev then w.cb(state, prev, w.label) end
end

-- Calls cb(state, previous_state, label) whenever the agent in block_id
-- reports a new state.
function M.watch(session_id, block_id, opts)
  watched[block_id] = { session = session_id, state = opts.state, label = opts.label, cb = opts.cb }
  if streams[session_id] then return end
  local partial, job = "", nil
  job = vim.fn.jobstart({ "rex", "events", "-s", session_id, "--json" }, {
    on_stdout = function(_, data)
      data[1] = partial .. data[1]
      partial = data[#data]
      for i = 1, #data - 1 do M.handle_event(data[i]) end
    end,
    -- the stream is gone (Rex restarted, say): forget its blocks, so the next
    -- open or send watches them again
    on_exit = function()
      if streams[session_id] ~= job then return end
      streams[session_id] = nil
      for block, w in pairs(watched) do
        if w.session == session_id then watched[block] = nil end
      end
    end,
  })
  streams[session_id] = job
end

function M.watching(block_id)
  return watched[block_id] ~= nil
end

function M.unwatch_all()
  for _, job in pairs(streams) do pcall(vim.fn.jobstop, job) end
  streams, watched = {}, {}
end

return M
