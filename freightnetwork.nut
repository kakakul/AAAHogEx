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
			destIndustry = FreightNetwork.state.destIndustry,
			availableJunctions = junctions,
			networkId = FreightNetwork.state.networkId,
			servedSources = FreightNetwork.servedSources,
			servedDests = FreightNetwork.servedDests
		};
	}

	function FreightNetwork::LoadStatics(data) {
		if(!data.rawin("freightNetwork")) return;
		local fn = data.freightNetwork;
		FreightNetwork.state.destIndustry = fn.destIndustry;
		FreightNetwork.state.networkId = fn.networkId;
		FreightNetwork.servedSources.clear();
		foreach(k, v in fn.servedSources) FreightNetwork.servedSources.rawset(k, v);
		FreightNetwork.servedDests.clear();
		foreach(k, v in fn.servedDests) FreightNetwork.servedDests.rawset(k, v);
		FreightNetwork.availableJunctions.clear();
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
		FreightNetwork.state.destPlace = null;
		if(FreightNetwork.state.destIndustry != null) {
			FreightNetwork.state.destPlace = Place.Get(
				AIIndustry.GetLocation(FreightNetwork.state.destIndustry));
		}
		FreightNetwork.state.lastBuiltRoute = null;
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
		local maxRouteDist = mapLongSide * 20 / 100;
		local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();

		HgLog.Info("FreightNetwork.FindSpine: mapLongSide=" + mapLongSide
			+ " maxRouteDist=" + maxRouteDist);

		// Pre-build cargo->producers lookup once (reused across all edgePct iterations).
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

	function FreightNetwork::BuildJunctions() {
		local route = FreightNetwork.state.lastBuiltRoute;
		if(route == null) {
			HgLog.Warning("FreightNetwork.BuildJunctions: lastBuiltRoute is null, skipping");
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
			FreightNetwork.state.lastBuiltRoute = null;
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

		FreightNetwork.state.lastBuiltRoute = null;
	}

	function FreightNetwork::SearchAndConnect() {
		if(FreightNetwork.availableJunctions.len() == 0) {
			return false;
		}

		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		local destTile = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);

		// Process the first junction per Step() call — every branch returns,
		// so subsequent junctions are tried on the next Step() invocation.
		local ji = 0;
		local junc = FreightNetwork.availableJunctions[ji];

		// Pick active merge tile (prefer left)
		local mergeTile = (junc.leftTile != -1) ? junc.leftTile : junc.rightTile;
		if(mergeTile == -1) {
			FreightNetwork.availableJunctions.remove(ji);
			return false;
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
			return false;
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
			local destType = AIIndustry.GetIndustryType(FreightNetwork.state.destIndustry);
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

		if(found == null) {
			HgLog.Info("FreightNetwork.SearchAndConnect: no source in rectangle"
				+ " junc=" + HgTile(mergeTile)
				+ " primaryRadius=" + junc.primaryRadius);
			return false; // will retry next Step() call with larger rectangle
		}

		HgLog.Info("FreightNetwork.SearchAndConnect: found source "
			+ AIIndustry.GetName(found.industry) + " at " + HgTile(found.tile));

		// Build route to destination with junction as waypoint hint
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
			HgLog.Warning("FreightNetwork.SearchAndConnect: estimate null, skipping");
			FreightNetwork.availableJunctions.remove(ji);
			return false;
		}

		local t = {
			src = srcPlace,
			dest = FreightNetwork.state.destPlace,
			cargo = found.cargo,
			vehicleType = AIVehicle.VT_RAIL,
			estimate = estimate,
			score = estimate.value,
			isBiDirectional = false,
			viaWaypoint = mergeTile,
			explain = AIIndustry.GetName(found.industry) + " -> " + AIIndustry.GetName(FreightNetwork.state.destIndustry)
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
