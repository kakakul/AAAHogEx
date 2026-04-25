# Spur Connection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `SearchAndConnect`'s `CreateBuilder` call with a direct two-leg spur build that merges physically at the junction's `leftTile`/`rightTile`, so spur trains travel src_station → junction → spine → dest_station.

**Architecture:** `SearchAndConnect` builds the src station directly via `RailStationFactory`, then uses two `RailPathBuilder.PathToStation` calls (one per direction) starting from sub-paths of the existing spine to route into the src station. A `TrainRoute` is constructed from the resulting `BuildedPath` objects and registered automatically. `DoPostBuild` is skipped to prevent uncontrolled AI extensions; `BuildVehicle(true)` deploys the initial train.

**Tech Stack:** Squirrel, OpenTTD AI API. Key classes: `RailPathBuilder`, `BuildedPath`, `Path`, `TrainRoute`, `RailStationFactory`.

---

### Task 1: Replace SearchAndConnect build logic with spur build

**Goal:** `SearchAndConnect` builds a two-leg spur that merges at the junction tiles instead of a direct src→dest route.

**Files:**
- Modify: `freightnetwork.nut` — `FreightNetwork::SearchAndConnect` function

**Acceptance Criteria:**
- [ ] `FreightNetwork.SearchAndConnect: connected via junction` appears in log
- [ ] Spur track merges at junction tile, not parallel to spine
- [ ] `test_source_connected` passes for seeds 42 and 1

**Verify:** `cd tests && python -m pytest test_integration.py::test_source_connected -v -s` → both seeds PASSED

**Steps:**

- [ ] **Step 1: Write a failing test to confirm current behaviour is wrong**

The existing `test_source_connected` already asserts `'FreightNetwork.SearchAndConnect: connected'` in output. We need a stronger assertion that the spur connects via a junction (not direct). Add to `tests/test_integration.py`:

```python
@pytest.mark.parametrize("seed", [42, 1])
def test_spur_connects_via_junction(seed):
    """Spur must log 'connected via junction', not just 'connected'."""
    row = run_hognet(network_mode=1, days=365 * 5, seed=seed)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.SearchAndConnect: connected via junction' in row['output'], (
        f"Expected spur to connect via junction\nOutput:\n{row['output']}"
    )
```

Run: `cd tests && python -m pytest test_integration.py::test_spur_connects_via_junction -v -s`
Expected: FAIL (log says "connected" not "connected via junction")

- [ ] **Step 2: Understand the key APIs before editing**

In `freightnetwork.nut`, the found-source block (around line 425) currently does:
```squirrel
local t = { src = srcPlace, dest = ..., viaWaypoint = mergeTile, ... };
local builder = ai.CreateBuilder(t, [], {}, ...);
local newRoutes = builder.Build();
```

Replace this entire block. Key APIs you will use:

**`BuildedPath`** (`railbuilder.nut:848`): wraps a `Path` with `.path`, `.array_`, `.route`. Constructed as `BuildedPath(path, route, array_)`.

**`Path.SubPathEnd(endTile)`** (`railbuilder.nut:131`): returns a copy of the path from its start up to (but not including) `endTile`. The spine path `route.pathSrcToDest.path` starts at src station and ends at dest station. `leftTile` is on this path.

**`RailPathBuilder.GetStartArray(path)`** (`railbuilder.nut:2071`): takes a `Path` object, returns an array of 4-tile start arrays `[[cur, prev, prev2, prev3], ...]` — the format needed by `PathToStation`'s `srcPathGetter`. Requires at least 4 consecutive tiles on existing track.

**`RailPathBuilder().PathToStation(srcPathGetter, destStation, limitCount, eventPoller, reversePath, isArrival)`** (`railbuilder.nut:2201`): configures a `RailPathBuilder` to find a path from the spine to a station. Returns `this` (the builder). Call `.Build()` to execute; result is in `.buildedPath`.

