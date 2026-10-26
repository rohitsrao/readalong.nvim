-- Unreal Speech backend: text is sent in chunks to the /speech endpoint, which returns an MP3
-- plus per-word timestamps. Both are cached on disk, keyed by the text and voice settings,
-- and played with mpv. The chunk after the one playing is synthesized ahead of time.

local config = require("readalong.config")
local Player = require("readalong.player")

local M = {}

-- Characters sent to Unreal Speech during this Neovim session.
M.chars_used = 0

function M.api_key()
  local key = config.options.unreal.api_key
  if type(key) == "function" then key = key() end
  if key == nil or key == "" then key = vim.env.UNREAL_SPEECH_API_KEY end
  if key == nil or key == "" then return nil end
  return key
end

function M.available()
  return M.api_key() ~= nil and vim.fn.executable(config.options.unreal.mpv) == 1
end

-- Group consecutive segments into chunks of at most chunk_chars characters.
-- Chunks always start at segment boundaries counted from the start of the text, so the same
-- file produces the same chunks (and cache hits) wherever reading starts.
local function build_chunks(words, segments)
  local opts = config.options.unreal
  local chunks, of_word = {}, {}
  local cur
  for si, seg in ipairs(segments) do
    if not cur or #cur.text + 1 + #seg.text > opts.chunk_chars then
      cur = { text = "", first = seg.first, last = seg.last, base = {} }
      chunks[#chunks + 1] = cur
    end
    if cur.text ~= "" then cur.text = cur.text .. "\n" end
    cur.base[si] = #cur.text
    cur.text = cur.text .. seg.text
    cur.last = seg.last
    for i = seg.first, seg.last do
      of_word[i] = #chunks
    end
  end
  for _, c in ipairs(chunks) do
    local key = vim.fn.sha256(table.concat(
      { opts.api_url, opts.voice, opts.bitrate, tostring(opts.speed), tostring(opts.pitch), c.text }, "\n"))
    c.mp3 = opts.cache_dir .. "/" .. key .. ".mp3"
    c.json = opts.cache_dir .. "/" .. key .. ".json"
  end
  return chunks, of_word
end

local function cached(c)
  return vim.uv.fs_stat(c.mp3) ~= nil and vim.uv.fs_stat(c.json) ~= nil
end

-- Match the API's word timestamps to our words, in order. Matching is by normalized text, so it
-- tolerates punctuation differences and words the API splits (e.g. "2026-10-21").
local function align(c, words, entries)
  local normalize = require("readalong.text").normalize
  local times = {}
  local j, rem = c.first, nil
  for _, e in ipairs(entries) do
    local start = tonumber(e.start or e.Start)
    local nt = normalize(tostring(e.word or e.Word or e.text or ""))
    if start and nt ~= "" and j <= c.last then
      local found
      for k = j, math.min(j + 6, c.last) do
        if ((k == j and rem) or words[k].norm) == nt then
          found = k
          break
        end
      end
      if not found then
        local nw = rem or words[j].norm
        if vim.startswith(nw, nt) or vim.startswith(nt, nw) then found = j end
      end
      if found then
        times[#times + 1] = { start, found }
        local nw = (found == j and rem) or words[found].norm
        if #nt < #nw and vim.startswith(nw, nt) then
          j, rem = found, nw:sub(#nt + 1)
        else
          j, rem = found + 1, nil
        end
      end
    end
  end
  return times
end

local function load_times(c, words)
  local fd = io.open(c.json, "r")
  if not fd then return "could not read " .. c.json end
  local raw = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return "could not parse timestamps " .. c.json end
  local entries = data.timestamps or data.Timestamps or data
  c.times = align(c, words, entries)
  if #c.times == 0 then return "no word timestamps matched the text" end
end

local function curl(args, stdin, cb)
  local cmd = vim.list_extend({ "curl", "-sS", "--max-time", "120" }, args)
  vim.system(cmd, { stdin = stdin, text = true }, vim.schedule_wrap(cb))
end

local function download(url, dest, cb)
  curl({ "-f", "-o", dest, url }, nil, function(r)
    cb(r.code ~= 0 and ("download failed: " .. vim.trim(r.stderr or "")) or nil)
  end)
end

local function synthesize(c, cb)
  local opts = config.options.unreal
  local key = M.api_key()
  if not key then return cb("no Unreal Speech API key (set $UNREAL_SPEECH_API_KEY)") end
  vim.fn.mkdir(opts.cache_dir, "p")
  local body = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode({
    Text = c.text,
    VoiceId = opts.voice,
    Bitrate = opts.bitrate,
    Speed = opts.speed,
    Pitch = opts.pitch,
    OutputFormat = "uri",
    TimestampType = "word",
  }) }, body)
  -- The key goes through curl's stdin config, so it never shows up in the process list.
  curl({
    "-K", "-",
    "-X", "POST", opts.api_url .. "/speech",
    "-H", "Content-Type: application/json",
    "--data-binary", "@" .. body,
    "-w", "\n%{http_code}",
  }, 'header = "Authorization: Bearer ' .. key .. '"\n', function(r)
    os.remove(body)
    if r.code ~= 0 then return cb("request failed: " .. vim.trim(r.stderr or "")) end
    local out = r.stdout or ""
    local resp, status = out:match("^(.*)\n(%d+)$")
    if status ~= "200" then
      return cb(string.format("Unreal Speech HTTP %s: %s", status or "?", vim.trim(resp or out):sub(1, 200)))
    end
    local ok, data = pcall(vim.json.decode, resp)
    if not ok or type(data) ~= "table" or not data.OutputUri or not data.TimestampsUri then
      return cb("unexpected response: " .. resp:sub(1, 200))
    end
    M.chars_used = M.chars_used + (tonumber(data.RequestCharacters) or #c.text)
    -- Download to .part files and rename, so an interrupted download never looks cached.
    download(data.OutputUri, c.mp3 .. ".part", function(err)
      if err then return cb(err) end
      download(data.TimestampsUri, c.json .. ".part", function(err2)
        if err2 then return cb(err2) end
        os.rename(c.mp3 .. ".part", c.mp3)
        os.rename(c.json .. ".part", c.json)
        cb(nil)
      end)
    end)
  end)
end

-- Make sure chunk c has audio and timestamps, then call cb(err).
local function ensure(s, c, cb)
  if c.times then return cb(nil) end
  if c.waiting then
    table.insert(c.waiting, cb)
    return
  end
  c.waiting = { cb }
  local function finish(err)
    if not err then err = load_times(c, s.words) end
    local waiting = c.waiting
    c.waiting = nil
    for _, f in ipairs(waiting) do f(err) end
  end
  if cached(c) then
    finish(nil)
  else
    s:status("synthesizing " .. #c.text .. " characters…")
    synthesize(c, finish)
  end
end

-- Find the word playing at time t (last timestamp at or before t).
local function word_at_time(times, t)
  local lo, hi, found = 1, #times, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if times[mid][1] <= t then
      found, lo = mid, mid + 1
    else
      hi = mid - 1
    end
  end
  return found and times[found][2]
end

local function time_of_word(times, idx)
  for _, t in ipairs(times) do
    if t[2] >= idx then return math.max(0, t[1] - 0.05) end
  end
  return 0
end

local function state(s)
  if s.unreal then return s.unreal end
  local st = {}
  st.chunks, st.of_word = build_chunks(s.words, s.segments)
  st.player = Player.new({
    cmd = config.options.unreal.mpv,
    speed = s.rate,
    on_time = function(t)
      local c = st.chunks[st.playing]
      local idx = c and c.times and word_at_time(c.times, t)
      if idx and idx ~= s.current then s:word(idx) end
    end,
    on_eof = function()
      local next_chunk = st.chunks[(st.playing or 0) + 1]
      if next_chunk then
        M.start(s, next_chunk.first)
      else
        s:finished()
      end
    end,
    on_error = function(msg) s:fail(msg) end,
  })
  s.unreal = st
  return st
end

function M.start(s, idx)
  local st = state(s)
  local ci = st.of_word[idx]
  local c = st.chunks[ci]
  st.want = ci
  s:word(idx)
  ensure(s, c, function(err)
    if s.stopped or st.want ~= ci then return end
    if err then return s:fail(err) end
    st.playing = ci
    st.player:load(c.mp3, time_of_word(c.times, idx))
    s:status("")
    local after = st.chunks[ci + 1]
    if after then
      ensure(s, after, function() end) -- errors surface when that chunk is played
    end
  end)
end

function M.pause(s)
  if s.unreal then s.unreal.player:pause(true) end
end

function M.resume(s)
  if s.unreal then s.unreal.player:pause(false) end
end

function M.set_rate(s)
  if s.unreal then s.unreal.player:speed(s.rate) end
end

function M.stop(s)
  if s.unreal then
    s.unreal.player:quit()
    s.unreal = nil
  end
end

-- Characters that reading these words would send to Unreal Speech, and how many are cached.
function M.estimate(words, segments)
  local chunks = build_chunks(words, segments)
  local total, uncached = 0, 0
  for _, c in ipairs(chunks) do
    total = total + #c.text
    if not cached(c) then uncached = uncached + #c.text end
  end
  return total, uncached
end

return M
