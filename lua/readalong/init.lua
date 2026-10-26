local config = require("readalong.config")
local text = require("readalong.text")
local hl = require("readalong.highlight")

local M = {}

local session -- the reading in progress, if any
local did_setup = false

local function notify(msg, level)
  vim.notify("readalong: " .. msg, level or vim.log.levels.INFO)
end

local function backend(name)
  return require("readalong.backends." .. name)
end

local function resolve_backend()
  local b = config.options.backend
  if b == "auto" then
    return backend("unreal").available() and "unreal" or "say"
  end
  return b
end

local function init(opts)
  config.set(opts)
  did_setup = true
  hl.define_groups()
  local group = vim.api.nvim_create_augroup("readalong", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = hl.define_groups })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() M.stop() end })
end

local function set_keymaps(keys)
  if not keys then return end
  local maps = {
    { "n", keys.toggle, M.toggle, "play / pause" },
    { "n", keys.stop, M.stop, "stop" },
    { "n", keys.next, M.next, "next paragraph" },
    { "n", keys.prev, M.prev, "previous paragraph" },
    { "n", keys.faster, M.faster, "faster" },
    { "n", keys.slower, M.slower, "slower" },
    { "x", keys.play_selection, ":Readalong play<CR>", "read selection" },
  }
  for _, m in ipairs(maps) do
    if m[2] then
      vim.keymap.set(m[1], m[2], m[3], { silent = true, desc = "Readalong: " .. m[4] })
    end
  end
end

--- Configure the plugin and set its keymaps (see |readalong-config|). Calling it is optional:
--- without it the :Readalong command works with the defaults, but no keymaps are set.
function M.setup(opts)
  init(opts)
  set_keymaps(config.options.keymaps)
end

local function ensure_setup()
  if not did_setup then init() end
end

local Session = {}
Session.__index = Session

function Session:word(idx)
  if session ~= self then return end
  self.current = idx
  hl.show(self.buf, self.words[idx], self.win, config.options.follow_cursor)
end

function Session:finished()
  if session ~= self then return end
  M.stop()
  notify("finished")
end

function Session:status(msg)
  if session ~= self then return end
  vim.api.nvim_echo({ { msg ~= "" and ("readalong: " .. msg) or "" } }, false, {})
end

function Session:fail(msg)
  if session ~= self then return end
  local say = backend("say")
  if self.name == "unreal" and config.options.fallback_to_say and say.available() then
    notify(msg .. " (falling back to macOS say)", vim.log.levels.WARN)
    self.backend.stop(self)
    self.name, self.backend = "say", say
    self.paused = false
    say.start(self, self.current or 1)
  else
    notify(msg, vim.log.levels.ERROR)
    M.stop()
  end
end

local function start_session(buf, win, words, segments, idx)
  local name = resolve_backend()
  local b = backend(name)
  if not b.available() then
    if name == "unreal" then
      notify("Unreal Speech needs $UNREAL_SPEECH_API_KEY and mpv (see :checkhealth readalong)", vim.log.levels.ERROR)
    else
      notify("macOS `say` is not available; configure Unreal Speech (see :checkhealth readalong)", vim.log.levels.ERROR)
    end
    return
  end
  hl.anchor(buf, words)
  session = setmetatable({
    buf = buf, win = win, words = words, segments = segments,
    name = name, backend = b, current = idx, paused = false,
    rate = config.options.playback_rate,
  }, Session)
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buf,
    once = true,
    callback = function() M.stop() end,
  })
  b.start(session, idx)
end

local function extract(buf, first, last)
  local ft = vim.bo[buf].filetype
  local o = config.options
  return text.extract(vim.api.nvim_buf_get_lines(buf, first, last, false), first, {
    markdown = ft == "markdown" or ft == "md" or ft:find("markdown") ~= nil,
    skip_code_blocks = o.skip_code_blocks,
    soft = o.segment_chars.soft,
    hard = o.segment_chars.hard,
  })
end

--- Start reading. With a range ({ line1, line2 }, 1-based) reads those lines, otherwise reads
--- the buffer from the word under the cursor.
function M.play(range)
  ensure_setup()
  M.stop()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local words, segments, idx
  if range then
    words, segments = extract(buf, range[1] - 1, range[2])
    idx = 1
  else
    words, segments = extract(buf, 0, -1)
    local cur = vim.api.nvim_win_get_cursor(win)
    idx = text.word_at(words, cur[1] - 1, cur[2]) or 1
  end
  if #words == 0 then
    return notify("nothing to read", vim.log.levels.WARN)
  end
  start_session(buf, win, words, segments, idx)
end

function M.pause()
  if session and not session.paused then
    session.paused = true
    session.backend.pause(session)
  end
end

function M.resume()
  if session and session.paused then
    session.paused = false
    session.backend.resume(session)
  end