**`TrainRoute(routeType, cargo, srcHgStation, destHgStation, pathSrcToDest, pathDestToSrc)`** (`trainroute.nut:314`): constructor auto-registers in `Route.allRoutes`. `pathSrcToDest` and `pathDestToSrc` are `BuildedPath` objects.

**`route.BuildVehicle(firstBuild)`** (`route.nut:2121`): buys and deploys the first train.

- [ ] **Step 3: Replace the found-source block in SearchAndConnect**

Find the block starting at `if(found != null) {` (around line 425 in `freightnetwork.nut`). Replace the entire block from `if(found != null) {` through `return true;` (inclusive) with the following:

```squirrel
				if(found != null) {
					HgLog.Info("FreightNetwork.SearchAndConnect: found source "
						+ AIIndustry.GetName(found.industry) + " at " + HgTile(found.tile));

					local route = FreightNetwork.state.lastBuiltRoute;
					if(route == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: lastBuiltRoute null, skipping");
						FreightNetwork.availableJunctions.remove(ji);
						continue;
					}

					// Build src station near the found industry
					local srcPlace = HgIndustry(found.industry, true);
					local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
					local engineSet = route.GetLatestEngineSet();
					if(engineSet == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: engineSet null, skipping");
						FreightNetwork.availableJunctions.remove(ji);
						continue;
					}
					local srcStationFactory = RailStationFactory(srcPlace, engineSet);
					local destTile2 = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);
					local srcHgStation = srcStationFactory.CreateBest(srcPlace, found.cargo, destTile2);
					if(srcHgStation == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: failed to build src station");
						FreightNetwork.servedSources.rawset(found.industry, true); // blacklist
						ji++;
						continue;
					}

					// Sub-path of spine ending just before leftTile (direction: toward src end)
					// path starts at src station end, ends at dest — SubPathEnd excludes leftTile
					local spinePathFwd = route.pathSrcToDest.path.SubPathEnd(junc.leftTile);
					local spinePathRev = route.pathDestToSrc.path.SubPathEnd(junc.rightTile);

					if(spinePathFwd == null || spinePathFwd.GetParent() == null
							|| spinePathFwd.GetParent().GetParent() == null
							|| spinePathFwd.GetParent().GetParent().GetParent() == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: spine sub-path too short for leftTile");
						srcHgStation.Remove();
						ji++;
						continue;
					}
					if(spinePathRev == null || spinePathRev.GetParent() == null
							|| spinePathRev.GetParent().GetParent() == null
							|| spinePathRev.GetParent().GetParent().GetParent() == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: spine sub-path too short for rightTile");
						srcHgStation.Remove();
						ji++;
						continue;
					}

					local pathBuildParams = {
						engine         = engineSet.engine,
						cargo          = found.cargo,
						platformLength = route.GetPlatformLength(),
						distance       = AIMap.DistanceManhattan(found.tile, destTile2),
						isTransfer     = false,
						isBiDirectional = false,
						isSingle       = false
					};

					// Leg 1: spine→src (outbound: train travels src→dest)
					// Reverse the sub-path so GetStartArray sees it from leftTile outward
					local temp_spinePathFwd = spinePathFwd;
					local builder1 = RailPathBuilder();
					builder1.PathToStation(
						GetterFunction(function():(temp_spinePathFwd) {
							return RailPathBuilder.GetStartArray(temp_spinePathFwd.Reverse());
						}),
						srcHgStation,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						null,
						true
					);
					builder1.pathBuildParams = pathBuildParams;
					builder1.isReverse = false;
					builder1.isRevReverse = false;
					if(!builder1.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: outbound spur build failed");
						srcHgStation.Remove();
						ji++;
						continue;
					}
					local builtPath1 = builder1.buildedPath;

					// Leg 2: src→spine (return: train travels src→dest return leg)
					local temp_spinePathRev = spinePathRev;
					local builder2 = RailPathBuilder();
					builder2.PathToStation(
						GetterFunction(function():(temp_spinePathRev) {
							return RailPathBuilder.GetStartArray(temp_spinePathRev.Reverse());
						}),
						srcHgStation,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						builtPath1.path,
						false
					);
					builder2.pathBuildParams = pathBuildParams;
					builder2.isReverse = true;
					builder2.isRevReverse = false;
					if(!builder2.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: return spur build failed");
						builtPath1.Remove();
						srcHgStation.Remove();
						ji++;
						continue;
					}
					local builtPath2 = builder2.buildedPath;

					// Create TrainRoute (auto-registers in Route.allRoutes)
					local newRoute = TrainRoute(
						TrainRoute.ROUTE_TYPE_FREIGHT,
						found.cargo,
						srcHgStation,
						route.destHgStation,
						builtPath1,
						builtPath2
					);
					newRoute.isBiDirectional = false;
					newRoute.isTransfer = false;
					newRoute.isSrcTransfer = false;
					newRoute.startDate = AIDate.GetCurrentDate();
					newRoute.latestEngineSet = engineSet;
					newRoute.srcDepot = srcHgStation.GetDepot();
					newRoute.destDepot = route.destHgStation.GetDepot();
					newRoute.Save();

					// Deploy initial train (skip DoPostBuild — it triggers uncontrolled extensions)
					newRoute.BuildVehicle(true);

					FreightNetwork.servedSources.rawset(found.industry, true);
					FreightNetwork.availableJunctions.remove(ji);
					FreightNetwork.state.lastBuiltRoute = newRoute;
					HgLog.Info("FreightNetwork.SearchAndConnect: connected via junction "
						+ AIIndustry.GetName(found.industry) + " -> "
						+ AIIndustry.GetName(FreightNetwork.state.destIndustry));
					return true;
				}
```

