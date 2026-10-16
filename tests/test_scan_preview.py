"""Read-only previews retain acquisition axes, never invent energy stacks."""
import importlib
import json
from pathlib import Path

import h5py
import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1] / 'docs/Datasets'


@pytest.mark.parametrize('suffix', ['xrm', 'txrm'])
def test_real_xradia_first_frame(suffix):
    from mantis_xray.file_plugins import file_xrm
    paths = sorted(ROOT.glob('Xradia_Microscope/**/*.' + suffix))
    if not paths:
        pytest.skip('Optional real datasets absent')
    for path in paths:
        r = file_xrm.preview(path)
        ole = file_xrm.OleFileIO(str(path))
        try:
            pixels = np.frombuffer(ole.openstream('ImageData1/Image1').read(), dtype='<u2')
            np.testing.assert_array_equal(r['values'], pixels)
        finally:
            ole.close()
        assert r['metadata']['frame_count'] == (7 if suffix == 'txrm' else 1)
        assert r['metadata']['scientific_kind'] == ('tomography_projection' if suffix == 'txrm' else 'xray_image')
        if suffix == 'txrm':
            assert len(r['axes']['frame']['values']) == 7
            assert r['axes']['frame']['units'] == 'degree'
        json.dumps(r, allow_nan=False)


def plugin():
    return importlib.import_module('mantis_xray.file_plugins.file_nexus_scan')


def test_diffabs_preview_preserves_time_and_channels(tmp_path):
    path = tmp_path / 'scan.nxs'
    with h5py.File(path, 'w') as f:
        e = f.create_group('entry'); e.attrs['NX_class'] = 'NXentry'
        e.create_group('DIFFABS').attrs['NX_class'] = 'NXinstrument'
        g = e.create_group('scan_data'); g.attrs['NX_class'] = 'NXdata'
        for i in range(1, 3):
            d = g.create_dataset('data_%d' % i, data=np.arange(3) + 10*i)
            d.attrs['signal'] = i; d.attrs['units'] = 'counts'
        t = g.create_dataset('time_1', data=[0., .5, 1.])
        t.attrs['axis'] = 0; t.attrs['primary'] = 1; t.attrs['units'] = 's'
    p = plugin()
    assert p.identify(path)
    r = p.preview(path)
    assert (r['width'], r['height']) == (3, 2)
    assert r['values'] == [10, 11, 12, 20, 21, 22]
    assert r['axes']['x']['values'] == [0., .5, 1.]
    assert r['axes']['x']['units'] == 's'
    assert r['metadata']['frame_count'] == 1
    assert r['metadata']['scientific_kind'] == 'time_scan'
    json.dumps(r, allow_nan=False)


@pytest.mark.parametrize('pattern', ['SOLEIL_SWING/**/*.nxs', 'SLS_PolLux_X07DA/**/Focus*.hdf5'])
def test_real_image_and_focus_preview(pattern):
    paths = sorted(ROOT.glob(pattern))
    if not paths:
        pytest.skip('Optional real datasets absent')
    for path in paths:
        r = plugin().preview(path)
        assert r['kind'] == 'image'
        with h5py.File(path) as f:
            np.testing.assert_array_equal(r['values'], f[r['metadata']['dataset_path']][()].ravel())
        if 'Focus' in path.name:
            assert not plugin().identify(path)
            assert r['axes']['x']['name'] == 'line_position'
            assert r['axes']['y']['name'] == 'zone_plate'
            assert r['metadata']['frame_count'] == 1
        else:
            assert plugin().identify(path)
            assert r['metadata']['frame_count'] == 10
        json.dumps(r, allow_nan=False)
