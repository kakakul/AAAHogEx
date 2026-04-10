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

	function FreightNetwork::FindSpine() {
		HgLog.Info("FreightNetwork.FindSpine: stub");
		// Implemented in Task 4
	}

	function FreightNetwork::BuildJunctions() {
		HgLog.Info("FreightNetwork.BuildJunctions: stub");
		// Implemented in Task 5
		FreightNetwork.phase = FreightNetwork.PHASE_SEARCH_AND_CONNECT;
	}

	function FreightNetwork::SearchAndConnect() {
		HgLog.Info("FreightNetwork.SearchAndConnect: stub");
		// Implemented in Task 6
	}
