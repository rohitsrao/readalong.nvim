-- Controls one long-running mpv process over its JSON IPC socket.
-- mpv reports the playback position (time-pos), which drives the word highlight.

local M = {}

local Player = {}
Player.__index = Player

local count = 0

local function socket_path()
  count = count + 1
  local name = string.format("readalong-%d-%d", vim.fn.getpid(), count)
  if vim.fn.has("win32") == 1 then
    return "\\\\.\\pipe\\" .. name
  end
  return "/tmp/" .. name .. ".sock" -- short path: unix sockets are limited to ~104 bytes
end

---@param opts { cmd: string, speed: number, on_time: fun(t: number), on_eof: fun(), on_error: fun(msg: string) }
function M.new(opts)
  local self = setmetatable({ opts = opts, queue = {}, buf = "", loading = false }, Player)
  self.sock = socket_path()
  local ok, proc = pcall(vim.system, {
    opts.cmd,
    "--idle=yes",
    "--no-video",
    "--no-terminal",
    "--no-resume-playback",
    "--keep-open=no",
    "--speed=" .. opts.speed,
    "--input-ipc-server=" .. self.sock,
  }, {}, vim.schedule_wrap(function(r)
    if not self.closed then
      self.closed = true
      opts.on_error("mpv exited (code " .. r.code .. ")")
    end
  end))
  if not ok then
    opts.on_error("could not start mpv: " .. tostring(proc))
    self.closed = true
    return self
  end
  self.proc = proc
  self:connect(0)
  return self
end

function Player:connect(attempt)
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(self.sock, function(err)
    if err then
      pipe:close()
      if self.closed then return end
      if attempt < 100 then
        vim.defer_fn(function() self:connect(attempt + 1) end, 30)
      else
        vim.schedule(function() self.opts.on_error("could not connect to mpv: " .. err) end)
      end
      return
    end
    if self.closed then
      pipe:close()
      return
    end
    self.pipe = pipe
    pipe:read_start(function(_, data)
      if data then self:read(data) end
    end)
    pipe:write('{"command":["observe_property",1,"time-pos"]}\n')
    for _, line in ipairs(self.queue) do
      pipe:write(line)
    end
    self.queue = {}
  end)
end

function Player:read(data)
  self.buf = self.buf .. data
  while true do
    local nl = self.buf:find("\n", 1, true)
    if not nl then break end
    local line = self.buf:sub(1, nl - 1)
    self.buf = self.buf:sub(nl + 1)
    vim.schedule(function() self:handle(line) end)
  end
end

function Player:handle(line)
  if self.closed then return end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then return end
  if msg.event == "playback-restart" then
    self.loading = false
  elseif msg.event == "property-change" and msg.name == "time-pos" then
    -- Positions from the previous file can still arrive just after a load; skip until mpv restarts.
    if not self.loading and type(msg.data) == "number" then
      self.opts.on_time(msg.data)
    end
  elseif msg.event == "end-file" and msg.reason == "eof" then
    self.opts.on_eof()
  end
end

function Player:send(cmd)
  if self.closed then return end
  local line = vim.json.encode({ command = cmd }) .. "\n"
  if self.pipe then
    self.pipe:write(line)
  else
    table.insert(self.queue, line)
  end
end

function Player:load(path, start)
  self.loading = true
  self:send({ "set_property", "start", string.format("%.3f", start) })
  self:send({ "loadfile", path, "replace" })
  self:send({ "set_property", "pause", false })
end

function Player:pause(paused)
  self:send({ "set_property", "pause", paused })
end

function Player:speed(rate)
  self:send({ "set_property", "speed", rate })
end

function Player:quit()
  if self.closed then return end
  self:send({ "quit" })
  self.closed = true
  local pipe, proc = self.pipe, self.proc
  vim.defer_fn(function()
    if pipe and not pipe:is_closing() then pipe:close() end
    if proc then pcall(proc.kill, proc, 15) end
  end, 300)
end

return M
