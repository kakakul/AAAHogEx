// paxmailnetwork.nut
// HogNet passenger/mail network expansion. Network mode only.

class PaxMailNetwork {
	static state = {
		nextTraceId = 1,
		pairBlacklist = {},
		lastPerformanceYear = null
	};
}

	function PaxMailNetwork::NextTraceId() {
		local id = PaxMailNetwork.state.nextTraceId;
		PaxMailNetwork.state.nextTraceId = id + 1;
		return id;
	}

	function PaxMailNetwork::GetPairKey(connTown, unservedTown, paxCargo, vehicleType) {
		local a = min(connTown, unservedTown);
		local b = max(connTown, unservedTown);
		return a + "-" + b + "-" + paxCargo + "-" + vehicleType;
	}

	function PaxMailNetwork::IsPairBlacklisted(connTown, unservedTown, paxCargo, vehicleType) {
		local key = PaxMailNetwork.GetPairKey(connTown, unservedTown, paxCargo, vehicleType);
		if(!PaxMailNetwork.state.pairBlacklist.rawin(key)) return false;
		local limitDate = PaxMailNetwork.state.pairBlacklist[key];
		if(limitDate > AIDate.GetCurrentDate()) return true;
		PaxMailNetwork.state.pairBlacklist.rawdelete(key);
		return false;
	}

	function PaxMailNetwork::AddPairBlacklist(candidate, reason) {
		local srcTown = candidate.rawin("connTown") ? candidate.connTown : candidate.src.town;
		local destTown = candidate.rawin("destTown") ? candidate.destTown : candidate.dest.town;
		local key = PaxMailNetwork.GetPairKey(srcTown, destTown, candidate.cargo, candidate.vehicleType);
		local limitDate = AIDate.GetCurrentDate() + 365 * 2;
		PaxMailNetwork.state.pairBlacklist.rawset(key, limitDate);
		HgLog.Info("PaxMailNetwork.BlacklistAdd id:"+candidate.routeTraceId
				+" reason:"+reason
				+" mode:"+candidate.modeLabel
				+" limit:"+DateUtils.ToString(limitDate)
				+" "+candidate.explain);
	}

	function PaxMailNetwork::CanTryCandidate(src, dest, connTown, unservedTown, paxCargo, vehicleType, label) {
		if(PaxMailNetwork.IsPairBlacklisted(connTown, unservedTown, paxCargo, vehicleType)) {
			HgLog.Info("PaxMailNetwork.BlacklistSkip reason:cooldown mode:"+label
					+" "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown));
			return false;
		}
		if(Place.IsNgPlace(src, paxCargo, vehicleType) || Place.IsNgPlace(dest, paxCargo, vehicleType)) {
			HgLog.Info("PaxMailNetwork.BlacklistSkip reason:NgPlace mode:"+label
					+" "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown));
			return false;
		}
		if(Place.IsNgPathFindPair(src, dest, vehicleType)) {
			HgLog.Info("PaxMailNetwork.BlacklistSkip reason:NgPathFindPair mode:"+label
					+" "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown));
			return false;
		}
		return true;
	}

	function PaxMailNetwork::LogAnnualPerformance(paxCargo) {
		local year = AIDate.GetYear(AIDate.GetCurrentDate());
		if(PaxMailNetwork.state.lastPerformanceYear == year) return;
		PaxMailNetwork.state.lastPerformanceYear = year;

		foreach(route in Route.GetAllRoutes()) {
			if(route.routeTraceId == null) continue;
			if(!route.HasCargo(paxCargo)) continue;
			if(route.vehicleGroup == null) continue;

			local latestEngineSet = route.GetLatestEngineSet();
			local vehicleCount = 0;
			local depreciation = 0;
			local runningCost = 0;
			local vehicleList = route.GetVehicleList();
			vehicleCount = vehicleList.Count();
			if(latestEngineSet != null) {
				depreciation = latestEngineSet.GetDepreciation() * vehicleCount;
				runningCost = vehicleCount >= 1 ? AIEngine.GetRunningCost(latestEngineSet.engine) * vehicleCount : 0;
			}
			local profit = AIGroup.GetProfitLastYear(route.vehicleGroup);
			local infraCost = route.GetRouteInfrastractureCost();
			local net = profit - infraCost - depreciation;
			HgLog.Info("PaxMailNetwork.Performance trace:"+route.routeTraceId
					+" year:"+year
					+" mode:"+Route.Class(route.GetVehicleType()).GetLabel()
					+" routeId:"+route.id
					+" profit:"+profit
					+" runningCost:"+runningCost
					+" infraCost:"+infraCost
					+" depreciation:"+depreciation
					+" net:"+net
					+" vehicles:"+vehicleCount
					+" "+route);
		}
	}

	// Returns all station group IDs that are endpoints of any existing pax/mail route.
	// Used to enforce station-level global connectivity: a new pax/mail route must have
	// at least one endpoint whose station group is already in this set.
	function PaxMailNetwork::GetPassengerServedStationIds(paxCargo) {
		local served = {};
		foreach(route in Route.GetAllRoutes()) {
			if(!route.HasCargo(paxCargo)) continue;
			if(route.srcHgStation != null && route.srcHgStation.stationGroup != null) {
				served.rawset(route.srcHgStation.stationGroup.id, true);
			}
			if(route.destHgStation != null && route.destHgStation.stationGroup != null) {
				served.rawset(route.destHgStation.stationGroup.id, true);
			}
		}
		return served;
	}

	// Returns all towns that have at least one passenger route (any vehicle type).
	function PaxMailNetwork::AddServedTownFromStation(served, station) {
		if(station == null) return;
		if(station.place != null && station.place instanceof TownCargo) {
			served.rawset(station.place.town, true);
		}
		if(station.stationGroup == null) return;
		foreach(hgStation in station.stationGroup.hgStations) {
			if(hgStation.place != null && hgStation.place instanceof TownCargo) {
				served.rawset(hgStation.place.town, true);
			}
		}
	}

	function PaxMailNetwork::GetPassengerServedTowns(paxCargo) {
		local served = {};
		foreach(route in Route.GetAllRoutes()) {
			if(!route.HasCargo(paxCargo)) continue;
			PaxMailNetwork.AddServedTownFromStation(served, route.srcHgStation);
			PaxMailNetwork.AddServedTownFromStation(served, route.destHgStation);
		}
		return served;
	}

	function PaxMailNetwork::AddTownFromStation(towns, station) {
		if(station == null) return;
		if(station.place != null && station.place instanceof TownCargo) {
			towns.rawset(station.place.town, true);
		}
		if(station.stationGroup == null) return;
		foreach(hgStation in station.stationGroup.hgStations) {
			if(hgStation.place != null && hgStation.place instanceof TownCargo) {
				towns.rawset(hgStation.place.town, true);
			}
		}
	}

	function PaxMailNetwork::GetRouteTowns(route, isSrc) {
		local towns = {};
		PaxMailNetwork.AddTownFromStation(towns, isSrc ? route.srcHgStation : route.destHgStation);
		return towns;
	}

	function PaxMailNetwork::GetRouteGraphDistance(route) {
		if("pathDistance" in route && route.pathDistance != null && route.pathDistance > 0) {
			return route.pathDistance;
		}
		return route.GetDistance();
	}

	function PaxMailNetwork::AddGraphEdge(graph, fromTown, toTown, distance) {
		if(fromTown == toTown) return;
		if(!graph.rawin(fromTown)) graph.rawset(fromTown, {});
		local edges = graph[fromTown];
		if(!edges.rawin(toTown) || distance < edges[toTown]) {
			edges.rawset(toTown, distance);
		}
	}

	function PaxMailNetwork::GetNetworkGraph(paxCargo, connected) {
		local graph = {};
		foreach(route in Route.GetAllRoutes()) {
			if(!route.HasCargo(paxCargo)) continue;
			if(route.srcHgStation == null || route.destHgStation == null) continue;
			local srcTowns = PaxMailNetwork.GetRouteTowns(route, true);
			local destTowns = PaxMailNetwork.GetRouteTowns(route, false);
			local distance = PaxMailNetwork.GetRouteGraphDistance(route);
			foreach(srcTown, _ in srcTowns) {
				if(!connected.rawin(srcTown)) continue;
				foreach(destTown, _ in destTowns) {
					if(!connected.rawin(destTown)) continue;
					PaxMailNetwork.AddGraphEdge(graph, srcTown, destTown, distance);
					if(route.IsBiDirectional() || HogeAI.Get().IsNetworkMode()) {
						PaxMailNetwork.AddGraphEdge(graph, destTown, srcTown, distance);
					}
				}
			}
		}
		return graph;
	}

	function PaxMailNetwork::GetShortestNetworkDistance(graph, fromTown, toTown) {
		if(fromTown == toTown) return 0;
		local dist = {};
		local done = {};
		dist.rawset(fromTown, 0);

		while(true) {
			local bestTown = null;
			local bestDist = 99999999;
			foreach(town, d in dist) {
				if(done.rawin(town)) continue;
				if(d < bestDist) {
					bestDist = d;
					bestTown = town;
				}
			}
			if(bestTown == null) return null;
			if(bestTown == toTown) return bestDist;
			done.rawset(bestTown, true);
			if(!graph.rawin(bestTown)) continue;
			foreach(nextTown, edgeDist in graph[bestTown]) {
				if(done.rawin(nextTown)) continue;
				local nextDist = bestDist + edgeDist;
				if(!dist.rawin(nextTown) || nextDist < dist[nextTown]) {
					dist.rawset(nextTown, nextDist);
				}
			}
		}
	}

	function PaxMailNetwork::HasDirectTownRoute(townA, townB, paxCargo) {
		foreach(route in Route.GetAllRoutes()) {
			if(!route.HasCargo(paxCargo)) continue;
			if(route.srcHgStation == null || route.destHgStation == null) continue;
			local srcTowns = PaxMailNetwork.GetRouteTowns(route, true);
			local destTowns = PaxMailNetwork.GetRouteTowns(route, false);
			if(srcTowns.rawin(townA) && destTowns.rawin(townB)) return true;
			if((route.IsBiDirectional() || HogeAI.Get().IsNetworkMode())
					&& srcTowns.rawin(townB) && destTowns.rawin(townA)) return true;
		}
		return false;
	}

	function PaxMailNetwork::GetNearestConnectedDistance(town, connected) {
		local townLoc = AITown.GetLocation(town);
		local bestDist = 99999999;
		foreach(connTown, _ in connected) {
			local d = AIMap.DistanceManhattan(townLoc, AITown.GetLocation(connTown));
			if(d > 0 && d < bestDist) {
				bestDist = d;
			}
		}
		return bestDist;
	}

	function PaxMailNetwork::SortTownsByNetworkDistance(towns, connected) {
		towns.sort(function(a, b):(connected) {
			local da = PaxMailNetwork.GetNearestConnectedDistance(a, connected);
			local db = PaxMailNetwork.GetNearestConnectedDistance(b, connected);
			if(da != db) return da - db;
			return AITown.GetPopulation(b) - AITown.GetPopulation(a);
		});
	}

	function PaxMailNetwork::MakeCandidate(connTown, unservedTown, paxCargo, vehicleType, routeClass, estimate, dist, production, label, srcOverride = null, destOverride = null) {
		local traceId = PaxMailNetwork.NextTraceId();
		return {
			src        = srcOverride != null ? srcOverride : TownCargo(connTown, paxCargo, true),
			dest       = destOverride != null ? destOverride : TownCargo(unservedTown, paxCargo, true),
			connTown   = connTown,
			destTown   = unservedTown,
			vehicleType = vehicleType,
			estimate   = clone estimate,
			cargo      = paxCargo,
			distance   = dist,
			production = production,
			isBiDirectional = true,
			routeClass = routeClass,
			allowNetworkSourceReuse = true,
			requireFirstVehicle = true,
			routeTraceId = traceId,
			modeLabel = label,
			explain    = "GlobalConnect("+label+") "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown)+" dist:"+dist
		};
	}

	function PaxMailNetwork::MaybeUseCandidate(best, connTown, unservedTown, paxCargo, vehicleType, routeClass, estimate, dist, production, label, logCandidate = true) {
		if(estimate == null) return best;
		local score = estimate.value - dist;
		if(best != null && best.score >= score) return best;
		local candidate = PaxMailNetwork.MakeCandidate(connTown, unservedTown, paxCargo,
			vehicleType, routeClass, estimate, dist, production, label);
		candidate.score <- score;
		if(logCandidate) {
			HgLog.Info("PaxMailNetwork.Candidate id:"+candidate.routeTraceId
					+" mode:"+label
					+" estimate:"+estimate.value
					+" score:"+score
					+" dist:"+dist
					+" production:"+production
					+" src:"+AITown.GetName(connTown)
					+" dest:"+AITown.GetName(unservedTown));
		}
		return candidate;
	}

	function PaxMailNetwork::MakeShortcutCandidate(connTown, destTown, paxCargo, vehicleType, routeClass, estimate, dist, production, label, logCandidate = true) {
		if(estimate == null) return null;
		local candidate = PaxMailNetwork.MakeCandidate(connTown, destTown, paxCargo,
			vehicleType, routeClass, estimate, dist, production, label);
		candidate.score <- estimate.value - dist;
		candidate.isShortcut <- true;
		candidate.allowNetworkDestReuse <- true;
		candidate.transfer <- false;
		candidate.canChangeDest <- false;
		candidate.explain = "Shortcut("+label+") "+AITown.GetName(connTown)+"<->"+AITown.GetName(destTown)+" dist:"+dist;
		if(logCandidate) {
			HgLog.Info("PaxMailNetwork.ShortcutTownCargo id:"+candidate.routeTraceId
					+" mode:"+label
					+" estimate:"+estimate.value
					+" score:"+candidate.score
					+" dist:"+dist
					+" src:"+AITown.GetName(connTown)
					+" dest:"+AITown.GetName(destTown));
		}
		return candidate;
	}

	function PaxMailNetwork::ProbeRoadPathDistance(src, dest, paxCargo, estimate, manhattanDistance) {
		if(estimate == null || !("engine" in estimate) || estimate.engine == null) {
			HgLog.Warning("PaxMailNetwork.RoadProbe rejected reason:no_engine dist:"+manhattanDistance
					+" src:"+src.GetName()+" dest:"+dest.GetName());
			return null;
		}

		local oldRoadType = AIRoad.GetCurrentRoadType();
		if("infrastractureType" in estimate && estimate.infrastractureType != null) {
			AIRoad.SetCurrentRoadType(estimate.infrastractureType);
		}

		local roadBuilder = RoadBuilder(estimate.engine, paxCargo);
		roadBuilder.pathFindLimit = 50;
		local path = roadBuilder.FindPath([src.GetLocation()], [dest.GetLocation()], true);
		AIRoad.SetCurrentRoadType(oldRoadType);

		if(path == null) {
			HgLog.Info("PaxMailNetwork.RoadProbe rejected reason:no_path dist:"+manhattanDistance
					+" src:"+src.GetName()+" dest:"+dest.GetName());
			return null;
		}

		local pathDistance = Path.FromPath(path).GetTotalDistance(AIVehicle.VT_ROAD);
		if(pathDistance > 100) {
			HgLog.Info("PaxMailNetwork.RoadProbe rejected reason:too_far dist:"+manhattanDistance
					+" pathDist:"+pathDistance+" src:"+src.GetName()+" dest:"+dest.GetName());
			return null;
		}
		if(manhattanDistance > 40 && pathDistance * 2 > manhattanDistance * 3) {
			HgLog.Info("PaxMailNetwork.RoadProbe rejected reason:detour dist:"+manhattanDistance
					+" pathDist:"+pathDistance+" src:"+src.GetName()+" dest:"+dest.GetName());
			return null;
		}

		HgLog.Info("PaxMailNetwork.RoadProbe accepted dist:"+manhattanDistance
				+" pathDist:"+pathDistance+" src:"+src.GetName()+" dest:"+dest.GetName());
		return pathDistance;
	}

	function PaxMailNetwork::FindBestCandidateForPair(connTown, unservedTown, paxCargo, probeRoad = true, logCandidate = true) {
		local townLoc = AITown.GetLocation(unservedTown);
		local townPop = AITown.GetPopulation(unservedTown);
		local dist = AIMap.DistanceManhattan(townLoc, AITown.GetLocation(connTown));
		if(dist == 0) return null;

		local connPop = AITown.GetPopulation(connTown);
		local production = max(30, (townPop + connPop) / 20);
		local src = TownCargo(connTown, paxCargo, true);
		local dest = TownCargo(unservedTown, paxCargo, true);
		local bestCandidate = null;

		// Road: shortest practical town-to-town connector when land-connected.
		if(dist <= 100
				&& PaxMailNetwork.CanTryCandidate(src, dest, connTown, unservedTown, paxCargo, AIVehicle.VT_ROAD, "road")
				&& !RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)
				&& HgTile.IsLandConnectedForRoad(src.GetLocation(), dest.GetLocation())) {
			local infraTypes = RoadRoute.GetDefaultInfrastractureTypes();
			local est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, dist, min(production, 340), true, infraTypes);
			if(probeRoad) {
				local pathDist = PaxMailNetwork.ProbeRoadPathDistance(src, dest, paxCargo, est, dist);
				if(pathDist != null) {
					est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, pathDist, min(production, 340), true, infraTypes);
					bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, unservedTown, paxCargo,
						AIVehicle.VT_ROAD, RoadRoute, est, pathDist, min(production, 340), "road", logCandidate);
				}
			} else {
				bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, unservedTown, paxCargo,
					AIVehicle.VT_ROAD, RoadRoute, est, dist, min(production, 340), "road", false);
			}
		}

		// Water: useful when the nearest pair can be joined by sea/canal.
		if(PaxMailNetwork.CanTryCandidate(src, dest, connTown, unservedTown, paxCargo, AIVehicle.VT_WATER, "ship")
				&& !WaterRoute.IsTooManyVehiclesForNewRoute(WaterRoute)
				&& WaterRoute.CanBuild(src, dest, paxCargo, true)) {
			local infraTypes = WaterRoute.GetSuitableInfrastractureTypes(src, dest, paxCargo);
			local est = Route.Estimate(AIVehicle.VT_WATER, paxCargo, dist, min(production, 550), true, infraTypes);
			bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, unservedTown, paxCargo,
				AIVehicle.VT_WATER, WaterRoute, est, dist, min(production, 550), "ship", logCandidate);
		}

		// Rail: good for medium distances
		if(dist >= 50
				&& PaxMailNetwork.CanTryCandidate(src, dest, connTown, unservedTown, paxCargo, AIVehicle.VT_RAIL, "rail")
				&& !TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)
				&& HgTile.IsLandConnectedForRail(src.GetLocation(), dest.GetLocation())) {
			local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
			local est = Route.Estimate(AIVehicle.VT_RAIL, paxCargo, dist, min(production, 550), true, infraTypes);
			bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, unservedTown, paxCargo,
				AIVehicle.VT_RAIL, TrainRoute, est, dist, min(production, 550), "rail", logCandidate);
		}

		// Air: good for long distances when profitable
		if(dist >= 150
				&& PaxMailNetwork.CanTryCandidate(src, dest, connTown, unservedTown, paxCargo, AIVehicle.VT_AIR, "air")
				&& !AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)) {
			local infraTypes = AirRoute.GetSuitableInfrastractureTypes(
				src, dest, paxCargo);
			local est = Route.Estimate(AIVehicle.VT_AIR, paxCargo, dist, min(production, 550), true, infraTypes);
			bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, unservedTown, paxCargo,
				AIVehicle.VT_AIR, AirRoute, est, dist, min(production, 550), "air", logCandidate);
		}

		return bestCandidate;
	}

	function PaxMailNetwork::FindShortcutCandidateForPair(connTown, destTown, paxCargo, probeRoad = true, logCandidate = true) {
		local src = TownCargo(connTown, paxCargo, true);
		local dest = TownCargo(destTown, paxCargo, true);
		local dist = AIMap.DistanceManhattan(src.GetLocation(), dest.GetLocation());
		if(dist == 0) return null;
		local population = AITown.GetPopulation(connTown) + AITown.GetPopulation(destTown);
		local production = max(30, population / 20);
		local bestCandidate = null;

		// Shortcuts use the normal TownCargo station path. That still prefers
		// sharing an existing station ID and creates a feeder townbus when a
		// separate station ID is needed because of station spread limits. Mode
		// choice follows normal expansion: evaluate viable modes and keep the
		// highest score.
		if(dist <= 100
				&& PaxMailNetwork.CanTryCandidate(src, dest, connTown, destTown, paxCargo, AIVehicle.VT_ROAD, "road")
				&& !RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)
				&& HgTile.IsLandConnectedForRoad(src.GetLocation(), dest.GetLocation())) {
			local infraTypes = RoadRoute.GetDefaultInfrastractureTypes();
			local est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, dist, min(production, 340), true, infraTypes);
			if(probeRoad) {
				local pathDist = PaxMailNetwork.ProbeRoadPathDistance(src, dest, paxCargo, est, dist);
				if(pathDist != null) {
					est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, pathDist, min(production, 340), true, infraTypes);
					bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, destTown, paxCargo,
						AIVehicle.VT_ROAD, RoadRoute, est, pathDist, min(production, 340), "road", logCandidate);
				}
			} else {
				bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, destTown, paxCargo,
					AIVehicle.VT_ROAD, RoadRoute, est, dist, min(production, 340), "road", false);
			}
		}

		if(dist >= 50
				&& PaxMailNetwork.CanTryCandidate(src, dest, connTown, destTown, paxCargo, AIVehicle.VT_RAIL, "rail")
				&& !TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)
				&& HgTile.IsLandConnectedForRail(src.GetLocation(), dest.GetLocation())) {
			local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
			local est = Route.Estimate(AIVehicle.VT_RAIL, paxCargo, dist, min(production, 550), true, infraTypes);
			bestCandidate = PaxMailNetwork.MaybeUseCandidate(bestCandidate, connTown, destTown, paxCargo,
				AIVehicle.VT_RAIL, TrainRoute, est, dist, min(production, 550), "rail", logCandidate);
		}

		if(bestCandidate == null) return null;
		bestCandidate.isShortcut <- true;
		bestCandidate.allowNetworkDestReuse <- true;
		bestCandidate.transfer <- false;
		bestCandidate.canChangeDest <- false;
		bestCandidate.explain = "Shortcut("+bestCandidate.modeLabel+") "
				+AITown.GetName(connTown)+"<->"+AITown.GetName(destTown)+" dist:"+bestCandidate.distance;
		if(logCandidate) {
			HgLog.Info("PaxMailNetwork.ShortcutScoredSelection id:"+bestCandidate.routeTraceId
					+" mode:"+bestCandidate.modeLabel
					+" score:"+bestCandidate.score
					+" dist:"+bestCandidate.distance
					+" src:"+AITown.GetName(connTown)
					+" dest:"+AITown.GetName(destTown));
		}
		return bestCandidate;
	}

	function PaxMailNetwork::GetFrontierSourceTowns(connected) {
		local sourceLimit = 20;
		local sourceTowns = [];
		foreach(connTown, _ in connected) {
			sourceTowns.push(connTown);
		}
		sourceTowns.sort(function(a, b) {
			return AITown.GetPopulation(b) - AITown.GetPopulation(a);
		});
		while(sourceTowns.len() > sourceLimit) {
			sourceTowns.pop();
		}
		return sourceTowns;
	}

	function PaxMailNetwork::FindNearestTowns(connTown, towns) {
		local byDist = [];
		local connLoc = AITown.GetLocation(connTown);
		foreach(unservedTown in towns) {
			if(unservedTown == connTown) continue;
			byDist.push({
				town = unservedTown,
				dist = AIMap.DistanceManhattan(connLoc, AITown.GetLocation(unservedTown))
			});
		}
		byDist.sort(function(a, b) {
			if(a.dist != b.dist) return a.dist - b.dist;
			return AITown.GetPopulation(b.town) - AITown.GetPopulation(a.town);
		});
		return byDist;
	}

	function PaxMailNetwork::GetFrontierPairLists(connected, allTowns, paxCargo) {
		local perSourceLimit = 10;
		local sourceTowns = PaxMailNetwork.GetFrontierSourceTowns(connected);
		local connectedTowns = [];
		local unservedTowns = [];
		foreach(town in allTowns) {
			if(connected.rawin(town)) {
				connectedTowns.push(town);
			} else {
				unservedTowns.push(town);
			}
		}
		local seenPairs = {};
		local shortcutCandidates = [];
		local expansionCandidates = [];
		local graph = PaxMailNetwork.GetNetworkGraph(paxCargo, connected);

		foreach(connTown in sourceTowns) {
			local shortcutNearest = PaxMailNetwork.FindNearestTowns(connTown, connectedTowns);
			local shortcutLimit = min(shortcutNearest.len(), perSourceLimit);
			for(local i = 0; i < shortcutLimit; i++) {
				local destTown = shortcutNearest[i].town;
				local key = PaxMailNetwork.GetPairKey(connTown, destTown, paxCargo, "town");
				if(seenPairs.rawin(key)) continue;
				seenPairs.rawset(key, true);

				local straight = AIMap.DistanceManhattan(AITown.GetLocation(connTown), AITown.GetLocation(destTown));
				if(straight == 0) continue;
				if(PaxMailNetwork.HasDirectTownRoute(connTown, destTown, paxCargo)) continue;
				local networkDistance = PaxMailNetwork.GetShortestNetworkDistance(graph, connTown, destTown);
				if(networkDistance == null) continue;
				if(networkDistance * 2 <= straight * 3) continue;
				local candidate = PaxMailNetwork.FindShortcutCandidateForPair(connTown, destTown, paxCargo, false, false);
				if(candidate != null && candidate.score > 0) {
					local savingsBonus = networkDistance - straight;
					candidate.score += savingsBonus;
					candidate.isShortcut <- true;
					candidate.networkDistance <- networkDistance;
					candidate.straightDistance <- straight;
					candidate.savingsBonus <- savingsBonus;
					shortcutCandidates.push(candidate);
					HgLog.Info("PaxMailNetwork.ShortcutCandidate score:"+candidate.score
							+" bonus:"+savingsBonus
							+" networkDist:"+networkDistance
							+" straight:"+straight
							+" src:"+AITown.GetName(connTown)
							+" dest:"+AITown.GetName(destTown));
				}
			}

			local expansionNearest = PaxMailNetwork.FindNearestTowns(connTown, unservedTowns);
			local expansionLimit = min(expansionNearest.len(), perSourceLimit);
			for(local i = 0; i < expansionLimit; i++) {
				local destTown = expansionNearest[i].town;
				local key = PaxMailNetwork.GetPairKey(connTown, destTown, paxCargo, "town");
				if(seenPairs.rawin(key)) continue;
				seenPairs.rawset(key, true);

				local candidate = PaxMailNetwork.FindBestCandidateForPair(connTown, destTown, paxCargo, false, false);
				if(candidate != null) {
					expansionCandidates.push(candidate);
				}
			}
		}

		shortcutCandidates.sort(function(a, b) {
			return b.score - a.score;
		});
		expansionCandidates.sort(function(a, b) {
			return b.score - a.score;
		});
		HgLog.Info("PaxMailNetwork.PairQueue shortcuts:"+shortcutCandidates.len()
				+" expansions:"+expansionCandidates.len()
				+" shortcutSources:"+sourceTowns.len()
				+" expansionSources:"+sourceTowns.len()
				+" shortcutMode:towncargo"
				+" shortcutSelection:scored");
		return {
			shortcuts = shortcutCandidates,
			expansions = expansionCandidates
		};
	}

	function PaxMailNetwork::FindBestCandidateFromUpperBounds(upperCandidates, paxCargo, queueLabel) {
		local best = null;

		for(local i = 0; i < upperCandidates.len(); i++) {
			local upper = upperCandidates[i];
			local connTown = upper.rawin("connTown") ? upper.connTown : upper.src.town;
			local destTown = upper.rawin("destTown") ? upper.destTown : upper.dest.town;
			local candidate = null;
			if(upper.rawin("isShortcut") && upper.isShortcut) {
				candidate = PaxMailNetwork.FindShortcutCandidateForPair(connTown, destTown, paxCargo, true, true);
			} else {
				candidate = PaxMailNetwork.FindBestCandidateForPair(connTown, destTown, paxCargo, true, true);
			}
			if(candidate != null && upper.rawin("savingsBonus")) {
				candidate.score += upper.savingsBonus;
				candidate.isShortcut <- true;
				candidate.networkDistance <- upper.networkDistance;
				candidate.straightDistance <- upper.straightDistance;
				candidate.savingsBonus <- upper.savingsBonus;
				HgLog.Info("PaxMailNetwork.ShortcutScore id:"+candidate.routeTraceId
						+" base:"+(candidate.score - upper.savingsBonus)
						+" bonus:"+upper.savingsBonus
						+" score:"+candidate.score
						+" networkDist:"+upper.networkDistance
						+" straight:"+upper.straightDistance);
			}
			if(candidate != null && (best == null || candidate.score > best.score)) {
				best = candidate;
			}

			if(best != null) {
				local nextUpperScore = i + 1 < upperCandidates.len() ? upperCandidates[i + 1].score : null;
				if(nextUpperScore == null || best.score >= nextUpperScore) {
					HgLog.Info("PaxMailNetwork.EarlyStop best:"+best.score
							+" nextUpper:"+(nextUpperScore == null ? "none" : nextUpperScore)
							+" checked:"+(i + 1)
							+" total:"+upperCandidates.len()
							+" queue:"+queueLabel);
					break;
				}
			}
		}

		return best;
	}

	function PaxMailNetwork::FindBestFrontierCandidate(connected, allTowns, paxCargo) {
		local pairLists = PaxMailNetwork.GetFrontierPairLists(connected, allTowns, paxCargo);
		local shortcut = PaxMailNetwork.FindBestCandidateFromUpperBounds(pairLists.shortcuts, paxCargo, "shortcut");
		if(shortcut != null) {
			shortcut.isShortcut <- true;
			return shortcut;
		}
		return PaxMailNetwork.FindBestCandidateFromUpperBounds(pairLists.expansions, paxCargo, "expansion");
	}

	function PaxMailNetwork::Step() {
		local ai = HogeAI.Get();
		if(ai.IsFreightOnly()) return;
		HgLog.Info("###### ConnectUnservedTowns");
		if(ai.GetUsableMoney() < ai.GetInflatedMoney(100000)) return;

		local paxCargo = ai.GetPassengerCargo();
		if(paxCargo == false || paxCargo == null) return;
		PaxMailNetwork.LogAnnualPerformance(paxCargo);

		// No point running if all vehicle types are saturated
		if(TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)
				&& AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)
				&& RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)
				&& WaterRoute.IsTooManyVehiclesForNewRoute(WaterRoute)) {
			return;
		}

		// Collect all towns, sorted largest-first so bigger towns get priority
		local townList = AITownList();
		if(townList.Count() == 0) return;
		local allTowns = [];
		foreach(town, _ in townList) { allTowns.push(town); }
		allTowns.sort(function(a, b) {
			return AITown.GetPopulation(b) - AITown.GetPopulation(a);
		});

		// Towns with any existing passenger service (rail, road, air, water)
		local served = PaxMailNetwork.GetPassengerServedTowns(paxCargo);

		local unserved = [];
		foreach(town in allTowns) {
			if(!served.rawin(town)) unserved.push(town);
		}

		HgLog.Info("ConnectUnservedTowns: "+unserved.len()+" unserved / "+allTowns.len()+" {");

		// "connected" grows as we process towns this step (optimistic MST bookkeeping)
		local connected = {};
		foreach(town, _ in served) { connected.rawset(town, true); }
		if(connected.len() == 0) {
			// No service at all yet: seed with the largest town
			connected.rawset(allTowns[0], true);
			local filtered = [];
			foreach(t in unserved) { if(t != allTowns[0]) filtered.push(t); }
			unserved = filtered;
		}

		local dirtyPlaces = {};
		local pendingPlans = [];

		if(ai.limitDate < AIDate.GetCurrentDate()) {
			HgLog.Warning("ConnectUnservedTowns: reached limitDate");
			return;
		}

		local candidate = PaxMailNetwork.FindBestFrontierCandidate(connected, allTowns, paxCargo);

		if(candidate != null) {
			// Use the real profitable estimate; no value override needed
			candidate.maxValue <- candidate.estimate.value;
			HgLog.Info("PaxMailNetwork.Selected id:"+candidate.routeTraceId
					+" mode:"+candidate.modeLabel
					+" estimate:"+candidate.estimate.value
					+" score:"+candidate.score
					+" dist:"+candidate.distance
					+" production:"+candidate.production
					+" shortcut:"+(candidate.rawin("isShortcut") && candidate.isShortcut)
					+" "+candidate.explain);
			ai.DoInterval();
			local builder = ai.CreateBuilder(candidate, pendingPlans, dirtyPlaces, ai.limitDate);
			if(builder != null) {
				HgLog.Info("ConnectUnservedTowns: "+candidate.explain+" {");
				local newRoutes = builder.Build();
				HgLog.Info("} ConnectUnservedTowns build");
				if(newRoutes != null) {
					if(typeof newRoutes != "array") newRoutes = [newRoutes];
					foreach(newRoute in newRoutes) {
						if(newRoute.srcHgStation.place != null) {
							newRoute.srcHgStation.place.SetDirtyArround();
						}
					}
				} else {
					PaxMailNetwork.AddPairBlacklist(candidate, "BuildFailed");
					HgLog.Info("PaxMailNetwork.BuildFailed id:"+candidate.routeTraceId+" "+candidate.explain);
				}
			} else {
				PaxMailNetwork.AddPairBlacklist(candidate, "BuildSkipped");
				HgLog.Info("PaxMailNetwork.BuildSkipped id:"+candidate.routeTraceId+" "+candidate.explain);
			}
			ai.routeCandidates.Extend(pendingPlans);
			pendingPlans.clear();

		} else {
			HgLog.Info("ConnectUnservedTowns: no viable frontier route");
		}

		HgLog.Info("} ConnectUnservedTowns built");
	}
