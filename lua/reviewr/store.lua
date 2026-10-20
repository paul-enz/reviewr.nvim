local M = {}
local comments = {}
local counter = 0

local function matches(c, q)
  q = q or {}
  for k, v in pairs(q) do
    if c[k] ~= v then return false end
  end
  return true
end

function M.gen_id()
  counter = counter + 1
  return string.format("%d-%d", os.time(), counter)
end

function M.add(comment)
  comment = comment or {}
  if not comment.id then comment.id = M.gen_id() end
  if not comment.created then comment.created = os.date("!%Y-%m-%dT%H:%M:%SZ") end
  comments[comment.id] = comment
  return comment
end

function M.get(id)
  return comments[id]
end

function M.list(query)
  local out = {}
  for _, c in pairs(comments) do
    if matches(c, query) then table.insert(out, c) end
  end
  table.sort(out, function(a,b) return (a.created or "") < (b.created or "") end)
  return out
end

function M.update(id, patch)
  local c = comments[id]
  if not c then return nil end
  for k, v in pairs(patch or {}) do c[k] = v end
  return c
end

function M.remove(id)
  local c = comments[id]
  comments[id] = nil
  return c
end

function M.clear(query)
  if not query or vim.tbl_isempty(query) then
    comments = {}
    return
  end
  for id, c in pairs(comments) do
    if matches(c, query) then comments[id] = nil end
  end
end

function M.all() return comments end
function M.count(query) return #M.list(query) end

return M
