"""Validated, headless adapters for MANTiS's original scientific algorithms.

All computations are staged before committing analysis/results/history. Scientific
arrays retain signed values; display scaling (RGB only) is explicitly separate.
"""
import copy
import numpy as np

ADVANCED_METHODS = ('spectral_roi', 'spectral')


def _finite(value, name):
    value = np.asarray(value, dtype=float)
    if not np.all(np.isfinite(value)):
        raise ValueError(f'{name} must contain only finite values')
    return value


def _image(title, array):
    a = _finite(array, title)
    if a.ndim != 2:
        raise ValueError('Image must have two dimensions')
    nx, ny = a.shape
    small = a[::max(1, int(np.ceil(nx/256))), ::max(1, int(np.ceil(ny/256)))]
    return dict(title=title, width=small.shape[0], height=small.shape[1],
                full_width=nx, full_height=ny, values=small.T.ravel().tolist())


def _spectrum(name, x, y):
    return dict(name=name, x=_finite(x, name).tolist(), y=_finite(y, name).tolist())


def _range(value, size):
    if (not isinstance(value, (list, tuple)) or len(value) != 2 or
            any(isinstance(i, bool) or not isinstance(i, (int, np.integer)) for i in value) or
            not 0 <= value[0] < value[1] <= size):
        raise ValueError('Energy range must be [first, last_exclusive] within the stack')
    return slice(*value)


def _spectral_roi(s, p):
    a = _finite(s.stack.absdata, 'Intensity')
    pre = a[:, :, _range(p.get('pre'), a.shape[2])].mean(axis=2)
    post = a[:, :, _range(p.get('post'), a.shape[2])].mean(axis=2)
    if np.any(pre <= 0) or np.any(post <= 0):
        raise ValueError('Spectral ROI requires positive mean pre/post intensity')
    result = -np.log(post/pre)
    image = _image('Spectral ROI optical density', result)
    s.results['spectral_roi'] = {'map': result}
    s.record('spectral_roi', p)
    return s.snapshot(images=[image])


def _analysis_copy(s):
    # Algorithms may alter analysis attributes, but must never clone/mutate stack.
    return copy.deepcopy(s.analysis, {id(s.stack): s.stack})


def _references(a, paths):
    from ..file_plugins.file_stk import read_ascii
    from pathlib import Path
    refs, names = [], []
    for path in paths:
        loaded = read_ascii(a, path)
        if loaded is None:
            raise ValueError(f'No spectra in {path}')
        ev, spectra, labels = loaded
        ev = _finite(ev, 'Reference energies')
        if len(ev) < 4 or np.any(np.diff(ev) <= 0):
            raise ValueError('Original cubic remapping requires at least four unique increasing energies')
        for i, spectrum in enumerate(spectra):
            _finite(spectrum, 'Reference spectrum')
            refs.append(_finite(a.remap_spectrum(ev, spectrum)[0], 'Remapped reference'))
            names.append(labels[i].strip() if i < len(labels) else f'{Path(path).stem} {i+1}')
    return refs, names


def _index(value, size, name='index'):
    if isinstance(value, bool) or not isinstance(value, (int, np.integer)) or not 0 <= value < size:
        raise ValueError(f'{name} must be an integer in [0, {size})')
    return int(value)


