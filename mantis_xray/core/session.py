"""UI-independent scientific state, preserving MANTiS' [x,y,e] convention.

Legacy numerical algorithms are deliberately reused; validation and transactional
state boundaries belong here, not in either UI. Display arrays are never exports.
"""
from contextlib import redirect_stdout
import copy
import hashlib
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import numpy as np

# Historical plugins print during discovery. Never pollute machine-readable output.
with redirect_stdout(sys.stderr):
    from ..analysis import data_stack, data_struct, analyze


BASE_METHODS = ("open", "normalize", "intensity_to_od", "to_od", "pca", "cluster", "view", "crop", "dark",
                "remove_image", "reset", "despike", "align", "export", "inspect_file", "build_stack")


class SessionError(ValueError):
    def __init__(self, message, code="invalid_request"):
        super().__init__(message)
        self.code = code


def finite_array(value, name):
    try:
        array = np.asarray(value, dtype=float)
    except (ValueError, TypeError) as exc:
        raise SessionError(f"{name} must be numeric") from exc
    if not np.all(np.isfinite(array)):
        raise SessionError(f"{name} must contain only finite numbers")
    return array


def intensity_to_od(intensity, i0=None, min_intensity=1e-7):
    """Convert transmitted X-ray intensity to optical density (OD) via Beer-Lambert law.

    OD = -ln(I / I0)

    Parameters
    ----------
    intensity : array_like
        Transmitted X-ray intensity (1D spectrum, 2D image, 3D stack, or 4D stack).
    i0 : array_like or float, optional
        Incident beam intensity I0.
        - If provided as scalar or array, used directly.
        - If None:
            - If intensity values are normalized transmission (e.g. max <= 2.5),
              i0 defaults to 1.0 (OD = -ln(I)).
            - If intensity values are raw counts (max > 2.5), i0 defaults to the
              maximum spatial intensity per energy channel (OD = -ln(I / max(I))).
    min_intensity : float, optional
        Small positive floor to prevent division by zero or log of non-positive numbers.
        Default is 1e-7. If None, strict computation is performed without clipping.

    Returns
    -------
    ndarray
        Optical density array of the same shape as intensity.
    """
    arr = np.asarray(intensity, dtype=float)
    if arr.size == 0:
        return np.empty_like(arr)

    if i0 is None:
        finite_mask = np.isfinite(arr)
        if not np.any(finite_mask):
            raise ValueError("Intensity array contains no finite values")
        max_val = np.nanmax(arr[finite_mask])
        if max_val <= 2.5:
            i0_val = 1.0
        else:
            if arr.ndim >= 3:
                i0_val = np.nanmax(arr, axis=(0, 1), keepdims=True)
            elif arr.ndim == 2:
                i0_val = np.nanmax(arr, axis=0, keepdims=True)
            else:
                i0_val = np.nanmax(arr)
    else:
        i0_arr = np.asarray(i0, dtype=float)
        if arr.ndim == 4 and i0_arr.ndim == 1 and i0_arr.shape[0] == arr.shape[2]:
            i0_val = i0_arr[None, None, :, None]
        elif arr.ndim == 4 and i0_arr.ndim == 2 and i0_arr.shape == (arr.shape[2], arr.shape[3]):
            i0_val = i0_arr[None, None, :, :]
        elif arr.ndim == 3 and i0_arr.ndim == 1 and i0_arr.shape[0] == arr.shape[2]:
            i0_val = i0_arr[None, None, :]
        else:
            i0_val = i0_arr

    if min_intensity is not None:
        safe_i = np.maximum(arr, min_intensity)
        safe_i0 = np.maximum(i0_val, min_intensity)
        trans = np.maximum(safe_i / safe_i0, min_intensity)
    else:
        trans = arr / i0_val

    return -np.log(trans)


def _image_histogram(array):
    low, high = float(array.min()), float(array.max())
    if low == high:
        return np.histogram(array, bins=32)
    # Adjacent floating-point values cannot support 32 distinct bin intervals.
    # Reduce only the display bins; never round, smooth or change source values.
    edges = np.unique(np.linspace(low, high, 33))
    return np.histogram(array, bins=edges)


def image_record(title, array_xy, viewport=None, full_shape=None):
    array = finite_array(array_xy, title)
    if array.ndim != 2 or 0 in array.shape:
        raise SessionError("An image must be a nonempty [x,y] matrix")
    width, height = array.shape
    origin_x, origin_y = (viewport[:2] if viewport is not None else (0, 0))
    full_width, full_height = full_shape if full_shape is not None else (width, height)
    full_width, full_height = int(full_width), int(full_height)
    # Nearest sampled preview only. No alteration of the numerical data.
    xs = np.linspace(0, width - 1, min(width, 256), dtype=int)
    ys = np.linspace(0, height - 1, min(height, 256), dtype=int)
    preview = array[np.ix_(xs, ys)].T
    # Statistics use every source pixel in the visible frame, not the sampled
    # 256×256 display preview. They do not modify or smooth scientific data.
    counts, edges = _image_histogram(array)
    return {"title": str(title), "width": len(xs), "height": len(ys),
            "full_width": full_width, "full_height": full_height,
            "origin_x": origin_x, "origin_y": origin_y,
            "visible_width": width, "visible_height": height,
            "values": preview.ravel().tolist(), "minimum": float(array.min()),
            "maximum": float(array.max()), "mean": float(array.mean()),
            "histogram_counts": counts.tolist(), "histogram_edges": edges.tolist()}


def spectrum_record(name, x, y):
    x, y = finite_array(x, "spectrum x"), finite_array(y, "spectrum y")
    if x.ndim != 1 or y.shape != x.shape:
        raise SessionError("Spectrum axes must be equal-length vectors")
    return {"name": str(name), "x": x.tolist(), "y": y.tolist()}


def _private_structure(cls):
    # data_struct's legacy descriptors store values on the *class*, and nested
    # instances are class attributes. deepcopy(h5()) is therefore NOT isolated.
    node = SimpleNamespace()
    for name, value in vars(cls).items():
        if isinstance(value, data_struct.Descr):
            setattr(node, name, None)
        elif type(value).__module__ == data_struct.__name__:
            setattr(node, name, _private_structure(type(value)))
    return node


def _new_stack():
    stack = data_stack.data(_private_structure(data_struct.h5))
    stack.new_data()
    return stack


