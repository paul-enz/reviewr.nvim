-- Headless spec suite: nvim --headless -u NONE -l tests/run.lua
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.env.REX_SESSION, vim.env.TMUX, vim.env.WEZTERM_PANE, vim.env.WEZTERM_UNIX_SOCKET = nil, nil, nil, nil

local reviewr = require("reviewr").setup({ adapters = { "neovim-terminal", "filesystem-inbox" } })
local ui = require("reviewr.ui")
local store = require("reviewr.store")
local transport = require("reviewr.transport")

local failures, passed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failures = failures + 1 end
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. tostring(err))) .. "\n")
end
local function eq(a, b, what)
  if not vim.deep_equal(a, b) then
    error((what or "") .. " expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a), 2)
  end
end

local function sh(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, cmd .. "\n" .. out)
  return out
end

local function write(path, lines) vim.fn.writefile(lines, path) end

-- master: f.txt, g.lua, gone.txt; feature (off master~1 + master moved on):
-- f.txt modified, g.lua modified, gone.txt deleted, added.md added.
local repo = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(repo, "p")
local function git(args) return sh("git -C " .. vim.fn.shellescape(repo) .. " " .. args) end
git("init -q -b master")
repo = vim.trim(git("rev-parse --show-toplevel"))
git("config user.email t@t && git -C " .. repo .. " config user.name t")
write(repo .. "/f.txt", { "a", "b", "c", "d" })
write(repo .. "/g.lua", { "one", "two", "three" })
write(repo .. "/gone.txt", { "x", "y" })
git("add . && git -C " .. repo .. " commit -qm init")
git("checkout -qb feature")
write(repo .. "/f.txt", { "a", "B2", "c", "d", "new" })
write(repo .. "/g.lua", { "one", "TWO", "three", "four" })
write(repo .. "/added.md", { "brand", "new" })
git("rm -q gone.txt && git -C " .. repo .. " add . && git -C " .. repo .. " commit -qm feat")
git("checkout -q master")
write(repo .. "/f.txt", { "a", "b", "c", "d", "master-only" })
git("commit -qam 'master moves on'")
git("checkout -q feature")
vim.cmd("cd " .. repo)

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function panel_lines() return lines(ui.files_panel().buf) end
local function marks(buf)
  return #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("reviewr"), 0, -1, {})
end

test("open lists every changed file in a panel under the diff, in its own tab", function()
  local tabs = #vim.api.nvim_list_tabpages()
  assert(reviewr.open({ "master", "feature" }))
  eq(#vim.api.nvim_list_tabpages(), tabs + 1, "tabs")
  eq(panel_lines(), { "▶ A  added.md", "  M  f.txt", "  M  g.lua", "  D  gone.txt" })
  local d = ui.panes()
  assert(vim.wo[d.left_win].diff and vim.wo[d.right_win].diff, "diff windows")
  assert(not vim.wo[ui.files_panel().win].diff, "panel must not join the diff")
end)

test("<CR> in the panel opens that file", function()
  vim.api.nvim_set_current_win(ui.files_panel().win)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  eq(ui.panes().file, "g.lua")
  eq(lines(ui.panes().right_buf), { "one", "TWO", "three", "four" })
end)

test("the base pane shows the merge base, not the moved base branch", function()
  reviewr.open_file("f.txt")
  eq(lines(ui.panes().left_buf), { "a", "b", "c", "d" })
end)

test("deleted and added files open with an empty side", function()
  reviewr.open_file("gone.txt")
  eq(lines(ui.panes().right_buf), { "" })
  reviewr.open_file("added.md")
  eq(lines(ui.panes().left_buf), { "" })
end)

test("review keys are bound in both diff buffers", function()
  for _, b in ipairs({ ui.panes().left_buf, ui.panes().right_buf }) do
    for _, key in ipairs({ "c", "s", "y", "q", "f" }) do
      assert(vim.fn.maparg(key, "n", false, true).buffer == 1, key .. " not bound")
    end
  end
end)

test("a comment stays on its own file and side", function()
  reviewr.open_file("g.lua")
  vim.api.nvim_set_current_win(ui.panes().right_win)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("ReviewrComment why uppercase")
  eq(marks(ui.panes().right_buf), 1, "right pane")
  eq(marks(ui.panes().left_buf), 0, "left pane")
  reviewr.open_file("f.txt")
  eq(marks(ui.panes().right_buf), 0, "other file")
  eq(panel_lines()[3], "  M  g.lua  💬 1")
  reviewr.open_file("g.lua")
  vim.api.nvim_set_current_win(ui.panes().right_win)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  eq(ui.comment_at_cursor().body, "why uppercase")
end)

test("export copies every comment, naming the file only when there is one", function()
  local ok, n, dest = reviewr.export("clipboard")
  eq({ ok, n, dest }, { true, 1, "clipboard" })
  local text = vim.fn.getreg("+")
  assert(text:find("\nfile: g.lua\n", 1, true) and text:find("### g.lua:2-2 (right)\nwhy uppercase", 1, true), text)
  reviewr.add_comment({ file = "f.txt", side = "left", start = 2, body = "second" })
  reviewr.export("clipboard")
  assert(not vim.fn.getreg("+"):find("\nfile:", 1, true), "file header with two files")
end)

test("export is all-or-none", function()
  local bad = reviewr.add_comment({ file = "f.txt", start = 1, body = "" })
  vim.fn.setreg("+", "untouched")
  local ok, reason = reviewr.export("clipboard")
  eq({ ok, reason }, { false, "empty body" })
  eq(vim.fn.getreg("+"), "untouched")
  reviewr.delete_comment(bad.id)
end)

test("inbox export writes a git-ignored file", function()
  local ok, _, path = reviewr.export("inbox")
  assert(ok and vim.fn.filereadable(path) == 1, tostring(path))
  eq(vim.trim(git("status --porcelain")), "")
end)

test("send skips a terminal that is not running an agent", function()
  vim.cmd("tabnew | terminal sleep 30")
  eq(#transport.detect(repo), 0)
  vim.cmd("bwipeout!")
end)

test("send pastes into a terminal running an agent", function()
  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  sh("ln -s /bin/cat " .. bin .. "/codex")
  vim.cmd("tabnew | terminal " .. bin .. "/codex")
  vim.wait(500)
  local cands = transport.detect(repo)
  eq(#cands, 1)
  eq(cands[1].transport, "neovim-terminal")
  vim.cmd("bwipeout!")
end)

test("send asks which agent when there are several", function()
  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  sh("ln -s /bin/cat " .. bin .. "/codex && ln -s /bin/cat " .. bin .. "/aider")
  vim.cmd("tabnew | terminal " .. bin .. "/codex")
  vim.cmd("tabnew | terminal " .. bin .. "/aider")
  local chan = vim.bo.channel
  vim.wait(500)
  store.clear()
  reviewr.add_comment({ file = "f.txt", start = 1, body = "pick me" })
  vim.cmd("tabfirst")
  local offered
  local select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    offered = vim.tbl_map(opts.format_item, items)
    for _, c in ipairs(items) do if c.id == chan then return cb(c) end end
  end
  local ok, n, dest = reviewr.export("send")
  vim.ui.select = select
  eq(#offered, 2)
  eq({ ok, n, dest }, { true, 1, "aider (nvim terminal)" })
  eq(vim.bo.channel, chan, "focus moves to the agent")
  store.clear()
  vim.cmd("bwipeout! | bwipeout!")
end)

test("export with no comments is refused", function()
  store.clear()
  eq({ reviewr.export("clipboard") }, { false, "no comments to export" })
end)

test("staged scope compares HEAD with the index", function()
  write(repo .. "/g.lua", { "staged" })
  git("add g.lua")
  write(repo .. "/g.lua", { "unstaged" })
  assert(reviewr.set_scope("staged"))
  eq(panel_lines(), { "▶ M  g.lua" })
  eq(lines(ui.panes().right_buf), { "staged" })
end)

test("turn scope shows only what changed since the last turn", function()
  git("checkout -q -- g.lua")
  git("reset -q")
  write(repo .. "/f.txt", { "first" })
  reviewr.mark_turn({ repo = repo })
  write(repo .. "/g.lua", { "after turn" })
  assert(reviewr.set_scope("turn"))
  eq(panel_lines(), { "▶ M  g.lua" })
  eq(lines(ui.panes().left_buf), { "staged" })
  eq(vim.trim(git("stash list")), "")
end)

test("branch scope compares the default branch's merge base with HEAD", function()
  git("checkout -q -- . && git -C " .. repo .. " clean -qfd")
  assert(reviewr.set_scope("branch"))
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "added.md", "f.txt", "g.lua", "gone.txt" })
  eq(ui.panes().file, "g.lua", "keeps the file in view")
end)

test("a watched agent's turn sets the baseline when it starts and refreshes the review when it ends", function()
  local rex = require("reviewr.rex")
  require("reviewr.config").merge({ baseline_trigger = "agent", adapters = { "neovim-terminal", "filesystem-inbox" } })
  git("checkout -q -- . && git -C " .. repo .. " clean -qfd")
  write(repo .. "/f.txt", { "before the turn" })
  assert(reviewr.set_scope("uncommitted"))
  local function status(state)
    rex.handle_event(vim.json.encode({ type = "session_event", payload = { event = { type = "block_event", payload = {
      block_id = "block:agent", name = "program_status_changed", payload = { id = "", record = { state = state } },
    } } } }))
  end
  rex.watch("session:none", "block:agent", { state = "idle", label = "claude", cb = reviewr._on_agent })
  status("working")
  write(repo .. "/g.lua", { "written by the agent" })
  status("blocked")
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "f.txt" }, "no refresh while busy")
  status("idle")
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "f.txt", "g.lua" }, "refreshed")
  assert(reviewr.set_scope("turn"))
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "g.lua" }, "turn shows only the agent's edit")
  rex.unwatch_all()
