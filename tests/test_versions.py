"""Independent source-version and documented installer contracts."""
from pathlib import Path
import plistlib
import tomllib

from mantis_xray import __version__

ROOT = Path(__file__).resolve().parents[1]


def test_gui_and_cli_advance_their_own_patch_versions():
    gui = plistlib.loads((ROOT / "GUI/Info.plist").read_bytes())
    helper = plistlib.loads((ROOT / "GUI/Resources/LoginHelperInfo.plist").read_bytes())
    assert gui["CFBundleShortVersionString"] == "1.0.2"
    assert gui["CFBundleVersion"] == "3"
    assert helper["CFBundleShortVersionString"] == gui["CFBundleShortVersionString"]
    assert helper["CFBundleVersion"] == gui["CFBundleVersion"]
    assert __version__ == "3.3.2"
    metadata = tomllib.loads((ROOT / "pyproject.toml").read_text())
    assert metadata["tool"]["setuptools"]["dynamic"]["version"]["attr"] == "mantis_xray.__version__"
    assert "version" in metadata["project"]["dynamic"]


def test_current_source_versions_and_installer_are_documented():
    readme = (ROOT / "README.md").read_text()
    assert "**1.0.2**" in readme
    assert "**3.3.2**" in readme
    assert "GitHub Releases" in readme
    assert "Mantis-1.0.2-arm64.dmg" in readme
    assert "Mantis-1.0.2-arm64.dmg.sha256" in readme
    migration = (ROOT / "docs/native-migration.md").read_text()
    assert "Mantis-1.0.2-arm64.dmg" in migration
    assert "Mantis-1.0.2-arm64.dmg.sha256" in migration
    assert "Mantis-1.0.1-arm64.dmg" not in migration
    # The wire protocol is independently versioned, not bumped with products.
    contract = (ROOT / "docs/native-contract.md").read_text()
    assert '"engine_version":"3.3.2","protocol":1' in contract
