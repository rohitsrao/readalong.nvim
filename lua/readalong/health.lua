local M = {}

function M.check()
  local health = vim.health
  local config = require("readalong.config")
  local o = config.options

  health.start("readalong.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required")
  end
  health.info("backend = " .. o.backend)

  health.start("Unreal Speech backend")
  local unreal = require("readalong.backends.unreal")
  if unreal.api_key() then
    health.ok("API key found")
  else
    health.warn("no API key", { "export UNREAL_SPEECH_API_KEY=... in your shell profile, or set unreal.api_key" })
  end
  if vim.fn.executable(o.unreal.mpv) == 1 then
    health.ok("mpv found: " .. vim.fn.exepath(o.unreal.mpv))
  else
    health.warn("mpv not found", { "install it, e.g. `brew install mpv` or your distro's mpv package" })
  end
  if vim.fn.executable("curl") == 1 then
    health.ok("curl found")
  else
    health.error("curl not found")
  end
  health.info("voice " .. o.unreal.voice .. ", cache " .. o.unreal.cache_dir)

  health.start("macOS say backend")
  if vim.fn.executable("say") == 1 then
    health.ok("say found" .. (o.say.voice and (", voice " .. o.say.voice) or ", system voice"))
  else
    health.info("say not found (only available on macOS)")
  end
end

return M
