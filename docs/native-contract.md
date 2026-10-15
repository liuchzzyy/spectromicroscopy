# Native migration implementation contract (protocol v1)

The existing numerical algorithms remain Python. No Qt imports in the core or CLI.
Native SwiftUI/AppKit app communicates with its **private bundled engine** over JSON Lines stdin/stdout, never through the user-installed CLI. CLI and GUI versions/builds are independent; protocol is versioned separately.

## Wire

Launch `python -m mantis_xray.service` in development, or bundled `engine/mantis-engine` in the app. Each line request is `{"id":1,"protocol":1,"method":"open","params":{"path":"/absolute/file"}}`.
Response: `{"id":1,"protocol":1,"ok":true,"result":{...}}` or `{"id":1,"protocol":1,"ok":false,"error":{"code":"invalid_request","message":"..."}}`. All diagnostic output goes to stderr. `hello` works without a dataset and returns `{"engine_version":"3.3.0","protocol":1,"capabilities":[method names]}`. Unknown protocol/method is a structured error. Sequential requests, session state is private to one process. GUI executes I/O off main thread, disables mutations during requests, cancellation terminates/reaps engine and explicitly resets the session.

All analysis commands return a snapshot (below), with optional additional numeric results. Methods `hello` and `inspect_file` can return distinct records. `export` returns a snapshot plus `exported_path`. Image matrices are small display representations only, **not data export**; analysis and numeric exports retain full resolution. Images bound each preview dimension to 256 and record full_width/full_height. The optional `origin_x`, `origin_y`, `visible_width`, `visible_height` describe a source-pixel viewport; `minimum`, `maximum`, `mean`, and 32-bin (or fewer when floating-point spacing cannot represent distinct edges) `histogram_counts`/`histogram_edges` describe **all source pixels in that visible image**, not just the sampled preview. Optional `spatial` holds full-length x/y coordinate arrays and a unit only when recognized source metadata provides one; unlabeled coordinates are not presumed to be µm. Axes refer to input array [x,y,energy]; display images have rows y and columns x.

## Snapshot

```
{
 "source":"...", "shape":[width,height,energy_count], "energies":[...],
 "normalized":false, "pca_ready":false, "clusters_ready":false,
 "energy_index":0,"selected_x":0,"selected_y":0,
 "images":[{"title":"Intensity","width":2,"height":2,"values":[1,2,3,4],"full_width":2,"full_height":2,
            "origin_x":0,"origin_y":0,"visible_width":2,"visible_height":2,
            "minimum":1,"maximum":4,"mean":2.5,"histogram_counts":[1,1,1,1],
            "histogram_edges":[1,1.75,2.5,3.25,4]}],
 "spatial":{"x":[0,0.05],"y":[0,0.05],"unit":"µm"},
 "spectra":[{"name":"Pixel","x":[280,281],"y":[4,5]}],
 "metrics":{"key":"string value"}, "history":[{"method":"...","params":{}}]
}
```
All JSON numbers must be finite; invalid scientific inputs fail explicitly, never silently smooth or clip. `history` records parameters, deterministic seeds, source hashes where practicable.

## Base methods and parameters

