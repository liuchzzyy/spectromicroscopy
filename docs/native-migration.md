# Native migration: architecture and upgrade boundaries

This is an **unreleased source migration** of upstream MANTiS 3.3.0. It does not change any upstream PyPI publication or GitHub Release.

## Two components

| Component | Source | Version owner | Runtime dependencies |
|---|---|---|---|
| Python distribution: library, JSON-lines engine **and** CLI | `mantis_xray/` (`analysis`, `core`, `file_plugins`, `cli.py`, `batch.py`, `service.py`) | `mantis_xray.__version__` / `pyproject.toml` | Scientific Python; no Qt |
| macOS GUI | `GUI/` | `GUI/Info.plist` | SwiftUI/AppKit + private frozen engine bundled in `.app` |

One Python distribution installs a library, three console scripts (`mantis-xray`, `mantis`, `mantis-engine`) and the engine module; `python -m mantis_xray` is the same CLI. There is no separate CLI package and no inter-package dependency edge, so there is nothing that can resolve to a different MANTiS version: install this checkout and the CLI, the importable library and the engine always agree.

The GUI is a **fully separate product**. It must not discover `mantis-xray` via `$PATH`, import `mantis_xray`, or use the user's Python environment. Its engine is `Mantis.app/Contents/Resources/engine/mantis-engine`, a frozen copy bundled inside the app. GUI updates replace the app **and that private engine only**; CLI upgrades happen in a separate Python environment and cannot replace the engine inside the app, and replacing the app cannot change the Python distribution. The core is shared **source**, not shared mutable installation state.

> **Name collision to keep in mind.** This distribution is named `mantis-xray`, the same name and the same `3.3.0` version as the historical Qt-based release on PyPI. Use `uv sync --locked --python 3.12 --all-extras` from this checkout; installing a bare `mantis-xray` requirement would fetch the upstream Qt package instead of this code.

JSON Lines protocol version **1** is independent of GUI and Python versions. A handshake checks protocol and enumerates supported operations. Breaking protocol changes require a new protocol version and compatibility handling, not equality of product version strings. See [wire contract](native-contract.md).

## Installation and CLI usage

```sh
uv python install 3.12
uv sync --locked --python 3.12 --all-extras
uv run --locked --all-extras mantis-xray --help
uv run --locked --all-extras mantis-xray inspect /absolute/path/stack.npz
uv run --locked --all-extras mantis-xray analyze /absolute/path/stack.npz --pre-normalized \
  --components 3 --clusters 4 --seed 0 --output /absolute/path/results.npz
```

`--pre-normalized` is an explicit declaration that input values **already are OD**; do not use it for raw transmission. For raw data use `--i0 incident_spectrum.csv`. No automatic normalization, smoothing, energy-duplicate averaging, or extrapolation should be inferred from opening a file.

Scripted use can equally import the library (`from mantis_xray.core.session import Session`) or speak the JSON-lines protocol through `mantis-engine`; all three entry points share one implementation.

`mantis-xray batch settings.txt` and `python -m mantis_xray --batch settings.txt` translate the legacy settings format into shared-core operations. Settings are strictly validated (unknown keys fail instead of being ignored); relative paths are resolved against the settings file's directory. Legacy image export filenames/layouts are not a byte-for-byte compatibility promise. With the default settings only `<WORK_DIR>/<OUTPUT_DIR_NAME>/<input-stem>_analysis.png` is saved; set `SAVE_HDF5: 1` to retain full-resolution numeric data/PCA/clustering results in `<input-stem>_analysis.hdf5`. PNG/PDF/SVG exports are preview images, not substitutes for the numeric export. `python -m mantis_xray` runs this CLI directly; it no longer starts a GUI.

Pipelines expose all engine operations without growing coupled frontend logic:

```json
{
  "protocol": 1,
  "steps": [
    {"method":"open","params":{"path":"stack.npz"}},
    {"method":"normalize","params":{"mode":"file","path":"i0.csv"}},
    {"method":"pca","params":{"components":3}},
    {"method":"cluster","params":{"clusters":4,"components":3,"seed":0}},
    {"method":"export","params":{"path":"results.h5","format":"hdf5"}}
  ]
}
```

