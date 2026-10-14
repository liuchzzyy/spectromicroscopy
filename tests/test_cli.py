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


def test_pipeline_cannot_overwrite_consumed_i0(tmp_path):
    import numpy as np
    source = tmp_path / 'input.npz'
    np.savez(source, data=np.full((3, 3, 3), 10.), energies=[280., 281., 282.])
    incident = tmp_path / 'i0.txt'
    incident.write_text('280 100\n281 100\n282 100\n')
    original = incident.read_bytes()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'normalize', 'params': {'mode': 'file', 'path': 'i0.txt'}},
        {'method': 'export', 'params': {'path': 'i0.txt', 'format': 'npz', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'input' in result.stderr.lower()
    assert incident.read_bytes() == original


def test_pipeline_cannot_overwrite_its_configuration(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'workflow.json', 'format': 'npz', 'overwrite': True}},
    ]}))
    original = workflow.read_bytes()
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'input' in result.stderr.lower()
    assert workflow.read_bytes() == original


def test_pipeline_cannot_overwrite_earlier_opened_source(tmp_path):
    import numpy as np
    first, second = tmp_path / 'first.npz', tmp_path / 'second.npz'
    for path in (first, second):
        np.savez(path, data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    original = first.read_bytes()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'first.npz'}},
        {'method': 'open', 'params': {'path': 'second.npz'}},
        {'method': 'export', 'params': {'path': 'first.npz', 'format': 'npz', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert first.read_bytes() == original


def test_pipeline_rejects_export_format_suffix_mismatch(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'wrong.csv', 'format': 'npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'format' in result.stderr.lower() and 'suffix' in result.stderr.lower()
    assert not (tmp_path / 'wrong.csv').exists()


def test_pipeline_rejects_duplicate_json_keys(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text('{"steps":[{"method":"open","method":"build_stack","params":{"path":"missing.npz"}}]}')
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'duplicate' in result.stderr.lower()


def test_pipeline_rejects_nonfinite_json_values(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text('{"steps":[{"method":"open","params":{"path":"missing.npz","x":NaN}}]}')
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'nonfinite' in result.stderr.lower()


def test_pipeline_rejects_empty_method_before_open(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [{'method': '', 'params': {'path': 'missing.npz'}}]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'method' in result.stderr.lower()
    assert 'Traceback' not in result.stderr


def test_pipeline_reports_all_exports_and_completed_outputs_on_later_failure(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    steps = [{'method': 'open', 'params': {'path': 'input.npz'}},
             {'method': 'export', 'params': {'path': 'out/first.npz', 'format': 'npz'}},
             {'method': 'export', 'params': {'path': 'out/second.csv', 'format': 'csv'}}]
    workflow.write_text(json.dumps({'steps': steps}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['exported_paths'] == [str(tmp_path / 'out/first.npz'),
                                                            str(tmp_path / 'out/second.csv')]
    steps.append({'method': 'no_such_method'})
    workflow.write_text(json.dumps({'steps': steps[:2] + [steps[-1]]}))
    (tmp_path / 'out/first.npz').unlink()
    failed = run_cli('pipeline', str(workflow))
    assert failed.returncode == 1
    assert 'Step 3' in failed.stderr
    assert str(tmp_path / 'out/first.npz') in failed.stderr
    assert (tmp_path / 'out/first.npz').is_file()


def test_pipeline_cannot_overwrite_reference_spectrum(tmp_path):
    import numpy as np
    energies = np.linspace(280, 290, 11)
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 11)), energies=energies)
    reference = tmp_path / 'reference.csv'
    np.savetxt(reference, np.column_stack([energies, np.linspace(.2, 1., 11)]), delimiter=',')
    original = reference.read_bytes()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz', 'pre_normalized': True}},
        {'method': 'spectral', 'params': {'paths': ['reference.csv']}},
        {'method': 'export', 'params': {'path': 'reference.csv', 'format': 'csv', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'input' in result.stderr.lower()
    assert reference.read_bytes() == original


def test_pipeline_bad_paths_are_reported_with_step_and_no_traceback(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'build_stack', 'params': {'paths': ['a.tif', 4], 'energies': [280, 281]}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'Step 1 (build_stack)' in result.stderr
    assert 'paths' in result.stderr.lower()
    assert 'Traceback' not in result.stderr


def test_batch_saves_named_numeric_and_image_exports(tmp_path):
    import h5py
    import numpy as np
    data = np.random.default_rng(2).uniform(10, 20, (5, 4, 5))
    work = tmp_path / 'data'
    work.mkdir()
    np.savez(work / 'stack.npz', data=data, energies=np.arange(5) + 280.)
    (work / 'i0.txt').write_text(''.join(f'{280 + i} 100\n' for i in range(5)))
    settings = tmp_path / 'settings.txt'
    settings.write_text('VERSION: 2\nWORK_DIR: data\nFILENAME: stack.npz\nI0_FILE: i0.txt\n'
                        'RUN_PCA: 1\nN_SPCA: 2\nSAVE_HDF5: 1\nSAVE_PNG: 1\n'
                        'OUTPUT_DIR_NAME: nested/results\n')
    result = run_cli('batch', str(settings))
    assert result.returncode == 0, result.stderr
    folder = work / 'nested/results'
    paths = [folder / 'stack_analysis.hdf5', folder / 'stack_analysis.png']
    assert json.loads(result.stdout)['exported_paths'] == [str(path) for path in paths]
    assert paths[1].read_bytes().startswith(b'\x89PNG')
    with h5py.File(paths[0]) as archive:
        np.testing.assert_array_equal(archive['exchange/data'], data)
        assert 'results/pca/eigenvals' in archive
    blocked = run_cli('--batch', str(settings))
    assert blocked.returncode == 1
    assert 'Destination exists' in blocked.stderr
    assert str(paths[0]) in blocked.stderr


def test_pipeline_cannot_overwrite_a_later_input(tmp_path):
    import numpy as np
    first, future = tmp_path / 'first.npz', tmp_path / 'future.npz'
    for path in (first, future):
        np.savez(path, data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    original = future.read_bytes()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'first.npz'}},
        {'method': 'export', 'params': {'path': 'future.npz', 'format': 'npz', 'overwrite': True}},
        {'method': 'open', 'params': {'path': 'future.npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'input' in result.stderr.lower()
    assert future.read_bytes() == original


def test_pipeline_can_open_its_own_prior_export(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'first.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'first.npz'}},
        {'method': 'export', 'params': {'path': 'not-yet-created.npz', 'format': 'npz'}},
        {'method': 'open', 'params': {'path': 'not-yet-created.npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 0
    assert (tmp_path / 'not-yet-created.npz').is_file()
    assert json.loads(result.stdout)['source'] == str(tmp_path / 'not-yet-created.npz')


def test_pipeline_rejects_export_to_input_hardlink(tmp_path):
    import os
    import numpy as np
    source = tmp_path / 'input.npz'
    alias = tmp_path / 'alias.npz'
    np.savez(source, data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    os.link(source, alias)
    original = alias.read_bytes()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'alias.npz', 'format': 'npz', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert alias.read_bytes() == original


def test_pipeline_refuses_same_export_target_twice_without_overwrite(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'out/result.npz', 'format': 'npz'}},
        {'method': 'export', 'params': {'path': 'out/result.npz', 'format': 'npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    target = tmp_path / 'out/result.npz'
    assert result.returncode == 1
    assert 'Step 3' in result.stderr and str(target) in result.stderr
    with np.load(target, allow_pickle=False) as archive:
        np.testing.assert_array_equal(archive['data'], np.ones((3, 3, 3)))


def test_pipeline_explicitly_replaces_non_input_export(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    target = tmp_path / 'out/result.npz'
    target.parent.mkdir()
    target.write_bytes(b'older export')
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'out/result.npz', 'format': 'npz', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 0, result.stderr
    with np.load(target, allow_pickle=False) as archive:
        np.testing.assert_array_equal(archive['data'], np.ones((3, 3, 3)))
    assert json.loads(result.stdout)['exported_paths'] == [str(target)]


def test_pipeline_empty_path_reports_its_step(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [{'method': 'open', 'params': {'path': ''}}]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'Step 1 (open)' in result.stderr
    assert 'path must be' in result.stderr


def test_pipeline_rejects_missing_input_even_when_export_target_matches(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'first.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'first.npz'}},
        {'method': 'open', 'params': {'path': 'missing.npz'}},
        {'method': 'export', 'params': {'path': 'missing.npz', 'format': 'npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'Step 2' in result.stderr
    assert not (tmp_path / 'missing.npz').exists()


def test_pipeline_build_stack_paths_are_relative_to_workflow(tmp_path):
    from PIL import Image
    import numpy as np
    source = tmp_path / 'frame.tif'
    Image.fromarray(np.ones((3, 3), dtype=np.uint16)).save(source)
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'build_stack', 'params': {'paths': ['frame.tif'], 'energies': [280]}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['shape'] == [3, 3, 1]


def test_batch_runs_with_settings_in_separate_directory(tmp_path):
    import numpy as np
    source = tmp_path / 'input.npz'
    np.savez(source, data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    settings = tmp_path / 'settings.txt'
    settings.write_text('VERSION: 2\nFILENAME: input.npz\nSAVE_PNG: 1\n')
    original = settings.read_bytes()
    result = run_cli('batch', str(settings))
    assert result.returncode == 0, result.stderr
    assert settings.read_bytes() == original
    assert (tmp_path / 'MantisResults/input_analysis.png').is_file()


def test_batch_settings_cannot_be_overwritten_by_matching_png_output(tmp_path):
    import numpy as np
    source = tmp_path / 'settings.npz'
    np.savez(source, data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    settings = tmp_path / 'settings_analysis.png'
    settings.write_text('VERSION: 2\nFILENAME: settings.npz\nOUTPUT_DIR_NAME: .\nSAVE_PNG: 1\n')
    original = settings.read_bytes()
    result = run_cli('batch', str(settings))
    assert result.returncode == 1
    assert 'input' in result.stderr.lower()
    assert settings.read_bytes() == original


def test_pipeline_rejects_unsupported_output_suffix(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'out.dat', 'format': 'csv'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert not (tmp_path / 'out.dat').exists()


def test_pipeline_rejects_export_directory_target_without_temp_leak(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    target = tmp_path / 'directory.npz'
    target.mkdir()
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'export', 'params': {'path': 'directory.npz', 'format': 'npz', 'overwrite': True}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert target.is_dir()
    assert not list(tmp_path.glob('.mantis-export-*'))


def test_pipeline_rejects_non_numeric_i0_without_creating_export(tmp_path):
    import numpy as np
    np.savez(tmp_path / 'input.npz', data=np.ones((3, 3, 3)), energies=[280, 281, 282])
    (tmp_path / 'i0.txt').write_text('energy i0\n280 invalid\n')
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'open', 'params': {'path': 'input.npz'}},
        {'method': 'normalize', 'params': {'mode': 'file', 'path': 'i0.txt'}},
        {'method': 'export', 'params': {'path': 'out.npz', 'format': 'npz'}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'I0 file' in result.stderr
    assert not (tmp_path / 'out.npz').exists()


def test_pipeline_build_stack_empty_paths_rejected(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text(json.dumps({'steps': [
        {'method': 'build_stack', 'params': {'paths': [], 'energies': []}},
    ]}))
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'Step 1' in result.stderr
    assert 'paths' in result.stderr.lower()


def test_pipeline_rejects_boolean_protocol(tmp_path):
    workflow = tmp_path / 'workflow.json'
    workflow.write_text('{"protocol":true,"steps":[{"method":"open","params":{"path":"missing.npz"}}]}')
    result = run_cli('pipeline', str(workflow))
    assert result.returncode == 1
    assert 'protocol' in result.stderr.lower()


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
