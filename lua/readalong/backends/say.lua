-- macOS `say` backend. `say --interactive` redraws the text for every word it speaks, with the
-- current word in reverse video. It wraps long text at 80 columns and redraws only the current
-- line, so the marker's column is not an offset into the text. Instead the marked word is looked
-- up in the text, searching forward from the previous word since words are spoken in order.
-- One `say` process reads one segment; pausing stops it and resuming starts again at the word.

local config = require("readalong.config")
local text = require("readalong.text")

local M = {}

local REDRAW = "\r\27[M" -- start of each redraw
local MARK = "\27[7m" -- reverse video: the word being spoken
local UNMARK = "\27(B" -- end of reverse video

function M.available()
  return vim.fn.executable("say") == 1
end

local function kill(s)
  local st = s.say
  s.say = nil
  if st and st.proc then pcall(st.proc.kill, st.proc, 15) end
end

local function on_data(s, st, seg, data)
  if s.say ~= st then return end
  st.buf = st.buf .. data
  while true do
    local r = st.buf:find(REDRAW, 1, true)
    if not r then break end
    local rest = st.buf:sub(r + #REDRAW)
    local m = rest:find(MARK, 1, true)
    local u = m and rest:find(UNMARK, m, true)
    local next_redraw = rest:find(REDRAW, 1, true)
    if m and (not next_redraw or m < next_redraw) then
      if not u then break end -- wait for the end of the marked word
      local word = rest:sub(m + #MARK, u - 1)
      local found = word ~= "" and st.input:find(word, st.pos + 1, true)
      if found then
        st.pos = found - 1 + #word
        local idx = text.word_at_offset(s.words, seg, st.base + found - 1)
        if idx ~= s.current then s:word(idx) end
      end
      st.buf = rest
    elseif next_redraw then
      st.buf = rest -- the final redraw has no marker
    else
      break -- wait for the rest of this redraw
    end
  end
end

function M.start(s, idx)
  kill(s)
  local w = s.words[idx]
  local seg = s.segments[w.seg]
  local opts = config.options.say
  local cmd = { "say", "-i", "-r", tostring(math.floor(opts.rate * s.rate)), "-f", "-" }
  if opts.voice then
    vim.list_extend(cmd, { "-v", opts.voice })
  end
  -- input: the text given to say; pos: 0-based offset in input just after the last spoken word
  local st = { buf = "", base = w.offset, input = seg.text:sub(w.offset + 1), pos = 0 }
  s.say = st
  s:word(idx)
  local ok, proc = pcall(vim.system, cmd, {
    stdin = st.input,
    stdout = function(_, data)
      if data then vim.schedule(function() on_data(s, st, seg, data) end) end
    end,
  }, vim.schedule_wrap(function(r)
    if s.say ~= st then return end -- stopped or restarted on purpose
    s.say = nil
    if r.code ~= 0 then
      return s:fail("say exited with code " .. r.code .. ": " .. vim.trim(r.stderr or ""))
    end
    local next_seg = s.segments[w.seg + 1]
    if next_seg then
      M.start(s, next_seg.first)
    else
      s:finished()
    end
  end))
  if not ok then
    s.say = nil
    return s:fail("could not start say: " .. tostring(proc))
  end
  st.proc = proc
end

function M.pause(s)
  kill(s)
end

function M.resume(s)
  M.start(s, s.current)
end

function M.set_rate(s)
  if s.say then M.start(s, s.current) end
end

function M.stop(s)
  kill(s)
end

-- Voice names from `say -v '?'` (lines look like "Samantha    en_US    # Hello!").
function M.voices()
  local r = vim.system({ "say", "-v", "?" }, { text = true }):wait()
  local names = {}
  for line in (r.stdout or ""):gmatch("[^\n]+") do
    local name = line:match("^(.-)%s+%a%a[_-]%w+%s+#")
    if name then names[#names + 1] = name end
  end
  return names
end

return M