def _spectral(s, p):
    s.require_normalized()
    a = _analysis_copy(s)
    refs = list(np.atleast_2d(a.target_spectra)) if a.n_target_spectra else []
    names = list(a.tspec_names)
    added, labels = _references(a, p.get('paths', []))
    refs.extend(added)
    names.extend(labels)
    if p.get('add_clusters', False):
        if not a.clusters_calculated:
            raise ValueError('Cluster analysis is required')
        refs.extend(a.clusterspectra.copy())
        names.extend(f'Cluster {i+1}' for i in range(len(a.clusterspectra)))
    if p.get('flat', False):
        refs.append(np.ones(s.stack.n_ev))
        names.append('Flat')
    if 'remove' in p:
        index = _index(p['remove'], len(refs), 'remove')
        del refs[index], names[index]
    if 'move' in p:
        old, new = p['move']
        old, new = _index(old, len(refs)), _index(new, len(refs))
        refs[old], refs[new] = refs[new], refs[old]
        names[old], names[new] = names[new], names[old]
    if not refs:
        if 'remove' not in p:
            raise ValueError('Load at least one target spectrum')
        a.target_spectra, a.tspec_names = [], []
        a.n_target_spectra = a.tspectrum_loaded = 0
        s.analysis = a
        s.results.pop('spectral', None)
        s.results.pop('rgb', None)
        s.record('spectral', p)
        return s.snapshot()
    targets = _finite(refs, 'Target spectra')
    if np.linalg.matrix_rank(targets) < len(targets):
        raise ValueError('Target spectra must be linearly independent for original SVD inversion')
    use_pca = bool(p.get('use_pca', False))
    if use_pca and not a.pca_calculated:
        raise ValueError('PCA is required for fitted target maps')
    if use_pca:
        coefficients = _finite(targets @ a.eigenvecs[:, :a.numsigpca], 'PCA target coefficients')
        if np.linalg.matrix_rank(coefficients) < len(targets):
            raise ValueError('Target spectra must remain linearly independent in the retained PCA subspace')
    a.target_spectra, a.tspec_names = targets, names
    a.n_target_spectra, a.tspectrum_loaded = len(refs), 1
    a.calc_svd_maps()
    spectra = [_spectrum(name, s.stack.ev, row) for name, row in zip(names, targets)]
    maps = a.target_svd_maps
    basis = targets
    if use_pca:
        a.fit_target_spectra()
        maps, basis = a.target_pcafit_maps, a.target_pcafit_spectra
        spectra.extend(_spectrum(name+' PCA fit', s.stack.ev, row) for name, row in zip(names, basis))
        spectra.extend(_spectrum(name+' residual', s.stack.ev, row) for name, row in zip(names, targets-basis))
    residual = _finite(s.stack.od3d - maps @ basis, 'Residual')
    images = [_image(name, maps[:, :, i]) for i, name in enumerate(names)]
    images.append(_image('Fit residual RMS', np.sqrt(np.mean(residual**2, axis=2))))
    s.analysis = a
    s.results['spectral'] = dict(maps=maps.copy(), references=targets.copy(), names=names,
                                 fitted_references=basis.copy(), residual=residual, use_pca=use_pca)
    s.results.pop('rgb', None)
    s.record('spectral', p)
    return s.snapshot(images=images, spectra=spectra, metrics={'algorithm': 'Original MANTiS PCA target fit' if use_pca else 'Original MANTiS SVD'})


def _rgb(s, p):
    if 'spectral' not in s.results:
        raise ValueError('Spectral maps are required')
    maps = _finite(s.results['spectral']['maps'], 'Target maps')
    channels = p.get('channels', [0, 1, 2])
    if len(channels) != 3:
        raise ValueError('RGB requires three channel indices')
    channels = [_index(i, maps.shape[2], 'channel') for i in channels]
    selected = maps[:, :, channels]
    low, span = selected.min(axis=(0, 1)), np.ptp(selected, axis=(0, 1))
    rgb = np.divide(selected-low, span, out=np.zeros_like(selected), where=span > 0)
    nx, ny = rgb.shape[:2]
    small = rgb[::max(1, int(np.ceil(nx/256))), ::max(1, int(np.ceil(ny/256)))]
    record = dict(title='RGB composite', width=small.shape[0], height=small.shape[1],
                  full_width=nx, full_height=ny, channels=3,
                  values=small.transpose(1, 0, 2).ravel().tolist())
    s.results['rgb'] = dict(display=rgb, channels=channels, minima=low, spans=span)
    s.record('rgb', p)
    result = s.snapshot(images=[_image(f'RGB channel {i+1}', selected[:, :, i]) for i in range(3)],
                        metrics={'rgb_scaling': 'Per-channel min/max to [0,1], display only; constant channels are zero'})
    result['rgb'] = record
    return result


ADVANCED_METHODS += ('rgb',)


def _number(value, name, minimum=0, strict=False):
    value = float(value)
    if not np.isfinite(value) or value < minimum or (strict and value == minimum):
        raise ValueError(f'{name} must be finite and {">" if strict else ">="} {minimum}')
    return value


