"""Real ASCII fixtures are optional locally; synthetic contracts always run."""
from pathlib import Path
import importlib
import importlib.util

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'docs' / 'Datasets'


def plugin():
    # Isolate reader contracts from unrelated plugins being edited concurrently.
    spec = importlib.util.spec_from_file_location(
        'file_xafs_dat', ROOT / 'mantis_xray/file_plugins/file_xafs_dat.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(name):
    paths = list(DATA.rglob(name))
    if not paths:
        pytest.skip('Real beamline fixtures not installed')
    assert len(paths) == 1
    return paths[0]


@pytest.mark.parametrize('name,nrows,ncols', [
    ('NSLS_04BM_Cu_metal.xdi', 408, 4),
    ('NSLS_04BM_Fe_8ch.xdi', 100, 39),
    ('NSLS6BM_2019_VKedge.dat', 352, 23),
    ('APS13ID_2019.dat', 221, 21),
])
def test_real_xdi_preserves_every_column(name, nrows, ncols):
    p = plugin()
    source = fixture(name)
    result = p.read_spectra(source)
    expected = np.loadtxt(source)
    assert result['data'].shape == (nrows, ncols)
    np.testing.assert_array_equal(result['data'], expected)
    np.testing.assert_array_equal(result['energy_eV'], expected[:, 0])
    assert result['energy_unit'] == 'eV'
    assert result['formula_applied'] is None
    assert p.identify(source)
    if name == 'NSLS_04BM_Cu_metal.xdi':
        assert result['metadata']['Beamline.name'] == 'APS 13ID'
        assert result['columns'][3]['name'] == 'mutrans'
        assert result['columns'][3]['semantic'] == 'provided_absorption'
        assert result['data'][0, 3] == -1.3070486
    if name == 'NSLS6BM_2019_VKedge.dat':
        assert result['columns'][3]['semantic'] == 'provided_absorption'
        assert '(DTC1 + DTC2 + DTC3 + DTC4) / I0' in result['metadata']['Scan.plot_hint']
        assert result['data'][0, 3] == 53.156379


@pytest.mark.parametrize('name,start,rows,cols,energy,label,unit', [
    ('APS12BM_2019_CMS.dat', 8, 492, 26, 0, 'Energy', 'keV'),
    ('APS10BM_2019_MnO2.dat', 18, 3464, 5, 0, 'energy', None),
    ('APS13ID_2008.dat', 44, 469, 4, 0, 'Energy', None),
    ('CLSHXMA_standard.dat', 6, 414, 11, 1, 'BL1606-ID-1:Energy', None),
    ('CLS_PNC_CAT_2001_FeO.dat', 14, 412, 5, 0, 'Mono Energy', None),
    ('ESRF_BM08_LISA_2021.dat', 1, 198, 7, 0, 'eBraggEnergy', None),
    ('NSLS8ID_2019_AsKedge.dat', 19, 647, 6, 0, 'energy', None),
    ('SLS_PHOENIX_2023_MgAl.dat', 1, 301, 55, 0, 'Energy', None),
    ('SSRL1_2006_Ag.dat', 26, 455, 6, 2, 'Achieved Energy', None),
    ('SSRLmicro_2008_Ge.dat', 89, 296, 69, 1, 'Requested Energy', None),
])
def test_real_dat_labelled_tables(name, start, rows, cols, energy, label, unit):
    result = plugin().read_spectra(fixture(name))
    expected = np.loadtxt(fixture(name), skiprows=start,
                          delimiter=',' if name == 'CLSHXMA_standard.dat' else None)
    assert result['data'].shape == (rows, cols)
    np.testing.assert_array_equal(result['data'], expected)
    assert result['energy_column'] == energy
    assert result['columns'][energy]['name'] == label
    assert result['energy_unit'] == unit
    assert result['formula_applied'] is None
    if unit is None:
        assert result['energy_eV'] is None  # No magnitude-based unit inference.
    else:
        np.testing.assert_array_equal(result['energy_eV'], expected[:, energy] * 1000)
        assert result['columns'][7]['semantic'] == 'provided_absorption'


@pytest.mark.parametrize('name', ['PF9A_2022_Fe.dat', 'PFBL12C_2005_Hg.dat'])
def test_pf_preserves_angles_and_detector_metadata(name):
    source = fixture(name)
    result = plugin().read_spectra(source)
    np.testing.assert_array_equal(result['data'], np.loadtxt(source.read_text().replace('\x1a', '').splitlines(), skiprows=19))
    assert result['energy_column'] is None
    assert result['energy_eV'] is None
    assert result['axis_column'] == 0
    assert result['columns'][0]['unit'] == 'deg'
    assert result['columns'][2]['unit'] == 's'
    assert result['metadata']['detector_mode'].startswith('Mode')
    assert result['formula_applied'] is None
    assert plugin().identify(source)


def test_spec_scan_selection_preserves_all_rows():
    source = fixture('ESRF_SNBL_2013_GeO2.dat')
    p = plugin()
    lines = source.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith('#S ')]
    for index, start in enumerate(starts):
        stop = starts[index + 1] if index + 1 < len(starts) else len(lines)
        result = p.read_spectra(source, selection=index)
        np.testing.assert_array_equal(result['data'], np.loadtxt(lines[start:stop]))
        assert result['columns'][15]['name'] == 'ZapEnergy'
        assert result['energy_column'] == 15
        assert result['energy_unit'] is None
        assert result['energy_eV'] is None
        assert result['metadata']['selected_scan'] == index
        assert len(result['metadata']['scans']) == 2
    with pytest.raises(ValueError, match='selection'):
        p.read_spectra(source, selection=2)