end)

test("copying in Rex also sends OSC 52, so a remote Neovim reaches the local clipboard", function()
  local sent
  package.loaded["vim.ui.clipboard.osc52"] = { copy = function() return function(lines) sent = lines end end }
  vim.env.REX_SESSION = "session:test"
  require("reviewr.clipboard").copy("a\nb")
  vim.env.REX_SESSION = nil
  package.loaded["vim.ui.clipboard.osc52"] = nil
  eq(sent, { "a", "b" })
end)

test("branch scope includes uncommitted edits and staged new files, not untracked ones", function()
  write(repo .. "/g.lua", { "edited, not committed" })
  write(repo .. "/brand-new.lua", { "untracked" })
  write(repo .. "/staged-new.lua", { "added" })
  git("add staged-new.lua")
  assert(reviewr.set_scope("branch"))
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files),
    { "added.md", "f.txt", "g.lua", "gone.txt", "staged-new.lua" })
  reviewr.open_file("g.lua")
  eq(lines(ui.panes().right_buf), { "edited, not committed" })
  eq(lines(ui.panes().left_buf), { "one", "two", "three" }, "left is the merge base")
  eq(vim.trim(git("diff --cached --name-only")), "staged-new.lua", "index untouched")
  git("rm -q --cached staged-new.lua")
  git("checkout -q -- g.lua")
  vim.fn.delete(repo .. "/brand-new.lua")
  vim.fn.delete(repo .. "/staged-new.lua")