def _nnma(s, p):
    from ..analysis.nnma import nnma
    import contextlib
    import sys
    s.require_normalized()
    od = _finite(s.stack.od, 'Optical density')
    if np.any(od < 0):
        raise ValueError('NNMA cannot accept negative optical density; no clipping is performed')
    if not np.any(od > 0):
        raise ValueError('NNMA requires nonzero optical density')
    smooth = _number(p.get('lambda_smooth', 0), 'lambda_smooth')
    if smooth:
        raise ValueError('Original NNMA smoothness cost and gradient are unimplemented; nonzero lambda_smooth is unsupported')
    k = _index(p.get('components', 2), min(od.shape)+1, 'components')
    iterations = _index(p.get('iterations', 100), 100001, 'iterations')
    if k < 1 or iterations < 1:
        raise ValueError('components and iterations must be positive')
    seed = _index(p.get('seed', 0), 2**32, 'seed')
    initialization = p.get('initialization', 'random')
    kinds = {'random': 'Random', 'clusters': 'Cluster', 'standards': 'Standards'}
    if initialization not in kinds:
        raise ValueError('initialization must be random, clusters, or standards')
    sparse = _number(p.get('lambda_sparse', 0), 'lambda_sparse')
    cluster = _number(p.get('lambda_cluster', 0), 'lambda_cluster')
    if cluster and initialization != 'clusters':
        raise ValueError('Cluster similarity regularization requires clusters initialization')
    n = nnma(s.stack)
    if initialization != 'random':
        if initialization == 'clusters':
            if not s.analysis.clusters_calculated:
                raise ValueError('Cluster analysis is required')
            refs = _finite(s.analysis.clusterspectra, 'Cluster spectra')
            n.setClusterSpectra(refs)
        else:
            refs, _ = _references(s.analysis, p.get('paths', []))
            refs = _finite(refs, 'Standard spectra')
            n.setStandardsSpectra(refs.T)
        if refs.shape != (k, s.stack.n_ev) or np.any(refs < 0) or np.any(refs.sum(axis=1) <= 0):
            raise ValueError('Initial spectra must be nonnegative, nonzero and match components and energies')
    n.setParameters(kNNMA=k, maxIters=iterations, initMatrices=kinds[initialization],
                    lambdaSparse=sparse, lambdaClusterSim=cluster, lambdaSmooth=0)
    state = np.random.get_state()
    try:
        np.random.seed(seed)
        with contextlib.redirect_stdout(sys.stderr):
            n.calcNNMA(initmatrices=kinds[initialization])
    finally:
        np.random.set_state(state)
    maps, spectra = _finite(n.tRecon.transpose(1, 2, 0), 'NNMA maps'), _finite(n.muRecon.T, 'NNMA spectra')
    costs = _finite(n.costFnArray[:n.maxIters+1], 'NNMA convergence')
    images = [_image(f'NNMA {i+1}', maps[:, :, i]) for i in range(k)]
    curves = [_spectrum(f'NNMA {i+1}', s.stack.ev, spectra[i]) for i in range(k)]
    curves.append(_spectrum('NNMA total cost', np.arange(len(costs)), costs[:, 0]))
    s.results['nnma'] = dict(maps=maps, spectra=spectra, convergence=costs,
                              residual=s.stack.od3d-maps@spectra, initial_spectra=n.muinit.T)
    s.record('nnma', dict(p, seed=seed, components=k, iterations=iterations, initialization=initialization,
                          lambda_sparse=sparse, lambda_cluster=cluster, lambda_smooth=0))
    return s.snapshot(images=images, spectra=curves, metrics={'algorithm': 'Original MANTiS multiplicative NNMA; corrected iteration bookkeeping and nonnegative cluster-gradient split',
                        'iterations_completed': str(n.maxIters), 'smoothness': 'Original implementation has no smoothness penalty'})


ADVANCED_METHODS += ('nnma',)


def _selected_spectrum(s, p):
    s.require_normalized()
    if p.get('path'):
        refs, names = _references(s.analysis, [p['path']])
        index = _index(p.get('spectrum_index', 0), len(refs), 'spectrum_index')
        return names[index], refs[index]
    if 'cluster_index' in p:
        if not s.analysis.clusters_calculated:
            raise ValueError('Cluster analysis is required')
        index = _index(p['cluster_index'], len(s.analysis.clusterspectra), 'cluster_index')
        return f'Cluster {index+1}', _finite(s.analysis.clusterspectra[index], 'Cluster spectrum')
    source = p.get('source')
    if source is not None and source not in ('pixel', 'mean', 'roi'):
        raise ValueError('source must be pixel, mean, or roi')
    if source == 'pixel':
        return 'Pixel', _finite(s.stack.od3d[s.selected_x, s.selected_y], 'Pixel spectrum')
    mask = getattr(s, 'roi_mask', None)
    if source == 'roi' and mask is None:
        raise ValueError('ROI source requires a selected ROI')
    if mask is not None and source != 'mean':
        if not np.any(mask):
            raise ValueError('ROI is empty')
        return 'ROI mean', _finite(s.stack.od3d[mask].mean(axis=0), 'ROI spectrum')
    return 'Mean OD', _finite(s.stack.od3d.mean(axis=(0, 1)), 'Mean spectrum')


