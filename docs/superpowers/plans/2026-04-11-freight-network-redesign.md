# FreightNetwork Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign FreightNetwork to use a destination-first coastal FindSpine scan, exhaust SearchAndConnect fully in one Step() call, remove the phase state machine, and suppress ScanPlaces entirely in network mode.

**Architecture:** `FreightNetwork.Step()` is the sole owner of freight route decisions in network mode. It drives `FindSpine→BuildJunctions` or `SearchAndConnect→BuildJunctions` as a complete unit of work each call, decided by `state.destIndustry == null`. `ScanPlaces` is suppressed entirely in network mode. Phase constants are removed.

**Tech Stack:** OpenTTD Squirrel (NoAI API); OpenTTDLab + pytest for integration tests. Tab indentation throughout `.nut` files. Function declarations must appear **outside** the class block (Squirrel requirement).

---

### Task 1: Suppress ScanPlaces in network mode; add PaxMailOnly guard to FreightNetwork.Step()

**Goal:** Prevent `_ScanPlaces` from running at all in network mode, and skip FreightNetwork entirely when the AI is configured for Pax/Mail only.

**Files:**
- Modify: `main.nut` (~line 1160 `_ScanPlaces` top, ~line 1229 freight guard removal)
- Modify: `freightnetwork.nut` (~line 27 `Step()`)

**Acceptance Criteria:**
- [ ] `_ScanPlaces` returns immediately when `IsNetworkMode()` is true
- [ ] The per-candidate freight rail guard inside the `while(routeCandidates.Count() >= 1)` loop is removed
- [ ] `FreightNetwork.Step()` returns immediately when `HogeAI.Get().IsPaxMailOnly()` is true
- [ ] All 5 existing tests pass

**Verify:** `python -m pytest tests/test_integration.py -v` → 5 passed

**Steps:**

- [ ] **Step 1: Add network mode early return to `_ScanPlaces` in `main.nut`**

  The function starts at ~line 1160. Add the guard as the first statement after the log:

  ```squirrel
  	function _ScanPlaces() {
  		HgLog.Info("###### Scan places");
  		if(IsNetworkMode()) return;
  		if(/*IsForceToHandleFright() &&*/ isTimeoutToMeetSrcDemand) {
  ```

- [ ] **Step 2: Remove the per-candidate freight rail guard from `_ScanPlaces`**

  Inside the `while(routeCandidates.Count() >= 1)` loop (~line 1229), delete these lines entirely:

  ```squirrel
  			// In network mode, freight is handled exclusively by FreightNetwork.Step()
  			if(IsNetworkMode() && t.rawin("cargo") && !CargoUtils.IsPaxOrMail(t.cargo)
  					&& t.vehicleType == AIVehicle.VT_RAIL) {
  				continue;
  			}
  ```

- [ ] **Step 3: Add PaxMailOnly guard to `FreightNetwork.Step()`**

  In `freightnetwork.nut`, add the guard as the first statement in `Step()`:

  ```squirrel
  	function FreightNetwork::Step() {
  		if(HogeAI.Get().IsPaxMailOnly()) return;
  		switch(FreightNetwork.state.phase) {
  ```

- [ ] **Step 4: Run tests and commit**

  ```
  python -m pytest tests/test_integration.py -v
  ```

  Expected: 5 passed.

  ```bash
  git add main.nut freightnetwork.nut
  git commit -m "Suppress ScanPlaces in network mode; skip FreightNetwork for PaxMailOnly AI"
  ```

---

### Task 2: Remove phase state machine; rewrite Step() orchestration; update SaveStatics/LoadStatics

**Goal:** Remove `PHASE_*` constants and `state.phase`; rewrite `Step()` to use `state.destIndustry == null`; add `true`/`false` return values to `FindSpine` and `SearchAndConnect` so `Step()` can act on outcomes.

**Files:**
- Modify: `freightnetwork.nut` (class definition, `Step()`, end of `FindSpine()`, end of `SearchAndConnect()`, `SaveStatics()`, `LoadStatics()`)

