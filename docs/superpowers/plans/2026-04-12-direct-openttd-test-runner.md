# Direct OpenTTD Test Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OpenTTDLab-based test runner with a direct subprocess runner that captures AI log output correctly on Windows, so test assertions are never silently skipped.

**Architecture:** `conftest.py` is rewritten to write a per-run `game_start.scr`, launch OpenTTD via `subprocess.Popen`, stream output line-by-line collecting only matched log lines, and return a compact result dict. A static `openttd_test.cfg` is committed to the repo. All `if output:` guards are removed from test files.

**Tech Stack:** Python 3.8, subprocess.Popen, pytest, OpenTTD 15.x (system-installed at `C:\Program Files (x86)\Steam\steamapps\common\OpenTTD\openttd.exe`)

---

### Task 1: Static config file and gitignore

**Goal:** Commit `tests/openttd_test.cfg` (the static OpenTTD config used by all runs) and gitignore the per-run `game_start.scr`.

**Files:**
- Create: `tests/openttd_test.cfg`
- Create: `tests/scripts/.gitkeep`
- Modify: `.gitignore` (or create `tests/.gitignore`)

**Acceptance Criteria:**
- [ ] `tests/openttd_test.cfg` exists and contains `autosave = off` and `threaded_saves = false`
- [ ] `tests/scripts/game_start.scr` is gitignored
- [ ] `tests/scripts/` directory tracked via `.gitkeep`

**Verify:** `git status` shows `tests/openttd_test.cfg` and `tests/scripts/.gitkeep` as new files, and confirms `tests/scripts/game_start.scr` would be ignored.

**Steps:**

- [ ] **Step 1: Create `tests/openttd_test.cfg`**

```ini
[gui]
threaded_saves = false

[misc]
autosave = off
```

- [ ] **Step 2: Create `tests/scripts/.gitkeep`**

Empty file. Ensures the `scripts/` directory exists in the repo so the runner can write `game_start.scr` into it without creating the directory first.

- [ ] **Step 3: Add gitignore entry**