def _peaks(s, p):
    from .peak_reference import PEAK_REFERENCE
    name, y = _selected_spectrum(s, p)
    threshold = _number(p.get('threshold', 0.03), 'threshold', strict=True)
    maxima, minima = s.analysis.find_peaks(y, threshold, x=s.stack.ev)
    data = {'maxima': np.asarray(maxima).reshape(-1, 2).tolist(),
            'minima': np.asarray(minima).reshape(-1, 2).tolist()}
    s.results['peaks'] = copy.deepcopy(data)
    s.record('peaks', dict(p, threshold=threshold))
    result = s.snapshot(spectra=[_spectrum(name, s.stack.ev, y)],
                        metrics={'peak_reference_note': 'Original GUI labels; no citations supplied; comparison only, not chemical attribution'})
    result.update(peaks=data, peak_reference=copy.deepcopy(list(PEAK_REFERENCE)))
    return result


ADVANCED_METHODS += ('peaks',)


def _key_energies(s, p):
    s.require_normalized()
    if not s.analysis.pca_calculated:
        raise ValueError('PCA is required for key energies')
    threshold = _number(p.get('threshold', 0.03), 'threshold', strict=True)
    energies = _finite(s.analysis.calc_key_engs(threshold), 'Key energies')
    s.results['key_energies'] = {'energies': energies}
    s.record('key_energies', dict(p, threshold=threshold))
    result = s.snapshot(spectra=[_spectrum(f'PCA {i+1}', s.stack.ev, s.analysis.eigenvecs[:, i]) for i in range(s.analysis.numsigpca)],
                        metrics={'key_energies_eV': ', '.join(str(e) for e in energies)})
    result['key_energies'] = energies.tolist()
    return result


ADVANCED_METHODS += ('key_energies',)


def _fit_peaks(s, p):
    from ..analysis.analyze import Cfitparams
    name, y = _selected_spectrum(s, p)
    steps, peaks = _index(p.get('steps', 1), 3, 'steps'), _index(p.get('peaks', 1), 13, 'peaks')
    if 1+3*(steps+peaks) > len(y):
        raise ValueError('Not enough energy samples for requested fit parameters')
    a = _analysis_copy(s)
    a.xrayfitspectra = y[None, :].copy()
    a.xfitpars = [Cfitparams()]
    a.init_fit_params(0)
    fp = a.xfitpars[0]
    if 'baseline' in p:
        fp.base = float(_finite(p['baseline'], 'baseline'))
    for key, attr, count in [('step_params', 'stepfitparams', 3*steps),
                             ('peak_amplitudes', 'gauss_fp_a', peaks),
                             ('peak_centers', 'gauss_fp_m', peaks),
                             ('peak_widths', 'gauss_fp_s', peaks)]:
        if key in p:
            values = _finite(p[key], key).ravel()
            if values.size != count or np.any(values < 0):
                raise ValueError(f'{key} must contain {count} nonnegative values')
            getattr(fp, attr)[:count] = values
    if np.any(np.asarray(fp.stepfitparams)[:3*steps][2::3] <= 0) or np.any(fp.gauss_fp_s[:peaks] <= 0):
        raise ValueError('Step and peak widths must be positive')
    fitted, separate = a.fit_spectrum(0, steps, peaks)
    fitted = _finite(fitted, 'Fitted spectrum')
    parameters = [fp.base] + list(fp.stepfitparams[:3*steps])
    for i in range(peaks):
        parameters.extend([fp.gauss_fp_a[i], fp.gauss_fp_m[i], fp.gauss_fp_s[i]])
    parameters = _finite(parameters, 'Fit parameters')
    curves = [_spectrum(name, s.stack.ev, y), _spectrum('Fit', s.stack.ev, fitted),
              _spectrum('Residual', s.stack.ev, y-fitted)]
    labels = ['Baseline'] + [f'Step {i+1}' for i in range(steps)] + [f'Gaussian {i+1}' for i in range(peaks)]
    curves.extend(_spectrum(label, s.stack.ev, row) for label, row in zip(labels, separate))
    data = dict(fit=fitted, residual=y-fitted, parameters=parameters, components=np.asarray(separate),
                energies=np.array(s.stack.ev), observed=y, steps=steps, peaks=peaks)
    s.results['fit_peaks'] = data
    s.record('fit_peaks', dict(p, steps=steps, peaks=peaks))
    result = s.snapshot(spectra=curves, metrics={'algorithm': 'Original bounded least squares step/Gaussian fit; multi-step sum corrected',
                         'uncertainty': 'Not estimated', 'residual_rms': str(float(np.sqrt(np.mean((y-fitted)**2))))})
    result['fit_parameters'] = parameters.tolist()
    return result


