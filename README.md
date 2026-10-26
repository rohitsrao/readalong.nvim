# readalong.nvim

Read a buffer aloud in Neovim and highlight each word as it is spoken.

- **[Unreal Speech](https://unrealspeech.com)** voices, with word timings from the API
- **macOS `say`** as a free, offline fallback, also with word highlighting
- Markdown aware: headings, lists, links and emphasis are read as text, syntax and code blocks are skipped
- Synthesized audio is cached, so listening to the same text again costs no characters
- Pause, skip paragraphs, change speed, and start from the word under the cursor

## Requirements

- Neovim 0.10+
- For Unreal Speech: an API key, [`mpv`](https://mpv.io) and `curl`
- For the fallback: macOS (`say` ships with it)

## Installation

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/rohitsrao/readalong.nvim" })
require("readalong").setup()
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "rohitsrao/readalong.nvim", opts = {} }
```

Calling `setup()` is optional; the `:Readalong` command works with the defaults.

Put your Unreal Speech API key in your shell profile (the plugin never writes it to disk):

```sh
export UNREAL_SPEECH_API_KEY="your-key"
```

Run `:checkhealth readalong` to check everything is found.

## Usage

| Command | Action |
|---|---|
| `:Readalong` | Start reading from the cursor, or pause / resume |
| `:'<,'>Readalong` | Read the selected lines |
| `:Readalong play` | Start (again) from the cursor |
| `:Readalong pause` / `resume` / `toggle` / `stop` | Control playback |
| `:Readalong next` / `prev` | Skip to the next / previous paragraph |
| `:Readalong faster` / `slower` | Change speed (no new synthesis needed) |
| `:Readalong voice <name>` | Change voice for the active backend |
| `:Readalong backend auto\|unreal\|say` | Switch backend |
| `:Readalong estimate` | Characters this buffer would send to Unreal Speech, and how many are already cached |

The plugin sets no keymaps. For example:

```lua
local ra = require("readalong")
vim.keymap.set("n", "<leader>tp", ra.toggle, { desc = "Readalong: play / pause" })
vim.keymap.set("n", "<leader>ts", ra.stop, { desc = "Readalong: stop" })
vim.keymap.set("n", "<leader>tn", ra.next, { desc = "Readalong: next paragraph" })
vim.keymap.set("n", "<leader>tb", ra.prev, { desc = "Readalong: previous paragraph" })
vim.keymap.set("n", "<leader>t=", ra.faster, { desc = "Readalong: faster" })
vim.keymap.set("n", "<leader>t-", ra.slower, { desc = "Readalong: slower" })
vim.keymap.set("x", "<leader>tp", ":Readalong play<CR>", { desc = "Readalong: read selection" })
```

`require("readalong").status()` returns a short string such as `▶ unreal 1.2x` for your statusline.

## Configuration

Defaults:

```lua
require("readalong").setup({
  backend = "auto",        -- "auto" (Unreal if key + mpv available, else say) | "unreal" | "say"
  fallback_to_say = true,  -- continue with `say` when an Unreal request fails
  follow_cursor = true,    -- move the cursor with the word being read
  skip_code_blocks = true, -- skip fenced code blocks in markdown
  playback_rate = 1.0,
  rate_step = 0.1,
  segment_chars = { soft = 500, hard = 1000 }, -- how long paragraphs are split
  unreal = {
    api_key = nil,         -- string or function; defaults to $UNREAL_SPEECH_API_KEY
    api_url = "https://api.v8.unrealspeech.com",
    voice = "Sierra",
    bitrate = "192k",
    speed = 0,             -- synthesis speed -1.0..1.0 (prefer playback_rate, it costs nothing)
    pitch = 1.0,
    chunk_chars = 2000,    -- characters per request (API max 3000)
    cache_dir = vim.fn.stdpath("cache") .. "/readalong",
    mpv = "mpv",
  },
  say = {
    voice = nil,           -- nil = system voice; list with `say -v '?'`
    rate = 175,            -- words per minute at 1.0x
  },
})
```

The highlight group is `ReadalongWord` (linked to `IncSearch` by default):

```lua
vim.api.nvim_set_hl(0, "ReadalongWord", { bg = "#3e4452", bold = true })
```

## How it works

The buffer is turned into spoken text one paragraph, heading or list item at a time. Markdown
syntax is replaced by spaces, so every spoken word keeps its exact buffer position. Each word gets
an invisible extmark, so the highlight still lands correctly if you edit while it reads.

**Unreal Speech:** paragraphs are grouped into chunks of up to `chunk_chars` and sent to the
`/speech` endpoint with `TimestampType = "word"`. The MP3 and the word timestamps are downloaded
into `cache_dir`, keyed by a hash of the text and voice settings. mpv plays the audio and reports
its position over its IPC socket, and the word at that time is highlighted. The next chunk is
synthesized while the current one plays. Only chunks you actually listen to are synthesized,
and unchanged chunks come from the cache, so editing part of a file only costs the changed
paragraphs.

**macOS `say`:** `say --interactive` redraws the text for each word it speaks, marking the
current word. The plugin reads that output and highlights the marked word.

## Cost tips

- Use `:Readalong estimate` before reading a long file.
- Change speed with `faster` / `slower` instead of `unreal.speed`: playback speed is applied by
  mpv, while `unreal.speed` (like voice, pitch and bitrate) is part of the cache key.
- Reading a visual selection groups text differently from reading the whole file, so it may not
  reuse audio cached from a whole-file read.

## Development

```sh
nvim --headless -u NONE -l tests/text_test.lua
```

## License

MIT