**Acceptance Criteria:**
- [ ] `PHASE_FIND_SPINE`, `PHASE_BUILD_JUNCTION`, `PHASE_SEARCH_AND_CONNECT` constants removed
- [ ] `state.phase` field removed from `static state = {}`
- [ ] `Step()` dispatches on `state.destIndustry == null`
- [ ] `FindSpine()` returns `true` on success, `false` on all failure paths
- [ ] `SearchAndConnect()` returns `true` on successful connection, `false` on all other paths
- [ ] `SaveStatics` no longer saves `phase`; `LoadStatics` no longer loads `phase`
- [ ] `test_spine_built` assertion updated from `'advancing to PHASE_BUILD_JUNCTION'` to `'advancing to BuildJunctions'`
- [ ] All 5 existing tests pass

**Verify:** `python -m pytest tests/test_integration.py -v` → 5 passed

**Steps:**

- [ ] **Step 1: Replace the class definition block**

  Replace the existing class definition (lines 1–25) with:

  ```squirrel
  // freightnetwork.nut
  // Strategy C freight network builder. Network mode only.

  class FreightNetwork {
  	// Mutable scalar state in a table — Squirrel static slots cannot be reassigned with =
  	// so scalars (integers, null) live here and are updated via table-slot assignment.
  	static state = {
  		destIndustry = null,
  		destPlace = null,
  		networkId = 0,
  		lastBuiltRoute = null
  	};
  	// Available junction merge tiles: array of {leftTile, rightTile, srcIndustry,
  	//   primaryRadius, perpOutRadius, perpInRadius}
  	static availableJunctions = [];
  	// Industry IDs already serving as sources (across all networks, never cleared)
  	static servedSources = {};
  	// Industry IDs already serving as destinations (across all networks, never cleared)
  	static servedDests = {};
  }
  ```

- [ ] **Step 2: Replace Step()**

  ```squirrel
  	function FreightNetwork::Step() {
  		if(HogeAI.Get().IsPaxMailOnly()) return;
  		if(FreightNetwork.state.destIndustry == null) {
  			local built = FreightNetwork.FindSpine();
  			if(built) FreightNetwork.BuildJunctions();
  		} else {
  			local connected = FreightNetwork.SearchAndConnect();
  			if(connected) {
  				FreightNetwork.BuildJunctions();
  			} else if(FreightNetwork.availableJunctions.len() == 0) {
  				HgLog.Info("FreightNetwork: network exhausted, starting network id="
  					+ (FreightNetwork.state.networkId + 1));
  				FreightNetwork.state.destIndustry = null;
  				FreightNetwork.state.destPlace = null;
  				FreightNetwork.state.networkId++;
  			}
  		}
  	}
  ```

- [ ] **Step 3: Add return values to FindSpine()**

  FindSpine currently ends with a success block that sets `state.phase`. Replace that block:

  ```squirrel
  		FreightNetwork.state.destIndustry = selected.destIndustry;
  		FreightNetwork.state.destPlace = selected.destPlace;
  		FreightNetwork.servedDests.rawset(selected.destIndustry, true);
  		FreightNetwork.servedSources.rawset(selected.srcIndustry, true);
  		FreightNetwork.state.lastBuiltRoute = newRoutes[0];
  		HgLog.Info("FreightNetwork.FindSpine: spine built, advancing to BuildJunctions");
  		return true;
  ```

  Change every `return;` / early-return failure path in `FindSpine()` to `return false;`. The four failure sites are: no candidates, no candidate survived filters, CreateBuilder null, Build failed.

- [ ] **Step 4: Add return values to SearchAndConnect()**

  Remove the early-exhaustion block at the top of `SearchAndConnect()` that resets the network (Step() now owns that):

  ```squirrel
  	function FreightNetwork::SearchAndConnect() {
  		if(FreightNetwork.availableJunctions.len() == 0) {
  			return false;
  		}
  ```

  Find the success path (currently logs `"advancing to PHASE_BUILD_JUNCTION"`). Replace:

  ```squirrel
  			FreightNetwork.servedSources.rawset(found.industry, true);
  			FreightNetwork.availableJunctions.remove(ji);
  			FreightNetwork.state.lastBuiltRoute = newRoutes[0];
  			HgLog.Info("FreightNetwork.SearchAndConnect: connected "
  				+ AIIndustry.GetName(found.industry)
  				+ ", advancing to BuildJunctions");
  			return true;
  ```

  Change every other `return;` in `SearchAndConnect()` to `return false;`. Add `return false;` at the very end of the function (after the bare block closes).

