# Strategy C — Freight Network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Strategy C — a spine-and-tree freight network builder that runs in network mode, selecting a high-value spine route and recursively attaching new sources via pre-built junctions.

**Architecture:** A new static class `FreightNetwork` (in `freightnetwork.nut`) drives all Strategy C logic via a phase state machine (Find Spine → Build Junctions → Search & Connect). It replaces the existing `_ScanPlaces` freight path in network mode. Save/load is handled via `FreightNetwork.SaveStatics` / `LoadStatics` wired into the existing `HogeAI.Save()` / `DoLoad()` chain.

**Tech Stack:** Squirrel (OpenTTD AI), OpenTTD AILib API, Python + OpenTTDLab for automated testing. OpenTTD version: **15.3**. AI name: **HogNet**. All tests use `pytest` and are run from the project root.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `freightnetwork.nut` | Create | `FreightNetwork` class — all Strategy C logic and state |
| `railbuilder.nut` | Modify | Add `GetBranchEndTile()` to `RightDivergeJunction`; change `TryBuildNearStation` to return merge tiles |
| `trainroute.nut` | Modify | Gate existing `TryBuildNearStation` calls behind `!IsNetworkMode()` |
| `main.nut` | Modify | `require` new file; wire Save/Load; add case 5 in `DoStep()`; guard freight in `_ScanPlaces` |
| `tests/conftest.py` | Create | Shared OpenTTDLab fixtures |
| `tests/test_task1_railbuilder.py` | Create | Standalone test for Task 1 |
| `tests/test_integration.py` | Create | Cumulative integration test for Tasks 2–6 |

---

## Task 0: Test infrastructure setup

**Files:**
- Create: `tests/conftest.py`
- Create: `tests/test_task1_railbuilder.py` (empty placeholder)
- Create: `tests/test_integration.py` (empty placeholder)

- [ ] **Step 1: Create `tests/conftest.py`**

```python
# tests/conftest.py
import os
import pytest
from openttdlab import run_experiments, local_folder

AI_FOLDER = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
OPENTTD_VERSION = '15.3'
SEED = 42


def run_hognet(network_mode=0, days=365 * 3, extra_params=()):
    """Run HogNet headlessly and return the last result row."""
    params = (('network_mode', str(network_mode)),
              ('usable_cargos', '2'),        # freight only — speeds up freight route building
              ('IsForceToHandleFright', '1')) + extra_params
    results = list(run_experiments(
        openttd_version=OPENTTD_VERSION,
        experiments=({
            'seed': SEED,
            'ais': (local_folder(AI_FOLDER, 'HogNet', ai_params=params),),
            'days': days,
        },),
    ))
    assert results, "run_experiments returned no results"
    return results[0]
```

- [ ] **Step 2: Create empty test placeholder files**

```python
# tests/test_task1_railbuilder.py
# Tests added in Task 1
```

```python
# tests/test_integration.py
# Tests grow cumulatively through Tasks 2-6
```

- [ ] **Step 3: Verify pytest discovers files**

