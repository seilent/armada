log = Log.open_topic ("s-armada-dp-sink")

local args = ...
args = args:parse (1)

local flag = "/run/armada-dp-audio." .. args ["card"]
local node = nil

local function sync ()
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
          Core.timeout_add (3000, function ()
            sync ()
            return false
          end)
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
      sync ()
    end
  end)
  fm:call ("add-watch", "/run", "m")
end
sync ()