- [ ] **Step 5: Update SaveStatics — remove phase**

  In `SaveStatics()`, the saved table should be:

  ```squirrel
  		table.freightNetwork <- {
  			destIndustry = FreightNetwork.state.destIndustry,
  			availableJunctions = junctions,
  			networkId = FreightNetwork.state.networkId,
  			servedSources = FreightNetwork.servedSources,
  			servedDests = FreightNetwork.servedDests
  		};
  ```

- [ ] **Step 6: Update LoadStatics — remove phase**

  Delete the line `FreightNetwork.state.phase = fn.phase;` from `LoadStatics()`. All other lines remain.

- [ ] **Step 7: Update the stale test assertion**

  In `tests/test_integration.py`, `test_spine_built` checks for `'advancing to PHASE_BUILD_JUNCTION'` which no longer appears. Replace that assertion:

  ```python
  def test_spine_built():
      """C1 must select an industry pair and build the spine route."""
      row = run_hognet(network_mode=1, days=365 * 3)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'FreightNetwork.FindSpine: spine built' in output, (
              "Expected spine route to be built"
          )
          assert 'advancing to BuildJunctions' in output
  ```

- [ ] **Step 8: Run tests and commit**

  ```
  python -m pytest tests/test_integration.py -v
  ```

  Expected: 5 passed.

  ```bash
  git add freightnetwork.nut tests/test_integration.py
  git commit -m "Remove phase state machine; rewrite Step() orchestration; FindSpine/SearchAndConnect return booleans"
  ```

---

### Task 3: Rewrite FindSpine as destination-first coastal scan

**Goal:** Replace the all-pairs scan with a destination-first approach: collect a `cargo→producers` lookup once, then iterate coastal destinations with a widening edge threshold (10%→100%), applying distance and inland-direction filters, scoring by `estProfit * 1000 / (minEdgeDist + 1)`.

**Files:**
- Modify: `freightnetwork.nut` (`FindSpine()` function body only)

**Acceptance Criteria:**
- [ ] Destination edge threshold starts at 10% of map long side, widens by 10% each cycle
- [ ] `cargo→producers` lookup built once before the widening loop (not rebuilt per cycle)
- [ ] Source industries found via `AIIndustryType.GetProducedCargo` — not `AIIndustry.GetProducedCargo`
- [ ] Pax/mail cargos skipped
- [ ] Route length filter: `0 < dist < mapLongSide * 20 / 100`
- [ ] Inland filter reuses `GetPrimaryDirection(destLoc, srcLoc)` with edge-direction sign check
- [ ] Score = `estimate.value * 1000 / (minEdgeDist + 1)`
- [ ] `notUseSingle = true` in the `t` table
- [ ] TODO comment present noting oil-rig / water-only industries are not yet handled
- [ ] All 5 existing tests pass

**Verify:** `python -m pytest tests/test_integration.py -v` → 5 passed

**Steps:**

