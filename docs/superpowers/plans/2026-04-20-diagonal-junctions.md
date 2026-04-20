# Diagonal Junctions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the AI to build rail junctions on diagonal track sections (NE-SW and NW-SE spines) so that branches can be added to any spine segment regardless of orientation.

**Architecture:** `RightDivergeDiagonalJunction` in `railbuilder.nut` handles all four diagonal configurations via `flipX`, `flipY`, and `rotate` flags (same interface as `RightDivergeJunction`). `FourWayJunction.TryBuildNearStation` is extended to detect diagonal parallel-track windows and attempt diagonal junctions interleaved with straight ones, preserving closest-first ordering. The return value shape (`{leftTile, rightTile, leftPath, rightPath, leftInboundPath, rightInboundPath}`) is unchanged so callers in `freightnetwork.nut` and `trainroute.nut` need no modification.

**Tech Stack:** Squirrel, OpenTTD AIRail/AIMap API, `railbuilder.nut`

---

## File Structure

- Modify: `railbuilder.nut` — `RightDivergeDiagonalJunction` (lines ~3158–3192) and `FourWayJunction.TryBuildNearStation` (lines ~3507–3690)

---

### Task 1: Implement `RightDivergeDiagonalJunction`

**Goal:** Produce a fully working `RightDivergeDiagonalJunction` class that can test-mode-check and build a diagonal junction at a given origin tile for all four flip/rotate configurations shown in the layout comments.

**Files:**
- Modify: `railbuilder.nut:3158-3192`

**Acceptance Criteria:**
- [ ] `Build(true)` (test mode) returns `true` on a flat, clear area for all four orientations
- [ ] `Build(false)` places rails and signals visible in-game for the canonical orientation
- [ ] `GetBranchEndTile()`, `GetBranchPath()`, `GetInboundBranchPath()` return tiles that form a contiguous chain in all four orientations
- [ ] No errors in the AI debug log on load

**Verify:** Load AI in a new game, trigger `Build(true)` then `Build(false)` for the canonical orientation via a temporary call in `FreightNetwork` or `SearchAndConnect`; observe rails and signals in-game.

**Steps:**

- [ ] **Step 1: Add fields, constructor, and structural stubs**

Replace the empty class body (the `}` at line 3192) with the full scaffold below. Keep all layout comments intact above it.

