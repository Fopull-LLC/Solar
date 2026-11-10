-- The story probe's hooks (scenarios/_story/scenario.lua `hooks`): a
-- scenario's code, for the game's own scenarios only (docs/scenarios.md §6).
-- scenario_run spawns prefabs/scn_story_hooks and calls these through
-- findScript; every one gets the scenario `api` and nothing else is used.

function on_step(api, id) api.log("step opened: " .. id) end

goals = {
  -- met once the fault has happened (the fault sequence's hook set the var)
  faultSeen = function(g, api)
    local seen = api.var("faulted") == true
    return seen, seen and "the fault happened" or "waiting for the fault"
  end,
}

function markFault(api) api.setVar("faulted", true) end
