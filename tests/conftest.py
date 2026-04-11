import os
from openttdlab import run_experiments, local_folder

AI_FOLDER = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
OPENTTD_VERSION = '15.3'
SEED = 42


def run_hognet(network_mode=0, days=365 * 3, extra_params=(), seed=SEED):
    """Run HogNet headlessly and return the result row."""
    params = (('network_mode', str(network_mode)),
              ('usable_cargos', '2'),
              ('IsForceToHandleFright', '1')) + extra_params
    results = list(run_experiments(
        openttd_version=OPENTTD_VERSION,
        experiments=({
            'seed': seed,
            'ais': (local_folder(AI_FOLDER, 'HogNet', ai_params=params),),
            'days': days,
        },),
    ))
    assert results, "run_experiments returned no results"
    return results[0]