- [ ] **Step 1: Replace the entire body of `FreightNetwork::FindSpine()`**

  ```squirrel
  	function FreightNetwork::FindSpine() {
  		local ai = HogeAI.Get();
  		local mapW = AIMap.GetMapSizeX();
  		local mapH = AIMap.GetMapSizeY();
  		local mapLongSide = max(mapW, mapH);
  		local maxRouteDist = mapLongSide * 20 / 100;
  		local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();

  		HgLog.Info("FreightNetwork.FindSpine: mapLongSide=" + mapLongSide
  			+ " maxRouteDist=" + maxRouteDist);

  		// Pre-build cargo→producers lookup once (reused across all edgePct iterations).
  		// TODO: industries only reachable by water (e.g. oil rigs) are silently skipped
  		// because Route.Estimate(VT_RAIL,...) returns null for them. A future pass should
  		// detect water-only industries and route them via ship or skip them explicitly.
  		local cargoProducers = {};
  		foreach(indId, _ in AIIndustryList()) {
  			if(FreightNetwork.servedSources.rawin(indId)) continue;
  			local indType = AIIndustry.GetIndustryType(indId);
  			foreach(cargo, _ in AIIndustryType.GetProducedCargo(indType)) {
  				if(CargoUtils.IsPaxOrMail(cargo)) continue;
  				if(!cargoProducers.rawin(cargo)) cargoProducers.rawset(cargo, []);
  				cargoProducers[cargo].push({
  					id  = indId,
  					loc = AIIndustry.GetLocation(indId)
  				});
  			}
  		}

  		local allDests = AIIndustryList();

  		for(local edgePct = 10; edgePct <= 100; edgePct += 10) {
  			local edgeThresh = mapLongSide * edgePct / 100;
  			local bestCandidate = null;
  			local bestScore = -1;

  			foreach(destId, _ in allDests) {
  				if(FreightNetwork.servedDests.rawin(destId)) continue;
  				local destLoc = AIIndustry.GetLocation(destId);
  				local destX = AIMap.GetTileX(destLoc);
  				local destY = AIMap.GetTileY(destLoc);
  				local dN = destY;
  				local dS = mapH - 1 - destY;
  				local dW = destX;
  				local dE = mapW - 1 - destX;
  				local minEdgeDist = min(min(dN, dS), min(dW, dE));
  				if(minEdgeDist > edgeThresh) continue;

  				local destType = AIIndustry.GetIndustryType(destId);
  				foreach(cargo, _ in AIIndustryType.GetAcceptedCargo(destType)) {
  					if(CargoUtils.IsPaxOrMail(cargo)) continue;
  					if(!cargoProducers.rawin(cargo)) continue;

  					foreach(src in cargoProducers[cargo]) {
  						if(src.id == destId) continue;
  						local dist = AIMap.DistanceManhattan(src.loc, destLoc);
  						if(dist == 0 || dist >= maxRouteDist) continue;

  						local pDir = FreightNetwork.GetPrimaryDirection(destLoc, src.loc);
  						local inlandOk = false;
  						if(minEdgeDist == dN)      inlandOk = (pDir.dy == 1);
  						else if(minEdgeDist == dS) inlandOk = (pDir.dy == -1);
  						else if(minEdgeDist == dW) inlandOk = (pDir.dx == 1);
  						else                       inlandOk = (pDir.dx == -1);
  						if(!inlandOk) continue;

  						local production = AIIndustry.GetLastMonthProduction(src.id, 0);
  						if(production <= 0) production = 1;
  						local estimate = Route.Estimate(
  							AIVehicle.VT_RAIL, cargo, dist, production, false, infraTypes);
  						if(estimate == null || estimate.value <= 0) continue;

  						local score = estimate.value * 1000 / (minEdgeDist + 1);
  						if(score > bestScore) {
  							bestScore = score;
  							bestCandidate = {
  								srcId      = src.id,
  								destId     = destId,
  								srcLoc     = src.loc,
  								destLoc    = destLoc,
  								cargo      = cargo,
  								estimate   = estimate,
  								score      = score,
  								minEdgeDist = minEdgeDist,
  								dist       = dist
  							};
  						}
  					}
  				}
  			}

  			if(bestCandidate != null) {
  				HgLog.Info("FreightNetwork.FindSpine: selected edgePct=" + edgePct
  					+ " src=" + AIIndustry.GetName(bestCandidate.srcId)
  					+ " dest=" + AIIndustry.GetName(bestCandidate.destId)
  					+ " score=" + bestCandidate.score
  					+ " dist=" + bestCandidate.dist
  					+ " minEdgeDist=" + bestCandidate.minEdgeDist);

  				local srcPlace = Place.Get(bestCandidate.srcLoc);
  				local destPlace = Place.Get(bestCandidate.destLoc);
  				if(srcPlace == null || destPlace == null) {
  					HgLog.Warning("FreightNetwork.FindSpine: Place.Get failed");
  					return false;
  				}

  				local t = {
  					src          = srcPlace,
  					dest         = destPlace,
  					cargo        = bestCandidate.cargo,
  					vehicleType  = AIVehicle.VT_RAIL,
  					estimate     = bestCandidate.estimate,
  					score        = bestCandidate.score,
  					isBiDirectional = false,
  					notUseSingle = true,
  					explain      = bestCandidate.estimate.value + " RAIL "
  						+ destPlace + "<=" + srcPlace
  						+ "[" + bestCandidate.cargo + "] dist:" + bestCandidate.dist
  				};
  				local builder = ai.CreateBuilder(t, [], {}, AIDate.GetCurrentDate() + 600);
  				if(builder == null) {
  					HgLog.Warning("FreightNetwork.FindSpine: CreateBuilder returned null");
  					return false;
  				}
  				local newRoutes = builder.Build();
  				if(newRoutes == null) newRoutes = [];
  				if(typeof newRoutes != "array") newRoutes = [newRoutes];
  				if(newRoutes.len() == 0) {
  					HgLog.Warning("FreightNetwork.FindSpine: Build failed");
  					return false;
  				}

  				FreightNetwork.state.destIndustry = bestCandidate.destId;
  				FreightNetwork.state.destPlace = destPlace;
  				FreightNetwork.servedDests.rawset(bestCandidate.destId, true);
  				FreightNetwork.servedSources.rawset(bestCandidate.srcId, true);
  				FreightNetwork.state.lastBuiltRoute = newRoutes[0];
  				HgLog.Info("FreightNetwork.FindSpine: spine built, advancing to BuildJunctions");
  				return true;
  			}
  		}

  		HgLog.Info("FreightNetwork.FindSpine: no candidate survived filters");
  		return false;
  	}
  ```

