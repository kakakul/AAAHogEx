# Right-Hand Drive Bias Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bias the rail pathfinder's heuristic so the second track of a double-track section prefers the correct (right-hand drive) side by assigning higher `_reverseNears` levels to wrong-side tiles.

**Architecture:** Extend `SetReverseNears()` in `RailPathFinder` to run a second BFS from wrong-side seeds (`tile - revDir`), then post-process `_reverseNears` to add +3 to any tile where the wrong-side BFS reached it closer than the correct-side BFS did.

**Tech Stack:** Squirrel, `pathfinder.nut`

---

## File Structure

- Modify: `pathfinder.nut` — `SetReverseNears()` only

---

### Task 1: Add wrong-side penalty to `SetReverseNears`

**Goal:** Wrong-side tiles in `_reverseNears` get their level increased by 3, making the heuristic more expensive for the pathfinder to route on the wrong side.

**Files:**
- Modify: `pathfinder.nut:346-411`

**Acceptance Criteria:**
- [ ] `_reverseNears` levels are higher for tiles on the wrong side of `reversePath` than for equidistant tiles on the correct side
- [ ] Correct-side tiles are unchanged (levels 0–20 as before)
- [ ] Wrong-side tiles adjacent to the path have level ≥ 3 (were level 2 before)
- [ ] The change is confined to `SetReverseNears()` — no other methods modified

**Verify:** Reload AI in-game on a new game and observe that double-track sections (spine and branch spurs) consistently use one side for each direction. Check AI debug log shows no new errors.

**Steps:**

- [ ] **Step 1: Understand the current seed and spread pattern**

Current `SetReverseNears()` (lines 346–411 in `pathfinder.nut`):

```squirrel
// Initial path walk — seeds `nears` (correct side) at level 0
local revDir = _GetRevDir(prev, tile);   // correct-side perpendicular offset
if(d > 1) {                              // bridge/tunnel: seed intermediate tiles
    for(local i=0; i<d; i++) {
        nears.rawset(tile + i * offset + revDir, 0);
        _reverseNears.rawset(tile + i * offset + revDir, 0);
    }
} else {
    nears.rawset(tile + revDir, 0);       // correct-side seed
    _reverseNears.rawset(tile + revDir, 0);
}

// Spreading loop — fills all tiles within 20 steps at levels 1–19
for(local i=1; i<20; i++) {
    local next = {}
    foreach(tile, level in nears) {
        foreach(d in HgTile.DIR4Index) {
            if(!_reverseNears.rawin(tile+d)) {
                next.rawset(tile+d, i)
                _reverseNears.rawset(tile+d, i)
            }
        }
    }
    nears = next;
}
```

`revDir` is a tile-index offset. `tile + revDir` = correct-side adjacent tile. `tile - revDir` = wrong-side adjacent tile.

- [ ] **Step 2: Add wrong-side seed collection during path walk**

In the initial path-walk loop (the `while(path != null)` block), alongside every `nears.rawset(tile + revDir, 0)` call, also add the wrong-side tile to a new `wrongNears` table at level 0 (raw distance — the +3 is applied in the post-process step).

Replace the existing `while(path != null)` block:

```squirrel
local nears = {};
local wrongNears = {};      // new: wrong-side seeds
_reverseNears = {};
_reverseTiles = {};

local path = reversePath;
local prev = null;
local prevprev = null;
while(path != null) {
    local tile = path.GetTile();
    _reverseTiles.rawset(tile, 0);
    if(prev != null) {
        local d = AIMap.DistanceManhattan(prev, tile);
        if(d == 0) {
            HgLog.Warning("distance0 (SetReversePath)"+HgTile(prev));
        } else {
            local revDir = _GetRevDir(prev, tile);
            if(d > 1) {
                local offset;
                if(AIMap.GetTileX(prev) == AIMap.GetTileX(tile)) {
                    offset = AIMap.GetTileIndex(0, 1);
                } else {
                    offset = AIMap.GetTileIndex(1, 0);
                }
                for(local i=0; i<d; i++) {
                    nears.rawset(tile + i * offset + revDir, 0);
                    _reverseNears.rawset(tile + i * offset + revDir, 0);
                    // wrong side: opposite perpendicular
                    if(!wrongNears.rawin(tile + i * offset - revDir))
                        wrongNears.rawset(tile + i * offset - revDir, 0);
                }
            } else {
                nears.rawset(tile + revDir, 0);
                _reverseNears.rawset(tile + revDir, 0);
                // wrong side: opposite perpendicular
                if(!wrongNears.rawin(tile - revDir))
                    wrongNears.rawset(tile - revDir, 0);
                if(prevprev != null && AIMap.DistanceManhattan(prevprev,prev)==1 && prev == prevprev + revDir) {
                    nears.rawset(prev, 0);
                    _reverseNears.rawset(prev, 0);
                }
            }
        }
    }
    prevprev = prev;
    prev = tile;
    path = path.GetParent();
}
```

