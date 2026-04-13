# Spur Connection Design

## Goal

`SearchAndConnect` must build a spur route that physically merges with the existing spine at the recorded junction merge tiles, so trains travel src_station → merge_point → spine → dest_station rather than building a separate parallel track directly to the destination.

## Background

`BuildJunctions` records two merge tiles per junction: `leftTile` (spine tile where trains depart toward dest) and `rightTile` (spine tile where trains arrive from dest). These are the physical points where spur track must join the spine.

`SearchAndConnect` currently calls `CreateBuilder` with a `viaWaypoint` hint that is never read. The builder builds a direct src→dest route, ignoring the junction.

Train deployment: `RouteBuilder.DoPostBuild` handles initial vehicle spawning after a standard route build, but also triggers uncontrolled extensions and transfers that are inappropriate for network-managed spurs. For spurs, skip `DoPostBuild` and call `builtRoute.BuildVehicle(true)` directly for initial deployment. The main loop's `CheckBuildVehicle` handles fleet growth over time.

## Design

### What changes

`freightnetwork.nut` — `SearchAndConnect` function only. No changes to `railbuilder.nut`, `pathfinder.nut`, `trainroute.nut`, or `route.nut`.

### Spur build sequence

After a source industry is found in the search rectangle:

**1. Build src station**

Call `RailStationFactory` (or reuse the `CreateStationFactory` path via a minimal `CommonRouteBuilder`) to build a station near the source industry. Use the same `infrastractureType`, `platformLength`, and `cargo` as the spine route (`FreightNetwork.state.lastBuiltRoute`). This gives `srcHgStation`.

If station build fails: log warning, blacklist the industry in `failedPairs`, remove junction, continue.

**2. Build outbound spur track** (junction → src, train direction: src→dest)

`PathToStation`'s `srcPathGetter` must return an array of 4-tile start arrays (as produced by `RailPathBuilder.GetStartArray`). Extract the sub-path of `route.pathSrcToDest` ending at `leftTile` using `SubPathEnd(leftTile)`, then call `GetStartArray` on its reverse to get valid departure points on the spine.

```
local spineSubPath = route.pathSrcToDest.SubPathEnd(leftTile);
RailPathBuilder().PathToStation(
    srcPathGetter  = GetterFunction(function():(spineSubPath) {
        return RailPathBuilder.GetStartArray(spineSubPath.Reverse());
    }),
    destStation    = srcHgStation,
    limitCount     = HogeAI.Get().pathFindLimit,
    eventPoller    = HogeAI.Get(),
    reversePath    = null,
    isArrival      = true
)
```

**3. Build return spur track** (src → junction, train direction: src→dest return)

Similarly extract the sub-path of `route.pathDestToSrc` ending at `rightTile`.

```
local revSpineSubPath = route.pathDestToSrc.SubPathEnd(rightTile);
RailPathBuilder().PathToStation(
    srcPathGetter  = GetterFunction(function():(revSpineSubPath) {
        return RailPathBuilder.GetStartArray(revSpineSubPath.Reverse());
    }),
    destStation    = srcHgStation,
    limitCount     = HogeAI.Get().pathFindLimit,
    eventPoller    = HogeAI.Get(),
    reversePath    = outboundBuiltPath.path,
    isArrival      = false
)
```

If either path build fails: rollback src station, log warning, remove junction, continue to next junction. Do NOT blacklist the industry — a different junction may succeed.

**4. Create TrainRoute**

Instantiate `TrainRoute` with:
- `srcHgStation` (newly built)
- `destHgStation` = `FreightNetwork.state.lastBuiltRoute.destHgStation`
- `pathSrcToDest` = outbound built path (step 2)
- `pathDestToSrc` = return built path (step 3)

Register via `Route.allRoutes`.

**5. Initial vehicle deployment**

Call `builtRoute.BuildVehicle(true)` once. Do NOT call `DoPostBuild` — it would trigger uncontrolled route extensions and transfer searches incompatible with network management.

**6. Mark source served**

`FreightNetwork.servedSources.rawset(found.industry, true)`  
Remove junction from `availableJunctions`.  
Log: `FreightNetwork.SearchAndConnect: connected via junction <source and destination name>`  
Return `true`.

### pathBuildParams

```squirrel
{
    engine         = route.GetLatestEngineSet().engine,
    cargo          = found.cargo,
    platformLength = route.GetPlatformLength(),
    distance       = AIMap.DistanceManhattan(found.tile, destTile),
    isTransfer     = false,
    isBiDirectional = false,
    isSingle       = false
}
```

## Files

- Modify: `freightnetwork.nut` — `SearchAndConnect` function only

## Acceptance Criteria

- [ ] Spur track physically merges at the junction tile, not parallel to the spine
- [ ] `FreightNetwork.SearchAndConnect: connected via junction` appears in log
- [ ] `test_source_connected` passes for seeds 42 and 1
- [ ] No direct src→dest track bypassing the junction
- [ ] Trains appear on the spur after build