- [ ] **Step 4: Find the ROUTE_TYPE_FREIGHT constant**

Before applying step 3, verify the constant name exists:

Run: `grep -n "ROUTE_TYPE_FREIGHT\|routeType\s*=\s*[0-9]" "c:\Program Files (x86)\Steam\steamapps\common\OpenTTD\ai\HogNet\trainroute.nut" | head -20`

If `ROUTE_TYPE_FREIGHT` does not exist, find the correct constant by looking at how the spine route's `routeType` is set in `CommonRouteBuilder.DoBuild` and use that same value.

Run: `grep -n "routeType\b" "c:\Program Files (x86)\Steam\steamapps\common\OpenTTD\ai\HogNet\trainroute.nut" | head -20`

Use whatever value is used for a standard one-way freight rail route.

- [ ] **Step 5: Find the RailStationFactory constructor signature**

Run: `grep -n "class RailStationFactory\|function RailStationFactory\|RailStationFactory.constructor\|constructor()" "c:\Program Files (x86)\Steam\steamapps\common\OpenTTD\ai\HogNet\station.nut" | head -10`

Then: `grep -n "function.*CreateBest\b" "c:\Program Files (x86)\Steam\steamapps\common\OpenTTD\ai\HogNet\station.nut" | head -5`

Adjust the `RailStationFactory(srcPlace, engineSet)` call and `CreateBest(srcPlace, found.cargo, destTile2)` call in step 3 to match the actual signatures.

- [ ] **Step 6: Verify no dead code remains**

Run from the repo root: `grep -n "Route.Estimate\|viaWaypoint\|CreateBuilder" freightnetwork.nut`

Expected: no matches inside `SearchAndConnect` (any remaining matches should be in `FindSpine` only).

- [ ] **Step 7: Run the tests**

Run: `cd tests && python -m pytest test_integration.py -v -s 2>&1 | tail -40`

Expected: all integration tests pass including both `test_source_connected` seeds and both `test_spur_connects_via_junction` seeds.

If `test_spur_connects_via_junction` fails with a crash, check the log for the exact error and fix the constructor/method calls identified in steps 4–5.

- [ ] **Step 8: Commit**

```bash
git add freightnetwork.nut tests/test_integration.py
git commit -m "Connect spur to spine via junction merge tiles"
```
