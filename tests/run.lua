-- Headless spec suite: nvim --headless -u NONE -l tests/run.lua
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.env.REX_SESSION, vim.env.TMUX, vim.env.WEZTERM_PANE, vim.env.WEZTERM_UNIX_SOCKET = nil, nil, nil, nil

local reviewr = require("reviewr").setup({ adapters = { "neovim-terminal", "filesystem-inbox" } })
local ui = require("reviewr.ui")
local store = require("reviewr.store")
local transport = require("reviewr.transport")

-- `rex events` is never started: watchers get a stream that stays open until
-- a test ends it through its on_exit.
local streams = {}
local jobstart = vim.fn.jobstart
vim.fn.jobstart = function(cmd, opts)
  if type(cmd) == "table" and cmd[1] == "rex" then
    table.insert(streams, opts)
    return 1000 + #streams
  end
  return jobstart(cmd, opts)
end

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
  local text = vim.fn.getreg('"')
  local feat = vim.trim(git("rev-parse feature")):sub(1, 12)
  assert(text:find("\nfile: g.lua\n", 1, true)
    and text:find("### g.lua:2-2 (right, commit " .. feat .. ")\nwhy uppercase", 1, true), text)
  reviewr.add_comment({ file = "f.txt", side = "left", start = 2, body = "second" })
  reviewr.export("clipboard")
  assert(not vim.fn.getreg('"'):find("\nfile:", 1, true), "file header with two files")
end)

