"""Read-only regressions against the optional, real beamline corpus."""
from pathlib import Path

import h5py
import numpy as np
import pytest

from mantis_xray.file_plugins import file_nexus_hdf5 as nexus
from mantis_xray.file_plugins import file_dataexch_hdf5 as exchange

ROOT = Path(__file__).resolve().parents[1] / 'docs' / 'Datasets'


def source(beamline, name):
    paths = list((ROOT / beamline).rglob(name))
    if not paths:
        pytest.skip('optional real beamline corpus unavailable')
    assert len(paths) == 1
    return paths[0]


def stack():
    from mantis_xray.core.session import _new_stack
    return _new_stack()


@pytest.mark.parametrize('name', ['NEXAFS_stack_Alignment-1.nxs', 'Diff_map_Polymer-blend.nxs'])
def test_i08_default_selection_preserves_real_axes_and_values(name):
    path = source('Diamond_I08', name)
    s = stack()
    assert nexus.identify(path)
    nexus.read(path, s)
    with h5py.File(path) as f:
        g = f['entry1/Counter1']
        np.testing.assert_array_equal(s.absdata, g['data'][()].transpose(2, 1, 0))
        np.testing.assert_array_equal(s.ev, g['photon_energy'][()])
        np.testing.assert_array_equal(s.x_dist, g['sample_x'][()])
        np.testing.assert_array_equal(s.y_dist, g['sample_y'][()])
        np.testing.assert_array_equal(s.data_dwell, g['count_time'][()])
        assert s.data_struct.exchange.energy_units == 'unknown'
        assert s.data_struct.exchange.x_units == 'unknown'
        assert s.data_struct.exchange.y_units == 'unknown'


@pytest.mark.parametrize('name', ['I14_XANES.hdf5', 'I14_sparse-XANES.hdf5'])
def test_i14_preserves_calibration_and_declared_units(name):
    path = source('Diamond_I14', name)
    s = stack()
    assert exchange.identify(path)
    exchange.read(path, s)
    with h5py.File(path) as f:
        g = f['exchange']
        order = np.argsort(g['energy'][()])
        np.testing.assert_array_equal(s.absdata, g['data'][()][:, :, order])
        np.testing.assert_array_equal(s.ev, g['energy'][()][order])
        np.testing.assert_array_equal(s.x_dist, g['x'][()])
        np.testing.assert_array_equal(s.y_dist, g['y'][()])
        assert s.data_struct.exchange.energy_units == 'eV'
        # No units are supplied for x/y: do not silently label these microns.
        assert s.data_struct.exchange.x_units in (None, 'unknown')
        assert s.data_struct.exchange.y_units in (None, 'unknown')


@pytest.mark.parametrize('name,axes', [
    ('Sample_Image_2021-03-16_095.hdf5', (1, 0)),
    ('Sample_Stack_2021-03-16_128.hdf5', (2, 1, 0)),
    ('Sample_Line_2021-03-16_096.hdf5', (1, 0)),
])
def test_pollux_real_sample_scans(name, axes):
    path = source('SLS_PolLux_X07DA', name)
    s = stack()
    nexus.read(path, s)
    with h5py.File(path) as f:
        g = f['entry1/counter0']
        expected = g['data'][()].transpose(axes)
        if 'Image' in name:
            expected = expected[:, :, None]
        elif 'Line' in name:
            expected = expected[:, None, :]
        np.testing.assert_array_equal(s.absdata, expected)
        np.testing.assert_array_equal(s.ev, g['energy'][()])
        np.testing.assert_array_equal(s.x_dist, g['sample_x'][()])
        y = g['sample_y'][()]
        np.testing.assert_array_equal(s.y_dist, y[:1] if 'Line' in name else y)
        assert s.data_struct.exchange.energy_units == 'eV'
        assert s.data_struct.exchange.x_units == 'um'
        assert s.data_struct.exchange.y_units == 'um'


def test_pollux_focus_is_explicitly_rejected():
    path = source('SLS_PolLux_X07DA', 'Focus_2021-03-16_051.hdf5')
    with pytest.raises(ValueError, match='focus'):
        nexus.read(path, stack())


@pytest.mark.parametrize('beamline,name,reason', [
    ('SOLEIL_DIFFABS', 'DIFFABS_timescan_tscan.nxs', 'timescan'),
    ('SOLEIL_DIFFABS', 'DIFFABS_timescan_scan2.nxs', 'timescan'),
    ('SOLEIL_SWING', 'SWING_biologie_scan1.nxs', 'scattering'),
    ('SOLEIL_SWING', 'SWING_biologie_scan2.nxs', 'scattering'),
])
def test_non_spectromicroscopy_nexus_rejected(beamline, name, reason):
    path = source(beamline, name)
    assert not nexus.identify(path)
    with pytest.raises(ValueError, match=reason):
        nexus.read(path, stack())


