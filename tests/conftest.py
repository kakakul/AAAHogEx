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