```squirrel
	originTile = null;
	flipX = null;
	flipY = null;
	rotate = null;

	constructor(tile, flipY_ = false, flipX_ = false, rotate_ = false) {
		this.originTile = tile;
		this.flipY = flipY_;
		this.flipX = flipX_;
		this.rotate = rotate_;
	}

	function Transform(x, y) {
		// STUB — replace with derived equations in Step 3
		return [x, y];
	}

	function TransformDir(dx, dy) {
		// STUB — replace with derived equations in Step 3
		return [dx, dy];
	}

	function At(x, y) {
		local t = Transform(x, y);
		return AIMap.GetTileIndex(
			AIMap.GetTileX(originTile) + t[0],
			AIMap.GetTileY(originTile) + t[1]);
	}

	function AtSignal(x, y) {
		local t = Transform(x, y);
		return AIMap.GetTileIndex(
			AIMap.GetTileX(originTile) + t[0],
			AIMap.GetTileY(originTile) + t[1]);
	}

	function BuildSignals(x, y, dx, dy, pbs) {
		local t = Transform(x, y);
		local fx = t[0];
		local fy = t[1];
		local d = TransformDir(dx, dy);
		local fdx = d[0];
		local fdy = d[1];
		local px = fx + fdx;
		local py = fy + fdy;
		BuildUtils.BuildSignalSafe(AtSignal(fx, fy), AtSignal(px, py), pbs);
	}

	function GetRequiredTiles() {
		// Canonical tiles from layout (flipX=false, flipY=false, rotate=false).
		// At() applies the transform for other orientations.
		return [
			[-2,-1], [-1,-1], [0,-1],
			[-1,0],  [0,0],   [1,0],  [2,0], [3,0],
			         [0,1],   [1,1],  [2,1], [3,1],
			                  [1,2],  [2,2], [3,2],
		];
	}

	function GetRails() {
		// STUB — fill in during Step 4
		return [];
	}

	function GetBranchEndTile() {
		// STUB — fill in after Step 4 testing confirms the outermost branch tip
		return At(3, 1);
	}

	function GetBranchPath() {
		// STUB — fill in after Step 4
		return [];
	}

	function GetInboundBranchPath() {
		// STUB — fill in after Step 4
		return [];
	}

	function CollectAndRemoveSignals() {
		local mapW = AIMap.GetMapSizeX();
		local saved = [];
		foreach(xy in GetRequiredTiles()) {
			local t = At(xy[0], xy[1]);
			if(!AIRail.IsRailTile(t)) continue;
			// Diagonal tiles have diagonal neighbors (±1,±1) in addition to cardinal.
			local neighbors = [
				t - 1, t + 1, t - mapW, t + mapW,
				t - mapW - 1, t - mapW + 1, t + mapW - 1, t + mapW + 1
			];
			foreach(nb in neighbors) {
				if(!AIMap.IsValidTile(nb)) continue;
				local stype = AIRail.GetSignalType(t, nb);
				if(stype != AIRail.SIGNALTYPE_NONE) {
					HgLog.Info("RightDivergeDiagonalJunction: removing signal at " + HgTile(t)
						+ " facing " + HgTile(nb) + " type=" + stype);
					saved.push([t, nb, stype]);
					BuildUtils.RemoveSignalSafe(t, nb);
				}
			}
		}
		return saved;
	}

	function RestoreSignals(saved) {
		foreach(sig in saved) {
			HgLog.Info("RightDivergeDiagonalJunction: restoring signal at " + HgTile(sig[0])
				+ " facing " + HgTile(sig[1]) + " type=" + sig[2]);
			BuildUtils.BuildSignalSafe(sig[0], sig[1], sig[2]);
		}
	}

	function Build(isTestMode = true) {
		foreach(xy in GetRequiredTiles()) {
			local t = At(xy[0], xy[1]);
			if(!HogeAI.IsBuildable(t) && !AIRail.IsRailTile(t)) {
				HgLog.Info("RightDivergeDiagonalJunction.Build: blocked at ["
					+ xy[0] + "," + xy[1] + "] " + HgTile(t)
					+ (isTestMode ? " (test)" : " (real)"));
				return false;
			}
		}

		if(isTestMode) return true;

		// Level the branch arm tiles (E-W or N-S depending on rotate).
		// Branch arm canonical tiles: (1,0)..(3,0) and (1,1)..(3,1)
		local branchTiles = [At(1,0), At(2,0), At(3,0), At(1,1), At(2,1), At(3,1)];
		local tileList = TileListUtils.GetLevelTileList(branchTiles);
		tileList.Valuate(AITile.GetCornerHeight, AITile.CORNER_N);
		local trackHeight = AITile.GetMinHeight(At(0, 0));
		local levelTrack = rotate ? AIRail.RAILTRACK_NE_SW : AIRail.RAILTRACK_NW_SE;
		if(!TileListUtils.LevelAverage(tileList, levelTrack, false, trackHeight)) {
			HgLog.Warning("RightDivergeDiagonalJunction.Build: LevelTiles failed");
			return false;
		}

		local savedSignals = CollectAndRemoveSignals();
		local builtRails = [];

		foreach(r in GetRails()) {
			local a = At(r[0][0], r[0][1]);
			local b = At(r[1][0], r[1][1]);
			local c = At(r[2][0], r[2][1]);
			if(RailBuilder.BuildRailSafe(a, b, c)) {
				builtRails.push([a, b, c]);
			} else if(AIError.GetLastError() == AIError.ERR_ALREADY_BUILT) {
				HgLog.Info("RightDivergeDiagonalJunction.Build: already built at ["
					+ r[1][0] + "," + r[1][1] + "] " + HgTile(b) + " (ok)");
			} else {
				HgLog.Warning("RightDivergeDiagonalJunction.Build: rail failed at ["
					+ r[1][0] + "," + r[1][1] + "] " + HgTile(b)
					+ " err=" + AIError.GetLastErrorString());
				foreach(built in builtRails) {
					AIRail.RemoveRail(built[0], built[1], built[2]);
				}
				RestoreSignals(savedSignals);
				return false;
			}
		}

		// Signals — fill in coordinates after Step 4 confirms rail layout
		local pbs = AIRail.SIGNALTYPE_PBS_ONEWAY;
		// TODO: BuildSignals calls (Step 5)

		HgLog.Info("RightDivergeDiagonalJunction: built at origin " + HgTile(originTile)
			+ " flipY=" + flipY + " flipX=" + flipX + " rotate=" + rotate);
		return true;
	}
```

- [ ] **Step 2: Verify the scaffold compiles**

Run the existing test suite to confirm the scaffold loads without Squirrel errors:

