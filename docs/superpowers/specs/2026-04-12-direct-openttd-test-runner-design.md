# Direct OpenTTD Test Runner — Design Spec

## Goal

Replace the OpenTTDLab-based test runner with a self-contained runner that calls the
system-installed OpenTTD binary directly, captures AI log output via UTF-8 subprocess,
and returns only relevant matched lines so test failures produce compact, useful output.

## Background

The existing runner (`conftest.py`) uses OpenTTDLab's `run_experiments`. On Windows,
OpenTTDLab calls `subprocess.check_output(..., text=True)` which decodes output with
the default cp1252 encoding. The AI debug log is UTF-8. The mismatch silently drops all
AI log output, so `row['output']` is always an empty string. Every `if output:` guard in
`test_integration.py` is always False, meaning all meaningful assertions are silently
skipped and tests pass vacuously regardless of what the AI does.

## Architecture

`tests/conftest.py` is rewritten to contain a self-contained `run_hognet` function. It
writes a per-run `game_start.scr`, launches OpenTTD via `subprocess.Popen`, streams
stdout+stderr line by line, collects matched lines, and returns a compact result dict.
OpenTTDLab is no longer imported.

## Constants

```
OPENTTD_EXE   = C:\Program Files (x86)\Steam\steamapps\common\OpenTTD\openttd.exe
STEAM_DIR     = C:\Program Files (x86)\Steam\steamapps\common\OpenTTD
TESTS_DIR     = directory containing conftest.py
CONFIG_FILE   = <TESTS_DIR>/openttd_test.cfg
SCRIPTS_DIR   = <TESTS_DIR>/scripts/
TICKS_PER_DAY = 74
DEFAULT_SEED  = 42
```

## Files

| Path | Action | Notes |
|------|--------|-------|
| `tests/conftest.py` | Rewrite | Remove OpenTTDLab; new runner |
| `tests/openttd_test.cfg` | Create (committed) | Static OpenTTD config |
| `tests/scripts/game_start.scr` | Written per-run | gitignored |
| `tests/test_integration.py` | Modify | Remove all `if output:` guards |
| `tests/test_output_check.py` | Delete | Temporary diagnostic; no longer needed |
| `tests/.gitignore` | Create or update | Ignore `scripts/game_start.scr` |

## `openttd_test.cfg`

```ini
[gui]
threaded_saves = false

[misc]
autosave = off
```

This file is committed to the repository and never modified at runtime.

## `game_start.scr` (written per-run)

Written to `tests/scripts/game_start.scr` before each subprocess call:

```
start_ai HogNet network_mode=1,usable_cargos=2,IsForceToHandleFright=1
```

Parameters vary per call (e.g. `network_mode=0` for the baseline run). OpenTTD finds
this file via its config-dir search path: because `-c` points to `openttd_test.cfg` in
`TESTS_DIR`, OpenTTD adds `TESTS_DIR` to its content search paths and looks for
`scripts/game_start.scr` there before looking in the binary dir.

## Runner function

```python
def run_hognet(network_mode=0, days=365*3, seed=DEFAULT_SEED, extra_params=()):
    """Run HogNet headlessly; return {'output': str, 'error': bool}.

    'output' contains only matched log lines (lines containing 'dbg: [script]'
    or the crash sentinel), plus up to TAIL_LINES lines before a crash for context.
    Tests assert directly on this string.
    """
```

### Setup

1. Build the AI params string:
   `network_mode=<n>,usable_cargos=2,IsForceToHandleFright=1[,extra...]`
2. Write `SCRIPTS_DIR/game_start.scr`:
   `start_ai HogNet <params>\n`
3. Compute ticks: `TICKS_PER_DAY * days`

### Subprocess

```python
proc = subprocess.Popen(
    [OPENTTD_EXE, '-g', '-G', str(seed), '-snull', '-mnull',
     '-vnull:ticks=' + str(ticks), '-d', 'script=5', '-c', CONFIG_FILE],
    cwd=STEAM_DIR,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    encoding='utf-8',
    errors='replace',
)
```

`errors='replace'` ensures any residual encoding issues produce `?` instead of raising.

### Line streaming and collection

Constants:
- `LOG_MARKER = 'dbg: [script]'` — prefix OpenTTD adds to AI `AILog.*` output
- `CRASH_MARKER = 'The script died unexpectedly'`
- `TAIL_LINES = 20` — lines of context captured before a crash

Logic:
```
matched = []       # lines containing LOG_MARKER or CRASH_MARKER
tail_buf = deque(maxlen=TAIL_LINES)   # rolling window of recent lines
error = False

for line in proc.stdout:
    tail_buf.append(line)
    if LOG_MARKER in line or CRASH_MARKER in line:
        matched.append(line)
    if CRASH_MARKER in line:
        error = True
        break      # stop reading; no need to continue

proc.wait(timeout=120)   # ensure process exits; raises TimeoutExpired if hung
```

Early exit on crash means we don't wait for the remaining ticks to elapse.

### Return value

```python
if error:
    output = ''.join(matched) + '\n--- last lines ---\n' + ''.join(tail_buf)
else:
    output = ''.join(matched)
return {'output': output, 'error': error}
```

## Test changes

### `test_integration.py`

Remove every `if output:` guard. All assertions become unconditional:

```python
# Before
if output:
    assert 'FreightNetwork.FindSpine: spine built' in output

# After
assert 'FreightNetwork.FindSpine: spine built' in output, (
    f"Expected spine route to be built\nOutput:\n{output}"
)
```

Adding `output` to assertion messages gives useful context on failure without
printing the full game log.

### `test_output_check.py`

Delete entirely. It was a temporary diagnostic to inspect the OpenTTDLab row structure.

## `tests/.gitignore`

```
scripts/game_start.scr
```

## Concurrency

Tests run sequentially (pytest default, no `-n` flag). `game_start.scr` is overwritten
before each run. No locking required. If parallel test execution is ever added, each
worker would need its own temp scripts dir — out of scope for this design.

## Failure modes

| Condition | Behaviour |
|-----------|-----------|
| OpenTTD binary not found | `FileNotFoundError` from `Popen` — test errors with clear message |
| Process times out | `proc.wait(timeout=120)` raises `subprocess.TimeoutExpired`; test errors with clear message |
| `game_start.scr` dir missing | `os.makedirs(SCRIPTS_DIR, exist_ok=True)` in runner setup |
| Encoding error in output | `errors='replace'` prevents exceptions |
