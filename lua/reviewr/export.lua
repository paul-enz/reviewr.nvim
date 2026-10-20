-- reviewr.export — all-or-none clipboard/send/inbox formatting + envelope
local M = {}

local required = { "file", "start", "body" }

local function validate(comments)
  comments = comments or {}
  if type(comments) ~= "table" then return nil, "comments must be a list" end
  for i, c in ipairs(comments) do
    if type(c) ~= "table" then return nil, "comment " .. i .. " invalid" end
    for _, f in ipairs(required) do
      if c[f] == nil or c[f] == "" then
        if f == "start" and c.line ~= nil then
          c.start = c.line
        else
          return nil, "comment " .. i .. " missing " .. f
        end
      end
    end
    c["end"] = c["end"] or c.start
  end
  return comments
end

function M.build_envelope(comments, meta)
  return {
    format = "reviewr",
    version = 1,
    meta = meta or {},
    comments = comments or {},
  }
end

function M.to_text(comments)
  local lines = { "# reviewr export", "" }
  for i, c in ipairs(comments) do
    lines[#lines + 1] = string.format("## %d. %s:%d-%d", i, c.file, c.start, c["end"] or c.start)
    if c.author then lines[#lines + 1] = "author: " .. c.author end
    if c.status then lines[#lines + 1] = "status: " .. c.status end
    lines[#lines + 1] = ""
    lines[#lines + 1] = tostring(c.body)
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

function M.to_clipboard(comments)
  local ok, text = pcall(M.to_text, comments)
  if not ok then return false, text end
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  return true, text
end

function M.write_inbox(comments, path)
  path = path or (vim.fn.stdpath("data") .. "/reviewr-inbox.md")
  local text = M.to_text(comments)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(text)
  f:close()
  return true, path
end

function M.send(comments, cmd)
  cmd = cmd or "cat"
  local text = M.to_text(comments)
  local job = vim.fn.jobstart(cmd, { stdin = "pipe" })
  if job <= 0 then return false, "failed to start send command" end
  vim.fn.chansend(job, text)
  vim.fn.chanclose(job, "stdin")
  return true
end

-- All-or-none: validate everything up front, then perform all actions; on any
-- failure, report without claiming partial success.
function M.export_all(comments, opts)
  opts = opts or {}
  local vc, err = validate(comments or {})
  if not vc then return false, err end
  comments = vc

  -- all actions collected first as closures
  local actions = {}
  if opts.clipboard ~= false then
    actions[#actions + 1] = function() return M.to_clipboard(comments) end
  end
  if opts.inbox then
    actions[#actions + 1] = function() return M.write_inbox(comments, opts.inbox_path) end
  end
  if opts.send_cmd then
    actions[#actions + 1] = function() return M.send(comments, opts.send_cmd) end
  end
  if #actions == 0 then
    actions[#actions + 1] = function() return M.to_clipboard(comments) end
  end

  -- execute all-or-none: if any fails, stop and report
  local results = {}
  for i, act in ipairs(actions) do
    local ok, r = pcall(act)
    if not ok or r == false then
      return false, "export failed at step " .. i .. ": " .. tostring(r)
    end
    results[i] = r
  end
  return true, M.build_envelope(comments, opts.meta)
end

M.export = M.export_all
M.all_or_none = M.export_all
return M
