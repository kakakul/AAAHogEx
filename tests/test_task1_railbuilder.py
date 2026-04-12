# tests/test_task1_railbuilder.py
from conftest import run_hognet


def test_trybuildn_returns_merge_tiles_non_network_mode():
    """In non-network mode, TryBuildNearStation should still run and log merge tiles."""
    row = run_hognet(network_mode=0, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'TryBuildNearStation: tried=' in row['output'], (
        f"Expected TryBuildNearStation to run in non-network mode\nOutput:\n{row['output']}"
    )
    assert 'leftTile=' in row['output'], (
        f"Expected new leftTile= format in TryBuildNearStation log\nOutput:\n{row['output']}"
    )
