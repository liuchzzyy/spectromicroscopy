"""Numerical acceptance tests for the headless advanced workflows."""
from types import SimpleNamespace
import importlib
import numpy as np
import pytest
from mantis_xray.analysis.analyze import analyze


class ProtocolSession:
    """Contract fixture until Session integration tests can use real file I/O."""
    def __init__(self, od, energies=None):
        od = np.asarray(od, dtype=float)
        self.stack = SimpleNamespace(od3d=od.copy(), absdata=np.exp(-od),
            od=od.reshape((-1, od.shape[2]), order='F'),
            ev=np.arange(od.shape[2], dtype=float)+280 if energies is None else np.asarray(energies),
            n_cols=od.shape[0], n_rows=od.shape[1], n_ev=od.shape[2])
        self.analysis = analyze(self.stack)
        self.results = {}
        self.history = []
    def require_normalized(self):
        return None
    def record(self, method, params):
        self.history.append({'method': method, 'params': params})
    def snapshot(self, images=None, spectra=None, metrics=None):
        return {'images': images or [], 'spectra': spectra or [], 'metrics': metrics or {}, 'history': self.history}


def run(session, method, **params):
    try:
        advanced = importlib.import_module('mantis_xray.core.advanced')
    except ModuleNotFoundError:
        pytest.fail('advanced workflow dispatch is not implemented')
    return advanced.dispatch_advanced(session, method, params)


def test_spectral_roi_exact_log_ratio_and_transactional_validation():
    s = ProtocolSession(np.array([[[0.1, 0.2, 0.8, 1.1]], [[-0.3, 0.0, 0.4, 0.6]]]))
    raw = s.stack.absdata.copy()
    result = run(s, 'spectral_roi', pre=[0, 2], post=[2, 4])
    expected = -np.log(raw[:, :, 2:].mean(2)/raw[:, :, :2].mean(2))
    np.testing.assert_allclose(s.results['spectral_roi']['map'], expected)
    assert result['images'][0]['width'] == 2
    np.testing.assert_array_equal(s.stack.absdata, raw)
    history = list(s.history)
    with pytest.raises(ValueError, match='range'):
        run(s, 'spectral_roi', pre=[0, 0], post=[2, 4])
    assert s.history == history