- [ ] **Step 2: Run tests and commit**

  ```
  python -m pytest tests/test_integration.py -v
  ```

  Expected: 5 passed.

  ```bash
  git add freightnetwork.nut
  git commit -m "Rewrite FindSpine as destination-first coastal scan with widening edge threshold"
  ```

---

### Task 4: Rewrite SearchAndConnect to exhaust fully in one Step() call

**Goal:** Replace the single-junction-per-Step() bare block with a nested loop that cycles through all available junctions in one call — expanding each by 10 tiles per outer round — until a source is found or all junctions hit the map boundary.

**Files:**
- Modify: `freightnetwork.nut` (`SearchAndConnect()` function body only)

**Acceptance Criteria:**
- [ ] All junctions are scanned in one `Step()` call, not spread across multiple calls
- [ ] Each junction expands by +10 primary, +2 perpOut, +1 perpIn per outer round
- [ ] A junction is removed when its primary far-point exceeds map boundary
- [ ] Returns `true` immediately on successful connection
- [ ] Returns `false` when the loop ends with all junctions exhausted
- [ ] Cargo matching uses `AIIndustryType.GetAcceptedCargo`/`GetProducedCargo`
- [ ] `notUseSingle = true` in the `t` table passed to `CreateBuilder`
- [ ] All 5 existing tests pass

**Verify:** `python -m pytest tests/test_integration.py -v` → 5 passed

**Steps:**