```bash
cd tests
pytest test_task1_railbuilder.py -v -s
```

The existing test starts the AI and checks it doesn't crash. If it crashes, fix the Squirrel syntax before proceeding.

- [ ] **Step 3: Derive Transform and TransformDir using out-of-game Python tests**

`Transform(x, y)` is pure arithmetic — it can be fully verified with a Python test, no OpenTTD needed. Write and iterate on the formula in Python first, then port the confirmed formula to Squirrel.

**Create `tests/test_transform.py`:**

```python
"""
Out-of-game unit tests for RightDivergeDiagonalJunction.Transform.

How the layout comments encode world positions:
  Each (x, y, dirs) entry in the layout comment is the WORLD OFFSET from originTile
  for that tile in that orientation. The canonical orientation is the identity:
  Transform(x, y) == (x, y).

Run with: pytest tests/test_transform.py -v
"""

def transform(x, y, flipX, flipY, rotate):
    """Candidate Transform formula — iterate until all tests pass."""
    # START: try the simplest form. Adjust based on failing cases.
    tx = y if rotate else x
    ty = x if rotate else y
    fx = -tx if flipX else tx
    fy = -ty if flipY else ty
    return (fx, fy)


# (flipY, flipX, rotate,  cx, cy,  expected_wx, expected_wy,  note)
CASES = [
    # --- Layout 1: canonical (NE→SW spine, branch West) ---
    (False, False, False,   0,  0,    0,  0,  "origin"),
    (False, False, False,  -2, -1,   -2, -1,  "far NE spine end (↗)"),
    (False, False, False,   2,  2,    2,  2,  "spine signal (↙↗S)"),
    (False, False, False,   3,  0,    3,  0,  "branch outbound far end (←)"),
    (False, False, False,   3,  1,    3,  1,  "branch inbound signal (→S)"),
    # --- Layout 2: flipX=true rotate=true (NE→SW spine, branch South) ---
    # Spine tiles at y<0 stay at the same world positions as layout 1.
    (False, True,  True,    0,  0,    0,  0,  "origin"),
    (False, True,  True,   -2, -1,   -2, -1,  "far NE spine end — same as layout 1"),
    (False, True,  True,    0, -1,    0, -1,  "spine signal (↙S) — same as layout 1"),
    (False, True,  True,    2,  2,    2,  2,  "spine signal (↙↗S) — same as layout 1"),
    # Branch arm moves. Inbound signal (↑S) is at world (0,2) in layout 2.
    # Canonical (3,1) = inbound arm signal in layout 1 → must map to (0,2) in layout 2.
    (False, True,  True,    3,  1,    0,  2,  "branch inbound signal layout1=(3,1)→layout2=(0,2)"),
    # --- Layout 3: flipX=true flipY=true rotate=false (SW→NE spine, branch East) ---
    (True,  True,  False,   0,  0,    0,  0,  "origin"),
    (True,  True,  False,  -2, -1,   -2, -1,  "far NE spine end — same as layout 1"),
    (True,  True,  False,   2,  2,    2,  2,  "spine signal — same as layout 1"),
    # Inbound signal (←S) is at world (-2,0) in layout 3.
    (True,  True,  False,   3,  1,   -2,  0,  "branch inbound signal layout1=(3,1)→layout3=(-2,0)"),
    # --- Layout 4: flipY=true flipX=false rotate=false (SE→NW spine, branch West) ---
    # Spine direction changes to ↘↖, so spine tiles DO move.
    (True,  False, False,   0,  0,    0,  0,  "origin"),
    # Canonical (-2,-1) → world (2,-1): the ↘ tile at the far SE spine end in layout 4.
    (True,  False, False,  -2, -1,    2, -1,  "far spine end layout1=(-2,-1)→layout4=(2,-1)"),
    # Canonical (2,2) → world (-2,2): the ↘↖S spine signal tile in layout 4.
    (True,  False, False,   2,  2,   -2,  2,  "spine signal layout1=(2,2)→layout4=(-2,2)"),
    # Canonical (3,1) → world (1,1): the →S inbound branch signal in layout 4.
    (True,  False, False,   3,  1,    1,  1,  "branch inbound signal layout1=(3,1)→layout4=(1,1)"),
]


def test_transform_cases():
    failures = []
    for flipY, flipX, rotate, cx, cy, ewx, ewy, note in CASES:
        actual = transform(cx, cy, flipX, flipY, rotate)
        expected = (ewx, ewy)
        if actual != expected:
            failures.append(
                f"FAIL flipY={flipY} flipX={flipX} rotate={rotate} "
                f"Transform({cx},{cy})={actual} expected={expected}  [{note}]"
            )
    if failures:
        raise AssertionError("Transform mismatches:\n" + "\n".join(failures))
```