end

--- Pause or resume; starts reading from the cursor when nothing is playing.
function M.toggle()
  if not session then
    M.play()
  elseif session.paused then
    M.resume()
  else
    M.pause()
  end
end

function M.stop()
  local s = session
  if not s then return end
  session = nil
  s.stopped = true
  s.backend.stop(s)
  hl.clear(s.buf)
end

local function jump(idx)
  local s = session
  if not s then return end
  s.paused = false
  s.backend.start(s, idx)
end

--- Skip to the next segment (paragraph, heading or list item).
function M.next()
  local s = session
  if not s then return end
  local seg = s.segments[s.words[s.current].seg + 1]
  if seg then jump(seg.first) end
end

--- Back to the start of this segment, or the previous one when already near its start.
function M.prev()
  local s = session
  if not s then return end
  local si = s.words[s.current].seg
  local seg = s.segments[si]
  if s.current - seg.first < 3 and si > 1 then
    seg = s.segments[si - 1]
  end
  jump(seg.first)
end

local function change_rate(delta)
  ensure_setup()
  local o = config.options
  local rate = math.floor((o.playback_rate + delta) * 100 + 0.5) / 100
  o.playback_rate = math.min(3, math.max(0.5, rate))
  if session then
    session.rate = o.playback_rate
    if not session.paused then session.backend.set_rate(session) end
  end
  notify(string.format("speed %.1fx", o.playback_rate))
end

function M.faster() change_rate(config.options.rate_step) end
function M.slower() change_rate(-config.options.rate_step) end

-- Restart the current reading with new settings, keeping the position.
local function restart()
  local s = session
  if not s then return end
  local buf, win, words, segments, idx = s.buf, s.win, s.words, s.segments, s.current
  M.stop()
  if vim.api.nvim_buf_is_valid(buf) then
    start_session(buf, win, words, segments, idx)
  end
end

function M.set_backend(name)
  ensure_setup()
  if not vim.tbl_contains({ "auto", "unreal", "say" }, name) then
    return notify("backend must be auto, unreal or say", vim.log.levels.ERROR)
  end
  config.options.backend = name
  notify("backend " .. name .. (name == "auto" and (" (" .. resolve_backend() .. ")") or ""))
  restart()
end

function M.set_voice(voice)
  ensure_setup()
  local name = session and session.name or resolve_backend()
  config.options[name].voice = voice
  notify(name .. " voice " .. voice)
  restart()
end

--- Show how many characters reading the current buffer would send to Unreal Speech.
function M.estimate()
  ensure_setup()
  local words, segments = extract(vim.api.nvim_get_current_buf(), 0, -1)
  local unreal = backend("unreal")
  local total, uncached = unreal.estimate(words, segments)
  notify(string.format("%d characters in this buffer, %d not cached yet (%d sent this session)",
    total, uncached, unreal.chars_used))
end

--- Short text for a statusline, e.g. "▶ unreal 1.2x"; empty when nothing is playing.
function M.status()
  if not session then return "" end
  return string.format("%s %s %.1fx", session.paused and "⏸" or "▶", session.name, session.rate)
end

M.subcommands = {
  play = function(o) M.play(o.range > 0 and { o.line1, o.line2 } or nil) end,
  toggle = M.toggle,
  pause = M.pause,
  resume = M.resume,
  stop = M.stop,
  next = M.next,
  prev = M.prev,
  faster = M.faster,
  slower = M.slower,
  estimate = M.estimate,
  backend = function(_, arg) M.set_backend(arg) end,
  voice = function(_, arg) M.set_voice(arg) end,
}

function M.command(o)
  local sub, arg = o.fargs[1], table.concat(vim.list_slice(o.fargs, 2), " ")
  if not sub then
    if o.range > 0 then return M.play({ o.line1, o.line2 }) end
    return M.toggle()
  end
  local f = M.subcommands[sub]
  if not f then
    return notify("unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
  if (sub == "backend" or sub == "voice") and arg == "" then
    return notify(sub .. " needs a value", vim.log.levels.ERROR)
  end
  f(o, arg)
end

function M.complete(arglead, cmdline)
  local args = vim.split(cmdline, "%s+", { trimempty = true })
  local completing = #args - (arglead == "" and 0 or 1) -- index of the argument being typed
  local items
  if completing <= 1 then
    items = vim.tbl_keys(M.subcommands)
    table.sort(items)
  elseif args[2] == "backend" then
    items = { "auto", "unreal", "say" }
  elseif args[2] == "voice" then
    ensure_setup()
    local name = session and session.name or resolve_backend()
    items = name == "unreal" and config.unreal_voices or backend("say").voices()
  else
    return {}
  end
  return vim.tbl_filter(function(i) return vim.startswith(i:lower(), arglead:lower()) end, items)
end

return M