def test_spectral_original_svd_recovers_signed_mixture_and_manages_references(tmp_path):
    ev = np.linspace(280, 290, 11)
    refs = np.array([np.exp(-((ev-283)/2)**2), np.ones(11)])
    maps = np.array([[[2., 0.3]], [[-0.5, 0.1]]])
    s = ProtocolSession(maps @ refs, ev)
    path = tmp_path/'reference.csv'
    np.savetxt(path, np.column_stack([ev, refs[0]]), delimiter=',', header='energy,Reference')
    result = run(s, 'spectral', paths=[str(path)], flat=True)
    np.testing.assert_allclose(s.results['spectral']['maps'], maps, atol=1e-12)
    np.testing.assert_allclose(s.results['spectral']['residual'], 0, atol=1e-12)
    assert len(result['spectra']) == 2
    import hashlib
    source = s.history[-1]['params']['reference_sources'][0]
    assert source['path'] == str(path.resolve())
    assert source['sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert 'cubic' in source['remapping']
    run(s, 'spectral', move=[0, 1])
    np.testing.assert_allclose(s.results['spectral']['maps'], maps[:, :, ::-1], atol=1e-12)
    run(s, 'spectral', remove=1)
    assert s.analysis.n_target_spectra == 1
    run(s, 'spectral', remove=0)
    assert s.analysis.n_target_spectra == 0
    assert 'spectral' not in s.results


def test_rgb_is_display_only_and_has_interleaved_y_x_channels():
    s = ProtocolSession(np.ones((2, 2, 4)))
    maps = np.arange(12, dtype=float).reshape(2, 2, 3)-4
    s.results['spectral'] = {'maps': maps.copy()}
    result = run(s, 'rgb', channels=[2, 0, 1])
    rgb = result['rgb']
    expected = maps[:, :, [2, 0, 1]]
    expected = (expected-expected.min((0, 1)))/np.ptp(expected, axis=(0, 1))
    np.testing.assert_allclose(np.asarray(rgb['values']).reshape(2, 2, 3), expected.transpose(1, 0, 2))
    assert rgb['channels'] == 3
    np.testing.assert_array_equal(s.results['spectral']['maps'], maps)


def test_nnma_one_iteration_returns_updated_factors_and_true_cost_change():
    from mantis_xray.analysis.nnma import nnma
    s = ProtocolSession(np.arange(1, 25).reshape(2, 3, 4)/24)
    n = nnma(s.stack)
    n.setParameters(kNNMA=2, maxIters=1)
    np.random.seed(13)
    mu = np.random.rand(4, 2)
    t = np.random.rand(2, 6)
    od = s.stack.od.T
    initial_cost = 0.5*np.linalg.norm(od-mu@t)**2
    updated_t = t*(mu.T@od)/(mu.T@mu@t+1e-9)
    updated_mu = mu*(od@updated_t.T)/(mu@updated_t@updated_t.T+1e-9)
    np.random.seed(13)
    n.calcNNMA()
    np.testing.assert_allclose(n.muRecon, updated_mu)
    np.testing.assert_allclose(n.tRecon.reshape(2, 6, order='F'), updated_t)
    final_cost = 0.5*np.linalg.norm(od-updated_mu@updated_t)**2
    np.testing.assert_allclose(n.costFnArray[:, 0], [initial_cost, final_cost])
    assert n.costFnArray[1, 1] == pytest.approx(final_cost-initial_cost)


@pytest.mark.parametrize('initialization', ['random', 'clusters', 'standards'])
def test_nnma_initializations_reconstruct_positive_rank_two_and_preserve_seed(tmp_path, initialization):
    ev = np.linspace(280, 290, 21)
    refs = np.array([0.1+np.exp(-((ev-282)/2)**2), 0.1+np.exp(-((ev-287)/2)**2)])
    maps = np.array([[[1., 0.1], [0.2, 2.]], [[3., 0.5], [0.1, 1.]]])
    s = ProtocolSession(maps @ refs, ev)
    paths = []
    for i, r in enumerate(refs):
        path = tmp_path/f'ref{i}.csv'
        np.savetxt(path, np.column_stack([ev, r]), delimiter=',')
        paths.append(str(path))
    s.analysis.clusters_calculated = 1
    s.analysis.clusterspectra = refs.copy()
    state = np.random.get_state()
    result = run(s, 'nnma', components=2, iterations=200, seed=12, initialization=initialization,
                 paths=paths, lambda_sparse=0.0001, lambda_cluster=0.001 if initialization == 'clusters' else 0)
    data = s.results['nnma']
    assert np.linalg.norm(data['maps'] @ data['spectra']-s.stack.od3d)/np.linalg.norm(s.stack.od3d) < 0.06
    assert np.min(data['maps']) >= 0 and np.min(data['spectra']) >= 0
    assert result['spectra'] and result['images']
    np.testing.assert_array_equal(np.random.get_state()[1], state[1])
    assert s.history[-1]['params']['seed'] == 12
    before = s.stack.od.copy()
    s.stack.od[0, 0] = -0.1
    with pytest.raises(ValueError, match='negative'):
        run(s, 'nnma', components=2)
    assert s.stack.od[0, 0] == -0.1
    s.stack.od[:] = before
    with pytest.raises(ValueError, match='smooth'):
        run(s, 'nnma', lambda_smooth=0.1)


def test_peak_detection_preserves_original_reference_labels_and_source():
    ev = np.arange(280., 291.)
    y = np.array([0, 0, 1, 0, 0, 2, 0, 0, 1, 0, 0.])
    s = ProtocolSession(y[None, None, :], ev)
    result = run(s, 'peaks', threshold=0.5)
    np.testing.assert_array_equal(result['peaks']['maxima'], [[282, 1], [285, 2], [288, 1]])
    table = result['peak_reference']
    assert [(r['energy'], r['label']) for r in table] == [(285., 'aromatic'), (286.5, 'phenolic'), (288.5, 'carboxyl'), (289.5, 'alkyl'), (290.5, 'carbonyl')]
    assert all(r['citation'] is None and 'peak_id.py' in r['source'] for r in table)
    with pytest.raises(ValueError):
        run(s, 'peaks', threshold=0)


def test_key_energies_uses_original_pca_extrema():
    s = ProtocolSession(np.ones((2, 2, 7)))
    with pytest.raises(ValueError, match='PCA'):
        run(s, 'key_energies', threshold=0.1)
    s.analysis.pca_calculated = 1
    s.analysis.numsigpca = 2
    s.analysis.eigenvecs = np.array([[0, 0], [1, 0], [0, 1], [-1, 0], [0, -1], [1, 0], [0, 1.]])
    expected = s.analysis.calc_key_engs(0.1)
    result = run(s, 'key_energies', threshold=0.1)
    np.testing.assert_array_equal(result['key_energies'], expected)
    np.testing.assert_array_equal(expected, [281, 282, 283, 284, 285])


def test_original_two_step_model_includes_both_steps():
    from mantis_xray.analysis.analyze import model, stepfunc
    ev = np.linspace(280, 300, 101)
    first, second = [284, 0.7, 1.2], [294, 0.3, 2.]
    expected = 0.2 + np.array([stepfunc(first, e)+stepfunc(second, e) for e in ev])
    np.testing.assert_allclose(model([0.2]+first+second, 2, 0, ev), expected)


def test_peak_fit_recovers_two_steps_gaussian_and_baseline():
    from mantis_xray.analysis.analyze import model
    ev = np.linspace(280, 300, 201)
    truth = [0.2, 284, 0.7, 1.2, 294, 0.3, 2., 0.6, 288, 0.7]
    y = model(truth, 2, 1, ev)
    s = ProtocolSession(y[None, None, :], ev)
    result = run(s, 'fit_peaks', steps=2, peaks=1, baseline=0.15,
                 step_params=[283.8, 0.6, 1., 293.8, 0.25, 1.8],
                 peak_amplitudes=[0.5], peak_centers=[287.8], peak_widths=[0.8])
    fit = s.results['fit_peaks']
    np.testing.assert_allclose(fit['fit'], y, atol=1e-6)
    np.testing.assert_allclose(fit['parameters'], truth, atol=1e-4)
    assert result['metrics']['uncertainty'] == 'Not estimated'
    assert len(result['spectra']) == 7


@pytest.mark.parametrize('algorithm', ['sirt', 'tv', 'fbp'])
def test_tomography_reconstructs_real_phantom_and_retains_angles(algorithm):
    from skimage.transform import radon
    n = 16
    x, y = np.ogrid[:n, :n]
    phantom = (((x-8)**2+(y-8)**2) < 16).astype(float)
    theta = np.linspace(-90, 90, 24, endpoint=False)
    projections = radon(phantom, theta=theta, circle=True)
    s = ProtocolSession(np.zeros((n, 2, 1)), [285.])
    s.stack.od4d = np.repeat(projections[:, None, None, :], 2, axis=1)
    s.stack.theta = theta.copy()
    result = run(s, 'tomography', energy_index=0, algorithm=algorithm, iterations=5, beta=0.01)
    volume = s.results['tomography']['volume']
    assert volume.shape == (n, 2, n)
    assert np.isfinite(volume).all()
    assert np.corrcoef(volume[:, 0, :].ravel(), phantom.ravel())[0, 1] > 0.6
    np.testing.assert_array_equal(s.stack.theta, theta)
    assert result['images']
    if algorithm == 'fbp':
        assert 'alternative' in result['metrics']['algorithm'].lower()
    viewed = run(s, 'tomography', slice_index=0)
    assert viewed['metrics']['slice_index'] == '0'


def test_dose_matches_original_henke_and_records_explicit_units():
    from mantis_xray.analysis.henke import henke
    ev = np.linspace(280, 310, 16)
    s = ProtocolSession(np.linspace(0.2, 1., 16)[None, None, :], ev)
    s.stack.i0data = np.full(16, 10000.)
    s.stack.evi0 = ev.copy()
    params = dict(composition='water', detector_efficiency=0.3,
                  pixel_size_x=0.05, pixel_size_y=0.08, dwell_time=2.)
    expected_stack = SimpleNamespace(ev=ev, x_pxsize=0.05, y_pxsize=0.08, data_dwell=2.)
    expected = henke().dose_calc(expected_stack, 'water', s.stack.od3d[0, 0], s.stack.i0data, 0.3)
    result = run(s, 'dose', **params)
    assert result['dose_Gy'] == pytest.approx(expected)
    assert expected > 0
    assert s.results['dose']['dose_Gy'] == pytest.approx(expected)
    assert result['metrics']['dose_units'] == 'Gy (J/kg)'
    assert s.history[-1]['params']['dwell_time_unit'] == 'ms'
    assert s.history[-1]['params']['i0_unit'] == 'detected counts/s'
    assert not hasattr(s.stack, 'x_pxsize')
    assert 'uncertainty' in result['metrics']


def test_pca_target_fit_rejects_rank_loss_without_committing(tmp_path):
    ev = np.arange(280., 285.)
    refs = np.array([[1, 0, 1, 0, 1.], [0, 1, 0, 1, 0.]])
    s = ProtocolSession(np.ones((2, 2, 5)), ev)
    paths = []
    for i, ref in enumerate(refs):
        path = tmp_path/f'target{i}.csv'
        np.savetxt(path, np.column_stack([ev, ref]), delimiter=',')
        paths.append(str(path))
    s.analysis.pca_calculated = 1
    s.analysis.numsigpca = 1
    s.analysis.eigenvecs = np.eye(5)
    analysis = s.analysis
    with pytest.raises(ValueError, match='independent.*PCA|PCA.*independent'):
        run(s, 'spectral', paths=paths, use_pca=True)
    assert s.analysis is analysis
    assert s.results == {} and s.history == []


@pytest.mark.parametrize('method,params', [
    ('spectral', {'flat': 'false'}),
    ('spectral', {'flat': True, 'use_pca': 'false'}),
    ('peaks', {'threshold': True}),
    ('spectral', {'flat': True, 'typo': 1}),
    ('spectral', {'paths': 'not-a-list.csv'}),
    ('rgb', {'channels': 1}),
    ('spectral', {'move': 1}),
    ('fit_peaks', {'baseline': [1, 2]}),
    ('peaks', {'threshold': 0.1, 'unused': float('nan')}),
])
def test_invalid_operation_parameters_fail_transactionally(method, params):
    s = ProtocolSession(np.ones((2, 2, 21)))
    s.results['spectral'] = {'maps': np.ones((2, 2, 3))}
    analysis = s.analysis
    with pytest.raises(ValueError):
        run(s, method, **params)
    assert s.history == [] and s.analysis is analysis
    assert list(s.results) == ['spectral']


@pytest.mark.parametrize('source', ['pixel', 'mean', 'roi', 'invalid'])
def test_explicit_spectrum_source_is_not_overridden_by_roi(source):
    od = np.array([[[0, 1, 0, 0, 0.]], [[0, 0, 0, 3, 0.]]])
    s = ProtocolSession(od)
    s.roi_mask = np.array([[False], [True]])
    s.selected_x, s.selected_y = 0, 0
    if source == 'invalid':
        with pytest.raises(ValueError, match='source'):
            run(s, 'peaks', source=source, threshold=0.1)
        return
    result = run(s, 'peaks', source=source, threshold=0.1)
    expected = {'pixel': od[0, 0], 'mean': od.mean((0, 1)), 'roi': od[1, 0]}[source]
    np.testing.assert_array_equal(result['spectra'][0]['y'], expected)


def test_nnma_cluster_gradient_split_remains_nonnegative():
    from mantis_xray.analysis.nnma import nnma
    n = nnma(ProtocolSession(np.ones((1, 1, 4))).stack)
    n.OD = np.ones((4, 1))
    n.lambdaClusterSim = 10.
    n.muCluster = np.full((4, 1), 4.)
    mu = np.full((4, 1), 0.1)
    t = np.ones((1, 1))
    expected = mu*(n.OD@t.T + 2*n.lambdaClusterSim*n.muCluster)/(mu@t@t.T + 2*n.lambdaClusterSim*mu + 1e-9)
    np.testing.assert_allclose(n.muUpdate(mu, t), expected)
    assert np.all(expected >= 0)


@pytest.mark.parametrize('algorithm', ['sirt', 'tv'])
def test_tomography_matches_legacy_slice_solver_on_asymmetric_data(algorithm):
    from mantis_xray.analysis.tomo_reconstruction import calc_cs, calc_sirt
    n = 9
    theta = np.array([-65., -30., 0., 25., 60.])
    tilt = np.random.default_rng(12).uniform(0.1, 4, (n, 2, 5))
    s = ProtocolSession(np.zeros((n, 2, 1)), [285.])
    s.stack.od4d = tilt[:, :, None, :].copy()
    s.stack.theta = theta.copy()
    run(s, 'tomography', algorithm=algorithm, iterations=3, beta=0.02)
    for y in range(2):
        if algorithm == 'sirt':
            expected = calc_sirt(tilt[:, y], theta.copy(), tilt.min(), tilt.max(), 0, 3, n)
        else:
            expected = calc_cs(tilt[:, y].T, np.deg2rad(theta), tilt.min(), tilt.max(), n, 0.02,
                               np.zeros((n, n)), 0, 3)
        np.testing.assert_allclose(s.results['tomography']['volume'][:, y, :], expected)
    np.testing.assert_array_equal(s.stack.od4d[:, :, 0], tilt)
    assert s.results['tomography']['normalization'].startswith('(projection -')
    saved = s.results['tomography']
    history = list(s.history)
    with pytest.raises(ValueError, match='slice_index'):
        run(s, 'tomography', slice_index=n)
    assert s.results['tomography'] is saved and s.history == history


@pytest.mark.parametrize('bad', [
    {}, {'detector_efficiency': 0}, {'detector_efficiency': 1.01},
    {'pixel_size_x': -1}, {'dwell_time': 0}, {'dwell_time': [1, 2]},
    {'i0': [0]}, {'composition': ''}, {'composition': 'not a compound'},
])
def test_dose_rejects_incomplete_or_unphysical_inputs(bad):
    s = ProtocolSession(np.ones((1, 1, 5)))
    params = dict(composition='water', detector_efficiency=0.3, pixel_size_x=0.1,
                  pixel_size_y=0.1, dwell_time=1., i0=100.)
    params.update(bad)
    if not bad:
        del params['pixel_size_x']
    with pytest.raises(ValueError):
        run(s, 'dose', **params)
    assert s.results == {} and s.history == []


def test_native_session_exports_full_advanced_arrays(tmp_path):
    from mantis_xray.core.session import Session
    import h5py
    ev = np.linspace(280, 300, 21)
    values = np.linspace(0.1, 1, 2*3*21).reshape(2, 3, 21)
    path = tmp_path/'stack.npz'
    np.savez(path, data=values, energies=ev)
    s = Session()
    s.dispatch('open', {'path': str(path), 'pre_normalized': True})
    s.dispatch('nnma', {'components': 2, 'iterations': 3})
    s.dispatch('spectral', {'flat': True})
    dose = s.dispatch('dose', dict(composition='water', detector_efficiency=0.3,
                                  pixel_size_x=0.05, pixel_size_y=0.05,
                                  dwell_time=2., i0=10000.))
    assert dose['dose_Gy'] > 0
    for format in ('hdf5', 'npz'):
        target = tmp_path/f'advanced.{format}'
        s.dispatch('export', {'path': str(target), 'format': format})
        if format == 'hdf5':
            with h5py.File(target) as archive:
                np.testing.assert_allclose(archive['results/nnma/maps'], s.results['nnma']['maps'])
                assert archive['results/dose/dose_Gy'][()] == dose['dose_Gy']
        else:
            with np.load(target, allow_pickle=False) as archive:
                np.testing.assert_allclose(archive['results/spectral/maps'], s.results['spectral']['maps'])
                assert archive['results/dose/dose_Gy'] == dose['dose_Gy']


def test_peak_fit_does_not_claim_success_when_optimizer_exhausted(monkeypatch):
    module = importlib.import_module('mantis_xray.analysis.analyze')
    # Inject only the optimizer termination status; preserve a finite candidate.
    monkeypatch.setattr(module, 'leastsqbound', lambda func, x, bounds, **kw: (np.asarray(x), 5))
    s = ProtocolSession(np.ones((1, 1, 21)))
    with pytest.raises(ValueError, match='converg'):
        run(s, 'fit_peaks', steps=0, peaks=1)
    assert s.results == {} and s.history == []