**How to iterate:**

Run `pytest tests/test_transform.py -v`. Each failure line shows `actual=(...) expected=(...)`. Read the pattern:
- If the actual x and y are swapped: the `rotate` axis-swap direction is wrong.
- If a sign is wrong on one axis: one of the `flipX`/`flipY` negation conditions is inverted.
- Adjust only the `transform()` function in the test file, re-run, repeat.

**Layout 4 caveat:** The expected values for layout 4 rows are role-matched (same functional tile across orientations) and may be off if the origin convention differs. If layouts 1–3 pass but layout 4 rows fail, re-read each failing tile from the layout 4 comment in `railbuilder.nut`, compute the expected world offset directly, and update those three expected values in the test.

Once all rows pass, **port the confirmed formula to Squirrel** in `Transform` and `TransformDir`. `TransformDir` uses the same axis swap and sign flip with no additive constants.

- [ ] **Step 4: Derive GetRails, GetBranchEndTile, GetBranchPath, GetInboundBranchPath**

With `Transform` working, identify the rail connections from the canonical layout comment. Each connection is a `[prev, cur, next]` triple where prev/cur and cur/next are adjacent tiles in the canonical layout (diagonally adjacent for spine track: |dx|=|dy|=1; straight-adjacent for branch track: Manhattan distance = 1).

Enumerate the connections by grouping tiles that share a track direction:

- **Diagonal spine track going SW (↙):** tiles (0,-1), (0,0), (1,1), (2,2) — read off triples from consecutive triplets.
- **Diagonal spine track going NE (↗):** tiles (-2,-1), (-1,-1) / (-1,0), (0,1), (1,2), (2,2) — same process.
- **E-W branch outbound (←):** tiles (3,0), (2,0), (1,0), (0,0) — triples for straight E-W connections.
- **E-W branch inbound (→):** tiles (3,1), (2,1), (1,1), (0,1) — triples for straight E-W connections.
- **Merge/diverge tiles** ((0,0), (1,1)): these have multiple track bits, so they will appear in multiple triples.

Add all triples to `GetRails()` and trigger `Build(false)` in-game. Examine which tracks appear on the map and which are missing. Add or remove triples until the track layout visually matches the layout comment.

After `GetRails()` produces the correct visual layout, identify:
- `GetBranchEndTile()`: the outer tip of the branch arm. For "branch West", this is the westernmost rail tile accessible from the branch — likely `At(3,0)` or `At(3,1)` depending on which arm the pathfinder connects to. Check which tile lies on the outbound arm (trains leaving spine) and which on the inbound arm (trains joining spine).
- `GetBranchPath()`: outbound arm — starts at the outer tip, ends at the deepest spine tile. Outermost-first (the same order as `RightDivergeJunction.GetBranchPath`).
- `GetInboundBranchPath()`: inbound arm — starts at outer tip, ends at deepest spine tile.

Verify both paths form a contiguous chain by logging each tile: consecutive tiles in the chain must be adjacent.

- [ ] **Step 5: Add signal placements to Build()**

With `GetRails()` working, identify the signal tiles from the layout comment (marked `S`). For each signal tile, call `BuildSignals(x, y, dx, dy, pbs)` where `(dx,dy)` is the direction of travel through that tile.

From the canonical layout:
- `(0,-1,↙S)`: signal on the SW-bound spine track just above the merge — direction is (dx,dy) pointing SW along the spine.
- `(3,1,→S)`: signal on the inbound branch just before merge — direction is (dx,dy) pointing East (→).
- `(2,2,↙↗S)`: signal on the diagonal spine below the junction — direction depends on which train direction this signal controls.

Add `BuildSignals` calls in `Build()` after the rail loop, replacing the `// TODO` comment. Test in-game: signals should appear on the correct tiles facing the correct direction. If a signal appears on the wrong tile or faces the wrong way, adjust the `(x,y,dx,dy)` arguments.

Signal chirality correction (odd-reflection flip) is deferred to a later testing phase — if signals appear on the wrong side of the track, that fix goes in `BuildSignals`.

- [ ] **Step 6: Remove probe code and commit**

Remove the temporary probe block added in Step 2 and all temporary log lines added in Steps 2–4.

```bash
git add railbuilder.nut
git commit -m "Implement RightDivergeDiagonalJunction with all four orientations"
```

