if vim.g.loaded_readalong then return end
vim.g.loaded_readalong = true

vim.api.nvim_create_user_command("Readalong", function(o)
  require("readalong").command(o)
end, {
  nargs = "*",
  range = true,
  desc = "Read the buffer aloud, highlighting each word",
  complete = function(arglead, cmdline)
    return require("readalong").complete(arglead, cmdline)
  end,
})
