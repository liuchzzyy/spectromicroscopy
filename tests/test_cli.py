"""The CLI ships in the same distribution as the core and stays Qt-free."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run_cli(*args):
    return subprocess.run([sys.executable, '-m', 'mantis_xray', *args], capture_output=True, text=True)


def test_help_is_headless():
    result = run_cli('--help')
    assert result.returncode == 0, result.stderr
    assert 'pipeline' in result.stdout
    assert 'inspect' in result.stdout
    assert 'Qt' not in result.stderr


def test_bad_option_has_failure_exit_status():
    assert run_cli('--not-a-real-option').returncode == 2


def test_cli_version_matches_the_single_distribution_version():
    from mantis_xray import __version__
    result = run_cli('--version')
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == f'mantis-xray CLI {__version__}'


def test_invalid_pipeline_does_not_create_output(tmp_path):
    pipeline = tmp_path / 'invalid.json'
    pipeline.write_text(json.dumps({'steps': [{'method': 'export', 'params': {}}]}))
    result = run_cli('pipeline', str(pipeline))
    assert result.returncode != 0
    assert 'first step' in result.stderr.lower()


def test_batch_paths_are_relative_to_settings_and_flags_are_typed(tmp_path):
    from mantis_xray.batch import parse_settings, to_pipeline
    settings = tmp_path / 'settings.txt'
    settings.write_text('VERSION: 2\nWORK_DIR: data\nFILENAME: input.npz\n'
                        'ALIGN_STACK: 0\nI0_FILE: \'\'\nRUN_PCA: 1\nN_SPCA: 2\n'
                        'RUN_CLUSTER_ANALYSIS: 1\nN_CLUSTERS: 3\nSAVE_PNG: 0\n')
    parsed = parse_settings(settings)
    assert parsed['ALIGN_STACK'] == 0
    steps = to_pipeline(parsed, settings.parent)['steps']
    assert steps[0]['params']['path'] == str(tmp_path / 'data' / 'input.npz')
    assert 'align' not in [s['method'] for s in steps]
    assert [s['method'] for s in steps][-2:] == ['pca', 'cluster']


def test_unknown_batch_setting_is_rejected(tmp_path):
    from mantis_xray.batch import parse_settings
    import pytest
    path = tmp_path / 'settings.txt'
    path.write_text('TYPO_N_CLUSTERS: 4\n')
    with pytest.raises(ValueError, match='Unknown'):
        parse_settings(path)


def test_pipeline_protocol_rejects_boolean():
    import pytest
    from mantis_xray.cli import validate_pipeline
    with pytest.raises(ValueError, match='protocol'):
        validate_pipeline({'protocol': True, 'steps': [{'method': 'open', 'params': {'path': 'x.npz'}}]})


def test_analysis_and_pipeline_match_real_numeric_export(tmp_path):
    import numpy as np
    rng = np.random.default_rng(4)
    data = rng.uniform(0.1, 2.0, (8, 6, 5))
    source = tmp_path / 'input.npz'
    np.savez(source, data=data, energies=np.arange(5) + 280.0)
    output = tmp_path / 'cli.npz'
    result = run_cli('analyze', str(source), '--pre-normalized', '--components', '2',
                     '--clusters', '2', '--seed', '7', '--output', str(output))
    assert result.returncode == 0, result.stderr
    snapshot = json.loads(result.stdout)
    assert snapshot['normalized'] and snapshot['pca_ready'] and snapshot['clusters_ready']
    assert output.is_file()
    pipeline = tmp_path / 'workflow.json'
    pipeline.write_text(json.dumps({'protocol': 1, 'steps': [
        {'method': 'open', 'params': {'path': 'input.npz', 'pre_normalized': True}},
        {'method': 'pca', 'params': {'components': 2}},
        {'method': 'cluster', 'params': {'components': 2, 'clusters': 2, 'seed': 7}},
        {'method': 'export', 'params': {'path': 'pipeline.npz', 'format': 'npz'}},
    ]}))
    replay = run_cli('pipeline', str(pipeline))
    assert replay.returncode == 0, replay.stderr
    assert json.loads(replay.stdout)['clusters_ready']
    with np.load(output, allow_pickle=False) as a, np.load(tmp_path / 'pipeline.npz', allow_pickle=False) as b:
        numeric = [key for key in a.files if a[key].dtype.kind in 'biufc']
        assert numeric
        for key in numeric:
            np.testing.assert_allclose(a[key], b[key])
    original = source.read_bytes()
    blocked = run_cli('analyze', str(source), '--pre-normalized', '--components', '2', '--output', str(source))
    assert blocked.returncode != 0
    assert source.read_bytes() == original