---

### Task 2: Extend `FourWayJunction.TryBuildNearStation` for diagonal track

**Goal:** Detect diagonal parallel-track windows in the path tile arrays and attempt `RightDivergeDiagonalJunction` at valid locations, interleaved with existing straight-junction attempts so the closest-first ordering is preserved.

**Files:**
- Modify: `railbuilder.nut:3507-3690` (`FourWayJunction.TryBuildNearStation`)

**Acceptance Criteria:**
- [ ] Straight junctions are still built on straight track (no regression)
- [ ] Diagonal junctions are attempted when consecutive path tiles form a diagonal run with a parallel diagonal track
- [ ] The junction closest to the station is built first (diagonal and straight candidates compete at each `i`)
- [ ] `result.leftTile`, `result.rightTile` etc. are populated from diagonal builds the same as from straight builds

**Verify:** Run a new game where the spine is diagonal. Observe that `FourWayJunction.TryBuildNearStation: tried=` logs appear and that a diagonal junction is built on-map.

**Steps:**

- [ ] **Step 1: Add a helper to detect diagonal window and compute flipX/flipY/rotate**

Add a new static helper inside `FourWayJunction` just before `TryBuildNearStation`:

```squirrel
// Returns null if the 6-tile window [mm1..m4] is not a valid diagonal run with a parallel tile at consistent diagonal offset.
// Returns {flipY, flipX, rotate, offset} if valid.
static function _CheckDiagonalWindow(mm1, m0, m1, m2, m3, m4, p2Set) {
    // Determine step direction from m0→m1
    local stepX = AIMap.GetTileX(m1) - AIMap.GetTileX(m0);
    local stepY = AIMap.GetTileY(m1) - AIMap.GetTileY(m0);

    // Must be a diagonal step: |stepX|=1 AND |stepY|=1
    if(stepX != 1 && stepX != -1) return null;
    if(stepY != 1 && stepY != -1) return null;

    // All 6 tiles must be consecutive with the same step
    local tiles = [mm1, m0, m1, m2, m3, m4];
    for(local k = 1; k < tiles.len(); k++) {
        if(AIMap.GetTileX(tiles[k]) - AIMap.GetTileX(tiles[k-1]) != stepX) return null;
        if(AIMap.GetTileY(tiles[k]) - AIMap.GetTileY(tiles[k-1]) != stepY) return null;
    }

    // Perpendicular offset for a diagonal: rotate step 90°
    // For step (+1,+1): perpendicular is (+1,-1) or (-1,+1)
    // For step (+1,-1): perpendicular is (+1,+1) or (-1,-1)
    // For step (-1,+1): perpendicular is (+1,+1) or (-1,-1)
    // For step (-1,-1): perpendicular is (+1,-1) or (-1,+1)
    local perpX = stepY;   // 90° clockwise rotation of (stepX,stepY)
    local perpY = -stepX;

    // Check m0..m3 all have a parallel tile at the same perpendicular offset
    local offset = null;
    local parallelOk = true;
    foreach(mt in [m0, m1, m2, m3]) {
        local found = false;
        foreach(sign in [-1, 1]) {
            local candidate = AIMap.GetTileIndex(
                AIMap.GetTileX(mt) + sign * perpX,
                AIMap.GetTileY(mt) + sign * perpY);
            if(p2Set.rawin(candidate)) {
                if(offset == null) offset = sign;
                if(sign == offset) { found = true; break; }
            }
        }
        if(!found) { parallelOk = false; break; }
    }
    if(!parallelOk) return null;

    // Level check: all 4 main + parallel tiles at same height
    local baseHeight = AITile.GetMinHeight(m1);
    local levelOk = true;
    foreach(mt in [mm1, m0, m1, m2, m3]) {
        if(AITile.GetMinHeight(mt) != baseHeight) { levelOk = false; break; }
        local par = AIMap.GetTileIndex(
            AIMap.GetTileX(mt) + offset * perpX,
            AIMap.GetTileY(mt) + offset * perpY);
        if(AITile.GetMinHeight(par) != baseHeight) { levelOk = false; break; }
    }
    if(!levelOk) return null;

    // Map step direction + parallel offset sign to flipX/flipY/rotate.
    // Derive this mapping by correlating the four layout orientations with their
    // spine step directions and branch side. Fill in the table below during testing (Step 3).
    //
    // Known from layout comments:
    //   NE→SW spine (stepX=-1,stepY=+1 going SW), branch West  → flipY=false, flipX=false, rotate=false
    //   NE→SW spine (stepX=-1,stepY=+1 going SW), branch South → flipY=false, flipX=true,  rotate=true
    //   SW→NE spine (stepX=+1,stepY=-1 going NE), branch East  → flipY=true,  flipX=true,  rotate=false
    //   SE→NW spine (stepX=-1,stepY=-1 going NW), branch West  → flipY=true,  flipX=false, rotate=false
    //
    // "branch West" vs "branch South" for the same spine direction is determined by
    // which side the parallel track is on (offset sign). Derive the sign-to-flipX/rotate
    // mapping empirically in Step 3.
    //
    // STUB — replace with derived mapping:
    local flipY = false;
    local flipX = false;
    local rotate = false;
    // TODO: set flipY, flipX, rotate from stepX, stepY, offset

    return {flipY = flipY, flipX = flipX, rotate = rotate, offset = offset,
            perpX = perpX, perpY = perpY};
}
```