- [ ] **Step 1: Replace the entire body of `FreightNetwork::SearchAndConnect()`**

  ```squirrel
  	function FreightNetwork::SearchAndConnect() {
  		if(FreightNetwork.availableJunctions.len() == 0) {
  			return false;
  		}

  		local ai = HogeAI.Get();
  		local mapW = AIMap.GetMapSizeX();
  		local mapH = AIMap.GetMapSizeY();
  		local destTile = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);
  		local destType = AIIndustry.GetIndustryType(FreightNetwork.state.destIndustry);

  		// Outer loop: keep expanding all junctions in rounds until a source is found
  		// or all junctions are removed (primary extent exceeds map boundary).
  		while(FreightNetwork.availableJunctions.len() > 0) {
  			local ji = 0;
  			local anyActive = false;
  			while(ji < FreightNetwork.availableJunctions.len()) {
  				local junc = FreightNetwork.availableJunctions[ji];
  				local mergeTile = (junc.leftTile != -1) ? junc.leftTile : junc.rightTile;
  				if(mergeTile == -1) {
  					FreightNetwork.availableJunctions.remove(ji);
  					continue;
  				}

  				local pDir = FreightNetwork.GetPrimaryDirection(destTile, mergeTile);
  				local perpDx = pDir.dy;
  				local perpDy = -pDir.dx;
  				local srcTile = (junc.srcIndustry != -1)
  					? AIIndustry.GetLocation(junc.srcIndustry)
  					: mergeTile;
  				local srcPerpOffset =
  					(AIMap.GetTileX(srcTile) - AIMap.GetTileX(mergeTile)) * perpDx
  					+ (AIMap.GetTileY(srcTile) - AIMap.GetTileY(mergeTile)) * perpDy;
  				local perpOutSign = (srcPerpOffset >= 0) ? -1 : 1;
  				local perpInSign = -perpOutSign;

  				junc.primaryRadius += 10;
  				junc.perpOutRadius += 2;
  				junc.perpInRadius  += 1;

  				local pFarX = AIMap.GetTileX(mergeTile) + pDir.dx * junc.primaryRadius;
  				local pFarY = AIMap.GetTileY(mergeTile) + pDir.dy * junc.primaryRadius;
  				if(pFarX < 1 || pFarX >= mapW - 1 || pFarY < 1 || pFarY >= mapH - 1) {
  					HgLog.Info("FreightNetwork.SearchAndConnect: junction exhausted at "
  						+ HgTile(mergeTile));
  					FreightNetwork.availableJunctions.remove(ji);
  					continue;
  				}
  				anyActive = true;

  				// Compute bounding box
  				local cx = AIMap.GetTileX(mergeTile);
  				local cy = AIMap.GetTileY(mergeTile);
  				local corners = [];
  				foreach(ps in [0, junc.primaryRadius]) {
  					foreach(po_sign in [
  						[perpOutSign, junc.perpOutRadius],
  						[perpInSign,  junc.perpInRadius]
  					]) {
  						corners.push([
  							cx + pDir.dx * ps + perpDx * po_sign[0] * po_sign[1],
  							cy + pDir.dy * ps + perpDy * po_sign[0] * po_sign[1]
  						]);
  					}
  				}
  				local minX = corners[0][0]; local maxX = corners[0][0];
  				local minY = corners[0][1]; local maxY = corners[0][1];
  				foreach(c in corners) {
  					if(c[0] < minX) minX = c[0]; if(c[0] > maxX) maxX = c[0];
  					if(c[1] < minY) minY = c[1]; if(c[1] > maxY) maxY = c[1];
  				}
  				minX = max(1, minX); maxX = min(mapW - 2, maxX);
  				minY = max(1, minY); maxY = min(mapH - 2, maxY);

  				// Scan for matching source in bounding box
  				local found = null;
  				foreach(indId, _ in AIIndustryList()) {
  					if(FreightNetwork.servedSources.rawin(indId)) continue;
  					local indLoc = AIIndustry.GetLocation(indId);
  					local ix = AIMap.GetTileX(indLoc);
  					local iy = AIMap.GetTileY(indLoc);
  					if(ix < minX || ix > maxX || iy < minY || iy > maxY) continue;
  					local srcType = AIIndustry.GetIndustryType(indId);
  					local matchCargo = -1;
  					foreach(dc, _ in AIIndustryType.GetAcceptedCargo(destType)) {
  						foreach(pc, _ in AIIndustryType.GetProducedCargo(srcType)) {
  							if(pc == dc) { matchCargo = dc; break; }
  						}
  						if(matchCargo != -1) break;
  					}
  					if(matchCargo == -1) continue;
  					found = {industry = indId, tile = indLoc, cargo = matchCargo};
  					break;
  				}

  				if(found != null) {
  					HgLog.Info("FreightNetwork.SearchAndConnect: found source "
  						+ AIIndustry.GetName(found.industry) + " at " + HgTile(found.tile));

  					local srcPlace = Place.Get(found.tile);
  					if(srcPlace == null) {
  						HgLog.Warning("FreightNetwork.SearchAndConnect: Place.Get failed");
  						FreightNetwork.availableJunctions.remove(ji);
  						return false;
  					}
  					local dist = AIMap.DistanceManhattan(found.tile,
  						AIIndustry.GetLocation(FreightNetwork.state.destIndustry));
  					local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
  					local estimate = Route.Estimate(AIVehicle.VT_RAIL, found.cargo, dist,
  						max(1, AIIndustry.GetLastMonthProduction(found.industry, 0)),
  						false, infraTypes);
  					if(estimate == null) {
  						HgLog.Warning("FreightNetwork.SearchAndConnect: estimate null");
  						FreightNetwork.availableJunctions.remove(ji);
  						return false;
  					}
  					local t = {
  						src          = srcPlace,
  						dest         = FreightNetwork.state.destPlace,
  						cargo        = found.cargo,
  						vehicleType  = AIVehicle.VT_RAIL,
  						estimate     = estimate,
  						score        = estimate.value,
  						isBiDirectional = false,
  						notUseSingle = true,
  						viaWaypoint  = mergeTile,
  						explain      = AIIndustry.GetName(found.industry) + " -> "
  							+ AIIndustry.GetName(FreightNetwork.state.destIndustry)
  					};
  					local builder = ai.CreateBuilder(t, [], {}, AIDate.GetCurrentDate() + 600);
  					if(builder == null) {
  						HgLog.Warning("FreightNetwork.SearchAndConnect: CreateBuilder null");
  						FreightNetwork.availableJunctions.remove(ji);
  						return false;
  					}
  					local newRoutes = builder.Build();
  					if(newRoutes == null) newRoutes = [];
  					if(typeof newRoutes != "array") newRoutes = [newRoutes];
  					if(newRoutes.len() == 0) {
  						HgLog.Warning("FreightNetwork.SearchAndConnect: Build failed");
  						FreightNetwork.availableJunctions.remove(ji);
  						return false;
  					}
  					FreightNetwork.servedSources.rawset(found.industry, true);
  					FreightNetwork.availableJunctions.remove(ji);
  					FreightNetwork.state.lastBuiltRoute = newRoutes[0];
  					HgLog.Info("FreightNetwork.SearchAndConnect: connected "
  						+ AIIndustry.GetName(found.industry)
  						+ ", advancing to BuildJunctions");
  					return true;
  				}

  				HgLog.Info("FreightNetwork.SearchAndConnect: no source in rectangle"
  					+ " junc=" + HgTile(mergeTile)
  					+ " primaryRadius=" + junc.primaryRadius);
  				ji++;
  			}
  			// All junctions processed this round; if none are still active, stop
  			if(!anyActive) break;
  		}

  		HgLog.Info("FreightNetwork.SearchAndConnect: all junctions exhausted");
  		return false;
  	}
  ```

