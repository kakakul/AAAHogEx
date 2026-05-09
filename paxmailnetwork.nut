// paxmailnetwork.nut
// HogNet passenger/mail network expansion. Network mode only.

class PaxMailNetwork {
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
	function PaxMailNetwork::GetPassengerServedTowns(paxCargo) {
		local served = {};
		foreach(route in Route.GetAllRoutes()) {
			if(!route.HasCargo(paxCargo)) continue;
			local srcPlace = route.srcHgStation != null ? route.srcHgStation.place : null;
			local destPlace = route.destHgStation != null ? route.destHgStation.place : null;
			if(srcPlace != null && srcPlace instanceof TownCargo) {
				served.rawset(srcPlace.town, true);
			}
			if(destPlace != null && destPlace instanceof TownCargo) {
				served.rawset(destPlace.town, true);
			}
		}
		return served;
	}

	// For a given unserved town, find the best profitable route to any connected town.
	// Tries rail and air; returns the highest-value candidate, or null if none is profitable.
	// For each unserved town the nearest N connected towns are evaluated to keep runtime bounded.
	function PaxMailNetwork::FindBestProfitableRouteForTown(unservedTown, connected, paxCargo) {
		local townLoc = AITown.GetLocation(unservedTown);
		local townPop = AITown.GetPopulation(unservedTown);

		// Sort connected towns by distance so we evaluate the nearest ones first
		local byDist = [];
		foreach(connTown, _ in connected) {
			byDist.push({
				town = connTown,
				dist = AIMap.DistanceManhattan(townLoc, AITown.GetLocation(connTown))
			});
		}
		byDist.sort(function(a, b) { return a.dist - b.dist; });

		local bestCandidate = null;
		local bestValue = 0;
		// Only evaluate up to 15 nearest connected towns to keep this step fast
		local limit = min(byDist.len(), 15);

		for(local i = 0; i < limit; i++) {
			local connTown = byDist[i].town;
			local dist = byDist[i].dist;
			if(dist == 0) continue;
			local connPop = AITown.GetPopulation(connTown);
			local production = max(30, min((townPop + connPop) / 20, 550));

			// Rail: good for medium distances
			if(!TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)) {
				local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_RAIL, paxCargo, dist, production, true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = {
						src        = TownCargo(connTown, paxCargo, true),
						dest       = TownCargo(unservedTown, paxCargo, true),
						vehicleType = AIVehicle.VT_RAIL,
						estimate   = clone est,
						cargo      = paxCargo,
						distance   = dist,
						production = production,
						isBiDirectional = true,
						routeClass = TrainRoute,
						explain    = "GlobalConnect(rail) "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown)+" dist:"+dist
					};
				}
			}

			// Air: good for long distances when profitable
			if(!AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)) {
				local infraTypes = AirRoute.GetSuitableInfrastractureTypes(
					TownCargo(connTown, paxCargo, true),
					TownCargo(unservedTown, paxCargo, true), paxCargo);
				local est = Route.Estimate(AIVehicle.VT_AIR, paxCargo, dist, production, true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = {
						src        = TownCargo(connTown, paxCargo, true),
						dest       = TownCargo(unservedTown, paxCargo, true),
						vehicleType = AIVehicle.VT_AIR,
						estimate   = clone est,
						cargo      = paxCargo,
						distance   = dist,
						production = production,
						isBiDirectional = true,
						routeClass = AirRoute,
						explain    = "GlobalConnect(air) "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown)+" dist:"+dist
					};
				}
			}
		}

		return bestCandidate; // null if nothing is profitable
	}

	// Find the nearest connected town to use as bus partner for small/unprofitable towns.
	function PaxMailNetwork::FindNearestConnectedTown(unservedTown, connected) {
		local townLoc = AITown.GetLocation(unservedTown);
		local bestTown = -1;
		local bestDist = 99999999;
		foreach(connTown, _ in connected) {
			local d = AIMap.DistanceManhattan(townLoc, AITown.GetLocation(connTown));
			if(d > 0 && d < bestDist) {
				bestDist = d;
				bestTown = connTown;
			}
		}
		return {town = bestTown, dist = bestDist};
	}

	function PaxMailNetwork::Step() {
		local ai = HogeAI.Get();
		if(ai.IsFreightOnly()) return;
		HgLog.Info("###### ConnectUnservedTowns");
		if(ai.GetUsableMoney() < ai.GetInflatedMoney(100000)) return;

		local paxCargo = ai.GetPassengerCargo();
		if(paxCargo == false || paxCargo == null) return;

		// No point running if all vehicle types are saturated
		if(TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)
				&& AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)
				&& RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)) {
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
		if(unserved.len() == 0) return;

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

		local maxNew = 3;
		local built = 0;
		local dirtyPlaces = {};
		local pendingPlans = [];

		foreach(unservedTown in unserved) {
			if(built >= maxNew) break;
			if(ai.limitDate < AIDate.GetCurrentDate()) {
				HgLog.Warning("ConnectUnservedTowns: reached limitDate");
				break;
			}

			local destKey = TownCargo(unservedTown, paxCargo, true).GetFacilityId() + ":" + paxCargo;
			if(dirtyPlaces.rawin(destKey)) {
				continue;
			}

			// --- Try rail or air (profitable routes only) ---
			local candidate = PaxMailNetwork.FindBestProfitableRouteForTown(unservedTown, connected, paxCargo);

			if(candidate != null) {
				// Use the real profitable estimate; no value override needed
				candidate.score <- candidate.estimate.value;
				candidate.maxValue <- candidate.estimate.value;
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
							foreach(c, _ in newRoute.GetEngineCargos()) {
								if(newRoute.srcHgStation.place != null) {
									dirtyPlaces.rawset(newRoute.srcHgStation.place.GetFacilityId()+":"+c, true);
								}
								if(newRoute.IsBiDirectional() && newRoute.destHgStation.place != null) {
									dirtyPlaces.rawset(newRoute.destHgStation.place.GetFacilityId()+":"+c, true);
								}
							}
						}
						built++;
						connected = PaxMailNetwork.GetPassengerServedTowns(paxCargo);
					}
				}
				ai.routeCandidates.Extend(pendingPlans);
				pendingPlans.clear();

			} else if(!RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)) {
				// --- Fallback: bus route to nearest connected town ---
				local nearest = PaxMailNetwork.FindNearestConnectedTown(unservedTown, connected);
				if(nearest.town == -1) {
					continue;
				}
				local connTown = nearest.town;
				local dist = nearest.dist;
				local production = max(30, min(
					(AITown.GetPopulation(unservedTown) + AITown.GetPopulation(connTown)) / 20, 340));
				local infraTypes = RoadRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, dist, production, true, infraTypes);
				if(est == null || est.value <= 0) {
					HgLog.Info("ConnectUnservedTowns: no viable route for "+AITown.GetName(unservedTown)+", skipping");
					continue;
				}
				local busCandidate = {
					src        = TownCargo(connTown, paxCargo, true),
					dest       = TownCargo(unservedTown, paxCargo, true),
					vehicleType = AIVehicle.VT_ROAD,
					estimate   = clone est,
					cargo      = paxCargo,
					distance   = dist,
					production = production,
					isBiDirectional = true,
					routeClass = RoadRoute,
					score      = est.value,
					maxValue   = est.value,
					explain    = "GlobalConnect(bus) "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown)+" dist:"+dist
				};
				ai.DoInterval();
				local builder = ai.CreateBuilder(busCandidate, pendingPlans, dirtyPlaces, ai.limitDate);
				if(builder != null) {
					HgLog.Info("ConnectUnservedTowns: "+busCandidate.explain+" {");
					local newRoutes = builder.Build();
					HgLog.Info("} ConnectUnservedTowns bus build");
					if(newRoutes != null) {
						if(typeof newRoutes != "array") newRoutes = [newRoutes];
						foreach(newRoute in newRoutes) {
							if(newRoute.srcHgStation.place != null) {
								newRoute.srcHgStation.place.SetDirtyArround();
							}
							foreach(c, _ in newRoute.GetEngineCargos()) {
								if(newRoute.srcHgStation.place != null) {
									dirtyPlaces.rawset(newRoute.srcHgStation.place.GetFacilityId()+":"+c, true);
								}
								if(newRoute.IsBiDirectional() && newRoute.destHgStation.place != null) {
									dirtyPlaces.rawset(newRoute.destHgStation.place.GetFacilityId()+":"+c, true);
								}
							}
						}
						built++;
						connected = PaxMailNetwork.GetPassengerServedTowns(paxCargo);
					}
				}
				ai.routeCandidates.Extend(pendingPlans);
				pendingPlans.clear();
			}

		}

		HgLog.Info("} ConnectUnservedTowns built:"+built);
	}
