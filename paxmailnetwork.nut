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
		local reason = PaxMailNetwork.GetTryRejectReason(src, dest, connTown, unservedTown, paxCargo, vehicleType);
		if(reason != null) {
			HgLog.Info("PaxMailNetwork.BlacklistSkip reason:"+reason+" mode:"+label
					+" "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown));
			return false;
		}
		return true;
	}

	function PaxMailNetwork::GetTryRejectReason(src, dest, connTown, unservedTown, paxCargo, vehicleType) {
		if(PaxMailNetwork.IsPairBlacklisted(connTown, unservedTown, paxCargo, vehicleType)) {
			return "cooldown";
		}
		if(Place.IsNgPlace(src, paxCargo, vehicleType) || Place.IsNgPlace(dest, paxCargo, vehicleType)) {
			return "NgPlace";
		}
		if(Place.IsNgPathFindPair(src, dest, vehicleType)) {
			return "NgPathFindPair";
		}
		return null;
	}

	function PaxMailNetwork::MakeRejectStats() {
		return {
			total = 0,
			direct = 0,
			cooldown = 0,
			NgPlace = 0,
			NgPathFindPair = 0,
			roadDistance = 0,
			roadLimit = 0,
			roadNoLand = 0,
			roadProbe = 0,
			shipLimit = 0,
			shipCannotBuild = 0,
			railDistance = 0,
			railLimit = 0,
			railNoLand = 0,
			airDistance = 0,
			airLimit = 0,
			noEstimate = 0,
			nonPositiveScore = 0,
			allModesRejected = 0
		};
	}

	function PaxMailNetwork::CountReject(stats, reason) {
		if(stats == null) return;
		if(!stats.rawin(reason)) {
			stats.rawset(reason, 0);
		}
		stats[reason] = stats[reason] + 1;
	}

	function PaxMailNetwork::LogRejectSummary(group, stats, selected) {
		if(stats == null) return;
		HgLog.Info("PaxMailNetwork.GroupRejectSummary group:"+group
				+" selected:"+(selected == null ? "none" : selected.routeTraceId)
				+" total:"+stats.total
				+" direct:"+stats.direct
				+" cooldown:"+stats.cooldown
				+" NgPlace:"+stats.NgPlace
				+" NgPathFindPair:"+stats.NgPathFindPair
				+" roadDistance:"+stats.roadDistance
				+" roadLimit:"+stats.roadLimit
				+" roadNoLand:"+stats.roadNoLand
				+" roadProbe:"+stats.roadProbe
				+" shipLimit:"+stats.shipLimit
				+" shipCannotBuild:"+stats.shipCannotBuild
				+" railDistance:"+stats.railDistance
				+" railLimit:"+stats.railLimit
				+" railNoLand:"+stats.railNoLand
				+" airDistance:"+stats.airDistance
				+" airLimit:"+stats.airLimit
				+" noEstimate:"+stats.noEstimate
				+" nonPositiveScore:"+stats.nonPositiveScore
				+" allModesRejected:"+stats.allModesRejected);
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

	function PaxMailNetwork::AddGraphEdge(graph, fromTown, toTown, distance) {
		if(fromTown == toTown) return;
		if(!graph.rawin(fromTown)) graph.rawset(fromTown, {});
		local edges = graph[fromTown];
		if(!edges.rawin(toTown) || distance < edges[toTown]) {
			edges.rawset(toTown, distance);
		}
	}

	function PaxMailNetwork::GetShortestNetworkDistance(graph, fromTown, toTown) {
		local result = PaxMailNetwork.GetShortestNetworkPath(graph, fromTown, toTown);
		return result == null ? null : result.distance;
	}

	function PaxMailNetwork::GetShortestNetworkPath(graph, fromTown, toTown) {
		if(fromTown == toTown) {
			return {
				distance = 0,
				edges = []
			};
		}
		local dist = {};
		local done = {};
		local prev = {};
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
			if(bestTown == toTown) {
				local pathEdges = [];
				local cursor = toTown;
				while(cursor != fromTown) {
					if(!prev.rawin(cursor)) return null;
					local step = prev[cursor];
					pathEdges.insert(0, {
						srcTown = step.town,
						destTown = cursor,
						distance = step.distance
					});
					cursor = step.town;
				}
				return {
					distance = bestDist,
					edges = pathEdges
				};
			}
			done.rawset(bestTown, true);
			if(!graph.rawin(bestTown)) continue;
			foreach(nextTown, edgeDist in graph[bestTown]) {
				if(done.rawin(nextTown)) continue;
				local nextDist = bestDist + edgeDist;
				if(!dist.rawin(nextTown) || nextDist < dist[nextTown]) {
					dist.rawset(nextTown, nextDist);
					prev.rawset(nextTown, {
						town = bestTown,
						distance = edgeDist
					});
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

	function PaxMailNetwork::HasHubHubRoute(hubs, paxCargo) {
		for(local i = 0; i < hubs.len(); i++) {
			for(local j = i + 1; j < hubs.len(); j++) {
				if(PaxMailNetwork.HasDirectTownRoute(hubs[i], hubs[j], paxCargo)) return true;
			}
		}
		return false;
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

	function PaxMailNetwork::MaybeUsePlannedCandidate(best, srcTown, destTown, paxCargo, vehicleType, routeClass, estimate, dist, production, label, role, group, logCandidate = true, rejectStats = null) {
		if(estimate == null) {
			PaxMailNetwork.CountReject(rejectStats, "noEstimate");
			return best;
		}
		local score = estimate.value;
		if(score <= 0) {
			PaxMailNetwork.CountReject(rejectStats, "nonPositiveScore");
			return best;
		}
		if(best != null && best.score >= score) return best;
		local candidate = PaxMailNetwork.MakeCandidate(srcTown, destTown, paxCargo,
			vehicleType, routeClass, estimate, dist, production, label);
		candidate.score <- score;
		candidate.role <- role;
		candidate.priorityGroup <- group;
		candidate.edgeDistance <- AIMap.DistanceManhattan(AITown.GetLocation(srcTown), AITown.GetLocation(destTown));
		candidate.canChangeDest <- false;
		candidate.allowNetworkDestReuse <- true;
		candidate.disableFullLoadOrder <- true;
		if(role == "spoke" || group == "hub_shortcut" || group == "hub_shortcut_support") {
			candidate.forceSrcTransfer <- true;
		}
		if(vehicleType == AIVehicle.VT_RAIL) {
			candidate.notUseSingle <- role == "hub";
			candidate.allowSingleNetworkPaxMail <- role != "hub";
		}
		candidate.explain = "GlobalConnect("+label+") "+AITown.GetName(srcTown)+"<->"
				+AITown.GetName(destTown)+" dist:"+dist+" role:"+role+" group:"+group;
		if(logCandidate) {
			HgLog.Info("PaxMailNetwork.HubSpokeCandidate id:"+candidate.routeTraceId
					+" group:"+group
					+" role:"+role
					+" mode:"+label
					+" estimate:"+estimate.value
					+" score:"+score
					+" dist:"+dist
					+" edgeDist:"+candidate.edgeDistance
					+" production:"+production
					+" src:"+AITown.GetName(srcTown)
					+" dest:"+AITown.GetName(destTown));
		}
		return candidate;
	}

	function PaxMailNetwork::ProbeRoadPathDistance(src, dest, paxCargo, estimate, manhattanDistance, maxPathDistance = 100) {
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
		if(pathDistance > maxPathDistance) {
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

	function PaxMailNetwork::GetHubTowns(allTowns) {
		local hubCount = max(3, (allTowns.len() + 2) / 5);
		hubCount = min(hubCount, allTowns.len());
		local hubs = [];
		for(local i = 0; i < hubCount; i++) {
			hubs.push(allTowns[i]);
		}
		return hubs;
	}

	function PaxMailNetwork::MakeTownSet(towns) {
		local result = {};
		foreach(town in towns) {
			result.rawset(town, true);
		}
		return result;
	}

	function PaxMailNetwork::AddShortcutSupportEdges(supportEdges, seen, pathEdges) {
		foreach(pathEdge in pathEdges) {
			local a = min(pathEdge.srcTown, pathEdge.destTown);
			local b = max(pathEdge.srcTown, pathEdge.destTown);
			local key = a+"-"+b;
			if(seen.rawin(key)) continue;
			seen.rawset(key, true);
			supportEdges.push(pathEdge);
		}
	}

	function PaxMailNetwork::GetPrunedHubEdges(hubs, connectedHubs = null, paxCargo = null) {
		local edges = [];
		for(local i = 0; i < hubs.len(); i++) {
			for(local j = i + 1; j < hubs.len(); j++) {
				local dist = AIMap.DistanceManhattan(AITown.GetLocation(hubs[i]), AITown.GetLocation(hubs[j]));
				if(dist == 0) continue;
				edges.push({
					srcTown = hubs[i],
					destTown = hubs[j],
					distance = dist
				});
			}
		}
		edges.sort(function(a, b) {
			return a.distance - b.distance;
		});

		local kept = [];
		local shortcutSupportEdges = [];
		local shortcutSupportSeen = {};
		local graph = {};
		foreach(edge in edges) {
			local path = PaxMailNetwork.GetShortestNetworkPath(graph, edge.srcTown, edge.destTown);
			if(path != null && path.distance * 2 <= edge.distance * 3) {
				if(connectedHubs != null
						&& paxCargo != null
						&& connectedHubs.rawin(edge.srcTown)
						&& connectedHubs.rawin(edge.destTown)
						&& !PaxMailNetwork.HasDirectTownRoute(edge.srcTown, edge.destTown, paxCargo)) {
					PaxMailNetwork.AddShortcutSupportEdges(shortcutSupportEdges, shortcutSupportSeen, path.edges);
				}
				continue;
			}
			kept.push(edge);
			PaxMailNetwork.AddGraphEdge(graph, edge.srcTown, edge.destTown, edge.distance);
			PaxMailNetwork.AddGraphEdge(graph, edge.destTown, edge.srcTown, edge.distance);
		}
		return {
			hubEdges = kept,
			shortcutSupportEdges = shortcutSupportEdges
		};
	}

	function PaxMailNetwork::GetConnectedHubs(hubs, served) {
		local connected = {};
		foreach(hub in hubs) {
			if(served.rawin(hub)) {
				connected.rawset(hub, true);
			}
		}
		if(connected.len() == 0 && hubs.len() >= 1) {
			connected.rawset(hubs[0], true);
		}
		return connected;
	}

	function PaxMailNetwork::OrientHubEdge(edge, connectedHubs) {
		local srcConnected = connectedHubs.rawin(edge.srcTown);
		local destConnected = connectedHubs.rawin(edge.destTown);
		if(srcConnected && !destConnected) return edge;
		if(destConnected && !srcConnected) {
			return {
				srcTown = edge.destTown,
				destTown = edge.srcTown,
				distance = edge.distance
			};
		}
		return edge;
	}

	function PaxMailNetwork::GetSpokeEdges(hubs, hubSet, allTowns) {
		local edges = [];
		foreach(town in allTowns) {
			if(hubSet.rawin(town)) continue;
			local bestHub = null;
			local bestDist = null;
			foreach(hub in hubs) {
				local dist = AIMap.DistanceManhattan(AITown.GetLocation(hub), AITown.GetLocation(town));
				if(dist > 80 || dist <= 0) continue;
				if(bestHub == null
						|| dist < bestDist
						|| (dist == bestDist && AITown.GetPopulation(hub) > AITown.GetPopulation(bestHub))) {
					bestHub = hub;
					bestDist = dist;
				}
			}
			if(bestHub != null) {
				edges.push({
					srcTown = bestHub,
					destTown = town,
					distance = bestDist
				});
			}
		}
		return edges;
	}

	function PaxMailNetwork::FindBestPlannedCandidateForPair(srcTown, destTown, paxCargo, role, group, probeRoad = true, logCandidate = true, rejectStats = null) {
		if(rejectStats != null) rejectStats.total++;
		if(PaxMailNetwork.HasDirectTownRoute(srcTown, destTown, paxCargo)) {
			PaxMailNetwork.CountReject(rejectStats, "direct");
			return null;
		}
		local src = TownCargo(srcTown, paxCargo, true);
		local dest = TownCargo(destTown, paxCargo, true);
		local dist = AIMap.DistanceManhattan(src.GetLocation(), dest.GetLocation());
		if(dist == 0) return null;
		local production = max(30, (AITown.GetPopulation(srcTown) + AITown.GetPopulation(destTown)) / 20);
		local bestCandidate = null;
		local rejectedModes = 0;
		local isHubShortcut = group == "hub_shortcut" || group == "hub_shortcut_support";
		local roadMaxDistance = isHubShortcut ? 200 : 100;
		local airMinDistance = isHubShortcut ? 100 : 150;

		if(dist > roadMaxDistance) {
			PaxMailNetwork.CountReject(rejectStats, "roadDistance");
			rejectedModes++;
		} else if(!RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)) {
			local roadReject = PaxMailNetwork.GetTryRejectReason(src, dest, srcTown, destTown, paxCargo, AIVehicle.VT_ROAD);
			if(roadReject != null) {
				PaxMailNetwork.CountReject(rejectStats, roadReject);
				HgLog.Info("PaxMailNetwork.BlacklistSkip reason:"+roadReject+" mode:road "
						+AITown.GetName(srcTown)+"<->"+AITown.GetName(destTown));
				rejectedModes++;
			} else if(!HgTile.IsLandConnectedForRoad(src.GetLocation(), dest.GetLocation())) {
				PaxMailNetwork.CountReject(rejectStats, "roadNoLand");
				rejectedModes++;
			} else {
				local infraTypes = RoadRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, dist, min(production, 340), true, infraTypes);
				if(probeRoad) {
					local pathDist = PaxMailNetwork.ProbeRoadPathDistance(src, dest, paxCargo, est, dist, roadMaxDistance);
					if(pathDist != null) {
						est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, pathDist, min(production, 340), true, infraTypes);
						bestCandidate = PaxMailNetwork.MaybeUsePlannedCandidate(bestCandidate, srcTown, destTown, paxCargo,
							AIVehicle.VT_ROAD, RoadRoute, est, pathDist, min(production, 340), "road", role, group, logCandidate, rejectStats);
					} else {
						PaxMailNetwork.CountReject(rejectStats, "roadProbe");
						rejectedModes++;
					}
				} else {
					bestCandidate = PaxMailNetwork.MaybeUsePlannedCandidate(bestCandidate, srcTown, destTown, paxCargo,
						AIVehicle.VT_ROAD, RoadRoute, est, dist, min(production, 340), "road", role, group, false, rejectStats);
				}
			}
		} else {
			PaxMailNetwork.CountReject(rejectStats, "roadLimit");
			rejectedModes++;
		}

		if(WaterRoute.IsTooManyVehiclesForNewRoute(WaterRoute)) {
			PaxMailNetwork.CountReject(rejectStats, "shipLimit");
			rejectedModes++;
		} else {
			local shipReject = PaxMailNetwork.GetTryRejectReason(src, dest, srcTown, destTown, paxCargo, AIVehicle.VT_WATER);
			if(shipReject != null) {
				PaxMailNetwork.CountReject(rejectStats, shipReject);
				HgLog.Info("PaxMailNetwork.BlacklistSkip reason:"+shipReject+" mode:ship "
						+AITown.GetName(srcTown)+"<->"+AITown.GetName(destTown));
				rejectedModes++;
			} else if(WaterRoute.CanBuild(src, dest, paxCargo, true)) {
				local infraTypes = WaterRoute.GetSuitableInfrastractureTypes(src, dest, paxCargo);
				local est = Route.Estimate(AIVehicle.VT_WATER, paxCargo, dist, min(production, 550), true, infraTypes);
				bestCandidate = PaxMailNetwork.MaybeUsePlannedCandidate(bestCandidate, srcTown, destTown, paxCargo,
					AIVehicle.VT_WATER, WaterRoute, est, dist, min(production, 550), "ship", role, group, logCandidate, rejectStats);
			} else {
				PaxMailNetwork.CountReject(rejectStats, "shipCannotBuild");
				rejectedModes++;
			}
		}

		if(dist < 50) {
			PaxMailNetwork.CountReject(rejectStats, "railDistance");
			rejectedModes++;
		} else if(TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)) {
			PaxMailNetwork.CountReject(rejectStats, "railLimit");
			rejectedModes++;
		} else {
			local railReject = PaxMailNetwork.GetTryRejectReason(src, dest, srcTown, destTown, paxCargo, AIVehicle.VT_RAIL);
			if(railReject != null) {
				PaxMailNetwork.CountReject(rejectStats, railReject);
				HgLog.Info("PaxMailNetwork.BlacklistSkip reason:"+railReject+" mode:rail "
						+AITown.GetName(srcTown)+"<->"+AITown.GetName(destTown));
				rejectedModes++;
			} else if(HgTile.IsLandConnectedForRail(src.GetLocation(), dest.GetLocation())) {
				local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_RAIL, paxCargo, dist, min(production, 550), true, infraTypes);
				bestCandidate = PaxMailNetwork.MaybeUsePlannedCandidate(bestCandidate, srcTown, destTown, paxCargo,
					AIVehicle.VT_RAIL, TrainRoute, est, dist, min(production, 550), "rail", role, group, logCandidate, rejectStats);
			} else {
				PaxMailNetwork.CountReject(rejectStats, "railNoLand");
				rejectedModes++;
			}
		}

		if(dist < airMinDistance) {
			PaxMailNetwork.CountReject(rejectStats, "airDistance");
			rejectedModes++;
		} else if(AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)) {
			PaxMailNetwork.CountReject(rejectStats, "airLimit");
			rejectedModes++;
		} else {
			local airReject = PaxMailNetwork.GetTryRejectReason(src, dest, srcTown, destTown, paxCargo, AIVehicle.VT_AIR);
			if(airReject != null) {
				PaxMailNetwork.CountReject(rejectStats, airReject);
				HgLog.Info("PaxMailNetwork.BlacklistSkip reason:"+airReject+" mode:air "
						+AITown.GetName(srcTown)+"<->"+AITown.GetName(destTown));
				rejectedModes++;
			} else {
				local infraTypes = AirRoute.GetSuitableInfrastractureTypes(src, dest, paxCargo);
				local est = Route.Estimate(AIVehicle.VT_AIR, paxCargo, dist, min(production, 550), true, infraTypes);
				bestCandidate = PaxMailNetwork.MaybeUsePlannedCandidate(bestCandidate, srcTown, destTown, paxCargo,
					AIVehicle.VT_AIR, AirRoute, est, dist, min(production, 550), "air", role, group, logCandidate, rejectStats);
			}
		}

		if(bestCandidate == null && rejectedModes >= 4) {
			PaxMailNetwork.CountReject(rejectStats, "allModesRejected");
		}
		return bestCandidate;
	}

	function PaxMailNetwork::FindBestInPlannedEdges(edges, paxCargo, role, group) {
		local best = null;
		local rejectStats = PaxMailNetwork.MakeRejectStats();
		foreach(edge in edges) {
			local candidate = PaxMailNetwork.FindBestPlannedCandidateForPair(
				edge.srcTown, edge.destTown, paxCargo, role, group, true, true, rejectStats);
			if(candidate != null && (best == null || candidate.score > best.score)) {
				best = candidate;
			}
		}
		PaxMailNetwork.LogRejectSummary(group, rejectStats, best);
		return best;
	}

	function PaxMailNetwork::FindBestHubSpokeCandidate(allTowns, served, paxCargo) {
		local hubs = PaxMailNetwork.GetHubTowns(allTowns);
		local hubSet = PaxMailNetwork.MakeTownSet(hubs);
		local connectedHubs = PaxMailNetwork.GetConnectedHubs(hubs, served);
		local hubPlan = PaxMailNetwork.GetPrunedHubEdges(hubs, connectedHubs, paxCargo);
		local hubEdges = hubPlan.hubEdges;
		local shortcutSupportEdges = hubPlan.shortcutSupportEdges;
		local spokeEdges = PaxMailNetwork.GetSpokeEdges(hubs, hubSet, allTowns);
		local hasHubHubRoute = PaxMailNetwork.HasHubHubRoute(hubs, paxCargo);
		local hubExpansion = [];
		local hubShortcuts = [];
		local hubShortcutSupport = [];
		local primarySpokes = [];

		foreach(edge in hubEdges) {
			local srcConnected = connectedHubs.rawin(edge.srcTown);
			local destConnected = connectedHubs.rawin(edge.destTown);
			if(srcConnected != destConnected) {
				hubExpansion.push(PaxMailNetwork.OrientHubEdge(edge, connectedHubs));
			} else if(srcConnected && destConnected) {
				hubShortcuts.push(edge);
			}
		}

		foreach(edge in shortcutSupportEdges) {
			hubShortcutSupport.push(PaxMailNetwork.OrientHubEdge(edge, connectedHubs));
		}

		foreach(edge in spokeEdges) {
			if(!connectedHubs.rawin(edge.srcTown)) continue;
			if(!served.rawin(edge.destTown)) {
				primarySpokes.push(edge);
			}
		}

		HgLog.Info("PaxMailNetwork.HubSpoke hubs:"+hubs.len()
				+" hubEdges:"+hubEdges.len()
				+" hubExpansion:"+hubExpansion.len()
				+" hasHubHubRoute:"+hasHubHubRoute
				+" primarySpokes:"+primarySpokes.len()
				+" hubShortcutSupport:"+hubShortcutSupport.len()
				+" hubShortcuts:"+hubShortcuts.len());

		local groups = [];
		if(!hasHubHubRoute) {
			groups.push({ name = "hub_expansion", role = "hub", edges = hubExpansion });
		} else {
			groups.push({ name = "primary_spoke", role = "spoke", edges = primarySpokes });
			groups.push({ name = "hub_shortcut_support", role = "hub", edges = hubShortcutSupport });
			groups.push({ name = "hub_shortcut", role = "hub", edges = hubShortcuts });
			groups.push({ name = "hub_expansion", role = "hub", edges = hubExpansion });
		}

		foreach(group in groups) {
			local candidate = PaxMailNetwork.FindBestInPlannedEdges(group.edges, paxCargo, group.role, group.name);
			HgLog.Info("PaxMailNetwork.HubSpoke group:"+group.name
					+" edges:"+group.edges.len()
					+" selected:"+(candidate == null ? "none" : candidate.routeTraceId));
			if(candidate != null) return candidate;
		}
		return null;
	}

	function PaxMailNetwork::Step() {
		local ai = HogeAI.Get();
		if(ai.IsFreightOnly()) return;
		if(!ai.IsPaxMailOnly()) {
			local liveFreightRoutes = ai.CountLiveFreightRoutes();
			if(liveFreightRoutes < 4) {
				HgLog.Info("PaxMailNetwork.BootstrapSkip liveFreightRoutes:"+liveFreightRoutes+" required:4");
				return;
			}
			HgLog.Info("PaxMailNetwork.BootstrapComplete liveFreightRoutes:"+liveFreightRoutes+" required:4");
		}
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

		local dirtyPlaces = {};
		local pendingPlans = [];

		if(ai.limitDate < AIDate.GetCurrentDate()) {
			HgLog.Warning("ConnectUnservedTowns: reached limitDate");
			return;
		}

		local candidate = PaxMailNetwork.FindBestHubSpokeCandidate(allTowns, served, paxCargo);

		if(candidate != null) {
			// Use the real profitable estimate; no value override needed
			candidate.maxValue <- candidate.estimate.value;
			HgLog.Info("PaxMailNetwork.Selected id:"+candidate.routeTraceId
					+" mode:"+candidate.modeLabel
					+" estimate:"+candidate.estimate.value
					+" score:"+candidate.score
					+" dist:"+candidate.distance
					+" edgeDist:"+candidate.edgeDistance
					+" production:"+candidate.production
					+" "+candidate.explain);
			local estimatedBuildCost = ai.GetEstimatedBuildCost(candidate);
			if(estimatedBuildCost > ai.GetUsableMoney()) {
				HgLog.Info("PaxMailNetwork.DeferBuild id:"+candidate.routeTraceId
						+" estimatedBuildCost:"+estimatedBuildCost
						+" usableMoney:"+ai.GetUsableMoney()
						+" "+candidate.explain);
				HgLog.Info("} ConnectUnservedTowns built");
				return;
			}
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
					local failureReason = builder.GetFailureReason();
					if(failureReason == "tooShortMoney") {
						HgLog.Info("PaxMailNetwork.BuildRetryLater id:"+candidate.routeTraceId+" reason:"+failureReason+" "+candidate.explain);
					} else {
						PaxMailNetwork.AddPairBlacklist(candidate, "BuildFailed");
						HgLog.Info("PaxMailNetwork.BuildFailed id:"+candidate.routeTraceId+" "+candidate.explain);
					}
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