end)

test("a review paired with an agent keeps its own turn baseline", function()
  local rex = require("reviewr.rex")
  vim.g.reviewr_agent = { session = "session:t", block = "block:A", name = "codex" }
  local function ref(name) return vim.trim(vim.fn.system({ "git", "-C", repo, "for-each-ref", "--format=%(objectname)",
    "refs/reviewr/" .. repo:gsub("[^%w%._-]", "_") .. "/" .. name })) end
  local shared = ref("turn")
  write(repo .. "/f.txt", { "before A's turn" })
  rex.watch("session:none", "block:A", { state = "idle", label = "codex", cb = reviewr._on_agent })
  rex.handle_event(vim.json.encode({ type = "session_event", payload = { event = { type = "block_event", payload = {
    block_id = "block:A", name = "program_status_changed", payload = { id = "", record = { state = "working" } } } } } }))
  assert(ref("turn-block_A") ~= "", "paired baseline written")
  eq(ref("turn"), shared, "the shared baseline is untouched")
  write(repo .. "/g.lua", { "A's edit" })
  assert(reviewr.set_scope("turn"))
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "g.lua" })
  rex.unwatch_all()
  vim.g.reviewr_agent = nil
end)

test("s sends straight to the paired agent; S and a gone agent fall back to choosing", function()
  local rex = require("reviewr.rex")
  local terminals, write, focus, select = rex.terminals, rex.write, rex.focus, vim.ui.select
  local alive = true
  rex.terminals = function()
    return alive and { { session_id = "session:t", block_id = "block:A", title = "fixing limiter",
      foreground = { argv0 = "codex", cwd = repo } } } or {}
  end
  local wrote, picked
  rex.write = function(_, block) wrote = block; return true end
  rex.focus = function() return true end
  vim.ui.select = function(items, _, cb) picked = #items; cb(nil) end
  vim.env.REX_SESSION = "session:t"
  vim.g.reviewr_agent = { session = "session:t", block = "block:A", name = "codex" }
  require("reviewr.config").merge({ adapters = { "rex", "filesystem-inbox" } })
  store.clear()
  reviewr.add_comment({ file = "g.lua", start = 1, body = "for A" })
  local ok, _, dest = reviewr.export("send")
  eq({ ok, wrote, picked }, { true, "block:A", nil })
  assert(dest:find("codex", 1, true), dest)
  reviewr.export("send", nil, { pick = true })
  assert(picked, "S offers the picker")
  alive, picked = false, nil
  local _, _, gone = reviewr.export("send")
  assert(gone and gone:find(".reviewr/inbox", 1, true), tostring(gone))
  rex.terminals, rex.write, rex.focus, vim.ui.select = terminals, write, focus, select
  vim.env.REX_SESSION = nil
  require("reviewr.config").merge({ adapters = { "neovim-terminal", "filesystem-inbox" } })
  vim.g.reviewr_agent = nil
  store.clear()
end)

test("the diff panes share the width evenly after Neovim is resized", function()
  assert(reviewr.set_scope("branch"))
  local d = ui.panes()
  vim.api.nvim_win_set_width(d.left_win, 10)
  vim.api.nvim_exec_autocmds("VimResized", {})
  local l, r = vim.api.nvim_win_get_width(d.left_win), vim.api.nvim_win_get_width(d.right_win)
  assert(math.abs(l - r) <= 1, l .. " vs " .. r)
end)

test("close drops comments and the review tab, even as the only tab", function()
  vim.cmd("tabonly")
  reviewr.add_comment({ file = "g.lua", start = 1, body = "x" })
  reviewr.close()
  eq(store.count(), 0)
  assert(not ui.is_open())
  eq(#vim.api.nvim_list_tabpages(), 1)
end)

io.stdout:write(string.format("\n%d passed, %d failed\n", passed, failures))
vim.fn.delete(repo, "rf")
os.exit(failures == 0 and 0 or 1)
