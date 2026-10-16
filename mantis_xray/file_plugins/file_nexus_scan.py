"""Non-spectroscopic NeXus previews; values are row-major raw measurements.

``preview(filename)`` is independent of the energy-stack reader. Missing physical
calibration is explicitly reported as index/pixel coordinates, never fabricated.
"""
import h5py
import numpy as np

title = 'NeXus scan preview'
extension = ['*.nxs', '*.hdf5', '*.h5']
read_types = ['image']
write_types = []


def _safe(value):
    if isinstance(value, bytes):
        try:
            return value.decode('utf-8')
        except UnicodeDecodeError:
            return value.decode('latin-1')
    if isinstance(value, np.ndarray):
        return _safe(value.tolist())
    if isinstance(value, np.generic):
        return _safe(value.item())
    if isinstance(value, (tuple, list)):
        return [_safe(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _safe(v) for k, v in value.items()}
    if isinstance(value, float) and not np.isfinite(value):
        return None
    return value


def _groups(f):
    return [g for e in f.values() if isinstance(e, h5py.Group)
            for g in e.values() if isinstance(g, h5py.Group)
            and _safe(g.attrs.get('NX_class')) == 'NXdata']


def identify(filename):
    """Claim only SOLEIL DIFFABS/SWING, leaving NXstxm dispatch untouched."""
    try:
        with h5py.File(filename, 'r') as f:
            for e in f.values():
                if not isinstance(e, h5py.Group):
                    continue
                if 'definition' in e and 'NXstxm' in str(_safe(e['definition'][()])):
                    return False
            return bool(_groups(f)) and any(
                name in e and _safe(e[name].attrs.get('NX_class')) == 'NXinstrument'
                for e in f.values() if isinstance(e, h5py.Group)
                for name in ('DIFFABS', 'SWING'))
    except (OSError, ValueError, TypeError):
        return False


def _axis(d):
    return dict(name=d.name.rsplit('/', 1)[-1], path=d.name,
                units=_safe(d.attrs.get('units', '')), values=_safe(d[()]),
                description=_safe(d.attrs.get('long_name', '')))


def _result(image, axes, metadata):
    return dict(kind='image', width=int(image.shape[1]), height=int(image.shape[0]),
                values=_safe(image.ravel()), axes=axes, metadata=_safe(metadata))


def preview(filename):
    """Return a JSON-safe raw first-frame preview, without normalization."""
    with h5py.File(filename, 'r') as f:
        groups = _groups(f)
        if not groups:
            raise ValueError('No NXdata group available for preview')
        g = groups[0]
        signal = _safe(g.attrs.get('signal', 'data'))
        if signal in g and isinstance(g[signal], h5py.Dataset) and g[signal].ndim >= 2:
            d = g[signal]
            image = d[(0,) * (d.ndim - 2) + (slice(None), slice(None))]
            names = _safe(g.attrs.get('axes', []))
            if isinstance(names, str):
                names = names.split(':')
            axes = {}
            for key, dim in [('y', -2), ('x', -1)]:
                name = names[dim] if len(names) >= 2 else None
                if name is not None and name in g:
                    axes[key] = _axis(g[name])
                else:
                    axes[key] = dict(name='detector_' + key, units='pixel',
                                     values=list(range(image.shape[dim])), calibrated=False)
            focus = 'zone_plate' in names
            frames = int(np.prod(d.shape[:-2])) if d.ndim > 2 else sum(
                signal in group and group[signal].shape == d.shape for group in groups)
            return _result(image, axes, dict(scientific_kind='focus_scan' if focus else 'detector_image',
                shape=list(d.shape), frame_count=frames, frame_index=0, dataset_path=d.name,
                signal_attributes=dict(d.attrs),
                interpretation='Zone-plate position versus line position; not an energy stack.' if focus else
                'Raw detector pixels; no reciprocal-space or sample-space calibration inferred.',
                auxiliary_coordinates={n: _axis(g[n]) for n in ('sample_x', 'sample_y') if n in g}))
        channels = [d for d in g.values() if isinstance(d, h5py.Dataset)
                    and d.ndim == 1 and 'signal' in d.attrs]
        if not channels:
            raise ValueError('No scan channels available for preview')
        channels.sort(key=lambda d: int(d.attrs['signal']))
        image = np.stack([d[()] for d in channels])
        time = next((d for d in g.values() if isinstance(d, h5py.Dataset)
                     and d.attrs.get('primary') == 1 and 'axis' in d.attrs), None)
        x = _axis(time) if time is not None else dict(name='point_index', units='index', values=list(range(image.shape[1])))
        return _result(image, dict(x=x, y=dict(name='channel', units='',
                       values=[d.name.rsplit('/', 1)[-1] for d in channels])),
                       dict(scientific_kind='time_scan', shape=list(image.shape),
                            frame_count=1, frame_index=0, dataset_paths=[d.name for d in channels],
                            channels=[dict(path=d.name, **_safe(dict(d.attrs))) for d in channels],
                            interpretation='Rows are independent channels with their own units; not spatial or energy axes.'))


def read(filename, stack=None, selection=None, **kwargs):
    """Preview-only plugin: deliberately does not populate an energy stack."""
    return preview(filename)


def GetFileStructure(filename):
    return None
