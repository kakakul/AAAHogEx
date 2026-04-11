# FreightNetwork Redesign

**Date:** 2026-04-11
**Branch:** strategy-c
**Scope:** Network mode only (`IsNetworkMode() == true`). Freight rail only. Supersedes spine-selection and phase-orchestration sections of the 2026-04-10 spec.

---

## Motivation

The original implementation had three problems:

1. **FindSpine scanned all industry pairs** — expensive and tended to select short coastal-to-coastal routes.
2. **SearchAndConnect expanded only 10 tiles per Step()** — taking many main-loop turns to reach distant sources, while ScanPlaces built competing routes in between.
3. **ScanPlaces interleaved with FreightNetwork** — causing route contention and redundant scanning in network mode.

---

## Structural Changes

### ScanPlaces suppressed in network mode

`_ScanPlaces` returns immediately at the top if `IsNetworkMode()`. The existing per-candidate freight rail guard inside the loop is removed (no longer needed).

### FreightNetwork skipped for Pax/Mail-only AI

`FreightNetwork.Step()` returns immediately if `IsPaxMailOnly()`.

### Phase state machine removed

The `PHASE_*` constants and the `state.phase` field are removed. Active network state is determined by `state.destIndustry != null`.

`FreightNetwork.Step()` decides the full unit of work each call:

```
if state.destIndustry == null:          // no active network
    FindSpine()
    if spine built: BuildJunctions()
else:                                   // active network
    result = SearchAndConnect()         // exhausts rectangle fully
    if result == "connected":
        BuildJunctions()
    elif availableJunctions empty:
        state.destIndustry = null
        state.networkId++
```

`SaveStatics`/`LoadStatics` updated: save/load `destIndustry` (null = no active network); remove `phase`.

---

## FindSpine — Destination-First Scan

**Function:** `FreightNetwork.FindSpine()`

Runs entirely within one Step() call. Uses a widening edge-distance threshold.

### Algorithm

```
for edgePct = 10 to 100 step 10:
    edgeThresh = edgePct * mapLongSide / 100

    for each industry D in AIIndustryList():
        if D in servedDests: skip
        dN = tileY(D)
        dS = mapH - 1 - tileY(D)
        dW = tileX(D)
        dE = mapW - 1 - tileX(D)
        minEdgeDist = min(dN, dS, dW, dE)
        if minEdgeDist > edgeThresh: skip   // not coastal enough

        for each cargo accepted by D (via AIIndustryType.GetAcceptedCargo):
            for each industry S producing that cargo:
                if S in servedSources: skip
                dist = DistanceManhattan(S, D)
                if dist == 0 or dist >= mapLongSide * 20 / 100: skip

                // Inland filter — reuse GetPrimaryDirection(D, S)
                pDir = GetPrimaryDirection(D, S)
                inlandOk = false
                if   minEdgeDist == dN: inlandOk = (pDir.dy == 1)
                elif minEdgeDist == dS: inlandOk = (pDir.dy == -1)
                elif minEdgeDist == dW: inlandOk = (pDir.dx == 1)
                else:                   inlandOk = (pDir.dx == -1)
                if not inlandOk: skip

                production = AIIndustry.GetLastMonthProduction(S, 0)
                if production <= 0: production = 1
                infraTypes = TrainRoute.GetDefaultInfrastractureTypes()
                estimate = Route.Estimate(VT_RAIL, cargo, dist, production, false, infraTypes)
                if estimate == null or estimate.value <= 0: skip

                score = estimate.value * 1000 / (minEdgeDist + 1)
                track as best candidate

    if best candidate found: break   // stop widening
```

Build the best candidate as a standard double-tracked `TrainRoute` (`notUseSingle = true`). On success: set `state.destIndustry`, `state.destPlace`, update `servedDests`, `servedSources`.

If no candidate survives after widening to 100%: log and return — Step() retries next call.

**TODO:** Handle freight not connectable by rail (e.g. oil rigs on water). Currently these are silently skipped because `Route.Estimate(VT_RAIL, ...)` returns null or zero value for unreachable pairs. A future pass should detect water-only industries and route them via ship or skip them explicitly.

---

## BuildJunctions — Unchanged

`FreightNetwork.BuildJunctions()` is unchanged in logic. Calls `TryBuildNearStation` on the path of the most recently built route, records `leftTile`/`rightTile` in `availableJunctions`.

**Out of scope:** Junction support on diagonal track. The spine scoring (`score = estProfit * 1000 / (destMinEdgeDist + 1)`) naturally favours longer routes, which tend to be more axis-aligned. Diagonal junction support is left as future work.

---

## SearchAndConnect — Full Exhaust Per Step()

**Function:** `FreightNetwork.SearchAndConnect()`

Exhausts the full rectangle search within one Step() call. Returns `"connected"` or `"exhausted"`.

```
while availableJunctions not empty:
    junc = availableJunctions[0]

    // Expand rectangle
    junc.primaryRadius  += 10
    junc.perpOutRadius  += 2
    junc.perpInRadius   += 1

    // Check map boundary on primary axis
    pFarX = tileX(mergeTile) + pDir.dx * junc.primaryRadius
    pFarY = tileY(mergeTile) + pDir.dy * junc.primaryRadius
    if pFarX or pFarY out of bounds:
        remove junc from availableJunctions
        continue

    // Compute bounding box, clamp to map
    // Scan AIIndustryList for industry in box producing cargo accepted by destIndustry
    // Use AIIndustryType.GetAcceptedCargo / GetProducedCargo (not AIIndustry.GetAcceptedCargo)
    if source found:
        build route src → destPlace via mergeTile waypoint (notUseSingle = true)
        add src to servedSources
        remove junc from availableJunctions
        state.lastBuiltRoute = newRoute
        return "connected"
    // else: loop — try next junction or next expansion (caller will re-enter next Step())

return "exhausted"   // Step() will reset network
```

Note: if the while loop completes without finding a source and `availableJunctions` is now empty, `Step()` resets `state.destIndustry = null` and increments `networkId`.

---

## Files Changed

| File | Change |
|------|--------|
| `freightnetwork.nut` | Remove phase state machine; rewrite `Step()` orchestration; rewrite `FindSpine()` as destination-first scan; rewrite `SearchAndConnect()` to exhaust in one call; update `SaveStatics`/`LoadStatics` |
| `main.nut` | Suppress `_ScanPlaces` entirely in network mode (replace per-candidate guard) |

`railbuilder.nut` and `trainroute.nut` are unchanged.

---

## Tests

Existing integration tests (`test_integration.py`) cover the observable outcomes and remain the acceptance criteria.

**Additional seed:** During implementation, run `test_spine_built` and `test_source_connected` against several candidate seeds and pick one that produces a different but valid map layout (different coastal industry distribution from seed=42). Add that seed as a second parametrized case for those two tests only. The skeleton and ScanPlaces-guard tests are layout-independent and stay seed=42 only.
