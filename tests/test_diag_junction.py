from conftest import run_hognet


def test_build_true_all_orientations():
    """Build(true) must return OK for all four orientations."""
    row = run_hognet(network_mode=1, days=3, extra_params=[('probe_diag_junction', '1')])
    assert not row['error'], f"AI crashed:\n{row['output']}"
    probe_lines = [l for l in row['output'].splitlines() if 'DiagProbe' in l]
    output_str = '\n'.join(probe_lines)
    assert 'Build(true) flipY=false flipX=false rotate=false: OK' in row['output'], \
        f"Canonical orientation blocked:\n{output_str}"
    assert 'BLOCKED' not in output_str, \
        f"One or more orientations blocked:\n{output_str}"


def test_build_false_canonical_ok():
    """Build(false) must succeed for the canonical orientation."""
    row = run_hognet(network_mode=1, days=3, extra_params=[('probe_diag_junction', '1')])
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'DiagProbe Build(false) canonical: OK' in row['output'], (
        "Build(false) failed for canonical orientation.\n" +
        '\n'.join(l for l in row['output'].splitlines() if 'DiagProbe' in l)
    )


def test_paths_contiguous():
    """GetBranchPath and GetInboundBranchPath must be contiguous."""
    row = run_hognet(network_mode=1, days=3, extra_params=[('probe_diag_junction', '1')])
    assert not row['error'], f"AI crashed:\n{row['output']}"
    assert 'BranchPath' in row['output'] and 'contiguous=true' in row['output'], (
        "Path not contiguous:\n" +
        '\n'.join(l for l in row['output'].splitlines() if 'DiagProbe' in l)
    )
