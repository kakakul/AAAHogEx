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
	// Pairs that failed pathfinding: key = "srcId-destId", never retried
	static failedPairs = {};
	// Pending feeder routes to build: array of {srcIndustry, branchStationTile, cargo, branchRouteId}
	// Drained before new branch work each Step().
	static pendingFeeders = [];
}

	function FreightNetwork::Step() {
		if(HogeAI.Get().IsPaxMailOnly()) return;
		// Guard against stale destIndustry after game load (industry may have closed).
		if(FreightNetwork.state.destIndustry != null && FreightNetwork.state.destPlace == null) {
			HgLog.Warning("FreightNetwork.Step: destPlace null after load, resetting network");
			FreightNetwork.state.destIndustry = null;
			FreightNetwork.state.networkId++;
		}
		// Feeders have priority over new branch work
		if(FreightNetwork.pendingFeeders.len() > 0) {
			FreightNetwork.TryBuildFeeder();
			return;
		}
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
				mergeTile = j.mergeTile,
				leg1Path = j.leg1Path,
				leg2Path = j.leg2Path,
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
			servedDests = FreightNetwork.servedDests,
			failedPairs = FreightNetwork.failedPairs,
			pendingFeeders = FreightNetwork.pendingFeeders
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
		FreightNetwork.failedPairs.clear();
		if(fn.rawin("failedPairs")) foreach(k, v in fn.failedPairs) FreightNetwork.failedPairs.rawset(k, v);
		FreightNetwork.pendingFeeders.clear();
		if(fn.rawin("pendingFeeders")) foreach(f in fn.pendingFeeders) FreightNetwork.pendingFeeders.push(f);
		FreightNetwork.availableJunctions.clear();
		foreach(j in fn.availableJunctions) {
			if(!j.rawin("mergeTile") || j.mergeTile == -1) continue;
			// leg1Path/leg2Path are essential for connection; skip entries missing them
			// (they cannot be recovered without the original route's path data).
			if(!j.rawin("leg1Path") || j.leg1Path == null) continue;
			if(!j.rawin("leg2Path") || j.leg2Path == null) continue;
			FreightNetwork.availableJunctions.push({
				mergeTile = j.mergeTile,
				leg1Path = j.leg1Path,
				leg2Path = j.leg2Path,
				srcIndustry = j.rawin("srcIndustry") ? j.srcIndustry : -1,
				primaryRadius = j.rawin("primaryRadius") ? j.primaryRadius : 0,
				perpOutRadius = j.rawin("perpOutRadius") ? j.perpOutRadius : 0,
				perpInRadius = j.rawin("perpInRadius") ? j.perpInRadius : 0,
				triedIndustries = {}
			});
		}
		FreightNetwork.state.destPlace = null;
		if(FreightNetwork.state.destIndustry != null) {
			FreightNetwork.state.destPlace = HgIndustry(FreightNetwork.state.destIndustry, false);
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

	function FreightNetwork::IsIndustryInTown(indId) {
		local indLoc = AIIndustry.GetLocation(indId);
		foreach(townId, _ in AITownList()) {
			if(AITile.IsWithinTownInfluence(indLoc, townId)) return true;
		}
		return false;
	}

	function FreightNetwork::ScanFeeders(branchRoute) {
		local srcStation = branchRoute.srcHgStation;
		local stationTile = srcStation.platformTile;
		local destIndustry = FreightNetwork.state.destIndustry;
		if(!AIIndustry.IsValidIndustry(destIndustry)) return;
		local destType = AIIndustry.GetIndustryType(destIndustry);
		local acceptedCargos = AIIndustryType.GetAcceptedCargo(destType);
		if(acceptedCargos == null) return;
		local feederRadius = 50;

		foreach(cargo, _ in acceptedCargos) {
			if(CargoUtils.IsPaxOrMail(cargo)) continue;
			foreach(indId, _ in AIIndustryList()) {
				if(FreightNetwork.servedSources.rawin(indId)) continue;
				if(indId == branchRoute.srcHgStation.place.industry) continue;
				local indLoc = AIIndustry.GetLocation(indId);
				if(AIMap.DistanceManhattan(indLoc, stationTile) > feederRadius) continue;
				local srcType = AIIndustry.GetIndustryType(indId);
				local produces = false;
				foreach(pc, _ in AIIndustryType.GetProducedCargo(srcType)) {
					if(pc == cargo) { produces = true; break; }
				}
				if(!produces) continue;
				if(AIIndustryType.IsProcessingIndustry(srcType)) {
					if(AIIndustry.GetLastMonthProduction(indId, cargo) <= 0) continue;
				}
				FreightNetwork.pendingFeeders.push({
					srcIndustry = indId,
					branchStationTile = stationTile,
					cargo = cargo,
					branchRouteId = branchRoute.id
				});
				HgLog.Info("FreightNetwork.ScanFeeders: queued feeder "
					+ AIIndustry.GetName(indId) + " -> " + srcStation.GetName()
					+ " [" + AICargo.GetName(cargo) + "]");
			}
		}
	}

	function FreightNetwork::ScanDestFeeders(spineRoute) {
		local destStation = spineRoute.destHgStations[0];
		local stationTile = destStation.platformTile;
		local destIndustry = FreightNetwork.state.destIndustry;
		if(!AIIndustry.IsValidIndustry(destIndustry)) return;
		local destType = AIIndustry.GetIndustryType(destIndustry);
		local acceptedCargos = AIIndustryType.GetAcceptedCargo(destType);
		if(acceptedCargos == null) return;
		local feederRadius = 50;
		local insertPos = 0;

		foreach(cargo, _ in acceptedCargos) {
			if(CargoUtils.IsPaxOrMail(cargo)) continue;
			foreach(indId, _ in AIIndustryList()) {
				if(FreightNetwork.servedSources.rawin(indId)) continue;
				if(indId == destIndustry) continue;
				local indLoc = AIIndustry.GetLocation(indId);
				if(AIMap.DistanceManhattan(indLoc, stationTile) > feederRadius) continue;
				local srcType = AIIndustry.GetIndustryType(indId);
				local produces = false;
				foreach(pc, _ in AIIndustryType.GetProducedCargo(srcType)) {
					if(pc == cargo) { produces = true; break; }
				}
				if(!produces) continue;
				if(AIIndustryType.IsProcessingIndustry(srcType)) {
					if(AIIndustry.GetLastMonthProduction(indId, cargo) <= 0) continue;
				}
				FreightNetwork.pendingFeeders.insert(insertPos, {
					srcIndustry = indId,
					branchStationTile = stationTile,
					cargo = cargo,
					branchRouteId = spineRoute.id,
					isDestFeeder = true
				});
				insertPos++;
				HgLog.Info("FreightNetwork.ScanDestFeeders: queued priority feeder "
					+ AIIndustry.GetName(indId) + " -> " + destStation.GetName()
					+ " [" + AICargo.GetName(cargo) + "]");
			}
		}
	}

	function FreightNetwork::TryBuildFeeder() {
		while(FreightNetwork.pendingFeeders.len() > 0) {
			local feeder = FreightNetwork.pendingFeeders[0];

			// Drop if industry closed or already served by a spine/branch route
			if(!AIIndustry.IsValidIndustry(feeder.srcIndustry)) {
				FreightNetwork.pendingFeeders.remove(0);
				continue;
			}
			if(FreightNetwork.servedSources.rawin(feeder.srcIndustry)) {
				FreightNetwork.pendingFeeders.remove(0);
				continue;
			}

			// Drop if branch route gone
			local branchRoute = Route.allRoutes.rawin(feeder.branchRouteId) ? Route.allRoutes[feeder.branchRouteId] : null;
			if(branchRoute == null || branchRoute.IsRemoved()) {
				FreightNetwork.pendingFeeders.remove(0);
				continue;
			}

			// Resolve branch station group as transfer destination
			local branchTile = feeder.branchStationTile;
			local destSg = HgStation.tileStation.rawin(branchTile)
				? HgStation.worldInstances[HgStation.tileStation[branchTile]].stationGroup
				: null;
			if(destSg == null) {
				HgLog.Warning("FreightNetwork.TryBuildFeeder: cannot find branch station group, deferring");
				return;
			}

			// Collect all pending entries for this same industry + station (may be multiple cargos)
			local batchIndices = [];
			local batchCargos = [];
			for(local i = 0; i < FreightNetwork.pendingFeeders.len(); i++) {
				local f = FreightNetwork.pendingFeeders[i];
				if(f.srcIndustry == feeder.srcIndustry && f.branchStationTile == feeder.branchStationTile) {
					batchIndices.push(i);
					batchCargos.push(f.cargo);
				}
			}

			// Build one feeder route per cargo; reuses or places a new truck stop per build
			local anyBuilt = false;
			foreach(cargo in batchCargos) {
				local src = HgIndustry(feeder.srcIndustry, true);
				local isDestFeeder = feeder.rawin("isDestFeeder") && feeder.isDestFeeder;
				local builderOpts = isDestFeeder ? {transfer = false} : {};	// set transfer false, or route builder will give transfer orders instead of unload orders
				local builder = RoadRouteBuilder(destSg, src, cargo, builderOpts);
				local route = builder.Build();
				if(route != null) {
					anyBuilt = true;
					HgLog.Info("FreightNetwork.TryBuildFeeder: built feeder "
						+ AIIndustry.GetName(feeder.srcIndustry) + " -> " + destSg.GetName()
						+ " [" + AICargo.GetName(cargo) + "]");
				} else {
					HgLog.Warning("FreightNetwork.TryBuildFeeder: builder failed for "
						+ AIIndustry.GetName(feeder.srcIndustry)
						+ " [" + AICargo.GetName(cargo) + "], blacklisting");
				}
			}

			// Remove all batch entries (reverse order to keep indices valid)
			for(local i = batchIndices.len() - 1; i >= 0; i--) {
				FreightNetwork.pendingFeeders.remove(batchIndices[i]);
			}
			if(anyBuilt) {
				FreightNetwork.servedSources.rawset(feeder.srcIndustry, true);
			}
			return; // one industry per Step()
		}
	}

	function FreightNetwork::FindSpine() {
		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		local mapLongSide = max(mapW, mapH);
		local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();

		HgLog.Info("FreightNetwork.FindSpine: mapLongSide=" + mapLongSide);

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
			local maxRouteDist = max(mapLongSide * edgePct / 100, 100);
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
				local acceptedCargos = AIIndustryType.GetAcceptedCargo(destType);
				if(acceptedCargos == null) continue;
				foreach(cargo, _ in acceptedCargos) {
					if(CargoUtils.IsPaxOrMail(cargo)) continue;
					if(!cargoProducers.rawin(cargo)) continue;

					foreach(src in cargoProducers[cargo]) {
						if(src.id == destId) continue;
						if(FreightNetwork.failedPairs.rawin(src.id + "-" + destId)) continue;
						if(FreightNetwork.IsIndustryInTown(src.id) && FreightNetwork.IsIndustryInTown(destId)) continue;
						local dist = AIMap.DistanceManhattan(src.loc, destLoc);
						if(dist < 30 || dist >= maxRouteDist) continue;

						if(edgePct < 100) {
							local pDir = FreightNetwork.GetPrimaryDirection(destLoc, src.loc);
							local inlandOk = false;
							if(minEdgeDist == dN)      inlandOk = (pDir.dy == 1);
							else if(minEdgeDist == dS) inlandOk = (pDir.dy == -1);
							else if(minEdgeDist == dW) inlandOk = (pDir.dx == 1);
							else                       inlandOk = (pDir.dx == -1);
							if(!inlandOk) continue;
						}

						local production = AIIndustry.GetLastMonthProduction(src.id, cargo);
						local srcType = AIIndustry.GetIndustryType(src.id);
						if(AIIndustryType.IsProcessingIndustry(srcType)) {
							if(production <= 0) continue;
						} else {
							if(production <= 0) production = 80; // floor for month 0 before any production recorded
						}
						local estimate = Route.Estimate(
							AIVehicle.VT_RAIL, cargo, dist, production, false, infraTypes);
						if(estimate == null || estimate.value <= 0) continue;

						local score = estimate.value * 1000 / (minEdgeDist + 100);
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

				local srcPlace = HgIndustry(bestCandidate.srcId, true);
				local destPlace = HgIndustry(bestCandidate.destId, false);

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
					HgLog.Warning("FreightNetwork.FindSpine: Build failed, blacklisting pair src="
						+ bestCandidate.srcId + " dest=" + bestCandidate.destId);
					FreightNetwork.failedPairs.rawset(bestCandidate.srcId + "-" + bestCandidate.destId, true);
					return false;
				}

				FreightNetwork.state.destIndustry = bestCandidate.destId;
				FreightNetwork.state.destPlace = destPlace;
				FreightNetwork.servedDests.rawset(bestCandidate.destId, 1);
				FreightNetwork.servedSources.rawset(bestCandidate.srcId, true);
				FreightNetwork.state.lastBuiltRoute = newRoutes[0];
				FreightNetwork.ScanDestFeeders(newRoutes[0]);
				FreightNetwork.ScanFeeders(newRoutes[0]);
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
		// Scan a wider range of the path to find a suitable junction location.
		// minDist=10 skips the first 10 tiles (near the station platform/depot).
		// maxDist is capped to leave 4 tiles at the far end but allow coverage
		// of the middle of short routes.
		local pathLen = arr2.len();
		local jMinDist = 10;
		local jMaxDist = max(30, pathLen - 10);
		local result = FourWayJunction.TryBuildNearStation(arr2, arr1, jMinDist, jMaxDist, true);

		local srcLoc = (route.srcHgStation != null && route.srcHgStation.place != null)
			? route.srcHgStation.place.GetLocation()
			: -1;
		// Use .industry directly — AIIndustry.GetIndustryID(tile) only matches the exact tile,
		// missing most of the industry footprint.
		local srcIndustry = (srcLoc != -1)
			? (route.srcHgStation.place instanceof HgIndustry ? route.srcHgStation.place.industry : -1)
			: -1;

		// Determine leg1/leg2 now, while we have the route's pathSrcToDest available.
		// leg1Path deepest tile must be on pathSrcToDest (spine forward track, spur→dest).
		// leg2Path is the other arm (dest→spur, return track).
		// This avoids re-checking against lastBuiltRoute in SearchAndConnect, which may
		// have changed to a branch route by the time those junctions are consumed.
		local srcToDestSet = {};
		foreach(t in arr1) srcToDestSet.rawset(t, true);

		local recordedCount = 0;
		if(result.leftTile != -1) {
			local ap = result.leftPath;
			local ip = result.leftInboundPath;
			local legs = null;
			if(ap != null && ip != null) {
				local deepestInbound = ip[ip.len() - 1];
				local deepestArm = ap[ap.len() - 1];
				if(srcToDestSet.rawin(deepestInbound))
					legs = {leg1Path = ip, leg2Path = ap};
				else if(srcToDestSet.rawin(deepestArm))
					legs = {leg1Path = ap, leg2Path = ip};
			}
			if(legs != null) {
				FreightNetwork.availableJunctions.push({
					mergeTile = result.leftTile,
					leg1Path = legs.leg1Path,
					leg2Path = legs.leg2Path,
					srcIndustry = srcIndustry,
					primaryRadius = 10,
					perpOutRadius = 5,
					perpInRadius = 0,
					triedIndustries = {}
				});
				recordedCount++;
			} else {
				HgLog.Warning("FreightNetwork.BuildJunctions: cannot resolve legs for leftTile="
					+ result.leftTile + ", skipping");
			}
		}
		if(result.rightTile != -1) {
			local ap = result.rightPath;
			local ip = result.rightInboundPath;
			local legs = null;
			if(ap != null && ip != null) {
				local deepestInbound = ip[ip.len() - 1];
				local deepestArm = ap[ap.len() - 1];
				if(srcToDestSet.rawin(deepestInbound))
					legs = {leg1Path = ip, leg2Path = ap};
				else if(srcToDestSet.rawin(deepestArm))
					legs = {leg1Path = ap, leg2Path = ip};
			}
			if(legs != null) {
				FreightNetwork.availableJunctions.push({
					mergeTile = result.rightTile,
					leg1Path = legs.leg1Path,
					leg2Path = legs.leg2Path,
					srcIndustry = srcIndustry,
					primaryRadius = 10,
					perpOutRadius = 5,
					perpInRadius = 0,
					triedIndustries = {}
				});
				recordedCount++;
			} else {
				HgLog.Warning("FreightNetwork.BuildJunctions: cannot resolve legs for rightTile="
					+ result.rightTile + ", skipping");
			}
		}
		if(recordedCount > 0) {
			HgLog.Info("FreightNetwork.BuildJunctions: recorded junctions count=" + recordedCount
				+ " leftTile=" + result.leftTile + " rightTile=" + result.rightTile
				+ " srcIndustry=" + srcIndustry);
		} else {
			HgLog.Warning("FreightNetwork.BuildJunctions: no junctions built near source");
		}

		// Do NOT clear lastBuiltRoute here — SearchAndConnect needs it to access spine paths/stations.
	}

	function FreightNetwork::SearchAndConnect() {
		if(FreightNetwork.availableJunctions.len() == 0) {
			return false;
		}

		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
		if(!AIIndustry.IsValidIndustry(FreightNetwork.state.destIndustry)) {
			HgLog.Warning("FreightNetwork.SearchAndConnect: dest industry closed, aborting");
			return false;
		}
		local destSrcCount = FreightNetwork.servedDests.rawin(FreightNetwork.state.destIndustry)
			? FreightNetwork.servedDests[FreightNetwork.state.destIndustry] : 0;
		local maxSources = 12;
		if(destSrcCount >= maxSources) {
			HgLog.Info("FreightNetwork.SearchAndConnect: dest already has " + maxSources + " sources, stop connecting more sources");
			FreightNetwork.availableJunctions.clear();
			return false;
		}
		local destTile = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);
		local destType = AIIndustry.GetIndustryType(FreightNetwork.state.destIndustry);

		local allIndustries = AIIndustryList();

		local mapLongSide = max(mapW, mapH);
		local maxRounds = mapLongSide / 10 + 1;
		local rounds = 0;

		// Outer loop: keep expanding all junctions in rounds until a source is found
		// or all junctions are removed (primary extent exceeds map boundary).
		while(FreightNetwork.availableJunctions.len() > 0) {
			rounds++;
			if(rounds > maxRounds) {
				HgLog.Info("FreightNetwork.SearchAndConnect: round limit reached, giving up");
				return false;
			}
			local ji = 0;
			local anyActive = false;
			while(ji < FreightNetwork.availableJunctions.len()) {
				local junc = FreightNetwork.availableJunctions[ji];
				local mergeTile = junc.mergeTile;
				if(mergeTile == -1) {
					FreightNetwork.availableJunctions.remove(ji);
					continue;
				}

				local pDir = FreightNetwork.GetPrimaryDirection(destTile, mergeTile);
				local perpDx = pDir.dy;
				local perpDy = -pDir.dx;
				// Outward = direction from spine toward arm tip.
				// leg1Path[0] = arm outer tip (mergeTile), leg1Path[last] = spine tile.
				local leg1 = junc.leg1Path;
				local spineTile = leg1[leg1.len() - 1];
				local armPerpOffset =
					(AIMap.GetTileX(mergeTile) - AIMap.GetTileX(spineTile)) * perpDx
					+ (AIMap.GetTileY(mergeTile) - AIMap.GetTileY(spineTile)) * perpDy;
				local perpOutSign = (armPerpOffset >= 0) ? 1 : -1;
				local perpInSign = -perpOutSign;

				local pFarX = AIMap.GetTileX(mergeTile) + pDir.dx * (junc.primaryRadius + 10);
				local pFarY = AIMap.GetTileY(mergeTile) + pDir.dy * (junc.primaryRadius + 10);
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
				foreach(indId, _ in allIndustries) {
					if(FreightNetwork.servedSources.rawin(indId)) continue;
					if(junc.triedIndustries.rawin(indId)) continue;
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
					if(AIIndustryType.IsProcessingIndustry(srcType)) {
						if(AIIndustry.GetLastMonthProduction(indId, matchCargo) <= 0) continue;
					}
					if(AIMap.DistanceManhattan(indLoc, mergeTile) < 30) continue;
					// Reject industries not in the same direction to the destination
					local toMerge = FreightNetwork.GetPrimaryDirection(indLoc, mergeTile);
					local toDest = FreightNetwork.GetPrimaryDirection(mergeTile, destTile);
					if(toMerge.dx != toDest.dx || toMerge.dy != toDest.dy) continue;
					found = {industry = indId, tile = indLoc, cargo = matchCargo};
					break;
				}

				if(found != null) {
					HgLog.Info("FreightNetwork.SearchAndConnect: found source "
						+ AIIndustry.GetName(found.industry) + " at " + HgTile(found.tile));

					local spineRoute = FreightNetwork.state.lastBuiltRoute;
					if(spineRoute == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: lastBuiltRoute null, skipping");
						FreightNetwork.availableJunctions.remove(ji);
						continue;
					}

					local engineSet = spineRoute.GetLatestEngineSet();
					if(engineSet == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: engineSet null, skipping");
						FreightNetwork.availableJunctions.remove(ji);
						continue;
					}

					// BuildFirstTrain deploys 2 trains (engine + clone) for non-single routes.
					// Add estimated track cost for the spur (both directions, matching Estimator.GetBuildingCost for VT_RAIL).
					// Modified formula as GetBuildingCost estimation is very high.
					local branchDist = AIMap.DistanceManhattan(found.tile, mergeTile);
					local demolishFarm = HogeAI.GetInflatedMoney(540) * 25 / 100;
					local trackCostPerTile = AIRail.GetBuildCost(engineSet.railType, AIRail.BT_TRACK) + demolishFarm;
					local estimatedTrackCost = trackCostPerTile * 2 * branchDist
						+ AIRail.GetBuildCost(engineSet.railType, AIRail.BT_TRACK) * 120;
					local estimatedCost = engineSet.price * 2 + estimatedTrackCost;
					HgLog.Info("FreightNetwork cost check: estimatedCost=" + estimatedCost
						+ " usableMoney=" + HogeAI.GetUsableMoney()
						+ " bankBalance=" + AICompany.GetBankBalance(AICompany.COMPANY_SELF)
						+ " maxLoan=" + AICompany.GetMaxLoanAmount()
						+ " currentLoan=" + AICompany.GetLoanAmount()
						+ " quarterlyIncome=" + HogeAI.GetQuarterlyIncome(4));
					if(HogeAI.Get().IsTooExpensive(estimatedCost)) {
						HgLog.Info("FreightNetwork.SearchAndConnect: deferred (cost " + estimatedCost + " too expensive)");
						local deferred = FreightNetwork.availableJunctions[ji];
						FreightNetwork.availableJunctions.remove(ji);
						FreightNetwork.availableJunctions.push(deferred);
						return false;
					}

					// Match rail type of spine so branch uses electrified/monorail/maglev correctly
					local savedRailType = AIRail.GetCurrentRailType();
					AIRail.SetCurrentRailType(engineSet.railType);

					// Build src station
					local srcPlace = HgIndustry(found.industry, true);
					local destTile2 = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);
					local srcStationFactory = SrcRailStationFactory();
					srcStationFactory.platformLength = spineRoute.GetPlatformLength();
					local srcHgStation = srcStationFactory.CreateBest(srcPlace, found.cargo, destTile2);
					if(srcHgStation == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: failed to build src station, skipping for this junction");
						junc.triedIndustries.rawset(found.industry, true);
						AIRail.SetCurrentRailType(savedRailType);
						ji++;
						continue;
					}
					srcHgStation.cargo = found.cargo;
					srcHgStation.isSourceStation = true;
					if(!srcHgStation.BuildExec()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: srcHgStation.BuildExec failed");
						AIRail.SetCurrentRailType(savedRailType);
						ji++;
						continue;
					}

					// leg1Path/leg2Path were resolved at junction build time (BuildJunctions)
					// against the route that was active then — no runtime spine lookup needed.
					// leg1Path: spur→dest (arm tip toward spine fwd track)
					// leg2Path: dest→spur (arm tip toward spine return track)
					local leg1Tiles = junc.leg1Path;
					local leg2Tiles = junc.leg2Path;

					// Arm paths are stored outermost-first: leg1Tiles[0] = arm outer tip.
					// We pass the arm-tip start tuple directly to Initialize, bypassing
					// PathToStation's GetStartArray so the pathfinder starts exactly at
					// the arm outer tip heading away from the junction, not at a spine tile.
					local arm1Start = [[leg1Tiles[0], leg1Tiles[1], leg1Tiles[2], leg1Tiles[3]]];
					local arm2Start = [[leg2Tiles[0], leg2Tiles[1], leg2Tiles[2], leg2Tiles[3]]];

					local pathBuildParams = {
						engine          = engineSet.engine,
						cargo           = found.cargo,
						platformLength  = spineRoute.GetPlatformLength(),
						distance        = AIMap.DistanceManhattan(found.tile, destTile2),
						isTransfer      = false,
						isBiDirectional = false,
						isSingle        = false
					};

					// Leg 1 (pathSrcToDest, isReverse=true): inbound arm tip → spur departures.
					// The forward trip (spur→dest) uses the inbound arm: trains depart spur
					// station, travel spur track, merge at At(2,2) onto x=0 spine toward dest.
					// Goals = GetDeparturesTiles so signals face: spur_departures → At(2,2).
					local ignoreTiles1 = [];
					ignoreTiles1.extend(srcHgStation.GetArrivalsTile());
					ignoreTiles1.extend(srcHgStation.GetIgnoreTiles());
					local builder1 = RailPathBuilder();
					builder1.Initialize(
						Container(arm1Start),
						Container(srcHgStation.GetDeparturesTiles()),
						ignoreTiles1,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						null
					);
					builder1.dangerTiles = srcHgStation.GetArrivalDangerTiles();
					foreach(goalTiles in srcHgStation.GetArrivalsTiles()) {
						RailPathFinder.SetRevOkTiles(builder1.revOkTiles, goalTiles);
					}
					builder1.pathBuildParams = pathBuildParams;
					builder1.isReverse = true;
					builder1.isRevReverse = false;
					if(!builder1.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: outbound spur build failed");
						srcHgStation.Remove();
						junc.triedIndustries.rawset(found.industry, true);
						AIRail.SetCurrentRailType(savedRailType);
						ji++;
						continue;
					}
					local builtPath1 = builder1.buildedPath;

					// Leg 2 (pathDestToSrc, isReverse=false): outbound arm tip → spur arrivals.
					// The return trip (dest→spur) uses the outbound arm: trains exit x=1 spine
					// at At(3,1), travel spur track, arrive at spur station arrivals.
					// Goals = GetArrivalsTiles so signals face: At(3,1) → spur_arrivals.
					local ignoreTiles2 = [];
					ignoreTiles2.extend(srcHgStation.GetDeparturesTile());
					ignoreTiles2.extend(srcHgStation.GetIgnoreTiles());
					local builder2 = RailPathBuilder();
					builder2.Initialize(
						Container(arm2Start),
						Container(srcHgStation.GetArrivalsTiles()),
						ignoreTiles2,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						builtPath1.path
					);
					builder2.dangerTiles = srcHgStation.GetDepartureDangerTiles();
					foreach(goalTiles in srcHgStation.GetDeparturesTiles()) {
						RailPathFinder.SetRevOkTiles(builder2.revOkTiles, goalTiles);
					}
					builder2.pathBuildParams = pathBuildParams;
					builder2.isReverse = false;
					builder2.isRevReverse = false;
					if(!builder2.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: return spur build failed");
						builtPath1.Remove();
						srcHgStation.Remove();
						junc.triedIndustries.rawset(found.industry, true);
						AIRail.SetCurrentRailType(savedRailType);
						ji++;
						continue;
					}
					local builtPath2 = builder2.buildedPath;

					// Create TrainRoute (auto-registers in Route.allRoutes via constructor)
					local newRoute = TrainRoute(
						TrainRoute.RT_ROOT,
						found.cargo,
						srcHgStation,
						spineRoute.destHgStation,
						builtPath1,
						builtPath2
					);
					newRoute.isBiDirectional = false;
					newRoute.isTransfer = false;
					newRoute.isSrcTransfer = false;
					newRoute.startDate = AIDate.GetCurrentDate();
					newRoute.latestEngineSet = engineSet;
					newRoute.srcDepot = srcHgStation.GetDepotTile() != null ? srcHgStation.GetDepotTile() : builder1.srcDepot;
					newRoute.destDepot = spineRoute.destDepot;
					newRoute.Initialize();
					newRoute.CalculateUseDepots();
					TrainRoute.instances.push(newRoute);
					PlaceDictionary.Get().AddRoute(newRoute);

					// Deploy initial train; skip DoPostBuild to avoid uncontrolled extensions
					if(!newRoute.BuildFirstTrain()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: BuildFirstTrain failed, continuing");
					}

					FreightNetwork.ScanFeeders(newRoute);
					FreightNetwork.servedSources.rawset(found.industry, true);
					FreightNetwork.availableJunctions.remove(ji);

					// Log total sources connected to destination - used to prevent traffic jams from too many connections
					local newDestSrcCount = (FreightNetwork.servedDests.rawin(FreightNetwork.state.destIndustry)
						? FreightNetwork.servedDests[FreightNetwork.state.destIndustry] : 0) + 1;
					FreightNetwork.servedDests.rawset(FreightNetwork.state.destIndustry, newDestSrcCount);

					// Update lastBuiltRoute so BuildJunctions (called from Step after we
					// return) places new junctions near this branch station, not on the spine.
					FreightNetwork.state.lastBuiltRoute = newRoute;
					AIRail.SetCurrentRailType(savedRailType);
					HgLog.Info("FreightNetwork.SearchAndConnect: connected via junction "
						+ AIIndustry.GetName(found.industry)
						+ " -> "
						+ AIIndustry.GetName(FreightNetwork.state.destIndustry));
					return true;
				}

				// No source found — expand search radius for next round
				junc.primaryRadius += 10;
				junc.perpOutRadius += 5;
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