def _hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Session:
    def __init__(self):
        self.stack = _new_stack()
        self.analysis = analyze.analyze(self.stack)
        self.source = ""
        self._source_paths = []
        self._protected_paths = set()
        self.history = []
        self.results = {}
        self.normalized = False
        self.input_is_od = self._original_input_is_od = False
        self.energy_index = self.selected_x = self.selected_y = 0
        self.display = "intensity"
        self.roi_mask = None
        self.rois = []
        self.viewport = None
        self.spatial_unit = None
        self.pixel_sizes = {}
        self._original = None
        self._raw_original = None
        self._last_snapshot = None

    def record(self, method, params):
        self.history.append({"method": method, "params": copy.deepcopy(params)})

    def protect_inputs(self, paths):
        """Protect workflow/settings files in addition to the loaded scientific inputs."""
        self._protected_paths.update(Path(path).expanduser().resolve() for path in paths)

    def require_data(self):
        if not self.source:
            raise SessionError("Open a dataset first", "invalid_state")

    def require_normalized(self):
        self.require_data()
        if not self.normalized:
            raise SessionError("Normalize the dataset first", "invalid_state")

    def dispatch(self, method, params=None):
        params = {} if params is None else params
        if not isinstance(params, dict):
            raise SessionError("params must be an object")
        from .advanced import ADVANCED_METHODS, dispatch_advanced
        with redirect_stdout(sys.stderr):
            if method in ADVANCED_METHODS:
                self.require_data()
                # Reserve reference inputs before analysis: even a failed fit must
                # not allow a later export to replace a file already read.
                paths = params.get("paths", [])
                if isinstance(paths, list):
                    self.protect_inputs(path for path in paths if isinstance(path, str) and path)
                path = params.get("path")
                if isinstance(path, str) and path:
                    self.protect_inputs((path,))
                return dispatch_advanced(self, method, params)
            if method not in BASE_METHODS:
                raise SessionError(f"Unknown method: {method}", "unknown_method")
            return getattr(self, method)(**params)

    def _make_stack(self, values, energies, theta=None, x=None, y=None):
        values, energies = finite_array(values, "data"), finite_array(energies, "energies")
        if values.ndim not in (3, 4) or 0 in values.shape:
            raise SessionError("Data must have nonempty shape [x,y,energy] or [x,y,energy,theta]")
        if energies.ndim != 1 or len(energies) != values.shape[2]:
            raise SessionError("energies must match the data energy dimension")
        if len(np.unique(energies)) != len(energies):
            raise SessionError("Duplicate energies are not supported; resolve them explicitly")
        if len(energies) > 1 and np.any(np.diff(energies) <= 0):
            raise SessionError("energies must be strictly increasing (no implicit reordering)")
        stack = _new_stack()
        stack.n_cols, stack.n_rows, stack.n_ev = values.shape[:3]
        stack.ev = energies.copy()
        stack.absdata = values[:, :, :, 0].copy() if values.ndim == 4 else values.copy()
        if values.ndim == 4:
            theta = finite_array(theta, "theta")
            if theta.shape != (values.shape[3],):
                raise SessionError("4D data requires an explicit theta vector")
            stack.stack4D = values.copy()
            stack.theta = theta.copy()
            stack.n_theta = len(theta)
        stack.x_dist = np.arange(stack.n_cols, dtype=float) if x is None else finite_array(x, "x").copy()
        stack.y_dist = np.arange(stack.n_rows, dtype=float) if y is None else finite_array(y, "y").copy()
        if stack.x_dist.shape != (stack.n_cols,) or stack.y_dist.shape != (stack.n_rows,):
            raise SessionError("Spatial coordinates must match data dimensions")
        stack.data_dwell = np.ones(stack.n_ev)
        stack.fill_h5_struct_from_stk()
        if stack.stack4D is not None:
            stack.data_struct.exchange.data = stack.stack4D
            stack.data_struct.exchange.theta = stack.theta
            stack.data_struct.exchange.data_axes = "x:y:energy:theta"
        stack.setScale()
        return stack

    @staticmethod
    def _file_path(path):
        if not isinstance(path, (str, Path)) or not str(path):
            raise SessionError("path must be a nonempty file path")
        path = Path(path).expanduser().resolve()
        if not path.is_file():
            raise SessionError(f"File not found: {path}", "file_error")
        return path

    def inspect_file(self, path):
        path = self._file_path(path)
        if path.suffix.lower() == ".npz":
            with np.load(path, allow_pickle=False) as archive:
                if not {"data", "energies"}.issubset(archive.files):
                    raise SessionError("NPZ requires data and energies arrays")
                return {"path": str(path), "plugin": "MANTiS NPZ", "selections": [],
                        "shape": list(archive["data"].shape), "arrays": list(archive.files)}
        if path.suffix.lower() in (".h5", ".hdf5", ".hdf"):
            import h5py
            with h5py.File(path, "r") as archive:
                if "mantis_session_version" in archive.attrs:
                    return {"path": str(path), "plugin": "MANTiS session HDF5", "selections": [],
                            "shape": list(archive["exchange/data"].shape)}
        from .. import file_plugins
        plugin = file_plugins.identify(str(path))
        if plugin is None:
            raise SessionError(f"Unsupported file format: {path.suffix}", "unsupported_format")
        structure = file_plugins.GetFileStructure(str(path), plugin=plugin)
        selections = []
        for region, (name, channels) in enumerate((structure or {}).items()):
            for channel, label in enumerate(channels):
                selections.append({"selection": [region, channel], "region": str(name), "channel": str(label)})
        return {"path": str(path), "plugin": plugin.title, "selections": selections}

    def _load_plugin(self, path, selection):
        from .. import file_plugins
        plugin = file_plugins.identify(str(path))
        if plugin is None:
            raise SessionError(f"Unsupported file format: {path.suffix}", "unsupported_format")
        if path.suffix.lower() in (".tif", ".tiff"):
            # TIFF rows are y; retain input ordering rather than the legacy reader's
            # implicit energy sorting. Energies must be supplied by a sidecar.
            from PIL import Image, ImageSequence
            with Image.open(path) as image:
                frames = [np.asarray(frame).T.copy() for frame in ImageSequence.Iterator(image)]
            energies = np.loadtxt(path.with_suffix(".txt"), comments="*")
            return self._make_stack(np.stack(frames, axis=2), np.atleast_1d(energies))
        info = self.inspect_file(path)
        available = [row["selection"] for row in info["selections"]]
        if selection is None and available:
            if len(available) != 1:
                raise SessionError("Explicit selection is required; use inspect_file")
            selection = [available[0]]
        if selection is not None:
            if (not isinstance(selection, (list, tuple)) or not selection or
                    any(not isinstance(pair, (list, tuple)) or len(pair) != 2 or
                        any(type(index) is not int or index < 0 for index in pair) for pair in selection)):
                raise SessionError("selection must be nonempty [[region,channel], ...]")
            if available and any(list(pair) not in available for pair in selection):
                raise SessionError("selection is not available in this file")
            if not available:
                raise SessionError("This file has no selectable regions; omit selection")
        # NeXus plugin's private third coordinate enables ring-current correction.
        # Protocol v1 only selects region/channel; never opt into correction.
        plugin_selection = ([list(pair) + [0] for pair in selection]
                            if plugin.title == "NXstxm" else selection)
        stack = _new_stack()
        file_plugins.load(str(path), stack, plugin=plugin, selection=plugin_selection)
        # Validate independently without stripping plugin metadata/dwell times.
        self._make_stack(stack.absdata if stack.stack4D is None else stack.stack4D,
                         stack.ev, stack.theta if stack.stack4D is not None else None,
                         stack.x_dist, stack.y_dist)
        return stack

    def build_stack(self, paths, energies):
        if not isinstance(paths, (list, tuple)) or not paths:
            raise SessionError("paths must be a nonempty list")
        energies = finite_array(energies, "energies")
        if energies.shape != (len(paths),):
            raise SessionError("energies must match paths")
        files = [self._file_path(path) for path in paths]
        frames = []
        for path in files:
            if path.suffix.lower() in (".tif", ".tiff"):
                from PIL import Image
                with Image.open(path) as image:
                    if image.n_frames != 1:
                        raise SessionError("build_stack requires single-frame files")
                    frame = np.asarray(image).T.copy()
            else:
                item = Session()
                item.open(path)
                if item.stack.n_ev != 1 or item.stack.stack4D is not None:
                    raise SessionError("build_stack requires single-frame files")
                frame = item.stack.absdata[:, :, 0]
            if frame.ndim != 2 or frames and frame.shape != frames[0].shape:
                raise SessionError("Frames must be grayscale with identical dimensions")
            frames.append(frame)
        stack = self._make_stack(np.stack(frames, axis=2), energies)
        params = {"paths": [str(path) for path in files], "energies": energies.tolist(),
                  "sha256": [_hash(path) for path in files]}
        self.stack, self.source = stack, str(files[0])
        self._source_paths = files
        self._protected_paths.update(files)
        self.history, self.results = [], {}
        self.normalized, self.display = False, "intensity"
        self.input_is_od = self._original_input_is_od = False
        self.viewport, self.spatial_unit = None, None
        self.pixel_sizes = {}
        self.energy_index = self.selected_x = self.selected_y = 0
        self.roi_mask = None
        self.rois = []
        self._original = copy.deepcopy(stack)
        self._raw_original = copy.deepcopy(stack)
        self._invalidate()
        self.record("build_stack", params)
        return self.snapshot()

    def open(self, path, pre_normalized=False, selection=None):
        path = Path(path).expanduser().resolve()
        if not path.is_file():
            raise SessionError(f"File not found: {path}", "file_error")
        raw_original = None
        spatial_unit = None
        pixel_sizes = {}
        stored_input_is_od = False
        embedded_od = None
        embedded_i0 = embedded_i0_energies = None
        if path.suffix.lower() == ".npz":
            with np.load(path, allow_pickle=False) as archive:
                if not {"data", "energies"}.issubset(archive.files):
                    raise SessionError("NPZ requires data and energies arrays")
                stack = self._make_stack(archive["data"], archive["energies"], archive.get("theta"),
                                         archive.get("x"), archive.get("y"))
                if "spatial_unit" in archive:
                    raw_unit = archive["spatial_unit"]
                    if raw_unit.shape != ():
                        raise SessionError("spatial_unit must be a scalar string")
                    spatial_unit = str(raw_unit.item()) or None
                pixel_sizes = {key: float(archive[key].item()) for key in ("x_pixel_size", "y_pixel_size") if key in archive}
                if "input_is_od" in archive:
                    flag = archive["input_is_od"]
                    if flag.shape != () or flag.dtype.kind != "b":
                        raise SessionError("input_is_od must be a scalar boolean")
                    stored_input_is_od = bool(flag.item())
                embedded_od = archive.get("od")
                embedded_i0 = archive.get("i0")
                embedded_i0_energies = archive.get("i0_energies", stack.ev)
                if "raw_data" in archive:
                    raw_original = self._make_stack(archive["raw_data"], archive["raw_energies"],
                                                    archive.get("raw_theta", archive.get("theta")),
                                                    archive.get("raw_x"), archive.get("raw_y"))
        elif path.suffix.lower() in (".h5", ".hdf5", ".hdf"):
            import h5py
            with h5py.File(path, "r") as archive:
                if all(key in archive for key in ("exchange/data", "exchange/energy")):
                    # Read Exchange axes before legacy plugins can sort or repair.
                    read = lambda key: archive[key][()] if key in archive else None
                    stack = self._make_stack(read("exchange/data"), read("exchange/energy"),
                                             read("exchange/theta"), read("exchange/x"), read("exchange/y"))
                    if "provenance/spatial_unit" in archive:
                        raw_unit = archive["provenance/spatial_unit"][()]
                        spatial_unit = (raw_unit.decode("utf-8") if isinstance(raw_unit, bytes) else str(raw_unit)) or None
                    pixel_sizes = {key: float(archive[f"provenance/{key}"][()]) for key in ("x_pixel_size", "y_pixel_size")
                                   if f"provenance/{key}" in archive}
                    if "provenance/input_is_od" in archive:
                        flag = np.asarray(archive["provenance/input_is_od"][()])
                        if flag.shape != () or flag.dtype.kind != "b":
                            raise SessionError("input_is_od must be a scalar boolean")
                        stored_input_is_od = bool(flag.item())
                    embedded_od = read("normalization/od")
                    embedded_i0 = read("normalization/i0")
                    embedded_i0_energies = read("normalization/energy")
                    if embedded_i0 is None:
                        embedded_i0 = read("spectromicroscopy/normalization/white_spectrum")
                        embedded_i0_energies = read("spectromicroscopy/normalization/white_spectrum_energy")
                    if embedded_i0_energies is None:
                        embedded_i0_energies = stack.ev
                    if "raw/data" in archive:
                        theta = read("raw/theta")
                        raw_original = self._make_stack(read("raw/data"), read("raw/energy"),
                                                        read("exchange/theta") if theta is None else theta,
                                                        read("raw/x"), read("raw/y"))
                else:
                    stack = self._load_plugin(path, selection)
        else:
            stack = self._load_plugin(path, selection)
        if embedded_od is not None:
            embedded_od = finite_array(embedded_od, "optical density")
            shape = stack.absdata.shape if stack.stack4D is None else stack.stack4D.shape
            if embedded_od.shape != shape:
                raise SessionError("Stored optical density shape does not match data")
            stack.od3d = embedded_od if stack.stack4D is None else embedded_od[:, :, :, 0].copy()
            if stack.stack4D is not None:
                stack.od4d = embedded_od
            stack.od = stack.od3d.reshape(-1, stack.n_ev, order="F").copy()
        if not isinstance(pre_normalized, bool):
            raise SessionError("pre_normalized must be boolean")
        if embedded_i0 is not None:
            incident = finite_array(embedded_i0, "I0")
            axes = finite_array(embedded_i0_energies, "I0 energies")
            allowed = [(len(axes),)] if axes.ndim == 1 else []
            if stack.stack4D is not None and axes.ndim == 1:
                allowed.append((len(axes), stack.n_theta))
            if incident.shape not in allowed or np.any(incident <= 0):
                raise SessionError("I0 must be positive with shape [energy] or [energy,theta]")
            stack.i0data, stack.evi0 = incident.copy(), axes.copy()
            stack.i0_dwell = stack.data_dwell
            if embedded_od is None and not pre_normalized:
                stack.calculate_optical_density()
            stack.fill_h5_struct_normalization()
        input_is_od = pre_normalized or stored_input_is_od
        if input_is_od:
            stack.UsePreNormalizedData()
        # Only recognized source metadata supplies a physical unit. Coordinate arrays
        # alone (e.g. NPZ fallback indices) do not establish micrometers.
        if path.suffix.lower() == ".hdr":
            from ..file_plugins.file_sdf import HDR_FileParser
            header = HDR_FileParser(str(path)).hdr
            regions = header["ScanDefinition"]["Regions"]
            if len(regions) > 1:
                xunit = regions[1]["PAxis"].get("Unit")
                yunit = regions[1]["QAxis"].get("Unit")
                if xunit == yunit and xunit in ("um", "µm"):
                    spatial_unit = "µm"
        elif path.suffix.lower() in (".h5", ".hdf5", ".hdf"):
            import h5py
            with h5py.File(path, "r") as source_file:
                if ("SpecNormalized/x_pixel_size" in source_file and
                        "SpecNormalized/y_pixel_size" in source_file):
                    spatial_unit = "µm"  # MISTRAL pixel-size fields are in micrometers.
                    pixel_sizes = {key: float(np.asarray(source_file[f"SpecNormalized/{key}"][()]).item())
                                   for key in ("x_pixel_size", "y_pixel_size")}
                elif "exchange/x" in source_file and "exchange/y" in source_file:
                    xunit = source_file["exchange/x"].attrs.get("units")
                    yunit = source_file["exchange/y"].attrs.get("units")
                    if isinstance(xunit, bytes):
                        xunit = xunit.decode("utf-8", errors="replace")
                    if isinstance(yunit, bytes):
                        yunit = yunit.decode("utf-8", errors="replace")
                    if xunit == yunit and isinstance(xunit, str) and xunit.strip() and "\ufffd" not in xunit:
                        spatial_unit = xunit.strip()
        # Calibrated axes are a fallback only when no explicit pixel size exists.
        # Capture once at import, not from a cropped/zoomed preview.
        if spatial_unit is not None:
            for key, axis in (("x_pixel_size", stack.x_dist), ("y_pixel_size", stack.y_dist)):
                steps = np.abs(np.diff(np.asarray(axis, dtype=float)))
                if key not in pixel_sizes and steps.size and steps[0] > 0 and np.allclose(steps, steps[0], rtol=1e-3, atol=1e-9):
                    pixel_sizes[key] = float(steps[0])
        if any(not np.isfinite(value) or value <= 0 for value in pixel_sizes.values()):
            raise SessionError("Source pixel sizes must be positive finite numbers")
        self.stack = stack
        self.spatial_unit = spatial_unit
        self.pixel_sizes = pixel_sizes
        self.viewport = None
        self.source = str(path)
        self._source_paths = [path]
        self._protected_paths.add(path)
        self.analysis = analyze.analyze(stack)
        self.history, self.results = [], {}
        self.input_is_od = self._original_input_is_od = input_is_od
        self.normalized = input_is_od or embedded_od is not None or embedded_i0 is not None
        self.energy_index = self.selected_x = self.selected_y = 0
        self.roi_mask = None
        self.rois = []
        self.display = "od" if input_is_od else "intensity"
        self._original = copy.deepcopy(stack)
        self._raw_original = raw_original if raw_original is not None else copy.deepcopy(stack)
        self.record("open", {"path": str(path), "sha256": _hash(path),
                             "pre_normalized": pre_normalized, "selection": selection})
        return self.snapshot()

    def _invalidate(self):
        self.analysis = analyze.analyze(self.stack)
        self.results = {}
        self.roi_mask = None
        self.rois = []
        self._last_snapshot = None

    def _bounds(self, bounds):
        if not isinstance(bounds, (list, tuple)) or len(bounds) != 4 or any(type(v) is not int for v in bounds):
            raise SessionError("bounds must be four integer coordinates")
        x0, y0, x1, y1 = bounds
        if not (0 <= x0 < x1 <= self.stack.n_cols and 0 <= y0 < y1 <= self.stack.n_rows):
            raise SessionError("bounds must select a nonempty ROI inside the image")
        return x0, y0, x1, y1

    def normalize(self, mode, path=None, bounds=None, min=None, max=None, fraction_min=None):
        self.require_data()
        trial = copy.deepcopy(self.stack)
        params = {"mode": mode}
        if mode == "pre_normalized":
            trial.UsePreNormalizedData()
        else:
            values = trial.absdata if trial.stack4D is None else trial.stack4D
            if mode == "file":
                if path is None:
                    raise SessionError("file normalization requires path")
                rows = []
                for line in Path(path).read_text().splitlines():
                    line = line.strip()
                    if not line or line.startswith(("#", "*")):
                        continue
                    try:
                        row = [float(v) for v in line.replace(",", " ").split()]
                    except ValueError:
                        if not rows and line.lower().startswith(("energy", "ev")):
                            continue
                        raise SessionError("I0 file must contain two numeric columns")
                    if len(row) != 2:
                        raise SessionError("I0 file must contain two numeric columns")
                    rows.append(row)
                table = finite_array(rows, "I0")
                if table.ndim != 2 or table.shape[1] != 2:
                    raise SessionError("I0 file must contain two numeric columns")
                trial.evi0, trial.i0data = table[:, 0].copy(), table[:, 1].copy()
                params.update(path=str(Path(path).resolve()), sha256=_hash(path))
            elif mode in ("roi", "histogram"):
                mask = np.zeros((trial.n_cols, trial.n_rows), dtype=bool)
                if mode == "roi":
                    x0, y0, x1, y1 = self._bounds(bounds)
                    mask[x0:x1, y0:y1] = True
                    params["bounds"] = list(bounds)
                else:
                    flux = values.mean(axis=tuple(range(2, values.ndim)))
                    if fraction_min is not None:
                        fraction = float(finite_array(fraction_min, "fraction_min"))
                        if not 0 <= fraction <= 1 or min is not None:
                            raise SessionError("fraction_min must be in [0,1] and cannot accompany min")
                        min = fraction * float(flux.max())
                        params["fraction_min"] = fraction
                    if min is None or max is None and fraction_min is None:
                        raise SessionError("histogram requires min/max or fraction_min")
                    low = float(finite_array(min, "min"))
                    high = float(flux.max()) if max is None else float(finite_array(max, "max"))
                    if low > high:
                        raise SessionError("histogram min must not exceed max")
                    mask = (flux >= low) & (flux <= high)
                    params.update(min=low, max=high)
                if not mask.any():
                    raise SessionError("Normalization ROI is empty")
                trial.evi0 = trial.ev.copy()
                trial.i0data = values[mask].mean(axis=0)
                trial.i0_mask = mask
            else:
                raise SessionError(f"Unknown normalization mode: {mode}")
            trial.i0_dwell = trial.data_dwell
            trial.calculate_optical_density()
            trial.fill_h5_struct_normalization()
        self.stack = trial
        if mode == "file":
            self._protected_paths.add(Path(params["path"]))
        self.normalized = True
        if mode == "pre_normalized":
            self.input_is_od = True
        self._invalidate()
        self.display = "od"
        self.record("normalize", params)
        return self.snapshot()

    def ensure_od(self, i0=None):
        if self.input_is_od:
            return
        if getattr(self.stack, "od3d", None) is not None and not (
            isinstance(self.stack.od3d, (int, float)) and self.stack.od3d == 0
        ) and self.normalized:
            return
        raw = self.stack.absdata if self.stack.stack4D is None else self.stack.stack4D
        i0_param = i0
        if i0_param is None and getattr(self.stack, "i0data", None) is not None:
            if np.any(self.stack.i0data):
                i0_param = self.stack.i0data
        od_data = intensity_to_od(raw, i0=i0_param)
        if self.stack.stack4D is not None:
            self.stack.od4d = od_data
            self.stack.od3d = od_data[:, :, :, 0].copy()
        else:
            self.stack.od3d = od_data
        self.stack.od = self.stack.od3d.reshape(-1, self.stack.n_ev, order="F").copy()
        self.normalized = True

    def intensity_to_od(self, i0=None):
        self.require_data()
        if self.input_is_od:
            return self.snapshot()
        self.ensure_od(i0=i0)
        self.display = "od"
        self._invalidate()
        self.record("intensity_to_od", {"i0": i0.tolist() if isinstance(i0, np.ndarray) else i0})
        return self.snapshot()

    to_od = intensity_to_od

    def view(self, energy_index=None, x=None, y=None, display=None, roi=None, polygon=None, viewport=None, rois=None):
        self.require_data()
        if viewport is not None:
            if (not isinstance(viewport, (list, tuple)) or len(viewport) != 4 or
                    any(type(value) is not int for value in viewport) or
                    not (0 <= viewport[0] < viewport[2] <= self.stack.n_cols and
                         0 <= viewport[1] < viewport[3] <= self.stack.n_rows)):
                raise SessionError("viewport must be nonempty integer [x0,y0,x1,y1] inside the image")
        energy = self.energy_index if energy_index is None else self._integer(energy_index, "energy_index", 0, self.stack.n_ev-1)
        sx = self.selected_x if x is None else self._integer(x, "x", 0, self.stack.n_cols-1)
        sy = self.selected_y if y is None else self._integer(y, "y", 0, self.stack.n_rows-1)
        display = self.display if display is None else display
        if display not in ("intensity", "od"):
            raise SessionError("display must be intensity or od")
        if self.input_is_od:
            display = "od"  # No I/I₀ can be recovered from an OD-only input.
        if display == "od":
            self.ensure_od()
        if roi is not None and polygon is not None:
            raise SessionError("Choose either rectangle ROI or polygon")
        # Every explicit ROI list replaces the prior selection, including a list
        # that retains saved ROIs but no longer selects one for the histogram.
        mask = None if rois is not None else self.roi_mask
        if roi is not None:
            x0, y0, x1, y1 = self._bounds(roi)
            mask = np.zeros((self.stack.n_cols, self.stack.n_rows), dtype=bool)
            mask[x0:x1, y0:y1] = True
        def polygon_mask(vertices):
            from matplotlib.path import Path as Polygon
            vertices = finite_array(vertices, "polygon")
            if vertices.ndim != 2 or vertices.shape[1] != 2 or len(vertices) < 3:
                raise SessionError("polygon requires at least three [x,y] vertices")
            xx, yy = np.meshgrid(np.arange(self.stack.n_cols)+0.5, np.arange(self.stack.n_rows)+0.5, indexing="ij")
            selection = Polygon(vertices).contains_points(np.column_stack((xx.ravel(), yy.ravel()))).reshape(xx.shape)
            if not selection.any():
                raise SessionError("polygon ROI is empty")
            return selection
        if polygon is not None:
            mask = polygon_mask(polygon)
        if rois is not None:
            if not isinstance(rois, (list, tuple)) or len(rois) > 10:
                raise SessionError("rois must be a list of at most 10 ROI definitions")
            parsed_rois = []
            for item in rois:
                if isinstance(item, dict):
                    has_bounds, has_polygon = "bounds" in item, "polygon" in item
                    if has_bounds == has_polygon:
                        raise SessionError("Each ROI requires exactly one of bounds or polygon")
                    if has_bounds:
                        b = self._bounds(item["bounds"])
                        parsed_rois.append({"bounds": b,
                                            "label": str(item.get("label", f"ROI {len(parsed_rois)+1}"))})
                    else:
                        vertices = finite_array(item["polygon"], "polygon").tolist()
                        polygon_mask(vertices)
                        parsed_rois.append({"polygon": vertices,
                                            "label": str(item.get("label", f"ROI {len(parsed_rois)+1}"))})
                elif isinstance(item, (list, tuple)) and len(item) == 4:
                    b = self._bounds(item)
                    parsed_rois.append({"bounds": b, "label": f"ROI {len(parsed_rois)+1}"})
                else:
                    raise SessionError("Each ROI in rois must have bounds [x0,y0,x1,y1] or polygon vertices")
            self.rois = parsed_rois
        self.energy_index, self.selected_x, self.selected_y = energy, sx, sy
        self.display, self.roi_mask, self.viewport = display, mask, list(viewport) if viewport is not None else None
        return self.snapshot()

    def _values(self):
        return self.stack.absdata if self.stack.stack4D is None else self.stack.stack4D

    def _commit_processed(self, values, energies=None, x=None, y=None):
        stack = self._make_stack(values, self.stack.ev if energies is None else energies,
                                 self.stack.theta if self.stack.stack4D is not None else None,
                                 self.stack.x_dist if x is None else x, self.stack.y_dist if y is None else y)
        self.stack = stack
        self.viewport = None
        self.normalized = self.input_is_od
        if self.input_is_od:
            stack.UsePreNormalizedData()
        self.display = "od" if self.input_is_od else "intensity"
        self.energy_index = min(self.energy_index, stack.n_ev-1)
        self.selected_x = min(self.selected_x, stack.n_cols-1)
        self.selected_y = min(self.selected_y, stack.n_rows-1)
        self._invalidate()

    def crop(self, bounds=None, energy_range=None):
        self.require_data()
        bounds = [0, 0, self.stack.n_cols, self.stack.n_rows] if bounds is None else bounds
        x0, y0, x1, y1 = self._bounds(bounds)
        energy_range = [0, self.stack.n_ev] if energy_range is None else energy_range
        if not isinstance(energy_range, (list, tuple)) or len(energy_range) != 2:
            raise SessionError("energy_range must be [first,last_exclusive]")
        start = self._integer(energy_range[0], "first", 0, self.stack.n_ev-1)
        end = self._integer(energy_range[1], "last_exclusive", start+1, self.stack.n_ev)
        self._commit_processed(self._values()[x0:x1, y0:y1, start:end], self.stack.ev[start:end],
                               self.stack.x_dist[x0:x1], self.stack.y_dist[y0:y1])
        self.record("crop", {"bounds": bounds, "energy_range": energy_range})
        return self.snapshot()

    def dark(self, value):
        self.require_data()
        value = float(finite_array(value, "dark value"))
        if value < 0:
            raise SessionError("dark value must be nonnegative")
        values = self._values() - value
        if np.any(values <= 0):
            raise SessionError("Dark-subtracted transmission must remain strictly positive")
        self._commit_processed(values)
        self.record("dark", {"value": value})
        return self.snapshot()

    def remove_image(self, index):
        self.require_data()
        self._integer(index, "index", 0, self.stack.n_ev-1)
        if self.stack.n_ev == 1:
            raise SessionError("Cannot remove the last image")
        self._commit_processed(np.delete(self._values(), index, axis=2), np.delete(self.stack.ev, index))
        self.record("remove_image", {"index": index})
        return self.snapshot()

    def reset(self):
        self.require_data()
        self.stack = copy.deepcopy(self._original)
        self.input_is_od = self._original_input_is_od
        if self.input_is_od:
            self.stack.UsePreNormalizedData()
        else:
            self.stack.reset_i0()
            self.stack.od4d = 0
        self.normalized = self.input_is_od
        self.display = "od" if self.input_is_od else "intensity"
        self.energy_index = self.selected_x = self.selected_y = 0
        self._invalidate()
        self.record("reset", {})
        return self.snapshot()

    def despike(self, sigma=5):
        self.require_data()
        sigma = float(finite_array(sigma, "sigma"))
        if sigma <= 0:
            raise SessionError("sigma must be positive")
        if min(self.stack.n_cols, self.stack.n_rows) < 3:
            raise SessionError("Despiking requires images at least 3 by 3")
        values = self._values().copy()
        # Original Enhanced Lee filter / four-neighbor replacement. sigma is
        # the Lee noise standard deviation, not an undocumented median filter.
        for index in np.ndindex(values.shape[2:]):
            sl = (slice(None), slice(None)) + index
            values[sl] = self.stack.despike(values[sl], sigma=sigma)
        self._commit_processed(values)
        self.record("despike", {"sigma": sigma, "algorithm": "enhanced Lee", "threshold_percent": 50.0})
        return self.snapshot()

    def align(self, reference=0, upsample_factor=1, manual_shifts=None, crop=False):
        self.require_data()
        self._integer(reference, "reference", 0, self.stack.n_ev-1)
        self._integer(upsample_factor, "upsample_factor", 1, 1000)
        if type(crop) is not bool:
            raise SessionError("crop must be boolean")
        values = self._values().copy()
        if manual_shifts is not None:
            shifts = finite_array(manual_shifts, "manual_shifts")
            if shifts.shape != (self.stack.n_ev, 2):
                raise SessionError("manual_shifts must have one [dx,dy] pair per energy")
            algorithm = "manual shifts; legacy cubic image registration"
        else:
            from skimage.registration import phase_cross_correlation
            images = self.stack.absdata
            if any(np.ptp(images[:, :, i]) == 0 for i in range(self.stack.n_ev)):
                raise SessionError("Cannot register constant images")
            shifts = np.array([phase_cross_correlation(images[:, :, reference], images[:, :, i],
                              upsample_factor=upsample_factor)[0] for i in range(self.stack.n_ev)])
            algorithm = "phase cross-correlation; legacy cubic image registration"
        for index in np.ndindex(values.shape[2:]):
            sl = (slice(None), slice(None)) + index
            values[sl] = self.stack.apply_image_registration(values[sl], *shifts[index[0]])
        x, y = self.stack.x_dist, self.stack.y_dist
        if crop:
            values, x0, x1, y0, y1 = self.stack.crop_registed_images(values, shifts[:, 0].min(), shifts[:, 0].max(),
                                                                  shifts[:, 1].min(), shifts[:, 1].max())
            if 0 in values.shape:
                raise SessionError("Alignment shifts leave no overlapping image")
            x, y = x[x0:x1], y[y0:y1]
        self._commit_processed(values, x=x, y=y)
        self.stack.xshifts, self.stack.yshifts = shifts[:, 0].copy(), shifts[:, 1].copy()
        self.results["alignment"] = {"shifts": shifts.copy()}
        self.record("align", {"reference": reference, "upsample_factor": upsample_factor,
                              "shifts": shifts.tolist(), "crop": crop, "algorithm": algorithm})
        return self.snapshot(metrics={"alignment": algorithm})

    @staticmethod
    def _integer(value, name, low, high):
        if type(value) is not int or not low <= value <= high:
            raise SessionError(f"{name} must be an integer in [{low},{high}]")
        return value

    def pca(self, components=None):
        self.require_normalized()
        if self.stack.n_ev < 2 or not np.any(self.stack.od):
            raise SessionError("PCA requires at least two energies and nonzero optical density")
        if components is not None:
            self._integer(components, "components", 1, self.stack.n_ev)
        trial = analyze.analyze(self.stack)
        # Original uncentered D.T @ D PCA, not sklearn/centered PCA.
        with np.errstate(divide="ignore", invalid="ignore"):
            trial.calculate_pca()
        for name in ("eigenvals", "eigenvecs", "pcaimages", "variance"):
            finite_array(getattr(trial, name), name)
        trial.numsigpca = components or getattr(trial, "numsigpca", 1)
        self.analysis = trial
        self.results = {"pca": {name: getattr(trial, name).copy() for name in
                                ("eigenvals", "eigenvecs", "pcaimages", "variance")}}
        self.record("pca", {"components": trial.numsigpca, "convention": "uncentered D.T @ D"})
        return self.snapshot(
            images=[image_record(f"PC {i+1}", trial.pcaimages[:, :, i]) for i in range(trial.numsigpca)],
            spectra=[spectrum_record("Eigenvalues", np.arange(1, self.stack.n_ev+1), trial.eigenvals)] +
                    [spectrum_record(f"PC {i+1}", self.stack.ev, trial.eigenvecs[:, i]) for i in range(trial.numsigpca)])

    def cluster(self, clusters, components=None, remove_first=False, sigma_split=False, seed=0):
        self.require_normalized()
        if not self.analysis.pca_calculated:
            raise SessionError("Run PCA first", "invalid_state")
        pixels = self.stack.n_cols * self.stack.n_rows
        self._integer(clusters, "clusters", 1, pixels)
        self._integer(seed, "seed", 0, 2**32-1)
        components = self.analysis.numsigpca if components is None else components
        self._integer(components, "components", 1, self.stack.n_ev)
        if type(remove_first) is not bool or type(sigma_split) is not bool:
            raise SessionError("remove_first and sigma_split must be boolean")
        if pixels < 2 or components <= int(remove_first):
            raise SessionError("Clustering requires two pixels and at least one selected component")
        reduced = self.analysis.pcaimages[:, :, int(remove_first):components].reshape(-1, components-int(remove_first))
        if np.unique(reduced, axis=0).shape[0] < clusters:
            raise SessionError("clusters exceeds the number of distinct pixel spectra")
        trial = copy.copy(self.analysis)
        trial.numsigpca = components
        rng_state = np.random.get_state()
        try:
            np.random.seed(seed)
            count = trial.calculate_clusters(clusters, int(remove_first), int(sigma_split))
        finally:
            np.random.set_state(rng_state)
        names = ("cluster_indices", "clusterspectra", "clustersizes", "cluster_distances", "sse")
        for name in names:
            finite_array(getattr(trial, name), name)
        self.analysis = trial
        self.results = {k: v for k, v in self.results.items() if k == "pca"}
        self.results["cluster"] = {name: getattr(trial, name).copy() for name in names}
        self.record("cluster", {"clusters": clusters, "components": components,
                                "remove_first": remove_first, "sigma_split": sigma_split, "seed": seed})
        return self.snapshot(images=[image_record("Clusters", trial.cluster_indices),
                                     image_record("Cluster distance (spectral SSE)", trial.cluster_distances)],
                             spectra=[spectrum_record(f"Cluster {i+1}", self.stack.ev, trial.clusterspectra[i])
                                      for i in range(count)], metrics={"clusters": count})

    def export(self, path, format, overwrite=False, dpi=None, include=None, spectrum_name=None):
        self.require_data()
        import os
        import tempfile
        target = Path(path).expanduser().resolve()
        if any(target == source or (target.exists() and source.is_file() and os.path.samefile(target, source))
               for source in self._protected_paths):
            raise SessionError("Cannot overwrite an input file")
        format_lower = str(format).lower()
        if format_lower not in ("hdf5", "npz", "csv", "png", "pdf", "svg", "json", "md", "markdown"):
            raise SessionError(f"Unsupported export format: {format}", "unsupported_format")
        suffixes = {"hdf5": {".h5", ".hdf5", ".hdf"}, "npz": {".npz"},
                    "csv": {".csv"}, "png": {".png"}, "pdf": {".pdf"}, "svg": {".svg"},
                    "json": {".json"}, "md": {".md"}, "markdown": {".md", ".markdown"}}
        if target.suffix.lower() not in suffixes[format_lower]:
            raise SessionError(f"Export format {format} does not match destination suffix {target.suffix or '(none)'}")
        if type(overwrite) is not bool:
            raise SessionError("overwrite must be boolean")
        if target.exists() and not overwrite:
            raise SessionError(f"Destination exists: {target}; set overwrite=true explicitly", "file_exists")
        allowed_groups = {"processed", "raw", "normalization", "analysis", "spectra"}
        if include is not None:
            if (not isinstance(include, list) or not include or
                    any(not isinstance(group, str) or group not in allowed_groups for group in include) or
                    len(include) != len(set(include))):
                raise SessionError("include must be a nonempty list of unique data groups: processed, raw, normalization, analysis, spectra")
            if format_lower not in ("npz", "hdf5"):
                raise SessionError("include is supported only for NPZ and HDF5 data exports")
            if "normalization" in include and not self.normalized:
                raise SessionError("include normalization requires a normalized stack")
        if spectrum_name is not None and (not isinstance(spectrum_name, str) or not spectrum_name or
                                          format_lower not in ("npz", "hdf5") or
                                          include is None or "spectra" not in include):
            raise SessionError("spectrum_name requires NPZ/HDF5 export with spectra selected")
        view = self._last_snapshot or self.snapshot()
        if spectrum_name is not None and sum(s["name"] == spectrum_name for s in view["spectra"]) != 1:
            raise SessionError("spectrum_name must match exactly one current spectrum")
        target.parent.mkdir(parents=True, exist_ok=True)
        export_params = {"path": str(target), "format": format_lower, "overwrite": overwrite}
        if include is not None:
            export_params["include"] = include
        if spectrum_name is not None:
            export_params["spectrum_name"] = spectrum_name
        if dpi is not None:
            export_params["dpi"] = int(dpi)
        history = self.history + [{"method": "export", "params": export_params}]
        original = self._raw_original
        raw = original.absdata if original.stack4D is None else original.stack4D
        arrays = {"data": self._values(), "energies": self.stack.ev, "x": self.stack.x_dist, "y": self.stack.y_dist,
                  "raw_data": raw, "raw_energies": original.ev,
                  "raw_x": original.x_dist, "raw_y": original.y_dist}
        if original.stack4D is not None:
            arrays["raw_theta"] = original.theta
        if self.stack.stack4D is not None:
            arrays["theta"] = self.stack.theta
        if self.normalized:
            arrays["od"] = self.stack.od3d if self.stack.stack4D is None else self.stack.od4d
            arrays["i0"] = np.asarray(self.stack.i0data)
            arrays["i0_energies"] = np.asarray(self.stack.evi0)
        if self.spatial_unit is not None:
            arrays["spatial_unit"] = np.asarray(self.spatial_unit)
        arrays.update({key: np.asarray(value) for key, value in self.pixel_sizes.items()})
        arrays["input_is_od"] = np.asarray(self.input_is_od)
        def flatten(prefix, value):
            if isinstance(value, dict):
                for name, child in value.items():
                    yield from flatten(f"{prefix}/{name}", child)
            else:
                yield prefix, value
        for key, value in flatten("results", self.results):
            if value is not None:
                arrays[key] = np.asarray(value)
        if include is not None:
            prefixes = {
                "processed": ("data", "energies", "x", "y", "theta", "spatial_unit", "x_pixel_size", "y_pixel_size", "input_is_od"),
                "raw": ("raw_data", "raw_energies", "raw_x", "raw_y", "raw_theta"),
                "normalization": ("od", "i0", "i0_energies"),
            }
            selected = set(include)
            arrays = {key: value for key, value in arrays.items()
                      if any(key in prefixes[group] for group in selected if group in prefixes)
                      or ("analysis" in selected and key.startswith("results/"))}
            if "spectra" in selected:
                chosen_spectra = (s for s in view["spectra"] if spectrum_name is None or s["name"] == spectrum_name)
                for index, spectrum in enumerate(chosen_spectra):
                    arrays[f"spectra/x/{index}"] = np.asarray(spectrum["x"])
                    arrays[f"spectra/y/{index}"] = np.asarray(spectrum["y"])
                    arrays[f"spectra/name/{index}"] = np.asarray(spectrum["name"])
        # Serialize into a private temporary file, then atomically publish. Failed
        # export never truncates a preexisting file. No input file is modified.
        handle, temporary = tempfile.mkstemp(prefix=".mantis-export-", dir=target.parent)
        os.close(handle)
        try:
            if format_lower == "json":
                log_content = {
                    "source": self.source,
                    "shape": [int(d) for d in self.stack.absdata.shape],
                    "energies": self.stack.ev.tolist(),
                    "normalized": self.normalized,
                    "history": history,
                    "metrics": {str(k): str(v) for k, v in (view.get("metrics") or {}).items()}
                }
                with open(temporary, "w", encoding="utf-8") as stream:
                    json.dump(log_content, stream, indent=2, ensure_ascii=False)
            elif format_lower in ("md", "markdown"):
                lines = [
                    "# MANTiS 工作日志\n",
                    "## 数据源信息",
                    f"- **数据源路径**: `{self.source}`",
                    f"- **数据维度**: `{' × '.join(str(d) for d in self.stack.absdata.shape)}`",
                    f"- **信号状态**: `{'已归一化 (光密度)' if self.normalized else '未归一化 (强度)'}`",
                    f"- **能量范围**: `{self.stack.ev[0]:.3f} eV – {self.stack.ev[-1]:.3f} eV ({len(self.stack.ev)} 点)`\n",
                    "## 执行命令与参数历史"
                ]
                for i, entry in enumerate(history, 1):
                    lines.append(f"{i}. **{entry.get('method', '')}**")
                    params_str = json.dumps(entry.get("params", {}), ensure_ascii=False)
                    lines.append(f"   - 参数: `{params_str}`")
                if view.get("metrics"):
                    lines.append("\n## 分析指标与计算结果")
                    for k, v in sorted(view["metrics"].items()):
                        lines.append(f"- **{k}**: `{v}`")
                with open(temporary, "w", encoding="utf-8") as stream:
                    stream.write("\n".join(lines) + "\n")
            elif format_lower == "npz":
                with open(temporary, "wb") as stream:
                    np.savez_compressed(stream, **arrays, source=self.source,
                                        history=json.dumps(history, allow_nan=False), schema_version=1)
            elif format_lower == "hdf5":
                import h5py
                mapping = {"data": "exchange/data", "energies": "exchange/energy", "x": "exchange/x", "y": "exchange/y",
                           "theta": "exchange/theta", "raw_data": "raw/data", "raw_energies": "raw/energy",
                           "raw_x": "raw/x", "raw_y": "raw/y", "raw_theta": "raw/theta",
                           "od": "normalization/od", "i0": "normalization/i0",
                           "i0_energies": "normalization/energy", "spatial_unit": "provenance/spatial_unit",
                           "x_pixel_size": "provenance/x_pixel_size", "y_pixel_size": "provenance/y_pixel_size", "input_is_od": "provenance/input_is_od"}
                with h5py.File(temporary, "w") as archive:
                    archive.attrs["mantis_session_version"] = 1
                    archive.create_dataset("implements", data="information:exchange:spectromicroscopy")
                    archive.create_dataset("version", data="1.0")
                    for key, value in arrays.items():
                        if value.dtype.kind == "U":
                            value = value.astype(h5py.string_dtype("utf-8"))
                        archive.create_dataset(mapping.get(key, key), data=value)
                    if "exchange/data" in archive:
                        archive["exchange/data"].attrs["axes"] = "x:y:energy:theta" if self.stack.stack4D is not None else "x:y:energy"
                    archive.create_dataset("provenance/source", data=self.source)
                    archive.create_dataset("provenance/history", data=json.dumps(history, allow_nan=False))
            elif format_lower == "csv":
                import csv
                with open(temporary, "w", newline="") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(["spectrum", "x", "y"])
                    for spectrum in view["spectra"]:
                        writer.writerows((spectrum["name"], x, y) for x, y in zip(spectrum["x"], spectrum["y"]))
            else:
                from matplotlib.figure import Figure
                from matplotlib.backends.backend_agg import FigureCanvasAgg
                count = max(1, len(view["images"]) + bool(view["spectra"]))
                figure = Figure(figsize=(5 * count, 4), layout="constrained")
                FigureCanvasAgg(figure)
                for i, image in enumerate(view["images"]):
                    axis = figure.add_subplot(1, count, i+1)
                    shape = (image["height"], image["width"])
                    if image.get("channels") == 3:
                        shape += (3,)
                    axis.imshow(np.asarray(image["values"]).reshape(shape), origin="lower", aspect="auto")
                    axis.set_title(image["title"])
                if view["spectra"]:
                    axis = figure.add_subplot(1, count, count)
                    for spectrum in view["spectra"]:
                        axis.plot(spectrum["x"], spectrum["y"], label=spectrum["name"])
                    axis.legend()
                fig_dpi = int(dpi) if dpi is not None else 150
                figure.savefig(temporary, format=format_lower, dpi=fig_dpi)
                figure.clear()
            if overwrite:
                os.replace(temporary, target)
            else:
                # link is an atomic no-clobber publication on the same filesystem.
                os.link(temporary, target)
                os.unlink(temporary)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self.history = history
        result = self.snapshot(images=view["images"], spectra=view["spectra"], metrics=view["metrics"])
        result["exported_path"] = str(target)
        return result

    def snapshot(self, images=None, spectra=None, metrics=None):
        self.require_data()
        values = self.stack.od3d if self.display == "od" else self.stack.absdata
        if images is None:
            image_values = values[:, :, self.energy_index]
            if self.viewport is not None:
                x0, y0, x1, y1 = self.viewport
                image_values = image_values[x0:x1, y0:y1]
            images = [image_record("Optical density" if self.display == "od" else "Intensity",
                                   image_values, self.viewport, (self.stack.n_cols, self.stack.n_rows))]
        if self.roi_mask is not None and images is not None and images and images[0].get("title") in ("Intensity", "Optical density") and "histogram_counts" in images[0]:
            selected_pixels = values[:, :, self.energy_index][self.roi_mask]
            counts, edges = _image_histogram(selected_pixels)
            images[0]["roi_histogram_counts"] = counts.tolist()
            images[0]["roi_histogram_edges"] = edges.tolist()
            images[0]["roi_minimum"] = float(selected_pixels.min())
            images[0]["roi_maximum"] = float(selected_pixels.max())
            images[0]["roi_mean"] = float(selected_pixels.mean())
        if spectra is None:
            spectra = [spectrum_record("Pixel", self.stack.ev, values[self.selected_x, self.selected_y])]
            if getattr(self, "rois", None):
                for idx, r in enumerate(self.rois):
                    lbl = r.get("label") or f"ROI {idx+1}"
                    if "bounds" in r:
                        rx0, ry0, rx1, ry1 = r["bounds"]
                        roi_spec = values[rx0:rx1, ry0:ry1, :].mean(axis=(0, 1))
                    else:
                        from matplotlib.path import Path as Polygon
                        vertices = np.asarray(r["polygon"], dtype=float)
                        xx, yy = np.meshgrid(np.arange(self.stack.n_cols)+0.5,
                                             np.arange(self.stack.n_rows)+0.5, indexing="ij")
                        selection = Polygon(vertices).contains_points(
                            np.column_stack((xx.ravel(), yy.ravel()))).reshape(xx.shape)
                        roi_spec = values[selection].mean(axis=0)
                    spectra.append(spectrum_record(lbl, self.stack.ev, roi_spec))
            elif self.roi_mask is not None:
                spectra.append(spectrum_record("ROI mean", self.stack.ev, values[self.roi_mask].mean(axis=0)))
            else:
                spectra.append(spectrum_record("Full image", self.stack.ev, values.mean(axis=(0, 1))))
        result = {"source": self.source, "shape": [int(dimension) for dimension in self.stack.absdata.shape],
                  "energies": self.stack.ev.tolist(), "normalized": self.normalized,
                  "input_is_od": self.input_is_od, "display": self.display,
                  "pca_ready": bool(self.analysis.pca_calculated),
                  "clusters_ready": bool(self.analysis.clusters_calculated),
                  "energy_index": self.energy_index, "selected_x": self.selected_x,
                  "selected_y": self.selected_y, "images": images, "spectra": spectra,
                  "metrics": {str(k): str(v) for k, v in (metrics or {}).items()},
                  "spatial": {"x": np.asarray(self.stack.x_dist, dtype=float).tolist(),
                              "y": np.asarray(self.stack.y_dist, dtype=float).tolist(),
                              "unit": self.spatial_unit, **self.pixel_sizes},
                  "history": copy.deepcopy(self.history)}
        json.dumps(result, allow_nan=False)
        self._last_snapshot = copy.deepcopy(result)
        return result