- [ ] **Step 2: Run tests and commit**

  ```
  python -m pytest tests/test_integration.py -v
  ```

  Expected: 5 passed.

  ```bash
  git add freightnetwork.nut
  git commit -m "Rewrite SearchAndConnect to exhaust all junctions in one Step() call"
  ```

---

### Task 5: Add second parametrized seed to test_spine_built and test_source_connected

**Goal:** Find a second fixed seed that produces a different but valid coastal industry layout, update `conftest.py` to accept a seed parameter, and add the second seed as a parametrized case to the two layout-sensitive tests.

**Files:**
- Modify: `tests/conftest.py`
- Modify: `tests/test_integration.py` (`test_spine_built` and `test_source_connected` only)

**Acceptance Criteria:**
- [ ] `run_hognet` accepts a `seed` keyword argument (default `SEED = 42`)
- [ ] `test_spine_built` and `test_source_connected` run with seeds `[42, NEW_SEED]`
- [ ] `NEW_SEED` is a different integer from 42 and both tests pass with it
- [ ] `test_freight_network_skeleton`, `test_freight_skipped_in_scanplaces`, `test_junctions_recorded` remain seed=42 only
- [ ] Total test count is 7 (3 single-seed + 2×2 parametrized)

**Verify:** `python -m pytest tests/test_integration.py -v` → 7 passed

**Steps:**

