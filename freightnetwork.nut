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
		HgLog.Info("FreightNetwork.SearchAndConnect: stub");
		// Implemented in Task 6
	}
