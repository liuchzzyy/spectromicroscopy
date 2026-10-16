"""Preview is read-only and available through the engine dispatch."""
from pathlib import Path
import pytest
from mantis_xray.core.session import Session

ROOT = Path(__file__).resolve().parents[1] / 'docs/Datasets'


def test_preview_uncalibrated_tiff_without_creating_analysis_stack():
    paths = list(ROOT.rglob('Cat2_RT36738.tif'))
    if not paths:
        pytest.skip('optional real corpus absent')
    session = Session()
    original = session.stack
    result = session.dispatch('preview_file', {'path': str(paths[0])})
    assert result['format'] == 'TIFF'
    assert result['beamline']
    assert result['kind'] == 'image'
    assert len(result['values']) == result['width'] * result['height']
    assert session.stack is original