test("export is all-or-none", function()
  local bad = reviewr.add_comment({ file = "f.txt", start = 1, body = "" })
  vim.fn.setreg('"', "untouched")
  local ok, reason = reviewr.export("clipboard")
  eq({ ok, reason }, { false, "empty body" })
  eq(vim.fn.getreg('"'), "untouched")
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

test("the agents option names which programs count; a paired agent always does", function()
  local bin = vim.fn.tempname()
  vim.fn.mkdir(bin, "p")
  sh("ln -s /bin/cat " .. bin .. "/myagent")
  vim.cmd("tabnew | terminal " .. bin .. "/myagent")
  vim.wait(500)
  eq(#transport.detect(repo), 0, "not an agent by default")
  require("reviewr.config").merge({ agents = { "myagent" }, adapters = { "neovim-terminal", "filesystem-inbox" } })
  eq(#transport.detect(repo), 1, "configured")
  require("reviewr.config").merge({ adapters = { "neovim-terminal", "filesystem-inbox" } })
  vim.g.reviewr_agent = { session = "session:t", block = "block:A", name = "myagent" }
  eq(#transport.detect(repo), 1, "paired")
  vim.g.reviewr_agent = nil
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
  local select = ui.pick
  ui.pick = function(items, opts, cb)
    offered = vim.tbl_map(opts.format_item, items)
    for _, c in ipairs(items) do if c.id == chan then return cb(c) end end
  end
  local ok, n, dest = reviewr.export("send")
  ui.pick = select
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
  local terminals, write, focus, select, available = rex.terminals, rex.write, rex.focus, ui.pick, rex.available
  rex.available = function() return true end
  local alive = true
  rex.terminals = function()
    return alive and { { session_id = "session:t", block_id = "block:A", title = "fixing limiter",
      foreground = { argv0 = "codex", cwd = repo } } } or {}
  end
  local wrote, picked
  rex.write = function(_, block) wrote = block; return true end
  rex.focus = function() return true end
  ui.pick = function(items, _, cb) picked = #items; cb(nil) end
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
  rex.terminals, rex.write, rex.focus, ui.pick, rex.available = terminals, write, focus, select, available
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

test("closing a review that Rex launched quits its Neovim", function()
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "vim.opt.rtp:prepend(" .. vim.inspect(plugin) .. ")",
    "vim.g.reviewr_standalone = true",
    "require('reviewr').setup({})",
    "vim.cmd('cd ' .. " .. vim.inspect(repo) .. ")",
    "assert(require('reviewr').set_scope('branch'))",
    "require('reviewr').close()",
    "io.stdout:write('still running')",
    "vim.cmd('qall!')",
  }, script)
  local res = vim.system({ "nvim", "--headless", "-u", "NONE", "-c", "luafile " .. script }, { text = true }):wait(20000)
  eq({ res.code, res.stdout }, { 0, "" })
end)

test("q asks once: Enter closes, Right then Enter or Esc keeps the review", function()
  assert(reviewr.set_scope("branch"))
  local keymaps = require("reviewr.keymaps")
  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end
  reviewr.add_comment({ file = "g.lua", start = 1, body = "unsent" })
  keymaps.quit(); press("<Esc>")
  assert(ui.is_open() and store.count() == 1, "Esc keeps it")
  keymaps.quit(); press("<Right><CR>")
  assert(ui.is_open() and store.count() == 1, "No keeps it")
  keymaps.quit(); press("<CR>")
  assert(not ui.is_open() and store.count() == 0, "Enter closes it")
end)

test("u, b and t switch views; gc reviews one picked commit; gb picks the base branch", function()
  assert(reviewr.set_scope("branch"))
  local d = ui.panes()
  for _, key in ipairs({ "u", "b", "t", "gc", "gb" }) do
    assert(vim.fn.maparg(key, "n", false, true).buffer == 1, key .. " not bound in the diff")
  end
  local select = ui.pick
  local feat = vim.trim(git("log -1 --format=%h feature"))
  ui.pick = function(items, _, cb)
    for _, it in ipairs(items) do if vim.startswith(it, feat) then return cb(it) end end
  end
  reviewr.pick_commit()
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "added.md", "f.txt", "g.lua", "gone.txt" })
  eq(require("reviewr.scope").get().label, "commit " .. feat)
  reviewr.open_file("f.txt")
  eq(lines(ui.panes().left_buf), { "a", "b", "c", "d" }, "left is the commit's parent")
  git("branch -f mid feature")
  git("checkout -q -- .")
  write(repo .. "/g.lua", { "after mid" })
  ui.pick = function(items, _, cb)
    assert(not vim.tbl_contains(items, "feature"), "the current branch is not offered")
    cb("mid")
  end
  reviewr.pick_base()
  eq(require("reviewr.scope").get().label, "branch vs mid")
  eq(vim.tbl_map(function(f) return f.path end, ui.files_panel().files), { "g.lua" })
  ui.pick = select
  git("checkout -q -- g.lua")
  git("branch -D mid")
end)

test("the picker moves with j and arrows, picks with Enter, cancels with Esc", function()
  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end
  local got = "unset"
  ui.pick({ "one", "two", "three" }, { prompt = "Pick" }, function(c) got = c end)
  press("j<Down><Up><CR>")
  eq(got, "two")
  ui.pick({ "one", "two" }, { prompt = "Pick" }, function(c) got = c end)
  press("<Esc>")
  eq(got, nil)
end)

test("refresh keeps both panes where they were", function()
  git("checkout -q -- .")
  write(repo .. "/f.txt", vim.split(string.rep("line\n", 60), "\n", { trimempty = true }))
  assert(reviewr.set_scope("uncommitted"))
  local d = ui.panes()
  vim.api.nvim_set_current_win(d.right_win)
  vim.api.nvim_win_set_cursor(d.right_win, { 40, 0 })
  assert(reviewr.refresh())
  eq(vim.api.nvim_win_get_cursor(ui.panes().right_win)[1], 40)
  eq(vim.api.nvim_get_current_win(), d.right_win, "focus stays")
  git("checkout -q -- .")
end)

test(":wq in the comment box saves the comment and keeps the review", function()
  assert(reviewr.open({ "master" }))
  store.clear()
  reviewr.open_file("g.lua")
  local d = ui.panes()
  vim.api.nvim_set_current_win(d.right_win)
  require("reviewr.keymaps").open_comment_box()
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved with wq" })
  vim.cmd("wq")
  vim.wait(100, function() return store.count() == 1 end)
  assert(ui.is_open(), "both diff panes still open")
  eq(store.count(), 1)
  eq(store.list()[1].body, "saved with wq")
  eq(vim.api.nvim_get_current_win(), d.right_win, "back in the pane commented on")
  require("reviewr.keymaps").open_comment_box()
  vim.cmd("stopinsert")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "dropped" })
  vim.cmd("q!")
  vim.wait(100)
  eq(store.count(), 1, ":q! saves nothing")
  eq(marks(d.right_buf), 1, "only the saved comment's mark is left")
  store.clear()
  ui.redraw()
end)

