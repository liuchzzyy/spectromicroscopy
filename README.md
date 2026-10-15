# Spectromicroscopy #
[Spectromicroscopy](http://spectromicroscopy.com) combines spectral data with microscopy,
where typical datasets consist of a stack of microscopic images
taken across an energy range. Due to the data complexity, manual analysis 
can be time consuming and inefficient, whereas multivariate analysis tools 
not only reduce the time needed but also can uncover hidden trends in the data.

# Mantis #
[MANTiS](http://spectromicroscopy.com) is Multivariate ANalysis Tool for Spectromicroscopy developed in Python by [2nd Look Consulting](http://2ndlookconsulting.com). It uses principal component analysis and cluster analysis to classify pixels according to spectral similarity.

## Native macOS migration (unreleased source branch)

This branch turns MANTiS into a single Qt-free Python distribution that provides the
numerical library, the JSON-lines engine **and** the command-line interface, plus a
native SwiftUI/AppKit macOS GUI (`GUI/`). The GUI bundles its own frozen engine and
never calls the Python distribution, so upgrading either side does not replace the
other.

Current source versions: macOS GUI **1.0.1** (build **2**), Python
CLI/library/engine **3.3.1**. The JSON-lines protocol remains **1**.

See **[build, CLI commands, architecture and upgrade boundaries](docs/native-migration.md)**
and the [engine protocol](docs/native-contract.md). These changes are not yet
published to PyPI or GitHub Releases. The upstream instructions below describe
the historical 3.3.0 release, **not this source branch**.

```sh
uv python install 3.12
uv sync --locked --python 3.12 --all-extras
uv run --locked --all-extras mantis-xray --help    # or: uv run --locked python -m mantis_xray --help
```

> The distribution keeps the name `mantis-xray`, which is also the name of the
> historical PyPI Qt release: always sync from this checkout rather than
> installing the similarly named PyPI distribution. This branch targets Python 3.12;
> `uv.lock` pins the resolved runtime and optional development/format dependencies.
> Run tests with `uv run --locked --all-extras pytest -q`. The upstream instructions
> below refer only to the historical release.

## Repository layout

| Path | Contents |
|---|---|
| `mantis_xray/` | The whole Python distribution: numerical core (`analysis/`, `core/`, `file_plugins/`), CLI (`cli.py`, `batch.py`), JSON-lines engine (`service.py`) and the packaged batch-settings template. No Qt. |
| `GUI/` | Native SwiftUI/AppKit macOS app: Swift package (`Sources/`, `Tests/`), `Info.plist`. |
| `scripts/` | `build_gui.sh` (app + DMG), `smoke_engine.py` (frozen-engine acceptance), `check_distributions.py` (wheel inspection), `engine_entry.py`. |
| `tests/` | Python suite: algorithms, session, engine service, advanced workflows, CLI, packaging boundaries. |
| `docs/` | `native-migration.md` (architecture, build, upgrade boundaries) and `native-contract.md` (wire protocol). |
| `dist/` | Generated deliverables only — `dist/python` (wheel, sdist) and `dist/GUI` (`Mantis.app`, DMG, checksum). Git-ignored. |
| `old/` | Untracked backup of the pre-migration Qt code, the historical Qt user guide and its screenshots. Nothing imports it; safe to delete. |

Build intermediates never enter the tree: `scripts/build_gui.sh` keeps PyInstaller work,
its spec file and the DMG staging area in a temporary directory and removes them on
exit, so `dist/` is the only generated path left behind (and it is Git-ignored, so the
DMG never affects repository size or diffs).


## Upstream historical download ##
Mantis package and binaries can be downloaded from 
[spectromicroscopy.com](http://spectromicroscopy.com).
Alternatively, you can install [Python](https://www.python.org/downloads/) and then run the command: `python3 -m pip install mantis-xray`

## Update ##
You can upgrade to the latest package release with the command: `pip3 install mantis-xray -U`.
It is recommended that you also upgrade the dependencies with: `pip3 install mantis-xray -U --upgrade-strategy "eager"`

## Run ##
Installation via pip provides the `mantis-xray` command (alternatively `python3 -m mantis_xray`) to start the Mantis GUI.

## User Guide ##
Mantis User Guide can be found at [https://docs.spectromicroscopy.com/](https://docs.spectromicroscopy.com/).

## References ##

Please use the following reference when quoting Mantis

Lerotic M, Mak R, Wirick S, Meirer F, Jacobsen C. MANTiS: a program for the analysis of X-ray spectromicroscopy data. J. Synchrotron Rad. 2014 Sep; 21(5); 1206–1212 [http://dx.doi.org/10.1107/S1600577514013964]