Run: `pytest tests/ --collect-only`
Expected: no errors, two test files collected (with 0 tests each — that's fine for now).

- [ ] **Step 4: Commit**

```bash
git add tests/conftest.py tests/test_task1_railbuilder.py tests/test_integration.py
git commit -m "Add OpenTTDLab test infrastructure"
```

---

## Task 1: Add `GetBranchEndTile()` and update `TryBuildNearStation` return value; gate in `trainroute.nut`

**Files:**
- Modify: `railbuilder.nut` (around line 3158 for `RightDivergeJunction`, around line 3392 for `TryBuildNearStation`)
- Modify: `trainroute.nut` (lines 3209–3218)
- Modify: `tests/test_task1_railbuilder.py`

The outer end of the diagonal branch is always at junction-local coordinate `(3, 1)` — the `At()` transform handles all flip/rotate variants. Change `TryBuildNearStation` to return `{leftTile, rightTile}` (each is a tile integer, -1 if not built). Gate the existing callers in `trainroute.nut` with `!IsNetworkMode()`.

- [ ] **Step 1: Add `GetBranchEndTile()` to `RightDivergeJunction`**

Read `railbuilder.nut` lines 3195–3200 to confirm the constructor, then add after it:

```squirrel
	function GetBranchEndTile() {
		// The outer end of the diagonal branch is at junction-local (3,1).
		// At() applies flipX/flipY/rotate so this is correct for all orientations.
		return At(3, 1);
	}
```

- [ ] **Step 2: Update `TryBuildNearStation` tracking variables**

Read `railbuilder.nut` lines 3392–3400. Replace:
```squirrel
		local leftBuilt = false;
		local rightBuilt = false;
```
with:
```squirrel
		local leftTile = -1;
		local rightTile = -1;
```

- [ ] **Step 3: Update the break condition**

In the same function, replace:
```squirrel
			if(leftBuilt && rightBuilt) break;
```
with:
```squirrel
			if(leftTile != -1 && rightTile != -1) break;
```

- [ ] **Step 4: Update the right-junction build guard and success recording**

Replace:
```squirrel
			if(!rightBuilt) {
				local rightJ = RightDivergeJunction(origin, flipY, flipY, rotate);
				if(rightJ.Build(true)) {
					if(rightJ.Build(false)) {
						HgLog.Info("RightDivergeJunction built at " + HgTile(origin)
							+ " flipY=" + flipY);
						rightBuilt = true;
					}
```
with:
```squirrel
			if(rightTile == -1) {
				local rightJ = RightDivergeJunction(origin, flipY, flipY, rotate);
				if(rightJ.Build(true)) {
					if(rightJ.Build(false)) {
						HgLog.Info("RightDivergeJunction built at " + HgTile(origin)
							+ " flipY=" + flipY);
						rightTile = rightJ.GetBranchEndTile();
					}
```

- [ ] **Step 5: Update the left-junction build guard and success recording**

Replace:
```squirrel
			if(!leftBuilt) {
				local leftJ = RightDivergeJunction(origin, flipY, !flipY, rotate);
				if(leftJ.Build(true)) {
					if(leftJ.Build(false)) {
						HgLog.Info("LeftDivergeJunction built at " + HgTile(origin)
							+ " flipY=" + flipY);
						leftBuilt = true;
					}
```
with:
```squirrel
			if(leftTile == -1) {
				local leftJ = RightDivergeJunction(origin, flipY, !flipY, rotate);
				if(leftJ.Build(true)) {
					if(leftJ.Build(false)) {
						HgLog.Info("LeftDivergeJunction built at " + HgTile(origin)
							+ " flipY=" + flipY);
						leftTile = leftJ.GetBranchEndTile();
					}
```

- [ ] **Step 6: Update the final log and return**

Replace:
```squirrel
		HgLog.Info("FourWayJunction.TryBuildNearStation: tried=" + tried
			+ " left=" + leftBuilt + " right=" + rightBuilt);
		return leftBuilt || rightBuilt;
```
with:
```squirrel
		HgLog.Info("FourWayJunction.TryBuildNearStation: tried=" + tried
			+ " leftTile=" + leftTile + " rightTile=" + rightTile);
		return {leftTile = leftTile, rightTile = rightTile};
```

- [ ] **Step 7: Gate `TryBuildNearStation` calls in `trainroute.nut`**

Read `trainroute.nut` lines 3209–3218. Replace the condition that opens the junction-building block. Currently it starts with:
```squirrel
		if(!useSingle && !CargoUtils.IsPaxOrMail(cargo)
```
Add the network mode guard:
```squirrel
		if(!useSingle && !CargoUtils.IsPaxOrMail(cargo)
			&& !HogeAI.Get().IsNetworkMode()) {
```
Also add the closing `}` to match. Read the full block first to confirm exact indentation and structure before editing.

- [ ] **Step 8: Write the standalone test**

```python
# tests/test_task1_railbuilder.py
from conftest import run_hognet


def test_trybuildn_returns_merge_tiles_non_network_mode():
    """In non-network mode, TryBuildNearStation should still run and log merge tiles."""
    row = run_hognet(network_mode=0, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'TryBuildNearStation: tried=' in row['output'], (
        "Expected TryBuildNearStation to run in non-network mode"
    )
    # New return format: leftTile= instead of left=
    assert 'leftTile=' in row['output'], (
        "Expected new leftTile= format in TryBuildNearStation log"
    )
```

- [ ] **Step 9: Run the test**

Run: `pytest tests/test_task1_railbuilder.py -v`
Expected: `PASSED`

- [ ] **Step 10: Commit**

```bash
git add railbuilder.nut trainroute.nut tests/test_task1_railbuilder.py
git commit -m "Return merge tiles from TryBuildNearStation; skip junctions in network mode"
```

---

## Task 2: Create `freightnetwork.nut` skeleton and wire into `main.nut`

**Files:**
- Create: `freightnetwork.nut`
- Modify: `main.nut`
- Modify: `tests/test_integration.py`

- [ ] **Step 1: Create `freightnetwork.nut`**

```squirrel
// freightnetwork.nut
// Strategy C freight network builder. Network mode only.

class FreightNetwork {
	static PHASE_FIND_SPINE = 0;
	static PHASE_BUILD_JUNCTION = 1;
	static PHASE_SEARCH_AND_CONNECT = 2;

	static phase = 0;
	// Active destination industry ID, null when no network is active
	static destIndustry = null;
	// Place object for the destination (re-derived on load)
	static destPlace = null;
	// Available junction merge tiles: array of {leftTile, rightTile, srcIndustry,
	//   primaryRadius, perpOutRadius, perpInRadius}
	static availableJunctions = [];
	// Increments each time a new spine network starts
	static networkId = 0;
	// Industry IDs already serving as sources (across all networks, never cleared)
	static servedSources = {};
	// Industry IDs already serving as destinations (across all networks, never cleared)
	static servedDests = {};
	// The most recently built route, used by PHASE_BUILD_JUNCTION
	static lastBuiltRoute = null;
}

	function FreightNetwork::Step() {
		switch(FreightNetwork.phase) {
			case FreightNetwork.PHASE_FIND_SPINE:
				FreightNetwork.FindSpine();
				break;
			case FreightNetwork.PHASE_BUILD_JUNCTION:
				FreightNetwork.BuildJunctions();
				break;
			case FreightNetwork.PHASE_SEARCH_AND_CONNECT:
				FreightNetwork.SearchAndConnect();
				break;
		}
	}

	function FreightNetwork::SaveStatics(table) {
		local junctions = [];
		foreach(j in FreightNetwork.availableJunctions) {
			junctions.push({
				leftTile = j.leftTile,
				rightTile = j.rightTile,
				srcIndustry = j.srcIndustry,
				primaryRadius = j.primaryRadius,
				perpOutRadius = j.perpOutRadius,
				perpInRadius = j.perpInRadius
			});
		}
		table.freightNetwork <- {
			phase = FreightNetwork.phase,
			destIndustry = FreightNetwork.destIndustry,
			availableJunctions = junctions,
			networkId = FreightNetwork.networkId,
			servedSources = FreightNetwork.servedSources,
			servedDests = FreightNetwork.servedDests
		};
	}

	function FreightNetwork::LoadStatics(data) {
		if(!data.rawin("freightNetwork")) return;
		local fn = data.freightNetwork;
		FreightNetwork.phase = fn.phase;
		FreightNetwork.destIndustry = fn.destIndustry;
		FreightNetwork.networkId = fn.networkId;
		FreightNetwork.servedSources = fn.servedSources;
		FreightNetwork.servedDests = fn.servedDests;
		FreightNetwork.availableJunctions = [];
		foreach(j in fn.availableJunctions) {
			FreightNetwork.availableJunctions.push({
				leftTile = j.leftTile,
				rightTile = j.rightTile,
				srcIndustry = j.srcIndustry,
				primaryRadius = j.rawin("primaryRadius") ? j.primaryRadius : 0,
				perpOutRadius = j.rawin("perpOutRadius") ? j.perpOutRadius : 0,
				perpInRadius = j.rawin("perpInRadius") ? j.perpInRadius : 0
			});
		}
		FreightNetwork.destPlace = null;
		if(FreightNetwork.destIndustry != null) {
			FreightNetwork.destPlace = Place.Get(
				AIIndustry.GetLocation(FreightNetwork.destIndustry));
		}
		FreightNetwork.lastBuiltRoute = null;
	}

	function FreightNetwork::FindSpine() {
		HgLog.Info("FreightNetwork.FindSpine: stub");
		// Implemented in Task 4
	}

	function FreightNetwork::BuildJunctions() {
		HgLog.Info("FreightNetwork.BuildJunctions: stub");
		// Implemented in Task 5
		FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
	}

	function FreightNetwork::SearchAndConnect() {
		HgLog.Info("FreightNetwork.SearchAndConnect: stub");
		// Implemented in Task 6
	}
```

- [ ] **Step 2: Add `require` in `main.nut`**

Read `main.nut` lines 1–15. After `require("railbuilder.nut");` add:
```squirrel
require("freightnetwork.nut");
```

- [ ] **Step 3: Add case 5 in `DoStep()` and expand loop bound**

Read `main.nut` lines 838–855. After case 4, add:
```squirrel
		case 5:
			if(IsNetworkMode()) FreightNetwork.Step();
			break;
```

Read `main.nut` line 752. Change:
```squirrel
			while(indexPointer < (IsNetworkMode() ? 5 : 4)) {
```
to:
```squirrel
			while(indexPointer < (IsNetworkMode() ? 6 : 4)) {
```

- [ ] **Step 4: Wire `SaveStatics` / `LoadStatics`**

Read `main.nut` lines 4391–4395. After `TrainRoute.SaveStatics(table);` add:
```squirrel
		FreightNetwork.SaveStatics(table);
```

Read `main.nut` lines 4479–4485. After `TrainRoute.LoadStatics(loadData);` add:
```squirrel
		FreightNetwork.LoadStatics(loadData);
```

- [ ] **Step 5: Add integration test — skeleton**

```python
# tests/test_integration.py
from conftest import run_hognet


def test_freight_network_skeleton():
    """FreightNetwork skeleton is loaded and Step() runs without crash."""
    row = run_hognet(network_mode=1, days=365 * 1)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.FindSpine: stub' in row['output'], (
        "Expected FreightNetwork.Step() to run in network mode"
    )
```

- [ ] **Step 6: Run the test**

Run: `pytest tests/test_integration.py::test_freight_network_skeleton -v`
Expected: `PASSED`

- [ ] **Step 7: Commit**

```bash
git add freightnetwork.nut main.nut tests/test_integration.py
git commit -m "Add FreightNetwork skeleton wired into main loop and save/load"
```

---

## Task 3: Guard freight candidates in `_ScanPlaces`

**Files:**
- Modify: `main.nut`
- Modify: `tests/test_integration.py`

- [ ] **Step 1: Add freight guard in the candidate loop**

Read `main.nut` lines 1222–1230 to find `while(routeCandidates.Count() >= 1)` and the `local t = routeCandidates.Pop();` line. Add immediately after it:

```squirrel
			// In network mode, freight is handled exclusively by FreightNetwork.Step()
			if(IsNetworkMode() && t.rawin("cargo") && !CargoUtils.IsPaxOrMail(t.cargo)
					&& t.vehicleType == AIVehicle.VT_RAIL) {
				continue;
			}
```

- [ ] **Step 2: Add assertion to integration test**

Add to `tests/test_integration.py`:

```python
def test_freight_skipped_in_scanplaces():
    """In network mode, ScanPlaces must not build freight rail via the old path."""
    row = run_hognet(network_mode=1, days=365 * 2)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    # TryBuildNearStation must NOT appear — freight junctions are now FreightNetwork's job
    assert 'TryBuildNearStation: tried=' not in row['output'], (
        "TryBuildNearStation should not run in network mode"
    )
    # FreightNetwork stubs should still appear
    assert 'FreightNetwork.FindSpine: stub' in row['output']
```

- [ ] **Step 3: Run the tests**

Run: `pytest tests/test_integration.py -v`
Expected: both tests `PASSED`

- [ ] **Step 4: Commit**

```bash
git add main.nut tests/test_integration.py
git commit -m "Skip freight rail candidates in _ScanPlaces when in network mode"
```

---

## Task 4: Implement C1 — `FindSpine()`

**Files:**
- Modify: `freightnetwork.nut`
- Modify: `tests/test_integration.py`

C1 scans industry pairs for the best spine route, reusing `HogeAI.Get().GetMaxCargoPlaces()` and `CreateRouteCandidates()` from `main.nut`.

- [ ] **Step 1: Add `GetMapEdgeDist()` helper**

Add below the class definition in `freightnetwork.nut`:

```squirrel
	function FreightNetwork::GetMapEdgeDist(tile, isNS) {
		// Minimum distance from tile to either of the two relevant map edges.
		// isNS=true: top/bottom edges (Y axis). isNS=false: left/right (X axis).
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		if(isNS) {
			local y = AIMap.GetTileY(tile);
			return min(y, mapH - 1 - y);
		} else {
			local x = AIMap.GetTileX(tile);
			return min(x, mapW - 1 - x);
		}
	}
```

- [ ] **Step 2: Replace `FindSpine()` stub**

```squirrel
	function FreightNetwork::FindSpine() {
		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		local mapLongSide = max(mapW, mapH);
		local isNS = (mapH >= mapW);
		local twentyPct = (mapLongSide * 20) / 100;
		local coastBand = (mapLongSide * 25) / 100;
		local maxRouteDist = (mapLongSide * 20) / 100;

		HgLog.Info("FreightNetwork.FindSpine: isNS=" + isNS
			+ " twentyPct=" + twentyPct + " maxRouteDist=" + maxRouteDist);

		// Collect candidate (src, dest, cargo) pairs using existing machinery.
		// GetMaxCargoPlaces() returns [{place, cargo, production, maxValue}, ...]
		local cargoPlaces = ai.GetMaxCargoPlaces();

		local candidates = [];
		foreach(srcInfo in cargoPlaces) {
			if(CargoUtils.IsPaxOrMail(srcInfo.cargo)) continue;
			local srcLoc = srcInfo.place.GetLocation();
			local srcIndustry = AIIndustry.GetIndustryID(srcLoc);
			if(srcIndustry == AIIndustry.INDUSTRY_INVALID) continue;
			if(FreightNetwork.servedSources.rawin(srcIndustry)) continue;

			// CreateRouteCandidates yields {place, estimate, score, distance, production, ...}
			foreach(destInfo in ai.CreateRouteCandidates(
					srcInfo.cargo, srcInfo.place,
					{searchProducing = false}, 0, 4, {})) {
				if(destInfo.estimate == null) continue;
				local destLoc = destInfo.place.GetLocation();
				local destIndustry = AIIndustry.GetIndustryID(destLoc);
				if(destIndustry == AIIndustry.INDUSTRY_INVALID) continue;
				if(FreightNetwork.servedDests.rawin(destIndustry)) continue;

				// Dest must be near a coast
				local destEdgeDist = FreightNetwork.GetMapEdgeDist(destLoc, isNS);
				if(destEdgeDist > coastBand) continue;

				// Route length filter
				local dist = AIMap.DistanceManhattan(srcLoc, destLoc);
				if(dist > maxRouteDist || dist == 0) continue;

				local srcEdgeDist = FreightNetwork.GetMapEdgeDist(srcLoc, isNS);
				// Score: high = src far from edge (capped at 20%), dest close to edge
				local score = (min(srcEdgeDist, twentyPct) * 1000) / (destEdgeDist + 1);
				candidates.push({
					srcPlace = srcInfo.place,
					destPlace = destInfo.place,
					srcIndustry = srcIndustry,
					destIndustry = destIndustry,
					cargo = srcInfo.cargo,
					estimate = destInfo.estimate,
					score = score,
					value = destInfo.estimate.value
				});
			}
		}

		if(candidates.len() == 0) {
			HgLog.Info("FreightNetwork.FindSpine: no candidates found");
			return;
		}

		// Sort by value descending for percentile filter
		candidates.sort(function(a, b) { return b.value - a.value; });

		// Widen percentile from 10% until a candidate is selected
		local selected = null;
		for(local pct = 10; pct <= 100 && selected == null; pct += 10) {
			local threshold = max(1, candidates.len() * pct / 100);
			for(local i = 0; i < threshold && selected == null; i++) {
				selected = candidates[i];
			}
		}

		if(selected == null) {
			HgLog.Info("FreightNetwork.FindSpine: no candidate survived filters");
			return;
		}

		HgLog.Info("FreightNetwork.FindSpine: selected src="
			+ AIIndustry.GetName(selected.srcIndustry)
			+ " dest=" + AIIndustry.GetName(selected.destIndustry)
			+ " score=" + selected.score + " value=" + selected.value);

		// Build route using the existing machinery
		local t = {
			src = selected.srcPlace,
			dest = selected.destPlace,
			cargo = selected.cargo,
			vehicleType = AIVehicle.VT_RAIL,
			estimate = selected.estimate,
			score = selected.score,
			isBiDirectional = false
		};
		local builder = ai.CreateBuilder(t, [], {}, AIDate.GetCurrentDate() + 600);
		if(builder == null) {
			HgLog.Warning("FreightNetwork.FindSpine: CreateBuilder returned null");
			return;
		}
		local newRoutes = builder.Build();
		if(newRoutes == null) newRoutes = [];
		if(typeof newRoutes != "array") newRoutes = [newRoutes];
		if(newRoutes.len() == 0) {
			HgLog.Warning("FreightNetwork.FindSpine: Build failed");
			return;
		}

		FreightNetwork.destIndustry = selected.destIndustry;
		FreightNetwork.destPlace = selected.destPlace;
		FreightNetwork.servedDests.rawset(selected.destIndustry, true);
		FreightNetwork.servedSources.rawset(selected.srcIndustry, true);
		FreightNetwork.lastBuiltRoute = newRoutes[0];
		FreightNetwork.phase = FreightNetwork.PHASE_BUILD_JUNCTION;
		HgLog.Info("FreightNetwork.FindSpine: spine built, advancing to PHASE_BUILD_JUNCTION");
	}
```

- [ ] **Step 3: Add assertion to integration test**

Add to `tests/test_integration.py`:

```python
def test_spine_built():
    """C1 must select an industry pair and build the spine route."""
    row = run_hognet(network_mode=1, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.FindSpine: spine built' in row['output'], (
        "Expected spine route to be built"
    )
    assert 'advancing to PHASE_BUILD_JUNCTION' in row['output']
```

- [ ] **Step 4: Run the tests**

Run: `pytest tests/test_integration.py -v`
Expected: all three tests `PASSED`

- [ ] **Step 5: Commit**

```bash
git add freightnetwork.nut tests/test_integration.py
git commit -m "Implement C1 FindSpine: select and build spine freight route"
```

---

## Task 5: Implement C2 — `BuildJunctions()`

**Files:**
- Modify: `freightnetwork.nut`
- Modify: `tests/test_integration.py`

- [ ] **Step 1: Replace `BuildJunctions()` stub**

```squirrel
	function FreightNetwork::BuildJunctions() {
		local route = FreightNetwork.lastBuiltRoute;
		if(route == null) {
			HgLog.Warning("FreightNetwork.BuildJunctions: lastBuiltRoute is null, skipping");
			FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
			return;
		}

		// pathDestToSrc starts at destination; pathSrcToDest starts at source.
		// Pass dest-to-src as mainTiles so the scan starts near the source station.
		local arr1 = route.pathSrcToDest.array_;
		local arr2 = route.pathDestToSrc.array_;
		local result = FourWayJunction.TryBuildNearStation(arr2, arr1, 10, 30, true);

		local srcLoc = (route.srcHgStation != null && route.srcHgStation.place != null)
			? route.srcHgStation.place.GetLocation()
			: -1;
		local srcIndustry = (srcLoc != -1)
			? AIIndustry.GetIndustryID(srcLoc)
			: -1;

		if(result.leftTile != -1 || result.rightTile != -1) {
			FreightNetwork.availableJunctions.push({
				leftTile = result.leftTile,
				rightTile = result.rightTile,
				srcIndustry = srcIndustry,
				primaryRadius = 0,
				perpOutRadius = 0,
				perpInRadius = 0
			});
			HgLog.Info("FreightNetwork.BuildJunctions: recorded junctions leftTile="
				+ result.leftTile + " rightTile=" + result.rightTile
				+ " srcIndustry=" + srcIndustry);
		} else {
			HgLog.Warning("FreightNetwork.BuildJunctions: no junctions built near source");
		}

		FreightNetwork.lastBuiltRoute = null;
		FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
	}
```

- [ ] **Step 2: Add assertion to integration test**

Add to `tests/test_integration.py`:

```python
def test_junctions_recorded():
    """C2 must build junctions and record merge tiles after spine route."""
    row = run_hognet(network_mode=1, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.BuildJunctions: recorded junctions' in row['output'], (
        "Expected junction merge tiles to be recorded"
    )
    assert 'advancing to PHASE_SEARCH_AND_CONNECT' not in row['output'] or \
           'FreightNetwork.SearchAndConnect: stub' in row['output'], (
        "Expected SearchAndConnect stub to run after junctions recorded"
    )
```

- [ ] **Step 3: Run the tests**

Run: `pytest tests/test_integration.py -v`
Expected: all four tests `PASSED`

- [ ] **Step 4: Commit**

```bash
git add freightnetwork.nut tests/test_integration.py
git commit -m "Implement C2 BuildJunctions: record merge tiles for available junctions"
```

---

## Task 6: Implement C3+C4 — `SearchAndConnect()`

**Files:**
- Modify: `freightnetwork.nut`
- Modify: `tests/test_integration.py`

**Industry search note:** `AIIndustry.GetIndustryID(tile)` only matches the exact industry tile, missing most industry footprints. Use `AIIndustryList()` filtered by a bounding rectangle instead — enumerate all industries and check if their location falls within the search rectangle.

**Waypoint note:** `viaWaypoint` in the candidate table is a forward-compatible hint. The existing `CreateBuilder` / `builder.Build()` machinery does not yet use it. After this task, test whether routes naturally join the junction by preferring existing track. If they bypass it, the follow-up is to modify `TrainRoute.Build` to accept a waypoint tile.

- [ ] **Step 1: Add `GetPrimaryDirection()` helper**

```squirrel
	function FreightNetwork::GetPrimaryDirection(fromTile, toTile) {
		// Returns unit vector {dx, dy} along the dominant axis.
		local dx = AIMap.GetTileX(toTile) - AIMap.GetTileX(fromTile);
		local dy = AIMap.GetTileY(toTile) - AIMap.GetTileY(fromTile);
		if(abs(dy) >= abs(dx)) {
			return {dx = 0, dy = (dy >= 0 ? 1 : -1)};
		} else {
			return {dx = (dx >= 0 ? 1 : -1), dy = 0};
		}
	}
```

- [ ] **Step 2: Replace `SearchAndConnect()` stub**

```squirrel
	function FreightNetwork::SearchAndConnect() {
		if(FreightNetwork.availableJunctions.len() == 0) {
			HgLog.Info("FreightNetwork: all junctions exhausted, starting new network (id="
				+ FreightNetwork.networkId + ")");
			FreightNetwork.networkId++;
			FreightNetwork.destIndustry = null;
			FreightNetwork.destPlace = null;
			FreightNetwork.phase = FreightNetwork.PHASE_FIND_SPINE;
			return;
		}

		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		local destTile = AIIndustry.GetLocation(FreightNetwork.destIndustry);

		for(local ji = 0; ji < FreightNetwork.availableJunctions.len(); ji++) {
			local junc = FreightNetwork.availableJunctions[ji];

			// Pick active merge tile (prefer left)
			local mergeTile = (junc.leftTile != -1) ? junc.leftTile : junc.rightTile;
			if(mergeTile == -1) {
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}

			// Primary direction: away from dest
			local pDir = FreightNetwork.GetPrimaryDirection(destTile, mergeTile);
			// Perpendicular axis (90-degree rotation of pDir)
			local perpDx = pDir.dy;
			local perpDy = -pDir.dx;

			// Determine which perp side is "away from" the source industry
			local srcTile = (junc.srcIndustry != -1)
				? AIIndustry.GetLocation(junc.srcIndustry)
				: mergeTile;
			local srcPerpOffset = (AIMap.GetTileX(srcTile) - AIMap.GetTileX(mergeTile)) * perpDx
				+ (AIMap.GetTileY(srcTile) - AIMap.GetTileY(mergeTile)) * perpDy;
			local perpOutSign = (srcPerpOffset >= 0) ? -1 : 1;
			local perpInSign = -perpOutSign;

			// Expand rectangle
			junc.primaryRadius += 10;
			junc.perpOutRadius += 2;
			junc.perpInRadius += 1;

			// Check if primary extent exceeds map boundary
			local pFarX = AIMap.GetTileX(mergeTile) + pDir.dx * junc.primaryRadius;
			local pFarY = AIMap.GetTileY(mergeTile) + pDir.dy * junc.primaryRadius;
			if(pFarX < 1 || pFarX >= mapW - 1 || pFarY < 1 || pFarY >= mapH - 1) {
				HgLog.Info("FreightNetwork.SearchAndConnect: junction exhausted at "
					+ HgTile(mergeTile));
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}

			// Compute the search bounding box for industry lookup
			local cx = AIMap.GetTileX(mergeTile);
			local cy = AIMap.GetTileY(mergeTile);
			local corners = [];
			foreach(ps in [0, junc.primaryRadius]) {
				foreach(po_sign in [[perpOutSign, junc.perpOutRadius], [perpInSign, junc.perpInRadius]]) {
					corners.push([
						cx + pDir.dx * ps + perpDx * po_sign[0] * po_sign[1],
						cy + pDir.dy * ps + perpDy * po_sign[0] * po_sign[1]
					]);
				}
			}
			local minX = corners[0][0]; local maxX = corners[0][0];
			local minY = corners[0][1]; local maxY = corners[0][1];
			foreach(c in corners) {
				if(c[0] < minX) minX = c[0];
				if(c[0] > maxX) maxX = c[0];
				if(c[1] < minY) minY = c[1];
				if(c[1] > maxY) maxY = c[1];
			}
			minX = max(1, minX); maxX = min(mapW - 2, maxX);
			minY = max(1, minY); maxY = min(mapH - 2, maxY);

			// Scan all industries; check if location falls in bounding box
			local found = null;
			local industries = AIIndustryList();
			foreach(indId, _ in industries) {
				if(FreightNetwork.servedSources.rawin(indId)) continue;
				local indLoc = AIIndustry.GetLocation(indId);
				local ix = AIMap.GetTileX(indLoc);
				local iy = AIMap.GetTileY(indLoc);
				if(ix < minX || ix > maxX || iy < minY || iy > maxY) continue;

				// Check this industry produces cargo accepted by destIndustry
				local matchCargo = -1;
				for(local ci = 0; ci < 3 && matchCargo == -1; ci++) {
					local dc = AIIndustry.GetAcceptedCargo(FreightNetwork.destIndustry, ci);
					if(dc == -1) continue;
					for(local pi = 0; pi < 2; pi++) {
						if(AIIndustry.GetProducedCargo(indId, pi) == dc) {
							matchCargo = dc;
							break;
						}
					}
				}
				if(matchCargo == -1) continue;
				found = {industry = indId, tile = indLoc, cargo = matchCargo};
				break;
			}

			if(found == null) {
				HgLog.Info("FreightNetwork.SearchAndConnect: no source in rectangle"
					+ " junc=" + HgTile(mergeTile)
					+ " primaryRadius=" + junc.primaryRadius);
				return; // will retry next Step() call with larger rectangle
			}

			HgLog.Info("FreightNetwork.SearchAndConnect: found source "
				+ AIIndustry.GetName(found.industry) + " at " + HgTile(found.tile));

			// Build route to destination with junction as waypoint hint
			local srcPlace = Place.Get(found.tile);
			if(srcPlace == null) {
				HgLog.Warning("FreightNetwork.SearchAndConnect: Place.Get failed");
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}
			local dist = AIMap.DistanceManhattan(found.tile,
				AIIndustry.GetLocation(FreightNetwork.destIndustry));
			local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
			local estimate = Route.Estimate(AIVehicle.VT_RAIL, found.cargo, dist,
				max(1, AIIndustry.GetLastMonthProduction(found.industry, 0)),
				false, infraTypes);
			if(estimate == null) {
				HgLog.Warning("FreightNetwork.SearchAndConnect: estimate null, skipping");
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}

			local t = {
				src = srcPlace,
				dest = FreightNetwork.destPlace,
				cargo = found.cargo,
				vehicleType = AIVehicle.VT_RAIL,
				estimate = estimate,
				score = estimate.value,
				isBiDirectional = false,
				viaWaypoint = mergeTile
			};
			local builder = ai.CreateBuilder(t, [], {}, AIDate.GetCurrentDate() + 600);
			if(builder == null) {
				HgLog.Warning("FreightNetwork.SearchAndConnect: CreateBuilder null");
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}
			local newRoutes = builder.Build();
			if(newRoutes == null) newRoutes = [];
			if(typeof newRoutes != "array") newRoutes = [newRoutes];
			if(newRoutes.len() == 0) {
				HgLog.Warning("FreightNetwork.SearchAndConnect: Build failed");
				FreightNetwork.availableJunctions.remove(ji);
				return;
			}

			FreightNetwork.servedSources.rawset(found.industry, true);
			FreightNetwork.availableJunctions.remove(ji);
			FreightNetwork.lastBuiltRoute = newRoutes[0];
			FreightNetwork.phase = FreightNetwork.PHASE_BUILD_JUNCTION;
			HgLog.Info("FreightNetwork.SearchAndConnect: connected "
				+ AIIndustry.GetName(found.industry)
				+ ", advancing to PHASE_BUILD_JUNCTION");
			return;
		}
	}
```

- [ ] **Step 3: Add assertion to integration test**

Add to `tests/test_integration.py`:

```python
def test_source_connected():
    """C3+C4 must find a second source and connect it to the existing junction."""
    row = run_hognet(network_mode=1, days=365 * 5)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.SearchAndConnect: found source' in row['output'], (
        "Expected SearchAndConnect to find a source industry"
    )
    assert 'FreightNetwork.SearchAndConnect: connected' in row['output'], (
        "Expected a second source to be connected via the junction"
    )
```

- [ ] **Step 4: Run all tests**

Run: `pytest tests/ -v`
Expected: all tests `PASSED`

- [ ] **Step 5: Commit**

```bash
git add freightnetwork.nut tests/test_integration.py
git commit -m "Implement C3+C4 SearchAndConnect: rectangle search and route building"
```

---

## Self-Review Notes

1. **`CreateRouteCandidates` call in C1:** This method is on `HogeAI` — confirm exact signature matches `main.nut:1611`. The third argument is `cargoPlaceInfo[srcInfo.cargo]` (a table with `{searchProducing}`), fourth and fifth are `0` and `4` (radius start/end), sixth is an options table. If the signature differs, fall back to using `GetRouteCandidatesGen` as a generator and filter candidates for the matching src industry.

2. **`Place.Get(tile)` in C4:** Confirm this static method exists in `place.nut`. Search for `static function Get` or `function Place::Get`. If it is named differently (e.g. `Place.GetByLocation`), use the correct name.

3. **`TrainRoute.GetDefaultInfrastractureTypes()`:** Confirm this static method exists in `trainroute.nut`. If not, pass `null` as the last argument to `Route.Estimate`.

4. **Industry bounding box search:** The bounding box in `SearchAndConnect` is an approximation — it covers the rectangle corners but is axis-aligned, not oriented. For a diagonal primary direction this will include extra tiles. This is acceptable over-inclusion; industry density is low enough that false positives will be rejected by the cargo check.

5. **`AIIndustry.GetIndustryID(tile)`:** Used in `FindSpine` to convert Place location → industry ID. Industry locations may not sit on the exact tile returned by `place.GetLocation()`. If this returns `INDUSTRY_INVALID`, consider using `AIIndustryList()` filtered by proximity to the Place location instead.

6. **Waypoint mechanism:** `viaWaypoint` is unused by current builder. After Task 6, observe in-game whether spur routes naturally join at the junction. If they bypass it, add a follow-up task to modify `TrainRoute.Build` to accept and honour the waypoint hint.