- [ ] **Step 2: Call `_CheckDiagonalWindow` inside the main scan loop**

Inside `TryBuildNearStation`, at the end of each loop iteration (after the existing straight-junction attempt block but within the `for(local i = ...)` loop), add:

```squirrel
			// --- Try diagonal junction ---
			if(leftTile == -1 || rightTile == -1) {
				local diagInfo = FourWayJunction._CheckDiagonalWindow(
					mm1, m0, m1, m2, m3, m4, p2Set);
				if(diagInfo != null) {
					local pm1 = AIMap.GetTileIndex(
						AIMap.GetTileX(m1) + diagInfo.offset * diagInfo.perpX,
						AIMap.GetTileY(m1) + diagInfo.offset * diagInfo.perpY);
					// origin = the tile with lower x+y (consistent convention, adjust if needed)
					local origin = (AIMap.GetTileX(m1) + AIMap.GetTileY(m1)
					              < AIMap.GetTileX(pm1) + AIMap.GetTileY(pm1))
					              ? m1 : pm1;

					HgLog.Info("FourWayJunction.Try diagonal: i=" + i
						+ " origin=" + HgTile(origin)
						+ " flipY=" + diagInfo.flipY
						+ " flipX=" + diagInfo.flipX
						+ " rotate=" + diagInfo.rotate);

					if(rightTile == -1) {
						local rj = RightDivergeDiagonalJunction(
							origin, diagInfo.flipY, diagInfo.flipX, diagInfo.rotate);
						if(rj.Build(true)) {
							if(rj.Build(false)) {
								HgLog.Info("RightDivergeDiagonalJunction built at "
									+ HgTile(origin));
								rightTile = rj.GetBranchEndTile();
								rightPath = rj.GetBranchPath();
								rightInboundPath = rj.GetInboundBranchPath();
							}
						}
					}
					if(leftTile == -1) {
						// Left = opposite branch side: invert the offset by flipping relevant flag.
						// Derive the correct flag inversion in Step 3 — placeholder: toggle flipX
						local lj = RightDivergeDiagonalJunction(
							origin, diagInfo.flipY, !diagInfo.flipX, diagInfo.rotate);
						if(lj.Build(true)) {
							if(lj.Build(false)) {
								HgLog.Info("RightDivergeDiagonalJunction (left) built at "
									+ HgTile(origin));
								leftTile = lj.GetBranchEndTile();
								leftPath = lj.GetBranchPath();
								leftInboundPath = lj.GetInboundBranchPath();
							}
						}
					}
				}
			}
```

- [ ] **Step 3: Derive and fill in the flipX/flipY/rotate mapping**

Load the AI in a game with a diagonal spine. The log will show "FourWayJunction.Try diagonal: i=..." with the current (stub) flip values. The diagonal junction will either build correctly or be misoriented.

For each of the four step+offset combinations, test whether the built junction matches the layout comment for that orientation. Iterate on the mapping table in `_CheckDiagonalWindow` and the left-branch flag inversion in the loop until all four orientations build correctly.

Verify:
- Trains running SW along the spine diverge onto the branch correctly
- Trains running NE along the spine merge from the branch correctly
- Both left and right junctions build on the correct side of the spine

Also verify that `nearSrc` inversion (applied in the straight case via `if(nearSrc) flipY = !flipY`) is needed or not for diagonal — if junctions near the source station are mirrored, add the same inversion.

- [ ] **Step 4: Commit**

```bash
git add railbuilder.nut
git commit -m "Extend FourWayJunction to detect and build diagonal junctions"
```
