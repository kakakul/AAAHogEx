# Right-Hand Drive Bias Design

**Goal:** Bias the rail pathfinder to build double-track sections with consistent right-hand drive by extending the existing `_reverseNears` heuristic to distinguish correct-side vs wrong-side tiles.

**Architecture:** Modify `SetReverseNears()` in `RailPathFinder` to assign higher heuristic levels to wrong-side tiles (+3 offset), steering the second path builder away from the wrong side while preserving the ability to cross when terrain demands it.

**Tech Stack:** Squirrel, `pathfinder.nut`

---

## Context

The pathfinder builds double-track routes in two passes:
- **Pass 1**: builds `pathSrcToDest` (or outbound spur leg)
- **Pass 2**: receives Pass 1's path as `reversePath`, calls `SetReverseNears()` to build `_reverseNears`, and uses it in the heuristic to stay near Pass 1

`_reverseNears` currently spreads levels 0–20 symmetrically in all directions from `reversePath` tiles. The heuristic adds `_cost_guide * level` to the estimated cost, steering Pass 2 toward tiles close to Pass 1. However, it treats both sides of Pass 1 equally — there is no penalty for routing to the wrong side.

This applies to both spine builds (in `trainroute.nut`) and branch spur builds (in `freightnetwork.nut`), since both set `reversePath` on the second builder.

---

## Design

### Side Determination

In OpenTTD tile coordinates (X increases East, Y increases South):

For each `reversePath` tile with travel direction `(dx, dy)`:
- **Correct side** (right-hand drive): perpendicular direction `(-dy, dx)`
- **Wrong side**: perpendicular direction `(dy, -dx)`

This is computed per tile as the path is iterated, using the direction between consecutive tiles.

### Level Assignment in `SetReverseNears`

The spreading loop already expands outward 20 iterations from `reversePath` tiles. The change: when assigning a level to a newly reached tile, check which side of the nearest `reversePath` tile it falls on and add +3 if it is on the wrong side.

**Level table:**

| Tile position | Level |
|---|---|
| On `reversePath` | 0 |
| Correct side, distance d | d (1–20) |
| Wrong side, distance d | d + 3 (3–23) |
| Outside range (unknown) | 20 (unchanged) |

**Effect on heuristic:** `_cost_guide * level`. Being 1 tile on the wrong side (`* 4`) costs the same as being 4 tiles away on the correct side (`* 4`). The pathfinder can still cross to the wrong side when terrain forces it — the penalty is a soft bias, not a hard exclusion.

### Side Tracking During Spread

The spreading loop in `SetReverseNears` currently assigns levels without tracking direction. To implement the offset, we need to know whether each spread tile is on the wrong side of the nearest `reversePath` tile.

Approach: for each `reversePath` tile, immediately mark its wrong-side neighbour (`tile + (dy, -dx)`) in a `_wrongSideSeed` table. During spreading, if a tile originated from a `_wrongSideSeed` tile, it inherits the +3 offset. Correct-side tiles spread as now.

Concretely:
1. First pass over `reversePath`: for each tile, compute `(dx, dy)` from previous tile, add `tile + (dy, -dx)` to `_wrongSideSeed`.
2. Spreading loop: initialise two queues — `correctNears` (existing behaviour) and `wrongNears` (seeded from `_wrongSideSeed`). Spread both, assigning `distance` for correct and `distance + 3` for wrong. If a tile is reached by both, use the lower level (correct side wins).

### No Changes to Calling Code

`SetReverseNears()` is called automatically when `reversePath != null`. Both spine and spur builders already set `reversePath` correctly — no changes needed in `trainroute.nut` or `freightnetwork.nut`.

---

## Constraints

- Wrong-side offset is +3 (levels 3–23 vs 0–20 correct side).
- Soft bias only — pathfinder can still use wrong-side tiles when terrain forces it.
- Change is confined to `pathfinder.nut` — no upstream callers modified.
- Must not increase pathfinder iteration count significantly; the level values stay within the existing 0–20 range plus a small extension to 23.