Run `uv run --locked --all-extras mantis-xray pipeline pipeline.json`. Relative input/output paths are relative to the pipeline file, not shell working directory. Intermediate arrays remain in memory until an explicit `export` step; exported numeric arrays are full resolution, whereas graphics are preview figures. Parent directories are created on export. Formats must match suffixes (`npz`→`.npz`, `hdf5`→`.h5`/`.hdf`/`.hdf5`, graphics/CSV their matching suffix); paths/filenames are otherwise chosen by the caller. stdout is machine-readable JSON (the last snapshot plus `exported_paths` in execution order); diagnostic output is stderr. A failed step exits nonzero and lists earlier successful exports on stderr; earlier successful exports are not rolled back. Exporting over any input read in the current run (including datasets, I0/reference files, workflow/settings files) is forbidden; replacing another existing output requires an explicit `overwrite` parameter (`false` by default). An existing destination remains intact on a failed export; neither a run-level manifest nor a separate intermediate-data directory is created.

## Standalone native app

Prerequisites: Apple Silicon macOS, full Xcode with Swift toolchain, and the above scientific build environment. Runtime minimum is macOS 14. The installed app needs neither Python nor a CLI installation.

```sh
swift test --package-path GUI -c release
bash scripts/build_gui.sh
hdiutil verify dist/GUI/Mantis-1.0.0-arm64.dmg
(cd dist/GUI && shasum -a 256 -c Mantis-1.0.0-arm64.dmg.sha256)
```

The build script freezes the engine, compiles the native GUI, signs the app ad hoc, runs a **standalone process smoke test with no `PYTHONPATH` or CLI**, and builds an arm64 DMG plus checksum. That smoke test drives the real JSON-line engine through handshake, open, PCA with the scree-selected component count, clustering, numeric export and every graphics format (`png`/`pdf`/`svg`); the frozen bundle must therefore include those matplotlib backends, and a missing one fails the build instead of surfacing as a broken export in the GUI. Open the DMG and drag Mantis.app to Applications. It does not install the app automatically. Local ad-hoc signatures verify integrity, **not developer identity**; no Apple Developer ID signing or notarization has been configured. Distribution beyond local testing requires proper signing/notarization and a tested release process.

### Exercising the installed app

The app accepts an explicit opt-in automation harness that drives the real window and the private bundled engine, never demonstration data:

```sh
open -n dist/GUI/Mantis.app --args --smoke-report /tmp/report.json \
  --smoke-open /absolute/synthetic.npz --smoke-pre-normalized --smoke-export /tmp/result.npz
```

It writes a JSON report (window visibility and content size, handshake state, image count, PCA state) and exits. Launch it through `open` (not by exec'ing the bundle binary) and do not run other app instances concurrently. This is the end-to-end check for the app↔engine boundary.

## Build outputs

Nothing is written into the source tree except deliverables:

| Path | Contents | Reproducible |
|---|---|---|
| `dist/python/` | `mantis-xray` wheel and sdist (`uv build --out-dir dist/python`) | yes, delete anytime |
| `dist/GUI/` | `Mantis.app`, `Mantis-<version>-arm64.dmg`, its `.sha256` | yes, rebuilt by `scripts/build_gui.sh` |
| temporary `mantis-gui-build.*` | PyInstaller work/dist/spec, DMG staging | removed by the build script on exit |

`dist/` is Git-ignored, so the DMG never enters version control. Both CI workflows and local builds write only here; a wheel edit cannot trigger a native rebuild, and a GUI-only edit cannot change the Python distribution. A change under `mantis_xray/**` triggers both test paths because the GUI bundles the engine built from that source.

## Preservation and validation

- Original GPL-3.0-or-later licensing and scientific citations remain applicable; the license ships inside the wheel and inside the app bundle.
- Numerical algorithms stay in Python; Swift is responsible for interaction and rendering, not a new unvalidated implementation of PCA/NNMA.
- Original source data and processed state must remain distinguishable; operations log parameters and deterministic seeds.
- Display images may be downsampled; numerical exports must retain full-resolution arrays. Display contrast does not change analyzed data.
- The old Qt interface remains recoverable from Git history at `021e1af`; it is not shipped as an optional fallback in the migrated distribution. A convenience copy of it, the historical Qt user guide and its screenshots live in the untracked `old/` directory.
- Synthetic fixtures are software tests, not evidence of correctness on all beamline formats or experimental datasets. Facility-specific formats, large 4D workloads and interactive parity require explicit acceptance records; passing unit tests alone is not a blanket scientific validation.
- Verified in the initial migration: 102 Python tests (core, session, service, advanced workflows, CLI, packaging), 17 Swift tests, a single `mantis-xray` wheel carrying library + engine + CLI with no Qt or Swift content and all three console scripts, an ad-hoc-signed arm64 app, a frozen-engine smoke test covering `png`/`pdf`/`svg` exports, and one GUI run of the real window plus private engine (`open` → `pca` → numeric export) under `env -i`. These counts describe the original migration, not the current suite. Interactive acceptance of every panel, facility file formats, large 4D tomographic workloads, and Developer ID signing/notarization remain untested.
