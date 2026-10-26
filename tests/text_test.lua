-- Run with: nvim --headless -u NONE -l tests/text_test.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local text = require("readalong.text")
local opts = { markdown = true, skip_code_blocks = true, soft = 500, hard = 1000 }

local function check(name, cond)
  if not cond then error("FAIL: " .. name, 2) end
  print("ok   " .. name)
end

local lines = {
  "# Plan for `api` changes",
  "",
  "Some **bold** text with a [link](https://example.com/x) and snake_case_name.",
  "continued line",
  "- [ ] first item",
  "1. numbered",
  "| a | b |",
  "|---|---|",
  "```lua",
  "local x = 1",
  "```",
  "> quoted _emph_",
}
local words, segs = text.extract(lines, 0, opts)
local spoken = vim.tbl_map(function(s) return s.text end, segs)

check("heading is own segment", spoken[1] == "Plan for api changes.")
check("paragraph joins lines", spoken[2] == "Some bold text with a link and snake_case_name. continued line.")
check("checkbox removed", spoken[3] == "first item.")
check("number removed", spoken[4] == "numbered.")
check("table row", spoken[5] == "a b.")
check("code block skipped", not table.concat(spoken, " "):find("local x"))
check("blockquote and emphasis", spoken[6] == "quoted emph.")

-- every word's buffer range must contain the word's text
for _, w in ipairs(words) do
  local s = lines[w.lnum + 1]:sub(w.scol + 1, w.ecol)
  if text.normalize(s) ~= w.norm then
    -- tokens like "**bold**" are masked, so compare against the spoken token
    local seg = segs[w.seg].text
    local tok = seg:sub(w.offset + 1):match("^%S+")
    check("word range " .. s, text.normalize(tok) == text.normalize(s))
  end
end
check("link word at right column", lines[3]:sub(words[10].scol + 1, words[10].ecol) == "link")

local idx = text.word_at(words, 2, 6) -- cursor inside "**bold**"
check("word_at cursor", words[idx].norm == "bold")

-- real plan file, if given
local path = os.getenv("PLAN")
if path then
  local real = vim.fn.readfile(path)
  local t0 = vim.uv.hrtime()
  local rw, rs = text.extract(real, 0, opts)
  local chars = 0
  for _, s in ipairs(rs) do chars = chars + #s.text end
  print(string.format("plan: %d lines, %d words, %d segments, %d spoken chars (file %d bytes), %.1f ms",
    #real, #rw, #rs, chars, #table.concat(real, "\n"), (vim.uv.hrtime() - t0) / 1e6))
  for i = 1, math.min(6, #rs) do print("  [" .. i .. "] " .. rs[i].text:sub(1, 110)) end
  for _, w in ipairs(rw) do
    local s = real[w.lnum + 1]:sub(w.scol + 1, w.ecol)
    assert(s:find("[%w\128-\255]"), "empty word range at line " .. w.lnum)
  end
  print("ok   all plan word ranges non-empty")
end
