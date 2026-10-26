local M = {}

-- Voices offered by the Unreal Speech v8 API (used for :Readalong voice completion).
M.unreal_voices = {
  "Autumn", "Melody", "Hannah", "Emily", "Ivy", "Kaitlyn", "Luna", "Willow", "Lauren", "Sierra",
  "Noah", "Jasper", "Caleb", "Ronan", "Ethan", "Daniel", "Zane",
  "Mei", "Lian", "Ting", "Jing", "Wei", "Jian", "Hao", "Sheng",
  "Lucía", "Mateo", "Javier", "Élodie", "Ananya", "Priya", "Arjun", "Rohan",
  "Giulia", "Luca", "Camila", "Thiago", "Rafael",
}

M.defaults = {
  -- "auto" uses Unreal Speech when an API key and mpv are available, otherwise macOS `say`.
  backend = "auto", -- "auto" | "unreal" | "say"
  -- When an Unreal Speech request fails (offline, out of characters, bad key), continue with `say`.
  fallback_to_say = true,
  -- Move the cursor along with the word being read, so it stays on screen.
  follow_cursor = true,
  -- Skip fenced code blocks in markdown buffers.
  skip_code_blocks = true,
  -- Playback speed multiplier, changed with :Readalong faster / slower.
  playback_rate = 1.0,
  rate_step = 0.1,
  -- Text is split into segments (paragraphs, headings, list items). Long paragraphs are split
  -- at the first sentence end after `soft` characters, or at any word after `hard` characters.
  segment_chars = { soft = 500, hard = 1000 },

  unreal = {
    -- API key as a string or a function returning one. Defaults to $UNREAL_SPEECH_API_KEY.
    api_key = nil,
    api_url = "https://api.v8.unrealspeech.com",
    voice = "Sierra",
    bitrate = "192k",
    speed = 0, -- synthesis speed, -1.0 to 1.0 (changing it re-synthesizes; prefer playback_rate)
    pitch = 1.0, -- 0.5 to 1.5
    -- Characters per /speech request (the API maximum is 3000). Must be >= segment_chars.hard.
    chunk_chars = 2000,
    -- Synthesized audio is cached here, so listening again costs no characters.
    cache_dir = vim.fn.stdpath("cache") .. "/readalong",
    mpv = "mpv",
  },

  say = {
    voice = nil, -- nil uses the system voice; list voices with `say -v '?'`
    rate = 175, -- words per minute at playback_rate 1.0
  },
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