ADVANCED_METHODS += ('fit_peaks',)


def _tomography(s, p):
    """Run the legacy slice solvers, without their GUI angle mutation/pool.

    The legacy SIRT/TV workflows normalize the full tilt series by its min/max.
    Their output is consequently in reconstruction units, not quantitative OD.
    FBP is an explicitly labelled alternative operating on unscaled projections.
    Volume axes are [reconstruction row, acquisition y, reconstruction column].
    """
    s.require_normalized()
    view_only = set(p) == {'slice_index'}
    if view_only:
        if 'tomography' not in s.results:
            raise ValueError('A tomography reconstruction is required before selecting a slice')
        data = s.results['tomography']
    else:
        projections = _finite(getattr(s.stack, 'od4d', []), 'Tomography projections')
        theta = _finite(getattr(s.stack, 'theta', []), 'theta')
        if projections.ndim != 4 or min(projections.shape) < 1 or projections.shape[0] < 2:
            raise ValueError('Tomography requires 4D optical density [x,y,energy,theta]')
        if theta.ndim != 1 or len(theta) != projections.shape[3] or len(np.unique(theta)) < 2:
            raise ValueError('Explicit theta must match projections and contain at least two distinct angles in degrees')
        energy = _index(p.get('energy_index', 0), projections.shape[2], 'energy_index')
        algorithm = p.get('algorithm', 'sirt')
        if algorithm not in ('sirt', 'tv', 'fbp'):
            raise ValueError('algorithm must be sirt, tv, or fbp')
        iterations = _index(p.get('iterations', 10), 100001, 'iterations')
        if iterations < 1:
            raise ValueError('iterations must be positive')
        beta = _number(p.get('beta', 0.5), 'beta', strict=algorithm == 'tv')
        nonnegative = p.get('nonnegative', False)
        if not isinstance(nonnegative, bool):
            raise ValueError('nonnegative must be a boolean')
        tilt = projections[:, :, energy, :]
        low, high = float(tilt.min()), float(tilt.max())
        if algorithm != 'fbp' and high == low:
            raise ValueError('Original SIRT/TV normalization requires nonconstant projections')
        # Validate view requests before performing/committing expensive work.
        index = _index(p.get('slice_index', tilt.shape[0]//2), tilt.shape[0], 'slice_index')
        slices = []
        from ..analysis.tomo_reconstruction import calc_cs, calc_sirt
        from skimage.transform import iradon
        for y in range(tilt.shape[1]):
            sino = tilt[:, y, :]
            if algorithm == 'fbp':
                rec = iradon(sino, theta=theta, output_size=tilt.shape[0],
                             filter_name='ramp', circle=True)
                if nonnegative:
                    raise ValueError('FBP does not implement a nonnegative constraint')
            elif np.all(sino == low):
                rec = np.zeros((tilt.shape[0], tilt.shape[0]))
            elif algorithm == 'sirt':
                rec = calc_sirt(sino, theta.copy(), low, high, int(nonnegative),
                                iterations, tilt.shape[0])
            else:
                rec = calc_cs(sino.T, np.deg2rad(theta), low, high, tilt.shape[0],
                              beta, np.zeros((tilt.shape[0], tilt.shape[0])),
                              int(nonnegative), iterations)
            slices.append(_finite(rec, 'Tomography reconstruction'))
        volume = np.stack(slices, axis=1)
        labels = {'sirt': 'Original MANTiS SIRT (sum-normalized filtered backprojection iteration)',
                  'tv': 'Original MANTiS TomoCS generalized forward-backward TV',
                  'fbp': 'Alternative: scikit-image ramp-filtered backprojection (FBP)'}
        data = dict(volume=volume, theta=theta.copy(), energy_index=energy,
                    energy_eV=float(s.stack.ev[energy]), algorithm=algorithm,
                    algorithm_description=labels[algorithm], iterations=iterations, beta=beta,
                    nonnegative=nonnegative, projection_min=low, projection_max=high,
                    normalization='none' if algorithm == 'fbp' else '(projection - global min) / (global max - global min)',
                    volume_axes='reconstruction row, acquisition y, reconstruction column')
    volume = data['volume']
    index = _index(p.get('slice_index', volume.shape[2]//2), volume.shape[2], 'slice_index')
    images = [_image(f'Tomography slice {index}', volume[:, :, index]),
              _image('Tomography central cross-section', volume[:, volume.shape[1]//2, :])]
    if not view_only:
        s.results['tomography'] = data
    s.record('tomography', dict(p, **({} if view_only else {
        'energy_index': energy, 'algorithm': algorithm, 'iterations': iterations,
        'beta': beta, 'nonnegative': nonnegative, 'normalization': data['normalization']})))
    return s.snapshot(images=images, metrics={
        'algorithm': data['algorithm_description'], 'slice_index': str(index),
        'normalization': data['normalization'], 'volume_axes': data['volume_axes'],
        'constraint': ('nonnegative; ' if data['nonnegative'] else 'signed; ') +
                      ('legacy TV upper bound 1' if data['algorithm'] == 'tv' else 'no upper bound')})


ADVANCED_METHODS += ('tomography',)


def _dose(s, p):
    """Legacy Henke dose: µm pixels, ms dwell, detected counts/s I0, Gy.

    Explicit geometry/dwell is mandatory: stack defaults may be pixel indices
    rather than calibrated spatial units. The inherited I0 rate assumption is
    reported, not silently inferred to be integrated counts.
    """
    from ..analysis.henke import henke
    from types import SimpleNamespace
    import hashlib
    from pathlib import Path
    name, od = _selected_spectrum(s, p)
    required = ('composition', 'detector_efficiency', 'pixel_size_x', 'pixel_size_y', 'dwell_time')
    if any(key not in p for key in required):
        raise ValueError('Dose requires composition, detector_efficiency (fraction), pixel_size_x/y (um), dwell_time (ms)')
    composition = p['composition']
    if not isinstance(composition, str) or not composition:
        raise ValueError('composition must be a nonempty Henke compound or chemical formula')
    efficiency = _number(p['detector_efficiency'], 'detector_efficiency', strict=True)
    if efficiency > 1:
        raise ValueError('detector_efficiency must be a fraction in (0, 1]')
    dx = _number(p['pixel_size_x'], 'pixel_size_x', strict=True)
    dy = _number(p['pixel_size_y'], 'pixel_size_y', strict=True)
    dwell = _finite(p['dwell_time'], 'dwell_time')
    energies = _finite(s.stack.ev, 'Dose energies')
    if dwell.ndim > 1 or dwell.size not in (1, len(energies)) or np.any(dwell <= 0):
        raise ValueError('dwell_time must be positive ms, scalar or one value per energy')
    i0 = _finite(p.get('i0', getattr(s.stack, 'i0data', [])), 'I0')
    if i0.ndim > 1 or i0.size not in (1, len(energies)) or np.any(i0 <= 0):
        raise ValueError('I0 must be positive detected counts/s, scalar or one value per energy')
    if 'i0' not in p:
        i0_ev = _finite(getattr(s.stack, 'evi0', []), 'I0 energies')
        if i0_ev.shape != energies.shape or not np.array_equal(i0_ev, energies):
            raise ValueError('I0 energies must match stack energies; provide explicitly remapped I0 rates')
    if od.shape != energies.shape or np.any(od < 0) or od[np.argmax(energies)] <= 0:
        raise ValueError('Dose requires nonnegative OD and positive OD at the highest energy')
    h = henke()
    try:
        _, mass = h.compound(composition, 1.)
    except (ValueError, IndexError, TypeError, UnboundLocalError) as exc:
        raise ValueError('Invalid Henke composition') from exc
    if not np.isfinite(mass) or mass <= 0:
        raise ValueError('Henke composition must have positive molecular mass')
    henke_ev = h.array(composition, 1.)[0]
    if np.any(energies < henke_ev[0]) or np.any(energies > henke_ev[-1]):
        raise ValueError('Dose energies must lie within the Henke tabulation')
    trial = SimpleNamespace(ev=energies.copy(), x_pxsize=dx, y_pxsize=dy, data_dwell=dwell)
    value = _number(h.dose_calc(trial, composition, od, i0.reshape(-1), efficiency), 'Dose')
    from ..analysis import henke as henke_module
    table = Path(henke_module.__file__).with_name('henke.xdr')
    provenance = dict(p, pixel_size_unit='um', dwell_time_unit='ms', i0_unit='detected counts/s',
                      detector_efficiency_unit='fraction', dose_unit='Gy', spectrum_source=name,
                      henke_sha256=hashlib.sha256(table.read_bytes()).hexdigest())
    s.results['dose'] = dict(dose_Gy=value, energies=energies.copy(), od=od.copy(),
                             i0=i0.copy(), dwell_time=dwell.copy(), parameters=provenance)
    s.record('dose', provenance)
    result = s.snapshot(spectra=[_spectrum(name, energies, od)], metrics={
        'dose_Gy': str(value), 'dose_units': 'Gy (J/kg)', 'algorithm': 'Original MANTiS Henke dose_calc',
        'input_units': 'pixel size: um; dwell: ms; I0: detected counts/s; efficiency: fraction',
        'uncertainty': 'Not estimated; legacy model assumes I0 is a count rate, not integrated counts'})
    result['dose_Gy'] = value
    return result


ADVANCED_METHODS += ('dose',)


_SOURCE_PARAMS = {'path', 'spectrum_index', 'cluster_index', 'source'}
_ALLOWED_PARAMS = {
    'spectral_roi': {'pre', 'post'},
    'spectral': {'paths', 'add_clusters', 'flat', 'use_pca', 'remove', 'move'},
    'rgb': {'channels'},
    'nnma': {'components', 'iterations', 'seed', 'initialization', 'paths',
             'lambda_sparse', 'lambda_cluster', 'lambda_smooth'},
    'peaks': {'threshold'} | _SOURCE_PARAMS,
    'key_energies': {'threshold'},
    'fit_peaks': {'steps', 'peaks', 'baseline', 'step_params', 'peak_amplitudes',
                  'peak_centers', 'peak_widths'} | _SOURCE_PARAMS,
    'tomography': {'energy_index', 'algorithm', 'iterations', 'beta', 'slice_index', 'nonnegative'},
    'dose': {'composition', 'detector_efficiency', 'pixel_size_x', 'pixel_size_y',
             'dwell_time', 'i0'} | _SOURCE_PARAMS,
}


def dispatch_advanced(session, method, params):
    import json
    if method not in ADVANCED_METHODS:
        raise ValueError(f'Unknown advanced method: {method}')
    if not isinstance(params, dict):
        raise ValueError('Advanced parameters must be an object')
    unknown = params.keys() - _ALLOWED_PARAMS[method]
    if unknown:
        raise ValueError(f'Unknown {method} parameters: {sorted(unknown)}')
    try:
        json.dumps(params, allow_nan=False)
    except (ValueError, TypeError) as exc:
        raise ValueError('Parameters must be finite JSON values') from exc
    for key in ('flat', 'add_clusters', 'use_pca', 'nonnegative'):
        if key in params and type(params[key]) is not bool:
            raise ValueError(f'{key} must be boolean')
    for key in ('threshold', 'baseline', 'beta', 'lambda_sparse', 'lambda_cluster',
                'lambda_smooth', 'detector_efficiency', 'pixel_size_x', 'pixel_size_y'):
        if key in params and (isinstance(params[key], bool) or not isinstance(params[key], (int, float))):
            raise ValueError(f'{key} must be a finite number')
    for key, count in (('channels', 3), ('move', 2)):
        if key in params and (not isinstance(params[key], (list, tuple)) or len(params[key]) != count):
            raise ValueError(f'{key} must contain {count} indices')
    if 'paths' in params and (not isinstance(params['paths'], list) or
                             any(not isinstance(path, str) or not path for path in params['paths'])):
        raise ValueError('paths must be a list of nonempty file paths')
    staged = copy.deepcopy(params)
    paths = list(staged.get('paths', []))
    if staged.get('path'):
        paths.append(staged['path'])
    if paths:
        import hashlib
        from pathlib import Path
        staged['reference_sources'] = [dict(
            path=str(Path(path).resolve()), sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            remapping='Original cubic interpolation; constant endpoint extension outside reference coverage')
            for path in paths]
    return globals()['_' + method](session, staged)
