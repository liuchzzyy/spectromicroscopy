# Spectromicroscopy & MANTiS #

[Spectromicroscopy](http://spectromicroscopy.com) combines spectral data with microscopy,
where typical datasets consist of a stack of microscopic images taken across an energy range.
Due to data complexity, manual analysis can be time-consuming and inefficient, whereas
multivariate analysis tools not only reduce the time needed but also uncover hidden trends in the data.

[MANTiS](http://spectromicroscopy.com) (Multivariate ANalysis Tool for Spectromicroscopy) was originally
developed by [2nd Look Consulting](http://2ndlookconsulting.com). It uses principal component analysis
(PCA), cluster analysis, and non-negative matrix approximation (NNMA) to classify pixels according to
spectral similarity and extract chemical state distributions from synchrotron X-ray datasets.

## Native macOS Application

This repository provides a native Apple Silicon macOS application built with SwiftUI and AppKit (`GUI/`),
backed by an isolated private numerical calculation engine.

- **GUI Version**: **1.0.2** (build **3**)
- **Architecture**: Apple Silicon (arm64), macOS 14.0 (Sonoma) or later
- **Design & Experience**: Native macOS design adhering to Apple Human Interface Guidelines, Dark and Light mode support, English and Simplified Chinese localization.
- **Scientific Fidelity**: High-precision numerical calibration preserving source pixel resolution with 5 significant digits (`%#.5g`), strict optical density (OD) semantics, and full-resolution raw array preservation.
- **In-App Updates**: Built-in auto-updater with SHA-256 integrity verification and atomic rollback protection.

### Download & Installation

Download the verified Apple Silicon installer from [GitHub Releases](https://github.com/liuchzzyy/spectromicroscopy/releases/tag/v1.0.2):

- **DMG Installer**: [`Mantis-1.0.2-arm64.dmg`](https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.2/Mantis-1.0.2-arm64.dmg)
- **SHA-256 Checksum**: [`Mantis-1.0.2-arm64.dmg.sha256`](https://github.com/liuchzzyy/spectromicroscopy/releases/download/v1.0.2/Mantis-1.0.2-arm64.dmg.sha256)

Verify the installer checksum in Terminal:
```sh
shasum -a 256 -c Mantis-1.0.2-arm64.dmg.sha256
```
Open `Mantis-1.0.2-arm64.dmg` and drag **Mantis.app** to your `/Applications` directory.

## Python Distribution (CLI, Library & Engine)

The numerical core is packaged as a single Qt-free Python distribution (`mantis-xray`) providing the CLI, batch processing, and headless JSON-lines engine.

- **CLI/Engine/Library Version**: **3.3.2**
- **Runtime**: Python 3.12 (managed via `uv`)
- **JSON-lines Engine Protocol**: Version **1**

### Quickstart with uv

```sh
uv python install 3.12
uv sync --locked --python 3.12 --all-extras
uv run --locked --all-extras mantis-xray --help
```

### CLI Commands

- `mantis-xray inspect <path>`: Inspect spectromicroscopy stack dimensions, calibration, and energy points.
- `mantis-xray batch <config.json>`: Run automated headless multivariate analysis pipelines.
- `mantis-xray engine`: Launch the persistent JSON-lines calculation service (used internally by the native GUI).

## Repository Layout

| Path | Contents |
|---|---|
| `mantis_xray/` | Python numerical core (`analysis/`, `core/`, `file_plugins/`), CLI (`cli.py`, `batch.py`), JSON-lines engine (`service.py`). |
| `GUI/` | Native SwiftUI/AppKit macOS app: Swift package (`Sources/`, `Tests/`), `Info.plist`. |
| `scripts/` | `build_gui.sh` (app + DMG packaging), `smoke_engine.py` (frozen-engine acceptance), `check_distributions.py` (wheel inspection), `engine_entry.py`. |
| `tests/` | Python test suite: algorithms, session, engine service, advanced workflows, CLI, packaging boundaries, version contracts. |
| `docs/` | `native-migration.md` (architecture, build, upgrade boundaries) and `native-contract.md` (wire protocol). |
| `dist/` | Generated deliverables: `dist/python` (wheel, sdist) and `dist/GUI` (`Mantis.app`, DMG, checksum). Git-ignored. |

## Documentation

- **[Native Migration & Architecture Guide](docs/native-migration.md)**: Full architecture specification, build workflows, and upgrade boundaries.
- **[Engine Protocol Specification](docs/native-contract.md)**: Wire protocol contract between the native GUI and the numerical engine.

## References

Please cite the following reference when using MANTiS for your research:

> Lerotic M, Mak R, Wirick S, Meirer F, Jacobsen C. *MANTiS: a program for the analysis of X-ray spectromicroscopy data*. **J. Synchrotron Rad.** 2014 Sep; 21(5); 1206–1212 [http://dx.doi.org/10.1107/S1600577514013964](http://dx.doi.org/10.1107/S1600577514013964)
