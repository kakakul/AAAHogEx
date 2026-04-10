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
			if(!(srcInfo.place instanceof HgIndustry)) continue;
			local srcLoc = srcInfo.place.GetLocation();
			local srcIndustry = srcInfo.place.industry;
			if(!AIIndustry.IsValidIndustry(srcIndustry)) continue;
			if(FreightNetwork.servedSources.rawin(srcIndustry)) continue;

			// CreateRouteCandidates yields {place, estimate, score, distance, production, ...}
			foreach(destInfo in ai.CreateRouteCandidates(
					srcInfo.cargo, srcInfo.place,
					{searchProducing = false}, 0, 4, {})) {
				if(destInfo.estimate == null) continue;
				if(!(destInfo.place instanceof HgIndustry)) continue;
				local destLoc = destInfo.place.GetLocation();
				local destIndustry = destInfo.place.industry;
				if(!AIIndustry.IsValidIndustry(destIndustry)) continue;
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

		// Widen percentile from 10% until a candidate is selected.
		// Within each band, pick the highest score (most interior src / most coastal dest).
		local selected = null;
		for(local pct = 10; pct <= 100 && selected == null; pct += 10) {
			local threshold = max(1, candidates.len() * pct / 100);
			local bestScore = -1;
			for(local i = 0; i < threshold; i++) {
				if(candidates[i].score > bestScore) {
					bestScore = candidates[i].score;
					selected = candidates[i];
				}
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
		local dist = AIMap.DistanceManhattan(
			selected.srcPlace.GetLocation(), selected.destPlace.GetLocation());
		local t = {
			src = selected.srcPlace,
			dest = selected.destPlace,
			cargo = selected.cargo,
			vehicleType = AIVehicle.VT_RAIL,
			estimate = selected.estimate,
			score = selected.score,
			isBiDirectional = false,
			explain = selected.estimate.value + " RAIL "
				+ selected.destPlace + "<=" + selected.srcPlace
				+ "[" + selected.cargo + "] dist:" + dist
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

	function FreightNetwork::BuildJunctions() {
		local route = FreightNetwork.lastBuiltRoute;
		if(route == null) {
			HgLog.Warning("FreightNetwork.BuildJunctions: lastBuiltRoute is null, skipping");
			FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
			return;
		}

		// pathDestToSrc starts at destination; pathSrcToDest starts at source.
		// Pass dest-to-src as mainTiles so the scan starts near the source station.
		// pathSrcToDest is always populated by Build() — null would indicate a broken route
		// that was never used to create trains, so this is safe to access directly.
		local arr1 = route.pathSrcToDest.array_;
		local arr2 = (route.pathDestToSrc != null) ? route.pathDestToSrc.array_ : null;
		if(arr2 == null) {
			HgLog.Warning("FreightNetwork.BuildJunctions: pathDestToSrc is null, skipping junction build");
			FreightNetwork.lastBuiltRoute = null;
			FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
			return;
		}
		local result = FourWayJunction.TryBuildNearStation(arr2, arr1, 10, 30, true);

		local srcLoc = (route.srcHgStation != null && route.srcHgStation.place != null)
			? route.srcHgStation.place.GetLocation()
			: -1;
		// Use .industry directly — AIIndustry.GetIndustryID(tile) only matches the exact tile,
		// missing most of the industry footprint.
		local srcIndustry = (srcLoc != -1)
			? (route.srcHgStation.place instanceof HgIndustry ? route.srcHgStation.place.industry : -1)
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

		// Process the first junction per Step() call — every branch returns,
		// so subsequent junctions are tried on the next Step() invocation.
		local ji = 0;
		{
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
				viaWaypoint = mergeTile,
				explain = AIIndustry.GetName(found.industry) + " -> " + AIIndustry.GetName(FreightNetwork.destIndustry)
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
