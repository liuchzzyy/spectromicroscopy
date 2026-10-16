"""Read-only regression checks against the optional real beamline corpus."""
from pathlib import Path
import numpy as np
import pytest
from mantis_xray.analysis import data_stack, data_struct
from mantis_xray.file_plugins import file_sdf, file_tif, file_xrm

ROOT = Path(__file__).resolve().parents[1] / 'docs' / 'Datasets'
HDRS = sorted(ROOT.rglob('*.hdr'))
TIFFS = sorted(p for p in ROOT.rglob('*') if p.suffix in ('.tif', '.tiff'))

@pytest.mark.parametrize('path', TIFFS, ids=lambda p: p.stem)
def test_tiff_real_pixels_axes_energy_units(path):
    import tifffile
    assert file_tif.identify(str(path))
    obj = stack()
    if path.name.startswith('Cat2_'):
        with pytest.raises(ValueError, match='energy'):
            file_tif.read(str(path), obj)
        return
    name, factor = ('Energy.txt', 1) if path.stem.isdigit() else (
        ('Ni_eng_list.txt', 1000) if path.stem == 'Ni_xanes' else ('energy_list_corr.txt', 1))
    energy = np.loadtxt(path.parent / name) * factor
    raw = tifffile.imread(path)
    expected = raw.transpose(1, 0, 2) if name == 'Energy.txt' else raw.transpose(2, 1, 0)
    if name == 'Energy.txt':
        paired = ROOT / 'ALS_11.0.2.2' / 'sdf_hdr_xim' / path.parent.name
        for i, image in enumerate(sorted(paired.glob('*_a*.xim'))):
            np.testing.assert_array_equal(expected[:, :, i], np.loadtxt(image).T)
    file_tif.read(str(path), obj)
    np.testing.assert_array_equal(obj.absdata, expected)
    np.testing.assert_array_equal(obj.ev, energy)
    assert obj.absdata.shape == (obj.n_cols, obj.n_rows, obj.n_ev)
    np.testing.assert_array_equal(obj.x_dist, np.arange(obj.n_cols))
    np.testing.assert_array_equal(obj.y_dist, np.arange(obj.n_rows))
    assert obj.data_struct.exchange.x_units == 'pixel'
    assert obj.data_struct.exchange.y_units == 'pixel'
    assert obj.data_struct.exchange.energy_units == 'eV'

def test_xrm_real_unsigned_pixels_and_calibration():
    import olefile
    paths = list(ROOT.rglob('test_chip00.xrm'))
    if not paths:
        pytest.skip('optional real beamline corpus unavailable')
    path = paths[0]
    obj = stack()
    file_xrm.read(str(path), obj)
    with olefile.OleFileIO(str(path)) as ole:
        raw = np.frombuffer(ole.openstream('ImageData1/Image1').read(), dtype='<u2')
        np.testing.assert_array_equal(obj.absdata[:, :, 0], raw.reshape(512, 512).T)
        energy = np.frombuffer(ole.openstream('ImageInfo/Energy').read(), dtype='<f4')
        pixel = np.frombuffer(ole.openstream('ImageInfo/PixelSize').read(), dtype='<f4')[0]
    np.testing.assert_array_equal(obj.ev, energy)
    np.testing.assert_allclose(obj.x_dist, np.arange(512) * float(pixel))
    assert obj.data_struct.exchange.x_units == 'um'
    assert obj.data_struct.exchange.energy_units.lower() == 'ev'


def test_txrm_tomography_is_not_energy_stack():
    paths = list(ROOT.rglob('txrm_test_chip_tomo.txrm'))
    if not paths:
        pytest.skip('optional real beamline corpus unavailable')
    path = paths[0]
    with pytest.raises(ValueError, match='tomography'):
        file_xrm.read(str(path), stack())


def stack():
    return data_stack.data(data_struct.h5())

@pytest.mark.parametrize('path', HDRS, ids=lambda p: p.stem)
def test_sdf_real_pixels_axes_energy_units(path):
    hdr = file_sdf.HDR_FileParser(str(path))
    obj = stack()
    file_sdf.read(str(path), obj)
    definition = hdr.hdr['ScanDefinition']
    region = definition['Regions'][1]
    np.testing.assert_array_equal(obj.ev, definition['StackAxis']['Points'][1:])
    np.testing.assert_array_equal(obj.x_dist, region['PAxis']['Points'][1:])
    np.testing.assert_array_equal(obj.y_dist, region['QAxis']['Points'][1:])
    files = sorted(path.parent.glob(path.stem + '_a*.xim'))
    assert len(files) == obj.n_ev
    for i, image in enumerate(files):
        np.testing.assert_array_equal(obj.absdata[:, :, i], np.loadtxt(image).T)
    assert obj.data_struct.exchange.energy_units.lower() == 'ev'
    assert obj.data_struct.exchange.x_units == 'um'
    assert obj.data_struct.exchange.y_units == 'um'
