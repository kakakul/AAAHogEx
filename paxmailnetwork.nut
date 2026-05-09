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

	function PaxMailNetwork::MakeCandidate(connTown, unservedTown, paxCargo, vehicleType, routeClass, estimate, dist, production, label) {
		return {
			src        = TownCargo(connTown, paxCargo, true),
			dest       = TownCargo(unservedTown, paxCargo, true),
			vehicleType = vehicleType,
			estimate   = clone estimate,
			cargo      = paxCargo,
			distance   = dist,
			production = production,
			isBiDirectional = true,
			routeClass = routeClass,
			allowNetworkSourceReuse = true,
			explain    = "GlobalConnect("+label+") "+AITown.GetName(connTown)+"<->"+AITown.GetName(unservedTown)+" dist:"+dist
		};
	}

	// For a given unserved town, find the nearest connected town that has any profitable
	// road, water, rail, or air candidate. Within that one town pair, use the highest-value
	// vehicle type.
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

		// Only evaluate up to 15 nearest connected towns to keep this step fast
		local limit = min(byDist.len(), 15);

		for(local i = 0; i < limit; i++) {
			local connTown = byDist[i].town;
			local dist = byDist[i].dist;
			if(dist == 0) continue;
			local connPop = AITown.GetPopulation(connTown);
			local production = max(30, (townPop + connPop) / 20);
			local src = TownCargo(connTown, paxCargo, true);
			local dest = TownCargo(unservedTown, paxCargo, true);
			local bestCandidate = null;
			local bestValue = 0;

			// Road: shortest practical town-to-town connector when land-connected.
			if(!RoadRoute.IsTooManyVehiclesForNewRoute(RoadRoute)
					&& HgTile.IsLandConnectedForRoad(src.GetLocation(), dest.GetLocation())) {
				local infraTypes = RoadRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_ROAD, paxCargo, dist, min(production, 340), true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = PaxMailNetwork.MakeCandidate(connTown, unservedTown, paxCargo,
						AIVehicle.VT_ROAD, RoadRoute, est, dist, min(production, 340), "road");
				}
			}

			// Water: useful when the nearest pair can be joined by sea/canal.
			if(!WaterRoute.IsTooManyVehiclesForNewRoute(WaterRoute)
					&& WaterRoute.CanBuild(src, dest, paxCargo, true)) {
				local infraTypes = WaterRoute.GetSuitableInfrastractureTypes(src, dest, paxCargo);
				local est = Route.Estimate(AIVehicle.VT_WATER, paxCargo, dist, min(production, 550), true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = PaxMailNetwork.MakeCandidate(connTown, unservedTown, paxCargo,
						AIVehicle.VT_WATER, WaterRoute, est, dist, min(production, 550), "ship");
				}
			}

			// Rail: good for medium distances
			if(!TrainRoute.IsTooManyVehiclesForNewRoute(TrainRoute)
					&& HgTile.IsLandConnectedForRail(src.GetLocation(), dest.GetLocation())) {
				local infraTypes = TrainRoute.GetDefaultInfrastractureTypes();
				local est = Route.Estimate(AIVehicle.VT_RAIL, paxCargo, dist, min(production, 550), true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = PaxMailNetwork.MakeCandidate(connTown, unservedTown, paxCargo,
						AIVehicle.VT_RAIL, TrainRoute, est, dist, min(production, 550), "rail");
				}
			}

			// Air: good for long distances when profitable
			if(!AirRoute.IsTooManyVehiclesForNewRoute(AirRoute)) {
				local infraTypes = AirRoute.GetSuitableInfrastractureTypes(
					src, dest, paxCargo);
				local est = Route.Estimate(AIVehicle.VT_AIR, paxCargo, dist, min(production, 550), true, infraTypes);
				if(est != null && est.value > bestValue) {
					bestValue = est.value;
					bestCandidate = PaxMailNetwork.MakeCandidate(connTown, unservedTown, paxCargo,
						AIVehicle.VT_AIR, AirRoute, est, dist, min(production, 550), "air");
				}
			}

			if(bestCandidate != null) return bestCandidate;
		}

		return null; // null if nothing is profitable
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
		local remaining = unserved;

		while(remaining.len() > 0 && built < maxNew) {
			PaxMailNetwork.SortTownsByNetworkDistance(remaining, connected);
			local unservedTown = remaining[0];
			remaining.remove(0);
			if(ai.limitDate < AIDate.GetCurrentDate()) {
				HgLog.Warning("ConnectUnservedTowns: reached limitDate");
				break;
			}

			local destKey = TownCargo(unservedTown, paxCargo, true).GetFacilityId() + ":" + paxCargo;
			if(dirtyPlaces.rawin(destKey)) {
				continue;
			}

			// --- Try nearest profitable road, water, rail, or air route ---
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
						}
						built++;
						connected = PaxMailNetwork.GetPassengerServedTowns(paxCargo);
						if(candidate.src instanceof TownCargo) connected.rawset(candidate.src.town, true);
						if(candidate.dest instanceof TownCargo) connected.rawset(candidate.dest.town, true);
						local filteredRemaining = [];
						foreach(town in remaining) {
							if(!connected.rawin(town)) filteredRemaining.push(town);
						}
						remaining = filteredRemaining;
					}
				}
				ai.routeCandidates.Extend(pendingPlans);
				pendingPlans.clear();

			} else {
				HgLog.Info("ConnectUnservedTowns: no viable route for "+AITown.GetName(unservedTown)+", skipping");
			}

		}

		HgLog.Info("} ConnectUnservedTowns built:"+built);
	}
