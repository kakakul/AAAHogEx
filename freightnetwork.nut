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
}

	function FreightNetwork::Step() {
		if(HogeAI.Get().IsPaxMailOnly()) return;
		// Guard against stale destIndustry after game load (industry may have closed).
		if(FreightNetwork.state.destIndustry != null && FreightNetwork.state.destPlace == null) {
			HgLog.Warning("FreightNetwork.Step: destPlace null after load, resetting network");
			FreightNetwork.state.destIndustry = null;
			FreightNetwork.state.networkId++;
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
			servedDests = FreightNetwork.servedDests,
			failedPairs = FreightNetwork.failedPairs
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
				local infraTypes = AIIndustryType.GetAcceptedCargo(destType);
				if(infraTypes == null) continue;
				foreach(cargo, _ in infraTypes) {
					if(CargoUtils.IsPaxOrMail(cargo)) continue;
					if(!cargoProducers.rawin(cargo)) continue;

					foreach(src in cargoProducers[cargo]) {
						if(src.id == destId) continue;
						if(FreightNetwork.failedPairs.rawin(src.id + "-" + destId)) continue;
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
						if(production <= 0) production = 80; // floor for month 0 before any production recorded
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

		if(result.leftTile != -1 || result.rightTile != -1) {
			FreightNetwork.availableJunctions.push({
				leftTile = result.leftTile,
				rightTile = result.rightTile,
				leftPath = result.leftPath,
				rightPath = result.rightPath,
				leftInboundPath = result.leftInboundPath,
				rightInboundPath = result.rightInboundPath,
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

		// Do NOT clear lastBuiltRoute here — SearchAndConnect needs it to access spine paths/stations.
	}

	function FreightNetwork::SearchAndConnect() {
		if(FreightNetwork.availableJunctions.len() == 0) {
			return false;
		}

		local ai = HogeAI.Get();
		local mapW = AIMap.GetMapSizeX();
		local mapH = AIMap.GetMapSizeY();
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
				foreach(indId, _ in allIndustries) {
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

					// Build src station
					local srcPlace = HgIndustry(found.industry, true);
					local destTile2 = AIIndustry.GetLocation(FreightNetwork.state.destIndustry);
					local srcStationFactory = SrcRailStationFactory();
					srcStationFactory.platformLength = spineRoute.GetPlatformLength();
					local srcHgStation = srcStationFactory.CreateBest(srcPlace, found.cargo, destTile2);
					if(srcHgStation == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: failed to build src station, blacklisting");
						FreightNetwork.servedSources.rawset(found.industry, true);
						ji++;
						continue;
					}
					srcHgStation.cargo = found.cargo;
					srcHgStation.isSourceStation = true;
					if(!srcHgStation.BuildExec()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: srcHgStation.BuildExec failed");
						ji++;
						continue;
					}

					// Determine which junction arm connects to which spine direction.
					// Each RightDivergeJunction has two arms:
					//   inbound arm (At(2,2) end): spur trains MERGE INTO spine → for leg 1 (spur→dest)
					//   outbound arm (At(3,1) end): spine trains DIVERGE to spur → for leg 2 (return)
					// The inbound arm's deepest tile (At(0,-1)) is on one of the two spine paths.
					// If it's on pathSrcToDest, that junction handles leg1=inbound, leg2=outbound.
					// Otherwise use the other junction (leftJ vs rightJ are on opposite spine sides).
					local srcToDestSet = {};
					foreach(t in spineRoute.pathSrcToDest.array_) srcToDestSet.rawset(t, true);

					local leg1Tiles = null; // inbound arm → leg 1 (spur→dest)
					local leg2Tiles = null; // outbound arm → leg 2 (dest→spur)

					if(junc.leftInboundPath != null && junc.leftPath != null) {
						local deepest = junc.leftInboundPath[junc.leftInboundPath.len() - 1];
						if(srcToDestSet.rawin(deepest)) {
							leg1Tiles = junc.leftInboundPath;
							leg2Tiles = junc.leftPath;
						}
					}
					if(leg1Tiles == null && junc.rightInboundPath != null && junc.rightPath != null) {
						local deepest = junc.rightInboundPath[junc.rightInboundPath.len() - 1];
						if(srcToDestSet.rawin(deepest)) {
							leg1Tiles = junc.rightInboundPath;
							leg2Tiles = junc.rightPath;
						}
					}
					if(leg1Tiles == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: cannot determine junction direction, skipping");
						srcHgStation.Remove();
						FreightNetwork.availableJunctions.remove(ji);
						continue;
					}

					// Use spine sub-paths ending just before each arm's deepest spine tile.
					// The pathfinder enters the junction from the spine side, following the
					// arm's existing rail direction, so DoBuild never demolishes shared tiles.
					local leg1DeepestTile = leg1Tiles[leg1Tiles.len() - 1];
					local leg2DeepestTile = leg2Tiles[leg2Tiles.len() - 1];

					if(spineRoute.pathDestToSrc == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: pathDestToSrc null, skipping");
						srcHgStation.Remove();
						ji++;
						continue;
					}
					local spinePathFwd = spineRoute.pathSrcToDest.path.SubPathEnd(leg1DeepestTile);
					local spinePathRev = spineRoute.pathDestToSrc.path.SubPathEnd(leg2DeepestTile);

					if(spinePathFwd == null || spinePathFwd.GetParent() == null
							|| spinePathFwd.GetParent().GetParent() == null
							|| spinePathFwd.GetParent().GetParent().GetParent() == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: spine fwd sub-path too short");
						srcHgStation.Remove();
						ji++;
						continue;
					}
					if(spinePathRev == null || spinePathRev.GetParent() == null
							|| spinePathRev.GetParent().GetParent() == null
							|| spinePathRev.GetParent().GetParent().GetParent() == null) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: spine rev sub-path too short");
						srcHgStation.Remove();
						ji++;
						continue;
					}

					local pathBuildParams = {
						engine          = engineSet.engine,
						cargo           = found.cargo,
						platformLength  = spineRoute.GetPlatformLength(),
						distance        = AIMap.DistanceManhattan(found.tile, destTile2),
						isTransfer      = false,
						isBiDirectional = false,
						isSingle        = false
					};

					// Leg 1: spine → src station via inbound arm
					// PathToStation internally calls srcPathGetter.Get().Reverse() then GetStartArray.
					local temp_fwd = spinePathFwd;
					local builder1 = RailPathBuilder();
					builder1.PathToStation(
						GetterFunction(function():(temp_fwd) {
							return temp_fwd;
						}),
						srcHgStation,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						null,
						true
					);
					builder1.pathBuildParams = pathBuildParams;
					builder1.isReverse = false;
					builder1.isRevReverse = false;
					if(!builder1.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: outbound spur build failed");
						srcHgStation.Remove();
						ji++;
						continue;
					}
					local builtPath1 = builder1.buildedPath;

					// Leg 2: src station → spine via outbound arm
					local temp_rev = spinePathRev;
					local builder2 = RailPathBuilder();
					builder2.PathToStation(
						GetterFunction(function():(temp_rev) {
							return temp_rev;
						}),
						srcHgStation,
						HogeAI.Get().pathFindLimit,
						HogeAI.Get(),
						builtPath1.path,
						false
					);
					builder2.pathBuildParams = pathBuildParams;
					builder2.isReverse = true;
					builder2.isRevReverse = false;
					if(!builder2.Build()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: return spur build failed");
						builtPath1.Remove();
						srcHgStation.Remove();
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

					// Deploy initial train; skip DoPostBuild to avoid uncontrolled extensions
					if(!newRoute.BuildFirstTrain()) {
						HgLog.Warning("FreightNetwork.SearchAndConnect: BuildFirstTrain failed, continuing");
					}

					FreightNetwork.servedSources.rawset(found.industry, true);
					FreightNetwork.availableJunctions.remove(ji);
					HgLog.Info("FreightNetwork.SearchAndConnect: connected via junction "
						+ AIIndustry.GetName(found.industry)
						+ " -> "
						+ AIIndustry.GetName(FreightNetwork.state.destIndustry));
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