test("a watched agent is watched again after its event stream ends", function()
  local rex = require("reviewr.rex")
  rex.unwatch_all()
  rex.watch("session:gone", "block:B", { state = "idle", label = "codex", cb = function() end })
  assert(rex.watching("block:B"))
  streams[#streams].on_exit(1001, 1, "exit")
  assert(not rex.watching("block:B"), "forgotten with its stream")
  local before = #streams
  rex.watch("session:gone", "block:B", { state = "idle", label = "codex", cb = function() end })
  eq(#streams, before + 1, "a new stream")
  streams[before].on_exit(1001, 1, "exit")
  assert(rex.watching("block:B"), "a stream stopped earlier does not drop the new one")
  rex.unwatch_all()
end)

test("a pasted review cannot end the bracketed paste early", function()
  local rex = require("reviewr.rex")
  local terminals, rwrite, focus = rex.terminals, rex.write, rex.focus
  local data
  rex.terminals = function()
    return { { session_id = "session:t", block_id = "block:A", foreground = { argv0 = "codex", cwd = repo } } }
  end
  rex.write = function(_, _, d) data = d; return true end
  rex.focus = function() return true end
  vim.env.REX_SESSION = "session:t"
  vim.g.reviewr_agent = { session = "session:t", block = "block:A", name = "codex" }
  require("reviewr.config").merge({ adapters = { "rex" } })
  store.clear()
  reviewr.add_comment({ file = "g.lua", start = 1, body = "a\27[201~b" })
  assert(reviewr.export("send"))
  local _, ends = data:gsub("\27%[201~", "")
  eq(ends, 1)
  assert(vim.endswith(data, "\27[201~"), "the end marker closes the paste")
  rex.terminals, rex.write, rex.focus = terminals, rwrite, focus
  vim.env.REX_SESSION, vim.g.reviewr_agent = nil, nil
  require("reviewr.config").merge({ adapters = { "neovim-terminal", "filesystem-inbox" } })
  store.clear()
end)

test("renames, non-ASCII paths, binary and CRLF files open with their real content", function()
  local other = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(other, "p")
  local function g(args) return sh("git -C " .. vim.fn.shellescape(other) .. " " .. args) end
  g("init -q -b main")
  other = vim.trim(g("rev-parse --show-toplevel"))
  g("config user.email t@t && git -C " .. other .. " config user.name t")
  write(other .. "/old name.txt", { "kept", "lines" })
  write(other .. "/café.txt", { "before" })
  local function raw(path, bytes) local f = assert(io.open(other .. "/" .. path, "wb")); f:write(bytes); f:close() end
  raw("bin.dat", "ab\0cd\nef")
  raw("crlf.txt", "one\r\ntwo\r\n")
  g("add . && git -C " .. other .. " commit -qm init")
  g("mv 'old name.txt' renamed.txt")
  write(other .. "/café.txt", { "after" })
  raw("bin.dat", "zz\0cd\nef")
  g("commit -qam change")
  raw("crlf.txt", "one\r\nTWO\r\n")
  vim.cmd("cd " .. other)
  assert(reviewr.open({ "main~1" }))
  eq(panel_lines(), { "▶ M  bin.dat", "  M  café.txt", "  M  crlf.txt", "  R  renamed.txt" })
  eq(lines(ui.panes().right_buf), { "zz\0cd", "ef" }, "binary")
  reviewr.open_file("café.txt")
  eq({ lines(ui.panes().left_buf), lines(ui.panes().right_buf) }, { { "before" }, { "after" } })
  reviewr.open_file("renamed.txt")
  eq(lines(ui.panes().left_buf), { "kept", "lines" }, "the left pane reads the old path")
  reviewr.open_file("crlf.txt")
  eq({ lines(ui.panes().left_buf), lines(ui.panes().right_buf) }, { { "one\r", "two\r" }, { "one\r", "TWO\r" } })
  vim.cmd("cd " .. repo)
  assert(reviewr.open({ "master" }))
  vim.fn.delete(other, "rf")
end)

test("a comment names the content it was made on and shows only where that content is", function()
  store.clear()
  assert(reviewr.open({ "master" }))
  reviewr.open_file("g.lua")
  local d = ui.panes()
  vim.api.nvim_set_current_win(d.left_win)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("ReviewrComment on the merge base")
  vim.api.nvim_set_current_win(d.right_win)
  vim.cmd("ReviewrComment on the working tree")
  local base = vim.trim(git("merge-base master HEAD"))
  local _, _, _ = reviewr.export("clipboard")
  local text = vim.fn.getreg('"')
  assert(text:find("### g.lua:2-2 (left, commit " .. base:sub(1, 12) .. ")", 1, true), text)
  assert(text:find("### g.lua:1-1 (right, working tree)", 1, true), text)
  eq(git("show " .. base:sub(1, 12) .. ":g.lua"), "one\ntwo\nthree\n", "the named commit resolves")
  write(repo .. "/g.lua", { "one", "two", "edited" })
  git("commit -qam 'move HEAD'")
  assert(reviewr.set_scope("uncommitted") == nil, "nothing uncommitted")
  write(repo .. "/g.lua", { "one", "two", "edited again" })
  assert(reviewr.set_scope("uncommitted"))
  eq({ marks(ui.panes().left_buf), marks(ui.panes().right_buf) }, { 0, 1 }, "the base comment stays with its base")
  eq(panel_lines(), { "▶ M  g.lua  💬 1" })
  git("checkout -q -- . && git -C " .. repo .. " reset -q --hard HEAD~1")
  store.clear()
end)

test("a left comment on a renamed file names the old path", function()
  git("mv g.lua h.lua")
  assert(reviewr.set_scope("uncommitted"))
  eq(panel_lines(), { "▶ R  h.lua" })
  vim.api.nvim_set_current_win(ui.panes().left_win)
  vim.cmd("ReviewrComment old name")
  reviewr.export("clipboard")
  assert(vim.fn.getreg('"'):find("### g.lua:1-1 (left, commit ", 1, true), vim.fn.getreg('"'))
  git("mv h.lua g.lua")
  store.clear()
end)

test("sent comments don't hold up closing; an edited one does again", function()
  assert(reviewr.open({ "master" }))
  local c = reviewr.add_comment({ file = "g.lua", start = 1, body = "will be sent" })
  eq(ui.hint(#store.unsent()), "s  send to agent    y  copy    ?  all keys")
  assert(reviewr.export("clipboard"))
  eq(#store.unsent(), 0)
  reviewr.edit_comment(c.id, "changed after sending")
  eq(#store.unsent(), 1, "edited")
  assert(reviewr.export("clipboard"))
  require("reviewr.keymaps").quit()
  assert(not ui.is_open(), "closed without asking")
  assert(reviewr.open({ "master" }))
end)

test("baselines of closed terminals and removed worktrees are pruned; live ones stay", function()
  local turn = require("reviewr.turn")
  local head = vim.trim(git("rev-parse HEAD"))
  local wt = vim.fn.resolve(vim.fn.tempname())
  git("worktree add -q " .. wt)
  wt = vim.trim(sh("git -C " .. wt .. " rev-parse --show-toplevel"))
  local function ref(r, name) return "refs/reviewr/" .. r:gsub("[^%w%._-]", "_") .. "/" .. name end
  for _, r in ipairs({ ref(repo, "turn"), ref(repo, "turn-block_live"), ref(repo, "turn-block_gone"),
    ref(wt, "turn"), ref("/no/such/worktree", "turn") }) do
    git("update-ref " .. r .. " " .. head)
  end
  turn.prune(repo, { ["block:live"] = true })
  local left = vim.split(vim.trim(git("for-each-ref '--format=%(refname)' refs/reviewr")), "\n")
  for _, r in ipairs({ ref(repo, "turn"), ref(repo, "turn-block_live"), ref(wt, "turn") }) do
    assert(vim.tbl_contains(left, r), r .. " kept")
  end
  for _, r in ipairs({ ref(repo, "turn-block_gone"), ref("/no/such/worktree", "turn") }) do
    assert(not vim.tbl_contains(left, r), r .. " pruned")
  end
  turn.prune(repo, nil)
  assert(git("for-each-ref refs/reviewr"):find("turn-block_live", 1, true), "unknown terminals: paired kept")
  git("worktree remove --force " .. wt)
end)

-- cmd+r, driven through a stand-in for Rex's Lua API.
local function rex_toggle(blocks, foregrounds, focused)
  local calls = {}
  _G.rex = {
    session_id = "session:s",
    block_id = focused,
    call = function(method, params)
      table.insert(calls, { method = method, params = params })
      if method == "session.list_blocks" then return { blocks = blocks } end
      if method == "block.method" then return { foreground = foregrounds[params.block_id] or {} } end
      return {}
    end,
    exec = function(cmd) return cmd[3] .. "\n", "", 0 end,
  }
  local mod = dofile(plugin .. "/rex/reviewr/init.lua")
  mod.toggle({})
  _G.rex = nil
  return vim.tbl_filter(function(c) return c.method ~= "session.list_blocks" and c.method ~= "block.method" end, calls)
end

test("cmd+r in a review hides it", function()
  local calls = rex_toggle({ { block_id = "block:R", label = "review:block:A", placement = "placed" } }, {}, "block:R")
  eq(#calls, 1)
  eq({ calls[1].method, calls[1].params.block_id }, { "session.detach_block", "block:R" })
end)

test("cmd+r in an agent's terminal opens a review paired with it, then hides and shows that one", function()
  local fg = { ["block:A"] = { argv0 = "codex", cwd = "/repo" } }
  local calls = rex_toggle({ { block_id = "block:A", window_id = "w" } }, fg, "block:A")
  eq(calls[1].method, "session.new_split")
  local block = calls[1].params.layout.block
  eq(block.label, "review:block:A")
  eq(block.options.cwd, "/repo")
  local command = table.concat(block.options.command, " ")
  assert(command:find("vim.g.reviewr_standalone = true", 1, true), command)
  assert(command:find('block = "block:A", name = "codex"', 1, true), command)
  calls = rex_toggle({ { block_id = "block:A" }, { block_id = "block:R", label = "review:block:A", placement = "placed" } },
    fg, "block:A")
  eq({ calls[1].method, calls[1].params.block_id }, { "session.detach_block", "block:R" })
  calls = rex_toggle({ { block_id = "block:A" }, { block_id = "block:R", label = "review:block:A", placement = "detached" } },
    fg, "block:A")
  eq(vim.tbl_map(function(c) return c.method end, calls), { "session.move_block", "session.focus_block" })
  eq(calls[1].params.anchor_block_id, "block:A")
end)

test("cmd+r elsewhere keeps one unpaired review per repository per window", function()
  local fg = { ["block:T"] = { argv0 = "fish", cwd = "/repo" }, ["block:U"] = { cwd = "/repo" },
    ["block:V"] = { cwd = "/other" } }
  local calls = rex_toggle({ { block_id = "block:T", window_id = "w" },
    { block_id = "block:U", label = "review", placement = "placed", window_id = "w" } }, fg, "block:T")
  eq({ calls[1].method, calls[1].params.block_id }, { "session.detach_block", "block:U" })
  calls = rex_toggle({ { block_id = "block:T", window_id = "w" },
    { block_id = "block:V", label = "review", placement = "detached" },
    { block_id = "block:U", label = "review", placement = "detached" } }, fg, "block:T")
  eq({ calls[1].method, calls[1].params.block_id }, { "session.move_block", "block:U" })
  calls = rex_toggle({ { block_id = "block:T", window_id = "w" },
    { block_id = "block:V", label = "review", placement = "detached" } }, fg, "block:T")
  eq(calls[1].method, "session.new_split")
  eq(calls[1].params.layout.block.label, "review")
end)

test("the changed-files panel keeps the configured height, however few files there are", function()
  local function rows()
    local win = ui.files_panel().win
    return vim.api.nvim_win_get_height(win) - (vim.wo[win].winbar ~= "" and 1 or 0)
  end
  require("reviewr").close()
  assert(reviewr.open({ "master", "feature" }))
  eq(rows(), 10, "default")
  require("reviewr").close()
  require("reviewr.config").merge({ files_panel_height = 6, adapters = { "neovim-terminal", "filesystem-inbox" } })
  assert(reviewr.open({ "master", "feature" }))
  eq(#ui.files_panel().files, 4)
  eq(rows(), 6, "configured")
  local ok = pcall(require("reviewr.config").merge, { files_panel_height = 0 })
  assert(not ok, "rejects 0")
  require("reviewr.config").merge({ adapters = { "neovim-terminal", "filesystem-inbox" } })
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
