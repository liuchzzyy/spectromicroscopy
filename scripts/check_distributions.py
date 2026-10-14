"""Inspect the built wheel: one self-contained, Qt-free mantis-xray distribution.

Run after building:
    uv build --out-dir dist/python && uv run --locked --all-extras python scripts/check_distributions.py
"""
from pathlib import Path
from email.parser import BytesParser
import sys
import zipfile

EXPECTED_SCRIPTS = {
    "mantis-xray = mantis_xray.cli:main",
    "mantis = mantis_xray.cli:main",
    "mantis-engine = mantis_xray.service:main",
}
REQUIRED_SOURCES = [
    "mantis_xray/__init__.py",
    "mantis_xray/__main__.py",
    "mantis_xray/cli.py",
    "mantis_xray/batch.py",
    "mantis_xray/service.py",
    "mantis_xray/core/session.py",
    "mantis_xray/core/advanced.py",
    "mantis_xray/analysis/henke.xdr",
]


def check(root):
    root = Path(root)
    wheels = sorted((root / "dist" / "python").glob("*.whl"))
    if len(wheels) != 1:
        raise ValueError(f"Expected exactly one wheel in dist/python, got {wheels}")
    with zipfile.ZipFile(wheels[0]) as archive:
        files = archive.namelist()
        metadata_path = next(p for p in files if p.endswith(".dist-info/METADATA"))
        metadata = BytesParser().parsebytes(archive.read(metadata_path))
        assert metadata["Name"] == "mantis-xray", metadata["Name"]
        for source in REQUIRED_SOURCES:
            assert source in files, f"Missing {source}"
        # Library, engine and CLI ship together; no Qt and no native frontend.
        assert not any("mantis_xray/gui/" in p or p.endswith(".swift") for p in files)
        assert not any("mantis_cli" in p for p in files), "The removed separate CLI package leaked in"
        dependencies = metadata.get_all("Requires-Dist", [])
        assert not any("qt" in dependency.lower() for dependency in dependencies), dependencies
        assert not [d for d in dependencies if d.startswith("mantis")], dependencies
        assert any(p.endswith("dist-info/licenses/LICENSE") for p in files), "Missing GPL license"
        entry_points = next(p for p in files if p.endswith("dist-info/entry_points.txt"))
        declared = {line.strip() for line in archive.read(entry_points).decode().splitlines() if line.strip()}
        assert EXPECTED_SCRIPTS <= declared, declared
    print("PASS: single mantis-xray wheel ships library + engine + CLI, no Qt/native content, "
          "GPL license and all three console scripts")
    return str(wheels[0])


if __name__ == "__main__":
    argument = sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
    check(argument)
