# tests/test_integration.py
from conftest import run_hognet


def test_freight_network_skeleton():
    """FreightNetwork skeleton is loaded and Step() runs without crash."""
    row = run_hognet(network_mode=1, days=365 * 1)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    output = row['output']
    if output:  # Windows: OpenTTD -vnull produces no stdout
        assert 'FreightNetwork.FindSpine:' in output, (
            "Expected FreightNetwork.Step() to run in network mode"
        )


def test_freight_skipped_in_scanplaces():
    """In network mode, ScanPlaces must not build freight rail via the old path."""
    row = run_hognet(network_mode=1, days=365 * 2)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    output = row['output']
    if output:  # Windows: OpenTTD -vnull produces no stdout; log assertions run on Linux/CI only
        # TryBuildNearStation must NOT appear — freight junctions are now FreightNetwork's job
        assert 'TryBuildNearStation: tried=' not in output, (
            "TryBuildNearStation should not run in network mode"
        )
        # FreightNetwork should still appear
        assert 'FreightNetwork.FindSpine:' in output


def test_spine_built():
    """C1 must select an industry pair and build the spine route."""
    row = run_hognet(network_mode=1, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    output = row['output']
    if output:  # Windows: OpenTTD -vnull produces no stdout; log assertions run on Linux/CI only
        assert 'FreightNetwork.FindSpine: spine built' in output, (
            "Expected spine route to be built"
        )
        assert 'advancing to PHASE_BUILD_JUNCTION' in output
