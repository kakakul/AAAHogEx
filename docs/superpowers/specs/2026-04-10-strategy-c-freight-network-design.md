# Strategy C — Freight Network Design

**Date:** 2026-04-10
**Branch:** strategy-c
**Scope:** Network mode only (`IsNetworkMode() == true`). Freight routes only. Passenger routes are unaffected.

---

## Overview

Strategy C builds freight rail networks as a spine-and-tree topology. A single high-value route (the "spine") is selected first. Further sources are then found and connected one at a time via pre-built junctions, extending the tree outward from the spine. Once no more sources can be found, a new independent network begins.

---

## Architecture

A new static class `FreightNetwork` is introduced in a new file `freightnetwork.nut`, required from `main.nut`.

### Integration points

- `FreightNetwork.Step()` is called once per main-loop iteration when `IsNetworkMode()` is true. It performs one unit of work and returns.
- `_ScanPlaces` skips freight route candidates when `IsNetworkMode()` is true (single guard at the freight candidate section). Passenger logic is untouched.
- `FourWayJunction.TryBuildNearStation` calls in `trainroute.nut` are removed for network mode. Junction building is now exclusively `FreightNetwork`'s responsibility. The calls remain for non-network mode (original behaviour preserved).

### Static state

```
FreightNetwork.phase             // current phase enum value
FreightNetwork.destIndustry      // current D (industry ID), null = no active network
FreightNetwork.destStation       // HgStation near D
FreightNetwork.availableJunctions // array of { mergeTile, side, srcIndustry }
FreightNetwork.networkId         // integer, increments each time C1 starts a new network
FreightNetwork.servedSources     // table: industry ID → true (never reset)
FreightNetwork.servedDests       // table: industry ID → true (never reset)
```

### Phase enum

| Value | Name | Description |
|-------|------|-------------|
| 0 | `PHASE_FIND_SPINE` | C1: select and build the spine route |
| 1 | `PHASE_BUILD_JUNCTION` | C2: build junctions near the most recently added source |
| 2 | `PHASE_SEARCH_AND_CONNECT` | C3+C4: find next source and connect it |

### Save / Load

`FreightNetwork.SaveStatics(table)` and `FreightNetwork.LoadStatics(data)` are added alongside existing statics in `HogeAI.Save()` / `DoLoad()`. Saved fields: `phase`, `destIndustry`, `availableJunctions`, `networkId`, `servedSources`, `servedDests`.

---

## C1 — Spine Selection (`PHASE_FIND_SPINE`)

**Function:** `FreightNetwork.FindSpine()`

1. Enumerate all industry pairs `(src, dest)` where:
   - `src` produces a cargo accepted by `dest`
   - `src` is not in `servedSources`, `dest` is not in `servedDests`
   - Both have buildable station sites

2. Estimate route value using the existing `TrainRoute` estimator (same as `GetRouteCandidatesGen`).

3. **Percentile filter** — keep the top 10% by estimated value. If no candidate survives steps 4–6, immediately widen to 20%, then 30%, up to 100%, within the same iteration. Reset to 10% when a new network starts.

4. **Route length filter** — keep only pairs where `AIMap.DistanceManhattan(src, dest) < 0.2 × mapLongSide`.

5. **Axis filter** — if `mapHeight > mapWidth`, only consider pairs where both `src` and `dest` are in the northern 25% or southern 25% of the map (by Y coordinate). For wide maps, use eastern/western 25% (by X coordinate).

6. **Score** — `min(distMapEdgeToSrc, 0.2 × mapLongSide) / (distMapEdgeToDest + 1)`. `distMapEdge` is the minimum distance from the industry tile to either of the two relevant edges (e.g. top and bottom for a tall map). High score = destination close to a map edge, source far from the edge.

7. Build the highest-scoring pair as a normal double-tracked `TrainRoute`. Add `destIndustry` to `servedDests` and `src` to `servedSources`. Set `destIndustry`, `destStation`. Advance `phase` to `PHASE_BUILD_JUNCTION`.

If no candidate is found after widening to 100%, log and remain in `PHASE_FIND_SPINE` (retry next iteration).

