# tests/test_integration.py
from conftest import run_hognet


def test_freight_network_skeleton():
    """FreightNetwork skeleton is loaded and Step() runs without crash."""
    row = run_hognet(network_mode=1, days=365 * 1)
    assert not row['error'], f"AI crashed:\n{row['output']}"
    output = row['output']
    if output:  # Windows: OpenTTD -vnull produces no stdout
        assert 'FreightNetwork.FindSpine: stub' in output, (
            "Expected FreightNetwork.Step() to run in network mode"
        )
