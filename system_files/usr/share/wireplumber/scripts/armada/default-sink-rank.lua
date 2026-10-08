log = Log.open_topic ("s-armada-sink-rank")

SimpleEventHook {
  name = "armada/default-sink-rank",
  after = { "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node",
            "default-nodes/find-echo-cancel-default-node" },
  before = { "default-nodes/find-best-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
      Constraint { "default-node.type", "=", "audio.sink" },
    },
  },
  execute = function (event)
    local nodes = event:get_data ("available-nodes")
    nodes = nodes and nodes:parse ()
    if not nodes then
      return
    end

    local selected = event:get_data ("selected-node")
    local priority = event:get_data ("selected-node-priority") or 0
    local device = nil
    if priority >= 25000 then
      for _, props in ipairs (nodes) do
        if props ["node.name"] == selected then
          device = props ["device.id"]
          break
        end
      end
      if not device then
        return
      end
    end

    local best, best_rank = nil, 0
    for _, props in ipairs (nodes) do
      local rank = tonumber (props ["armada.sink-rank"]) or 0
      local name = props ["node.name"]
      if (not device or props ["device.id"] == device) and
          (rank > best_rank or (rank == best_rank and rank > 0 and name == selected)) then
        best, best_rank = name, rank
      end
    end

    if best then
      log:debug ("ranked default sink " .. best .. " (" .. best_rank .. ")")
      if not device then
        event:set_data ("selected-node-priority", 20000 + best_rank)
      end
      event:set_data ("selected-node", best)
    end
  end
}:register ()