- [ ] **Step 3: Run correct-side spreading loop (unchanged)**

The existing spreading loop runs as-is, filling `_reverseNears` with levels 1–19 for all tiles reachable from correct-side seeds:

```squirrel
for(local i=1; i<20; i++) {
    local next = {}
    foreach(tile, level in nears) {
        foreach(d in HgTile.DIR4Index) {
            if(!_reverseNears.rawin(tile+d)) {
                next.rawset(tile+d, i)
                _reverseNears.rawset(tile+d, i)
            }
        }
    }
    nears = next;
}
```

No change here.

- [ ] **Step 4: Run wrong-side spreading loop**

After the existing spreading loop, add a second spreading loop for `wrongNears`. This fills a separate `_wrongBFS` table (raw distances, no +3 yet):

```squirrel
// Build wrong-side BFS (raw distances, no offset yet)
local _wrongBFS = {};
foreach(tile, level in wrongNears) {
    _wrongBFS.rawset(tile, 0);
}
local wrongFrontier = wrongNears;
for(local i=1; i<20; i++) {
    local next = {};
    foreach(tile, level in wrongFrontier) {
        foreach(d in HgTile.DIR4Index) {
            if(!_wrongBFS.rawin(tile+d)) {
                next.rawset(tile+d, i);
                _wrongBFS.rawset(tile+d, i);
            }
        }
    }
    wrongFrontier = next;
}
```

- [ ] **Step 5: Post-process — add +3 to wrong-side tiles**

After both spreading loops, iterate `_wrongBFS`. For each tile where wrong-side BFS reached it CLOSER than correct-side BFS did (meaning the tile is on the wrong side of the path), add 3 to its `_reverseNears` level:

```squirrel
// Penalise wrong-side tiles: if wrong BFS reached this tile closer than
// correct BFS, it's on the wrong side — raise its level by 3.
foreach(tile, wrongDist in _wrongBFS) {
    if(_reverseNears.rawin(tile)) {
        if(wrongDist < _reverseNears[tile]) {
            _reverseNears[tile] = _reverseNears[tile] + 3;
        }
    } else {
        // Tile only reachable from wrong side (beyond correct BFS range)
        _reverseNears.rawset(tile, wrongDist + 3);
    }
}
```

- [ ] **Step 6: Verify level values with a log statement (temporary)**

Add a temporary log line after the post-process step to spot-check that wrong-side tiles have higher levels. This fires once per `SetReverseNears` call — remove before committing:

```squirrel
// TEMPORARY: spot-check one wrong-side seed tile
local checkTile = wrongNears.len() > 0 ? wrongNears.begin() : -1;  // Squirrel: iterate first key
foreach(t, _ in wrongNears) {
    HgLog.Info("SetReverseNears check: wrongSeed=" + HgTile(t)
        + " level=" + (_reverseNears.rawin(t) ? _reverseNears[t].tostring() : "absent"));
    break;
}
```

Load the AI in a new game. In the debug log, confirm the reported level is ≥ 3 (ideally 5, since the wrong-side seed is 2 steps from the correct seed and the correct spread will have assigned it level 2, then +3 = 5).

- [ ] **Step 7: Remove temporary log, commit**

Remove the spot-check log added in Step 6. Confirm `SetReverseNears` compiles (no Squirrel errors on AI load).

```bash
git add pathfinder.nut
git commit -m "Bias pathfinder heuristic toward right-hand drive via wrong-side penalty in SetReverseNears"
```