def test_mismatched_numbered_header_is_readable_without_false_labels():
    source = fixture('SLS_PHOENIX_2023_TEY.dat')
    result = plugin().read_spectra(source)
    np.testing.assert_array_equal(result['data'], np.loadtxt(source))
    assert [col['name'] for col in result['columns']] == ['column_1', 'column_2', 'column_3']
    assert result['energy_column'] is None
    assert result['energy_eV'] is None
    assert len(result['metadata']['declared_columns']) == 55
    assert result['metadata']['warnings']
    assert plugin().identify(source)


@pytest.mark.parametrize('source', sorted(DATA.rglob('*.dat')) + sorted(DATA.rglob('*.xdi')))
def test_every_real_ascii_has_serializable_preview(source):
    import json
    p = plugin()
    result = p.preview(source)
    assert result['kind'] == 'table'
    assert result['schema_version'] == 1
    assert len(result['columns']) == len(result['axis_units'])
    assert all(len(row) == len(result['columns']) for row in result['rows'])
    assert result['rows']
    assert json.loads(json.dumps(result, allow_nan=False)) == result
    np.testing.assert_array_equal(result['rows'], p.read_spectra(source)['data'])
    assert result['metadata']['formula_applied'] is None
    assert p.identify(source)
    if source.name == 'ESRF_SNBL_2013_GeO2.dat':
        second = p.preview(source, selection=1)
        assert second['metadata']['selected_scan'] == 1
        np.testing.assert_array_equal(second['rows'], p.read_spectra(source, selection=1)['data'])


def test_unknown_multicolumn_is_not_fake_spectrum(tmp_path):
    source = tmp_path / 'unknown.dat'
    source.write_text('1000 10 20\n1001 11 21\n')
    with pytest.raises(ValueError, match='explicit column definitions'):
        plugin().read_spectra(source)
    assert not plugin().identify(source)


def test_session_does_not_misrepresent_absorption_as_i0_or_pixels():
    from mantis_xray.core.session import Session
    with pytest.raises(ValueError, match='Session spectrum support is required'):
        Session().open(fixture('NSLS_04BM_Cu_metal.xdi'))


@pytest.mark.parametrize('text,message', [
    ('# XDI/1.0\n# Column.1: energy eV\n# Column.1: mu\n1 2\n', 'Duplicate'),
    ('# XDI/1.0\n# Column.2: energy eV\n1\n', 'contiguous'),
    ('# XDI/1.0\n# Column.1: energy eV\n# Column.2: mu\n1 nan\n', 'finite'),
    ('SSRL EXAFS Data Collector\n', 'Invalid SSRL'),
])
def test_malformed_header_fails_cleanly(tmp_path, text, message):
    source = tmp_path / 'bad.dat'
    source.write_text(text)
    with pytest.raises(ValueError, match=message):
        plugin().read_spectra(source)
    assert not plugin().identify(source)


def test_synthetic_xdi_units_and_semantics(tmp_path):
    source = tmp_path / 'unrelated.dat'
    source.write_text('# XDI/1.0\n# Column.1: energy keV\n# Column.2: mutrans\n'
                      '# Column.3: i0 counts\n1.5 -0.25 20\n1.6 0.5 21\n')
    result = plugin().read_spectra(source)
    np.testing.assert_array_equal(result['energy_eV'], [1500, 1600])
    np.testing.assert_array_equal(result['data'][:, 1], [-0.25, 0.5])
    assert result['columns'][1]['semantic'] == 'provided_absorption'
    assert result['columns'][2]['semantic'] == 'source_channel'
    assert result['formula_applied'] is None


