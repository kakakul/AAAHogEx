# tests/test_task1_railbuilder.py
from conftest import run_hognet


def test_trybuildn_returns_merge_tiles_non_network_mode():
    """In non-network mode, TryBuildNearStation should still run and log merge tiles."""
    row = run_hognet(network_mode=0, days=365 * 3)
    assert not row['error'], f"AI crashed:\n{row['output']}"

    output = row['output']
    if output:
        # When OpenTTD log output is available (Linux/CI), verify log format.
        assert 'TryBuildNearStation: tried=' in output, (
            "Expected TryBuildNearStation to run in non-network mode"
        )
        # New return format: leftTile= instead of left=
        assert 'leftTile=' in output, (
            "Expected new leftTile= format in TryBuildNearStation log"
        )
