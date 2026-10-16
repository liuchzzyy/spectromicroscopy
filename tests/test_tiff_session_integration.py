"""The public Session must use the same calibrated reader as plugin callers."""
from pathlib import Path
import numpy as np
import pytest
from mantis_xray.core.session import Session
from mantis_xray.file_plugins import file_tif
from mantis_xray.core.session import _new_stack

ROOT = Path(__file__).resolve().parents[1] / 'docs' / 'Datasets'

@pytest.mark.parametrize('name', ['71214078.tiff', '71214098.tiff', 'nanoXANES_Fe.tiff', 'Ni_xanes.tiff'])
def test_session_uses_calibrated_tiff_reader(name):
    paths = list(ROOT.rglob(name))
    if not paths:
        pytest.skip('optional real beamline corpus unavailable')
    path = paths[0]
    expected = _new_stack()
    file_tif.read(path, expected)
    session = Session()
    session.open(path)
    np.testing.assert_array_equal(session.stack.absdata, expected.absdata)
    np.testing.assert_array_equal(session.stack.ev, expected.ev)
