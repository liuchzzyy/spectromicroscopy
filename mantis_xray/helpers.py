"""Headless resource and diagnostic helpers (no GUI dependencies/network calls)."""
from importlib import metadata
from pathlib import Path
from . import __version__


def resource_path(relative_path):
    return str(Path(__file__).parent / relative_path)


def print_welcome_banner():
    print(f"MANTiS engine {__version__}")


def print_dependency_versions():
    for package in ("numpy", "scipy", "matplotlib", "h5py", "Pillow", "lxml", "scikit-image", "xdrlib3"):
        try:
            print(f"{package} == {metadata.version(package)}")
        except metadata.PackageNotFoundError:
            print(f"{package}: not installed")


def print_startup_info():
    print_welcome_banner()
    print_dependency_versions()
