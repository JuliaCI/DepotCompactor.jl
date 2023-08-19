# DepotCompactor

This package is intended to make managing a shared depot used by multiple workers easier.
It was designed for running [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil/), where many large artifacts are downloaded by individual agents on a single machine, each agent writes to its own depot, but many artifacts are duplicated across each agent depot.
This package allows for transparent "compaction" of depots by inspecting resources contained within depots and moving shared resources into a shared, read-only depot stored higher on the `DEPOT_PATH` by each agent.

# Example usage
Agents are run with a stacked depot setup:
```
JULIA_DEPOT_PATH=${HOME}/depots/agent.0:${HOME}/depots/shared julia ...
```

Periodically, compaction for that agent is run via:
```
shared_depot_path = expanduser("~/depots/shared")
agent_depot_path = expanduser("~/depots/agent.0")
all_agent_depot_paths = [expanduser("~/depots/agent.$(idx)") for idx in 0:(num_agents-1)]

compact_depots(shared_depot_path, [agent_depot_path]; ref_depots=all_agent_depot_paths)
```

This will move any resouce used by `agent.0` and any other depot (including the shared depot) into the shared depot.
Other agents will be able to transparently pick up artifacts/packages that are available in the shared depot.
If another agent (say, `agent.1`) has a resource that `agent.0` also has, this will move it from `agent.0` into the shared depot, and then when the same compaction is run for `agent.1` at some time in the future, the shared resources (which already exist within the shared depot) will be simply removed from the `agent.1` depot.

This package takes pains to attempt to be as transactional as possible, to allow live compaction.
Please open issues if this does not work as desired.
Note that there is no support yet for performing a live `Pkg.gc()` on the shared depot, although it is theoretically possible to do with low risk.
