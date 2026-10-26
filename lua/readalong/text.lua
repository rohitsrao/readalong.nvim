-- Turns buffer lines into the text that gets spoken, and remembers where every spoken word
-- sits in the buffer so it can be highlighted.
--
-- Result of M.extract():
--   words[i]    = { lnum, scol, ecol, seg, offset, norm }
--                 lnum/scol/ecol: 0-based buffer position of the word (ecol exclusive)
--                 seg: index into segments; offset: 0-based byte offset of the token in seg.text
--                 norm: lowercased letters/digits only, for matching TTS word timestamps
--   segments[s] = { text, first, last } (first/last are indices into words)

local M = {}

local WORD_CHAR = "[%w\128-\255]" -- letters, digits and any non-ASCII byte

local function spaces(n)
  return string.rep(" ", type(n) == "number" and n or #n)
end

function M.normalize(s)
  return (s:lower():gsub("[^%w\128-\255]", ""))
end

-- Replace markdown syntax with spaces. Byte length is kept, so columns in the masked line
-- still match the buffer.
local function mask(line)
  while line:find("^%s*>") do
    line = line:gsub("^(%s*)>", "%1 ", 1)
  end
  line = line:gsub("^(%s*)(#+%s)", function(a, b) return a .. spaces(b) end)
  line = line:gsub("^(%s*)([-*+]%s)", function(a, b) return a .. spaces(b) end)
  line = line:gsub("^(%s*)(%d+[.)]%s)", function(a, b) return a .. spaces(b) end)
  line = line:gsub("^(%s*)(%[[ xX]%]%s)", function(a, b) return a .. spaces(b) end)
  -- [text](url) and ![alt](url): keep the text, drop the url
  line = line:gsub("(!?)%[([^%]]*)%]%(([^)]*)%)", function(bang, text, url)
    return spaces(#bang + 1) .. text .. spaces(#url + 3)
  end)
  line = line:gsub("<[^>]*>", spaces) -- html tags and single-line comments
  line = line:gsub("%a[%w+.-]*://[^%s)>]+", spaces) -- bare urls
  line = line:gsub("[`*~|\\]", " ")
  -- underscores used for emphasis, but not the ones inside snake_case words
  local orig = line
  line = line:gsub("()_", function(i)
    local prev, nxt = orig:sub(i - 1, i - 1), orig:sub(i + 1, i + 1)
    return (prev:match("%w") and nxt:match("%w")) and "_" or " "
  end)
  return line
end

local function starts_block(line)
  return line:find("^%s*#") or line:find("^%s*[-*+]%s") or line:find("^%s*%d+[.)]%s")
    or line:find("^%s*>") or line:find("^%s*|")
end

-- Headings and table rows are always a segment of their own.
local function single_line_block(line)
  return line:find("^%s*#") or line:find("^%s*|")
end

---@param lines string[] buffer lines
---@param first integer 0-based row of lines[1]
---@param opts { markdown: boolean, skip_code_blocks: boolean, soft: integer, hard: integer }
function M.extract(lines, first, opts)
  local words, segments = {}, {}
  local parts, len, seg_words = {}, 0, {}

  local function close()
    if #seg_words > 0 then
      local text = table.concat(parts, " ")
      if not text:find("[.!?:;]$") then
        text = text .. "." -- headings and list items without punctuation still get a pause
      end
      local s = #segments + 1
      for _, w in ipairs(seg_words) do
        w.seg = s
      end
      segments[s] = { text = text, first = seg_words[1].idx, last = seg_words[#seg_words].idx }
    end
    parts, len, seg_words = {}, 0, {}
  end

  local function add(token, lnum, col)
    local offset = #parts > 0 and len + 1 or 0
    parts[#parts + 1] = token
    len = offset + #token
    local s = token:find(WORD_CHAR)
    if s then
      local e = #token - token:reverse():find(WORD_CHAR) + 1
      local w = {
        lnum = lnum, scol = col + s - 1, ecol = col + e,
        offset = offset, norm = M.normalize(token), idx = #words + 1,
      }
      words[#words + 1] = w
      seg_words[#seg_words + 1] = w
    end
    if len >= opts.hard or (len >= opts.soft and token:find("[.!?]$")) then
      close()
    end
  end

  local fence, in_comment, in_front_matter = nil, false, false
  for i, line in ipairs(lines) do
    local lnum = first + i - 1
    local skip = false

    if opts.markdown then
      local f = line:match("^%s*(```)") or line:match("^%s*(~~~)")
      if lnum == 0 and line:find("^%-%-%-%s*$") then
        in_front_matter, skip = true, true
      elseif in_front_matter then
        in_front_matter = not line:find("^%-%-%-%s*$")
        skip = true
      elseif fence then
        if f == fence then
          fence, skip = nil, true
        else
          skip = opts.skip_code_blocks
        end
      elseif f then
        fence, skip = f, true
      elseif in_comment then
        in_comment = not line:find("-->", 1, true)
        skip = true
      elseif line:find("<!--", 1, true) and not line:find("-->", 1, true) then
        in_comment, skip = true, true
      elseif line:find("^[%s|:%-*_=]+$") then
        skip = true -- table separators, horizontal rules, setext underlines
      end
    end

    if skip or line:find("^%s*$") then
      close()
    else
      local spoken = line
      if opts.markdown and not fence then
        if starts_block(line) then close() end
        spoken = mask(line)
      end
      for col, token in spoken:gmatch("()(%S+)") do
        add(token, lnum, col - 1)
      end
      if opts.markdown and single_line_block(line) then close() end
    end
  end
  close()

  for _, w in ipairs(words) do
    w.idx = nil
  end
  return words, segments
end

-- Index of the first word at or after the given 0-based position, or nil.
function M.word_at(words, row, col)
  for i, w in ipairs(words) do
    if w.lnum > row or (w.lnum == row and w.ecol > col) then
      return i
    end
  end
end

-- Index of the word whose token starts at or before `offset` within segment `seg`.
function M.word_at_offset(words, seg, offset)
  local found = seg.first
  for i = seg.first, seg.last do
    if words[i].offset > offset then break end
    found = i
  end
  return found
end

return M
