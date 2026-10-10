log = Log.open_topic ("s-armada-dp-sink")

local args = ...
args = args:parse (1)

local flag = "/run/armada-dp-audio." .. args ["card"]
local node = nil
local retry = nil
local delay = 3000
local sync

local function retry_later ()
  if retry ~= nil then
    return
  end
  retry = Core.timeout_add (delay, function ()
    retry = nil
    sync ()
    return false
  end)
  delay = math.min (delay * 2, 60000)
end

local function retry_reset ()
  if retry ~= nil then
    retry:destroy ()
    retry = nil
  end
  delay = 3000
end

sync = function ()
  local ready = GLib.access (flag, "r")
  if ready and node == nil then
    node = Node ("adapter", {
      ["factory.name"] = "api.alsa.pcm.sink",
      ["api.alsa.path"] = "hw:CARD=" .. args ["card"] .. ",DEV=" .. args ["device"],
      ["media.class"] = "Audio/Sink",
      ["node.name"] = "DisplayPort",
      ["node.description"] = "DisplayPort",
      ["audio.format"] = "S16LE",
      ["audio.rate"] = 48000,
      ["audio.channels"] = 2,
      ["session.suspend-timeout-seconds"] = 0,
      ["node.pause-on-idle"] = false,
      ["armada.sink-rank"] = args ["rank"],
    })
    local created = node
    created:activate (Features.ALL, function (n, err)
      if err then
        log:warning ("DisplayPort sink failed: " .. tostring (err))
        if node == created then
          node = nil
          retry_later ()
        end
      elseif node ~= created then
        n:request_destroy ()
      end
    end)
  elseif not ready and node ~= nil then
    node:request_destroy ()
    node = nil
  end
end

local fm = Plugin.find ("file-monitor-api")
if fm then
  fm:connect ("changed", function (_, file)
    if file == flag then
      retry_reset ()
      sync ()
    end
  end)
  fm:call ("add-watch", "/run", "m")
end
sync ()
