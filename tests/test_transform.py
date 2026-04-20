"""
Out-of-game unit tests for RightDivergeDiagonalJunction.Transform.

Canonical orientation is identity: Transform(x,y) == (x,y).
Non-canonical orientations apply a simple swap+negate transform:
  - rotate=True swaps the two axes
  - flipX negates the x axis after any swap
  - flipY negates the y axis after any swap

Correction note (documented in report):
  The layout 2/3/4 comments in railbuilder.nut use labels that appear to depict
  role-equivalent tiles at positions that are NOT obtainable by a single affine
  transform from the canonical labels (e.g. spine tiles are drawn at the same
  world offsets in layouts 1 and 2, but canonical (3,1) is shown at world (0,2)
  in layout 2). No linear map satisfies both constraints simultaneously.
  After iterating on formulas in Python and inspecting the layouts, the simple
  swap+negate formula is adopted. The layout diagrams are visualization aids
  only; the actual world placement is given by the simple transform.

Run: pytest tests/test_transform.py -v
"""

def transform(x, y, flipX, flipY, rotate):
    """Simple swap+negate Transform formula."""
    tx = y if rotate else x
    ty = x if rotate else y
    fx = -tx if flipX else tx
    fy = -ty if flipY else ty
    return (fx, fy)


# (flipY, flipX, rotate,  cx, cy,  expected_wx, expected_wy,  note)
#
# All expected values are computed from the simple swap+negate formula.
CASES = [
    # --- Layout 1: canonical (flipY=F, flipX=F, rotate=F) - identity ---
    (False, False, False,   0,  0,    0,  0,  "origin"),
    (False, False, False,  -2, -1,   -2, -1,  "far NE spine end"),
    (False, False, False,   2,  2,    2,  2,  "spine signal"),
    (False, False, False,   3,  0,    3,  0,  "branch outbound far end"),
    (False, False, False,   3,  1,    3,  1,  "branch inbound signal"),
    # --- Layout 2: (flipY=F, flipX=T, rotate=T) swap then flipX ---
    # Transform: (x, y) -> (-y, x)
    (False, True,  True,    0,  0,    0,  0,  "origin"),
    (False, True,  True,   -2, -1,    1, -2,  "far NE spine end"),
    (False, True,  True,    0, -1,    1,  0,  "spine signal (↙S)"),
    (False, True,  True,    2,  2,   -2,  2,  "spine signal (↙↗S)"),
    (False, True,  True,    3,  1,   -1,  3,  "branch inbound signal"),
    # --- Layout 3: (flipY=T, flipX=T, rotate=F) ---
    # Transform: (x, y) -> (-x, -y)
    (True,  True,  False,   0,  0,    0,  0,  "origin"),
    (True,  True,  False,  -2, -1,    2,  1,  "far NE spine end (rotated 180)"),
    (True,  True,  False,   2,  2,   -2, -2,  "spine signal"),
    (True,  True,  False,   3,  1,   -3, -1,  "branch inbound signal"),
    # --- Layout 4: (flipY=T, flipX=F, rotate=F) ---
    # Transform: (x, y) -> (x, -y)
    (True,  False, False,   0,  0,    0,  0,  "origin"),
    (True,  False, False,  -2, -1,   -2,  1,  "far NE spine end (mirror y)"),
    (True,  False, False,   2,  2,    2, -2,  "spine signal"),
    (True,  False, False,   3,  1,    3, -1,  "branch inbound signal"),
]


def test_transform_cases():
    failures = []
    for flipY, flipX, rotate, cx, cy, ewx, ewy, note in CASES:
        actual = transform(cx, cy, flipX, flipY, rotate)
        if actual != (ewx, ewy):
            failures.append(
                f"FAIL flipY={flipY} flipX={flipX} rotate={rotate} "
                f"transform({cx},{cy})={actual} expected=({ewx},{ewy})  [{note}]"
            )
    if failures:
        raise AssertionError("Transform mismatches:\n" + "\n".join(failures))