---

## C2 — Junction Building (`PHASE_BUILD_JUNCTION`)

**Function:** `FreightNetwork.BuildJunctions(route)`

Called after any source station and its route to D are built (both the initial spine route and each subsequent S_n).

- Calls `FourWayJunction.TryBuildNearStation` (network mode only) for the source end of the route.
- The function is extended to return the merge-point tile for each successfully built junction — the outer end of the diagonal branch on the right-hand inbound side (the side a train travelling toward D1 merges from). Trains drive on the right-hand side.
- Each successfully built junction tile is appended to `availableJunctions` as `{ mergeTile: <tile>, side: "left"|"right", srcIndustry: <id> }`.
- Up to 2 entries added per source (left-diverge and right-diverge). If neither builds successfully, no entries are added.

Advance `phase` to `PHASE_SEARCH_AND_CONNECT`.

---

## C3+C4 — Search and Connect (`PHASE_SEARCH_AND_CONNECT`)

**Function:** `FreightNetwork.SearchAndConnect()`

Iterates over `availableJunctions` in order.

### Search rectangle (C3)

For each junction entry, a search rectangle is maintained. It grows outward from `mergeTile` away from `destIndustry`:

- **Primary direction** (away from D1): +10 tiles per iteration
- **Perpendicular away from S1-1**: +2 tiles per iteration
- **Perpendicular toward S1-1**: +1 tile per iteration

The primary axis is determined by comparing `abs(dy)` vs `abs(dx)` between `mergeTile` and the `destIndustry` tile. Signs of `dy` and `dx` are preserved for direction.

The lateral position of S1-1 relative to the junction determines which perpendicular side is "toward" vs "away."

A junction is exhausted and removed from `availableJunctions` when its rectangle edge exceeds the map boundary.

### Industry search

For each tile in the current rectangle: check for a producing industry whose cargo is accepted by `destIndustry`, and not already in `servedSources`. First valid one found is selected as S_next.

### Connect (C4)

- Build a normal double-tracked `TrainRoute` from S_next to `destStation`.
- Pass `mergeTile` as a required waypoint to the pathfinder so the route joins the existing corridor at the junction.
- Remove the used junction entry from `availableJunctions`.
- Add S_next to `servedSources`.
- Advance `phase` to `PHASE_BUILD_JUNCTION` to build junctions near S_next.

### Network exhaustion (C5)

When `availableJunctions` becomes empty (all entries exhausted or used):

- Reset `phase` to `PHASE_FIND_SPINE`.
- Increment `networkId`.

`servedSources` and `servedDests` are not cleared — they accumulate across all networks to prevent revisiting.

---

## Data Flow Summary

```
PHASE_FIND_SPINE
  → build spine (D1, S1-1)
  → add destIndustry to servedDests, S1-1 to servedSources
  → set destIndustry, destStation
  → phase = PHASE_BUILD_JUNCTION

PHASE_BUILD_JUNCTION
  → build left + right junctions near most recent source
  → append merge tiles to availableJunctions
  → phase = PHASE_SEARCH_AND_CONNECT

PHASE_SEARCH_AND_CONNECT
  → for each junction in availableJunctions:
      → expand search rectangle
      → if industry found (S_next):
          → build route S_next → destStation via mergeTile waypoint
          → remove junction from availableJunctions
          → add S_next to servedSources
          → phase = PHASE_BUILD_JUNCTION
          → return
      → if rectangle exceeds map: remove junction
  → if availableJunctions empty:
      → phase = PHASE_FIND_SPINE
      → networkId++
```

---

## Files Changed

| File | Change |
|------|--------|
| `freightnetwork.nut` | New file — `FreightNetwork` class |
| `main.nut` | Require `freightnetwork.nut`; call `FreightNetwork.Step()` in main loop; add `SaveStatics`/`LoadStatics`; guard freight candidates in `_ScanPlaces` |
| `trainroute.nut` | Gate existing `TryBuildNearStation` calls behind `!IsNetworkMode()` |
| `railbuilder.nut` | Extend `TryBuildNearStation` to return merge-point tiles |
