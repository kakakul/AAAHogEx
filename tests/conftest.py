import subprocess
from collections import deque

# WSL-based runner: OpenTTD 15.3 Linux binary inside WSL, output captured via stderr pipe.
WSL_OPENTTD   = '/home/sy/openttd-15.3-linux-generic-amd64/openttd'
WSL_SCRIPTS   = '/home/sy/.local/share/openttd/scripts'
WSL_CFG       = '/home/sy/.config/openttd/openttd.cfg'
TICKS_PER_DAY = 74
DEFAULT_SEED  = 42

LOG_MARKER    = 'dbg: [script'
CRASH_MARKER  = 'The script died unexpectedly'
TAIL_LINES    = 20


def run_hognet(network_mode=0, days=365 * 3, seed=DEFAULT_SEED, extra_params=()):
    """Run HogNet headlessly via WSL and return {'output': str, 'error': bool}.

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

    ticks = str(TICKS_PER_DAY * days)

    # Patch openttd.cfg to use a 512x512 map (map_x/map_y = 9 = log2(512)).
    subprocess.run(
        ['wsl', 'bash', '-c',
         f'sed -i "s/^map_x = .*/map_x = 9/" {WSL_CFG} && '
         f'sed -i "s/^map_y = .*/map_y = 9/" {WSL_CFG}'],
        check=True,
    )

    # Write game_start.scr into WSL openttd personal dir via wsl bash.
    scr_content = f'start_ai HogNet {params_str}\\n'
    subprocess.run(
        ['wsl', 'bash', '-c', f'mkdir -p {WSL_SCRIPTS} && printf "{scr_content}" > {WSL_SCRIPTS}/game_start.scr'],
        check=True,
    )

    proc = subprocess.Popen(
        ['wsl', WSL_OPENTTD,
         '-g',
         '-G', str(seed),
         '-snull',
         '-mnull',
         '-v', 'null:ticks=' + ticks,
         '-d', 'script=5'],
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
        proc.wait(timeout=300)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise

    if error:
        output = ''.join(matched) + '\n--- last lines before crash ---\n' + ''.join(tail_buf)
    else:
        output = ''.join(matched)

    return {'output': output, 'error': error}
