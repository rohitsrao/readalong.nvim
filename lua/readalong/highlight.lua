local M = {}

-- Invisible extmarks on every word, so positions survive edits made while reading.
local ns_anchor = vim.api.nvim_create_namespace("readalong_anchor")
-- The visible highlight on the word being read.
local ns_hl = vim.api.nvim_create_namespace("readalong")

function M.define_groups()
  vim.api.nvim_set_hl(0, "ReadalongWord", { link = "IncSearch", default = true })
end

function M.anchor(buf, words)
  vim.api.nvim_buf_clear_namespace(buf, ns_anchor, 0, -1)
  for _, w in ipairs(words) do
    w.mark = vim.api.nvim_buf_set_extmark(buf, ns_anchor, w.lnum, w.scol, { end_col = w.ecol })
  end
end

function M.show(buf, word, win, follow)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns_anchor, word.mark, { details = true })
  if #pos == 0 then return end
  local row, col, d = pos[1], pos[2], pos[3]
  pcall(vim.api.nvim_buf_set_extmark, buf, ns_hl, row, col, {
    id = 1,
    end_row = d.end_row,
    end_col = d.end_col,
    hl_group = "ReadalongWord",
    priority = 250,
  })
  if follow and win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col })
  end
end

function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns_hl, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, ns_anchor, 0, -1)
  end
end

return M
