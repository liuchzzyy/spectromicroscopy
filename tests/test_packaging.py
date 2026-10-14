"""Distribution structure: one Python package (core + CLI), one native GUI.

The CLI is no longer a separate distribution: it lives in `mantis_xray.cli` and is
exposed through the same `mantis-xray` distribution. The GUI remains a fully separate
product that bundles its own frozen engine and never imports this package.
"""
import ast
from pathlib import Path
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def project():
    return tomllib.loads((ROOT / 'pyproject.toml').read_text())['project']


def test_single_python_distribution_provides_library_engine_and_cli():
    metadata = project()
    assert metadata['name'] == 'mantis-xray'
    assert metadata['requires-python'] == '>=3.12,<3.13'
    assert (ROOT / '.python-version').read_text().strip() == '3.12'
    assert 'include .python-version uv.lock' in (ROOT / 'MANIFEST.in').read_text()
    scripts = metadata['scripts']
    assert scripts['mantis-xray'] == 'mantis_xray.cli:main'
    assert scripts['mantis'] == 'mantis_xray.cli:main'
    assert scripts['mantis-engine'] == 'mantis_xray.service:main'
    # One distribution means no self-referencing or leftover inter-package edges.
    assert metadata['dependencies'] == ['numpy', 'scipy>=1.11.4', 'matplotlib>=3.6.0',
                                        'h5py', 'Pillow', 'lxml', 'scikit-image>=0.19.1', 'xdrlib3']
    assert not [p for p in metadata['dependencies'] if p.startswith('mantis')]
    assert not (ROOT / 'CLI').exists(), 'The CLI must live inside the mantis_xray package'


def test_no_gui_dependency_or_gui_entrypoint():
    assert not any('qt' in dep.lower() for dep in project()['dependencies'])
    assert 'gui-scripts' not in project()
    assert not (ROOT / 'mantis_xray/gui').exists()


def test_no_qt_imports_remain_in_python_distribution():
    violations = []
    for path in (ROOT / 'mantis_xray').rglob('*.py'):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or '']
            else:
                continue
            if any('PyQt' in name or 'pyqtgraph' in name or 'backend_qt' in name for name in names):
                violations.append(str(path.relative_to(ROOT)))
    assert not violations


def test_cli_is_importable_inside_the_core_and_needs_no_second_install():
    """`python -m mantis_xray` must reach the CLI without a separate distribution."""
    entry = (ROOT / 'mantis_xray/__main__.py').read_text()
    assert 'from .cli import main' in entry
    assert 'mantis_cli' not in entry
    assert (ROOT / 'mantis_xray/cli.py').is_file()
    assert (ROOT / 'mantis_xray/batch.py').is_file()
    sources = '\n'.join(p.read_text() for p in (ROOT / 'mantis_xray').rglob('*.py'))
    assert 'mantis_cli' not in sources, 'No module may import the removed CLI package'


def test_native_gui_is_a_separate_product_with_no_python_frontend_import():
    """The GUI owns its Swift package and its own frozen engine."""
    assert (ROOT / 'GUI/Package.swift').is_file()
    assert not (ROOT / 'macos').exists()
    imports = set()
    for path in (ROOT / 'GUI/Sources').rglob('*.swift'):
        for line in path.read_text().splitlines():
            if line.startswith('import '):
                imports.add(line.split()[1])
    assert 'MantisCore' in imports  # its own Swift module, not the Python package
    assert 'mantis_xray' not in ' '.join(imports)


def test_gpl_license_is_shipped_with_every_component():
    license_text = (ROOT / 'LICENSE').read_bytes()
    assert license_text
    # The Python distribution declares it…
    assert project()['license'] == 'GPL-3.0-or-later'
    # …and the build script copies it into the native bundle.
    build = (ROOT / 'scripts/build_gui.sh').read_text()
    assert 'cp LICENSE "$APP/Contents/Resources/LICENSE"' in build