- `open`: path; optional selection [[region,channel]], optional `pre_normalized` bool (explicit opt in). Support existing file plugins plus NPZ (`data` [x,y,e] or [x,y,e,theta], `energies`, optional `theta`, `i0`). Retain original data, no auto duplicate averaging. Handle duplicate energies explicitly, never silently repair.
- `inspect_file`: path; return available plugin/selection metadata.
- `build_stack`: paths (single-frame files), energies list.
- `view`: energy_index, x, y, optional display `intensity`/`od`; optional rectangle ROI [x0,y0,x1,y1] (exclusive upper bounds), polygon list of [x,y], or **display-only** `viewport` [x0,y0,x1,y1] (exclusive upper bounds). Optional `rois` is an explicit list of up to 10 ROI definitions, each with either `bounds` or `polygon` plus `label`; `rois: []` clears saved ROIs and the selected mask. The viewport resamples the selected source-data region to at most 256×256; spectra, ROI analysis, stored arrays, processing history and numeric export remain full resolution. Empty or out-of-bounds intervals are rejected. Returns ROI spectra and an active ROI histogram when selected, otherwise the full-image spectrum and histogram; no mutation of underlying data.
- `normalize`: mode `file` with path (two-column CSV/XAS), `roi` with bounds, `histogram` with min/max, or `pre_normalized`. Validate positive transmission/I0; no silent repairs.
- `crop`: bounds [x0,y0,x1,y1], energy_range [first,last_exclusive]. Invalidate downstream analyses.
- `dark`: value; explicit subtract, validate.
- `despike`: sigma; explicit processing with provenance.
- `align`: reference (energy index), upsample_factor, optional manual_shifts [[dx,dy],...], crop bool. Retain reported shifts and invalidate analyses.
- `remove_image`: index. Keep coordinate axes consistent.
- `reset`: restore originally opened data and invalidate analyses.
- `pca`: components optional; use existing analyze.calculate_pca (do not replace PCA convention).
- `cluster`: clusters, components, remove_first bool, sigma_split bool, seed=0; existing analyze.calculate_clusters. Return cluster map and each cluster spectrum plus distance image and eigenvalue spectrum where useful.
- `export`: path; format `hdf5`/`npz`/`csv`/`png`/`pdf`/`svg`/`json`/`md`, optional `dpi` for graphics. HDF5/NPZ preserve source/history; by default include raw/processed data and numerical analyses. Optional `include` (NPZ/HDF5 only) is a nonempty unique list selected from `processed`, `raw`, `normalization` (only when normalized), `analysis`, `spectra`; numerical datasets are written only for selected groups, with spectra as `spectra/{x,y,name}/<index>`. Optional `spectrum_name` requires `spectra` in `include` and exactly one matching displayed spectrum; it exports only that spectrum to NPZ/HDF5. A selective raw-only HDF5/NPZ is an analysis artifact, not a re-importable processed stack. Never overwrite input. CSV exports displayed spectra, graphics exports current views with Agg. JSON/MD export the work log. Existing destination requires overwrite=true.

## Advanced methods and parameters

Implemented in `mantis_xray/core/advanced.py`, owning `ADVANCED_METHODS` and `dispatch_advanced(session, method, params)`. Base session (`core/session.py`) exposes `stack` (legacy data_stack.data), `analysis` (legacy analyze.analyze), `history` list, `results` dict for numerical exports, `require_normalized()`, `snapshot(images=None,spectra=None,metrics=None)` and `record(method,params)`. Helpers `image_record(title,array_xy)` and `spectrum_record(name,x,y)` module-level in session.py. Advanced code must validate before committing state. Advanced returns normal snapshots; parent base dispatch delegates known advanced names. No circular top-level imports; helpers import within functions if needed.

- `spectral`: paths list, add_clusters bool, flat bool, use_pca bool; load/remap references with original algorithms; maps and spectra, fit/residual where available. Optional remove index / move [from,to] for reference management.
- `rgb`: channels [0,1,2] referring to target maps; return images channel maps plus `rgb` image record with width,height,values interleaved RGB 0..1,channels=3. Scaling explicit display only.
- `nnma`: components, iterations, seed, initialization `random`/`clusters`/`standards`, paths, lambda_sparse, lambda_cluster, lambda_smooth. Reuse original NNMA algorithm; reject negatives rather than silently clamp user data. Show spectra/maps and convergence.
- `peaks`: threshold; use original peak detection and preserve predefined peak-ID reference table extracted from old GUI (with original labels/citations, no invented peak attribution).
- `fit_peaks`: path optional (otherwise ROI/pixel/current mean), steps, peaks, baseline, optional step_params, peak_amplitudes, peak_centers, peak_widths; original step+Gaussian fitter. Expose fitted spectrum, residual and parameters; don't fabricate fit certainty.
- `tomography`: energy_index, algorithm `sirt`/`tv`/`fbp`, iterations, beta; 4D input with explicit theta required. Reuse original supported algorithms and label any alternative accurately. Return central slice and export volume results. Optional slice_index for viewing volume slices.
- `key_energies`: threshold, PCA prerequisite; original algorithm.
- `spectral_roi`: pre [first,last_exclusive], post [first,last_exclusive]; map -log(mean(post intensity)/mean(pre intensity)), explicit positive validation.
- `dose`: parameters matching original Henke dose workflow, documented units; reject incomplete inputs.

## Ownership during implementation

Base worker owns core/session.py, service.py and tests/test_session.py, tests/test_service.py (and specific necessary legacy base algorithm fixes). Advanced worker owns core/advanced.py, core/peak_reference.py and tests/test_advanced.py (and necessary advanced legacy algorithm fixes). Native worker owns GUI/ (Swift package, models, views, tests, Info.plist), not root scripts. Parent owns CLI, root packaging/build/CI/docs, removal of Qt files and integration. No push, commit, installation or publication. Existing legacy GUI is available via `git show HEAD:path` after deletion.