Add to `tests/.gitignore` (create if it doesn't exist):

```
scripts/game_start.scr
```

- [ ] **Step 4: Verify gitignore works**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet"
echo "test" > tests/scripts/game_start.scr
git status tests/scripts/
```

Expected: `tests/scripts/game_start.scr` does NOT appear in git status output (it is ignored). `tests/scripts/.gitkeep` appears as untracked or tracked.

- [ ] **Step 5: Commit**

```bash
git add tests/openttd_test.cfg tests/scripts/.gitkeep tests/.gitignore
git commit -m "Add static OpenTTD test config and gitignore for game_start.scr"
```

---

### Task 2: Rewrite `conftest.py` with direct subprocess runner

**Goal:** Replace the OpenTTDLab runner with a `run_hognet` function that writes `game_start.scr`, launches OpenTTD via `Popen`, streams output line-by-line, and returns `{'output': str, 'error': bool}` containing only matched log lines.

**Files:**
- Modify: `tests/conftest.py`

**Acceptance Criteria:**
- [ ] `conftest.py` does not import `openttdlab`
- [ ] `run_hognet` writes `tests/scripts/game_start.scr` with the correct `start_ai` line before each run
- [ ] OpenTTD is launched with `-d script=5` and `encoding='utf-8'`
- [ ] Output is streamed line-by-line; only lines containing `dbg: [script]` or `The script died unexpectedly` are collected
- [ ] On crash detection (`The script died unexpectedly` in a line), streaming stops early and the last 20 lines are appended for context
- [ ] `run_hognet(network_mode=0, days=30, seed=42)` completes without error (smoke test — game runs and returns)

**Verify:** `cd tests && python -c "from conftest import run_hognet; r = run_hognet(network_mode=0, days=30); print('error:', r['error']); print('output lines:', len(r['output'].splitlines()))"` → prints `error: False` and a line count ≥ 0.

**Steps:**

- [ ] **Step 1: Write the new `conftest.py`**

Replace the entire file with:

```python
import os
import subprocess
from collections import deque

OPENTTD_EXE   = r'C:\Program Files (x86)\Steam\steamapps\common\OpenTTD\openttd.exe'
STEAM_DIR     = r'C:\Program Files (x86)\Steam\steamapps\common\OpenTTD'
TESTS_DIR     = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE   = os.path.join(TESTS_DIR, 'openttd_test.cfg')
SCRIPTS_DIR   = os.path.join(TESTS_DIR, 'scripts')
TICKS_PER_DAY = 74
DEFAULT_SEED  = 42

LOG_MARKER    = 'dbg: [script]'
CRASH_MARKER  = 'The script died unexpectedly'
TAIL_LINES    = 20


def run_hognet(network_mode=0, days=365 * 3, seed=DEFAULT_SEED, extra_params=()):
    """Run HogNet headlessly and return {'output': str, 'error': bool}.

    'output' contains only lines that include the AI log marker or crash marker,
    plus up to TAIL_LINES lines of context before a detected crash.
    """
    # Build AI params string
    params = [
        f'network_mode={network_mode}',
        'usable_cargos=2',
        'IsForceToHandleFright=1',
    ]
    for key, value in extra_params:
        params.append(f'{key}={value}')
    params_str = ','.join(params)

    # Write game_start.scr
    os.makedirs(SCRIPTS_DIR, exist_ok=True)
    scr_path = os.path.join(SCRIPTS_DIR, 'game_start.scr')
    with open(scr_path, 'w', encoding='utf-8') as f:
        f.write(f'start_ai HogNet {params_str}\n')

    ticks = str(TICKS_PER_DAY * days)

    proc = subprocess.Popen(
        [OPENTTD_EXE,
         '-g',
         '-G', str(seed),
         '-snull',
         '-mnull',
         '-vnull:ticks=' + ticks,
         '-d', 'script=5',
         '-c', CONFIG_FILE],
        cwd=STEAM_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding='utf-8',
        errors='replace',
    )

    matched = []
    tail_buf = deque(maxlen=TAIL_LINES)
    error = False

    for line in proc.stdout:
        tail_buf.append(line)
        if LOG_MARKER in line or CRASH_MARKER in line:
            matched.append(line)
        if CRASH_MARKER in line:
            error = True
            break  # stop early; remaining ticks don't matter

    try:
        proc.wait(timeout=120)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise

    if error:
        output = ''.join(matched) + '\n--- last lines before crash ---\n' + ''.join(tail_buf)
    else:
        output = ''.join(matched)

    return {'output': output, 'error': error}
```

- [ ] **Step 2: Smoke-test the runner manually**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet/tests"
python -c "
from conftest import run_hognet
r = run_hognet(network_mode=0, days=30)
print('error:', r['error'])
print('output lines:', len(r['output'].splitlines()))
print('first 3 lines:')
for l in r['output'].splitlines()[:3]:
    print(' ', repr(l))
"
```

Expected: `error: False`, output line count ≥ 0 (may be 0 if AI produces no log in 30 days), no exception raised.

- [ ] **Step 3: Commit**

```bash
git add tests/conftest.py
git commit -m "Replace OpenTTDLab runner with direct subprocess runner"
```

---

### Task 3: Remove `if output:` guards from all test files

**Goal:** Make all test assertions unconditional so they fail loudly instead of silently passing when output is empty.

**Files:**
- Modify: `tests/test_integration.py`
- Modify: `tests/test_task1_railbuilder.py`
- Delete: `tests/test_output_check.py`

**Acceptance Criteria:**
- [ ] No `if output:` block exists in any test file
- [ ] Every assertion in `test_integration.py` and `test_task1_railbuilder.py` runs unconditionally
- [ ] `test_output_check.py` is deleted
- [ ] `pytest tests/test_integration.py tests/test_task1_railbuilder.py -v` runs without collection errors

**Verify:** `pytest tests/test_integration.py tests/test_task1_railbuilder.py -v --collect-only` → all tests collected, no syntax errors.

**Steps:**

- [ ] **Step 1: Rewrite `tests/test_integration.py`**

Replace the entire file with:

```python
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
    assert 'TryBuildNearStation: tried=' not in row['output'], (
        "TryBuildNearStation should not run in network mode"
    )
    assert 'FreightNetwork.FindSpine:' in row['output'], (
        f"Expected FreightNetwork.FindSpine: in output\nOutput:\n{row['output']}"
    )


@pytest.mark.parametrize("seed", [42, 1])
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


@pytest.mark.parametrize("seed", [42, 1])
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
```

- [ ] **Step 2: Rewrite `tests/test_task1_railbuilder.py`**

Replace the entire file with:

```python
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
```

- [ ] **Step 3: Delete `tests/test_output_check.py`**

```bash
rm "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet/tests/test_output_check.py"
```

- [ ] **Step 4: Verify collection**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet"
pytest tests/test_integration.py tests/test_task1_railbuilder.py -v --collect-only
```

Expected: 8 tests collected (6 from test_integration, 1+1 parametrized from test_task1_railbuilder... actually: test_freight_network_skeleton, test_freight_skipped_in_scanplaces, test_spine_built[42], test_spine_built[1], test_junctions_recorded, test_source_connected[42], test_source_connected[1], test_trybuildn_returns_merge_tiles_non_network_mode = 8 tests), no errors.

- [ ] **Step 5: Commit**

```bash
git add tests/test_integration.py tests/test_task1_railbuilder.py
git rm tests/test_output_check.py
git commit -m "Remove if-output guards; delete diagnostic test file"
```

---

### Task 4: Run the full test suite and verify output is captured

**Goal:** Confirm the runner produces non-empty output for a short run, and that at least the skeleton test passes (i.e., `FreightNetwork.FindSpine:` appears in output).

**Files:** None modified — this task is verification only.

**Acceptance Criteria:**
- [ ] `run_hognet(network_mode=1, days=365)` returns non-empty `output`
- [ ] `test_freight_network_skeleton` passes

**Verify:** `pytest tests/test_integration.py::test_freight_network_skeleton -v -s` → PASSED.

**Steps:**

- [ ] **Step 1: Run the skeleton test**

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet"
pytest tests/test_integration.py::test_freight_network_skeleton -v -s
```

Expected: `PASSED`. If it fails with "Expected FreightNetwork.Step() to run in network mode", the output will be printed — check what log lines were captured to diagnose.

- [ ] **Step 2: If output is empty, diagnose**

If `output` is empty, the `game_start.scr` may not be found by OpenTTD. Run:

```bash
cd "c:/Program Files (x86)/Steam/steamapps/common/OpenTTD/ai/HogNet/tests"
python -c "
from conftest import run_hognet
r = run_hognet(network_mode=1, days=365)
print('error:', r['error'])
print('output repr:', repr(r['output'][:500]))
"
```

If empty: verify that `tests/scripts/game_start.scr` was written and contains the correct line. Then check that OpenTTD found it by temporarily adding `stdout=subprocess.PIPE, stderr=subprocess.STDOUT` without the line filter and printing the first 50 lines raw to see what OpenTTD reports at startup — look for "Loading script" or error lines near the top.

- [ ] **Step 3: If `game_start.scr` is not found**

OpenTTD may not be searching the config dir for scripts. In that case, change the runner to write `game_start.scr` directly into the Steam `scripts/` dir instead:

```python
SCRIPTS_DIR = os.path.join(STEAM_DIR, 'scripts')
```

This is a fallback — the Steam dir is the binary dir and OpenTTD always searches it. Tests are sequential so overwriting is safe.

- [ ] **Step 4: Commit if Step 3 fix was needed**

```bash
git add tests/conftest.py
git commit -m "Fix game_start.scr path to use Steam scripts dir"
```