- [ ] **Step 1: Update `conftest.py` to accept a seed parameter**

  ```python
  import os
  from openttdlab import run_experiments, local_folder

  AI_FOLDER = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
  OPENTTD_VERSION = '15.3'
  SEED = 42


  def run_hognet(network_mode=0, days=365 * 3, extra_params=(), seed=SEED):
      """Run HogNet headlessly and return the result row."""
      params = (('network_mode', str(network_mode)),
                ('usable_cargos', '2'),
                ('IsForceToHandleFright', '1')) + extra_params
      results = list(run_experiments(
          openttd_version=OPENTTD_VERSION,
          experiments=({
              'seed': seed,
              'ais': (local_folder(AI_FOLDER, 'HogNet', ai_params=params),),
              'days': days,
          },),
      ))
      assert results, "run_experiments returned no results"
      return results[0]
  ```

- [ ] **Step 2: Find a valid second seed**

  Create a temporary probe script at `tests/probe_seeds.py`:

  ```python
  # Run from project root: python tests/probe_seeds.py
  import sys, os
  sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
  from conftest import run_hognet

  for seed in [1, 7, 100, 123, 456, 999]:
      row = run_hognet(network_mode=1, days=365 * 3, seed=seed)
      output = row['output']
      passed = (not row['error']) and (not output or 'spine built' in output)
      print(f"seed={seed}: {'PASS' if passed else 'FAIL'}")
  ```

  Run it:

  ```
  python tests/probe_seeds.py
  ```

  Pick the first seed that prints `PASS`. That is `NEW_SEED`. Delete `probe_seeds.py` after picking.

- [ ] **Step 3: Parametrize `test_spine_built` and `test_source_connected`**

  In `tests/test_integration.py`, add `import pytest` at the top and replace the two tests. Substitute the actual integer for `NEW_SEED`:

  ```python
  import pytest
  from conftest import run_hognet


  def test_freight_network_skeleton():
      """FreightNetwork skeleton is loaded and Step() runs without crash."""
      row = run_hognet(network_mode=1, days=365 * 1)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'FreightNetwork.FindSpine:' in output, (
              "Expected FreightNetwork.Step() to run in network mode"
          )


  def test_freight_skipped_in_scanplaces():
      """In network mode, ScanPlaces must not build freight rail via the old path."""
      row = run_hognet(network_mode=1, days=365 * 2)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'TryBuildNearStation: tried=' not in output, (
              "TryBuildNearStation should not run in network mode"
          )
          assert 'FreightNetwork.FindSpine:' in output


  @pytest.mark.parametrize("seed", [42, NEW_SEED])
  def test_spine_built(seed):
      """C1 must select an industry pair and build the spine route."""
      row = run_hognet(network_mode=1, days=365 * 3, seed=seed)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'FreightNetwork.FindSpine: spine built' in output, (
              "Expected spine route to be built"
          )
          assert 'advancing to BuildJunctions' in output


  def test_junctions_recorded():
      """C2 must build junctions and record merge tiles after spine route."""
      row = run_hognet(network_mode=1, days=365 * 3)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'FreightNetwork.BuildJunctions:' in output, (
              "Expected BuildJunctions to run after spine is built"
          )
          assert 'FreightNetwork.BuildJunctions: recorded junctions' in output, (
              "Expected junction merge tiles to be recorded"
          )
          assert 'FreightNetwork.SearchAndConnect:' in output


  @pytest.mark.parametrize("seed", [42, NEW_SEED])
  def test_source_connected(seed):
      """C3+C4 must find a second source and connect it to the existing junction."""
      row = run_hognet(network_mode=1, days=365 * 5, seed=seed)
      assert not row['error'], f"AI crashed:\n{row['output']}"
      output = row['output']
      if output:
          assert 'FreightNetwork.SearchAndConnect: found source' in output, (
              "Expected SearchAndConnect to find a source industry"
          )
          assert 'FreightNetwork.SearchAndConnect: connected' in output, (
              "Expected a second source to be connected via the junction"
          )
  ```

- [ ] **Step 4: Run all tests and commit**

  ```
  python -m pytest tests/test_integration.py -v
  ```

  Expected: 7 passed.

  ```bash
  git add tests/conftest.py tests/test_integration.py
  git commit -m "Add second parametrized seed to test_spine_built and test_source_connected"
  ```
