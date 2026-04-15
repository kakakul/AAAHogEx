import pytest
from conftest import run_hognet


def test_freight_network_skeleton():
    """FreightNetwork skeleton is loaded and Step() runs without crash."""
    row = run_hognet(network_mode=1, days=365 * 1)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.FindSpine:' in row['output'], (
        "Expected FreightNetwork.Step() to run in network mode\n"
        f"Output:\n{row['output']}"
    )


def test_freight_skipped_in_scanplaces():
    """In network mode, ScanPlaces must not build freight rail via the old path."""
    row = run_hognet(network_mode=1, days=365 * 2)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    # TryBuildNearStation IS expected in network mode (called by FreightNetwork.BuildJunctions);
    # the ScanPlaces old path is blocked by the IsNetworkMode() early-return in main.nut.
    assert 'FreightNetwork.FindSpine:' in row['output'], (
        f"Expected FreightNetwork.FindSpine: in output\nOutput:\n{row['output']}"
    )


@pytest.mark.parametrize("seed", [42])
def test_spine_built(seed):
    """C1 must select an industry pair and build the spine route."""
    row = run_hognet(network_mode=1, days=365 * 3, seed=seed)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.FindSpine: spine built' in row['output'], (
        f"Expected spine route to be built\nOutput:\n{row['output']}"
    )
    assert 'advancing to BuildJunctions' in row['output'], (
        f"Expected 'advancing to BuildJunctions'\nOutput:\n{row['output']}"
    )


def test_junctions_recorded():
    """C2 must build junctions and record merge tiles after spine route."""
    row = run_hognet(network_mode=1, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.BuildJunctions:' in row['output'], (
        f"Expected BuildJunctions to run\nOutput:\n{row['output']}"
    )
    assert 'FreightNetwork.BuildJunctions: recorded junctions' in row['output'], (
        f"Expected junction merge tiles to be recorded\nOutput:\n{row['output']}"
    )
    assert 'FreightNetwork.SearchAndConnect:' in row['output'], (
        f"Expected SearchAndConnect to run\nOutput:\n{row['output']}"
    )


@pytest.mark.parametrize("seed", [42])
def test_source_connected(seed):
    """C3+C4 must find a second source and connect it to the existing junction."""
    row = run_hognet(network_mode=1, days=365 * 5, seed=seed)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.SearchAndConnect: found source' in row['output'], (
        f"Expected SearchAndConnect to find a source industry\nOutput:\n{row['output']}"
    )
    assert 'FreightNetwork.SearchAndConnect: connected' in row['output'], (
        f"Expected a second source to be connected\nOutput:\n{row['output']}"
    )


@pytest.mark.parametrize("seed", [42])
def test_spur_connects_via_junction(seed):
    """Spur must log 'connected via junction', not just 'connected'."""
    row = run_hognet(network_mode=1, days=365 * 5, seed=seed)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'FreightNetwork.SearchAndConnect: connected via junction' in row['output'], (
        f"Expected spur to connect via junction\nOutput:\n{row['output']}"
    )
