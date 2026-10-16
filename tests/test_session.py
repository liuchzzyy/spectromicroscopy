"""Headless scientific session acceptance/regression tests (real files)."""
import importlib.util
import json
import sys

import numpy as np
import pytest


def session_class():
    assert importlib.util.find_spec("mantis_xray.core.session") is not None, "Headless session is missing"
    from mantis_xray.core.session import Session
    return Session


def fixture_file(tmp_path, data=None, energies=None, **extra):
    if data is None:
        data = np.arange(3 * 2 * 5, dtype=float).reshape(3, 2, 5) + 20
    if energies is None:
        energies = np.arange(data.shape[2], dtype=float) + 280
    path = tmp_path / "input.npz"
    np.savez(path, data=data, energies=energies, **extra)
    return path, data, energies


def test_intensity_input_displays_intensity_only_and_rejects_od_view_before_normalization(tmp_path):
    data = np.linspace(0.2, 0.9, 30).reshape(3, 2, 5)
    source, _, _ = fixture_file(tmp_path, data=data)
    session = session_class()()
    opened = session.dispatch("open", {"path": str(source), "pre_normalized": False})
    assert opened["input_is_od"] is False
    assert opened["display"] == "intensity"
    assert opened["images"][0]["title"] == "Intensity"
    np.testing.assert_allclose(opened["images"][0]["values"], data[:, :, 0].T.ravel())

    # Attempting to view as OD without normalization fails - no on-the-fly conversion in Load Data
    with pytest.raises(ValueError, match="Normalize the dataset first"):
        session.dispatch("view", {"display": "od", "energy_index": 0})


def test_declared_od_import_never_masquerades_as_intensity(tmp_path):
    source, data, _ = fixture_file(tmp_path, data=np.linspace(-0.2, 1.5, 30).reshape(3, 2, 5))
    session = session_class()()
    opened = session.dispatch("open", {"path": str(source), "pre_normalized": True})
    assert opened["input_is_od"] is True
    assert opened["display"] == "od"
    assert opened["images"][0]["title"] == "Optical density"
    np.testing.assert_array_equal(session.stack.absdata, data)
    viewed = session.dispatch("view", {"display": "intensity", "energy_index": 1})
    assert viewed["display"] == "od", "An OD source has no recoverable raw intensity"
    assert viewed["images"][0]["title"] == "Optical density"
    np.testing.assert_array_equal(viewed["images"][0]["values"], data[:, :, 1].T.ravel())
    cropped = session.dispatch("crop", {"bounds": [0, 0, 2, 2]})
    assert cropped["normalized"] and cropped["input_is_od"]
    assert cropped["display"] == "od"
    reset = session.dispatch("reset", {})
    assert reset["normalized"] and reset["input_is_od"]
    assert reset["display"] == "od"
    np.testing.assert_array_equal(session.stack.absdata, data)


def test_od_only_numeric_export_reopens_without_relogging_negative_od(tmp_path):
    source, data, _ = fixture_file(tmp_path, data=np.linspace(-0.2, 1.5, 30).reshape(3, 2, 5))
    session = session_class()()
    session.dispatch("open", {"path": str(source), "pre_normalized": True})
    for fmt in ("npz", "hdf5"):
        for include in (None, ["processed"]):
            path = tmp_path / f"od-only-{include is not None}.{fmt}"
            params = {"path": str(path), "format": fmt}
            if include is not None:
                params["include"] = include
            session.dispatch("export", params)
            restored_session = session_class()()
            restored = restored_session.dispatch("open", {"path": str(path)})
            assert restored["input_is_od"] and restored["normalized"]
            assert restored["display"] == "od"
            np.testing.assert_array_equal(restored_session.stack.od3d, data)


def test_open_non_square_orientation_and_private_state(tmp_path):
    Session = session_class()
    path, data, energies = fixture_file(tmp_path)
    first, second = Session(), Session()
    result = first.dispatch("open", {"path": str(path)})
    assert result["shape"] == [3, 2, 5]
    assert result["images"][0]["values"] == data[:, :, 0].T.ravel().tolist()
    assert result["images"][0]["width"] == 3
    assert result["images"][0]["height"] == 2
    assert result["spectra"][0]["y"] == data[0, 0].tolist()
    assert not result["normalized"]
    assert result["history"][0]["method"] == "open"
    assert len(result["history"][0]["params"]["sha256"]) == 64
    second.dispatch("open", {"path": str(path)})
    first.stack.data_struct.exchange.data[0, 0, 0] = 1234
    assert second.stack.data_struct.exchange.data[0, 0, 0] == data[0, 0, 0]
    assert not any(name.startswith(("PyQt", "PySide", "pyqtgraph")) for name in sys.modules)
    json.dumps(result, allow_nan=False)


def test_spatial_axes_and_zoom_preview_are_source_accurate(tmp_path):
    Session = session_class()
    x, y, energy = np.indices((12, 8, 3))
    values = 10 * x + y + energy / 10
    coords_x = 1391.7 + np.arange(12) * 0.05
    coords_y = 1541.2 + np.arange(8) * 0.1
    source, _, _ = fixture_file(tmp_path, data=values, x=coords_x, y=coords_y)
    session = Session()
    full = session.dispatch("open", {"path": str(source)})
    assert full["spatial"]["x"] == coords_x.tolist()
    assert full["spatial"]["y"] == coords_y.tolist()
    assert full["spatial"]["unit"] is None  # NPZ has no trustworthy unit metadata
    zoomed = session.dispatch("view", {"energy_index": 2, "x": 4, "y": 3,
                                        "viewport": [2, 1, 7, 6]})
    image = zoomed["images"][0]
    assert (image["origin_x"], image["origin_y"], image["visible_width"], image["visible_height"]) == (2, 1, 5, 5)
    assert (image["full_width"], image["full_height"]) == (12, 8)
    assert image["values"] == values[2:7, 1:6, 2].T.ravel().tolist()
    assert sum(image["histogram_counts"]) == 25
    np.testing.assert_allclose(image["mean"], values[2:7, 1:6, 2].mean())
    assert len(image["histogram_edges"]) == len(image["histogram_counts"]) + 1
    assert zoomed["spectra"][0]["y"] == values[4, 3].tolist()
    assert session.dispatch("view", {"energy_index": 2})["images"][0]["values"] == values[:, :, 2].T.ravel().tolist()
    for invalid in ([0, 0, 13, 5], [0, 0, 0, 5], [1.5, 0, 4, 5], [1, 0, 4]):
        with pytest.raises(ValueError, match="viewport"):
            session.dispatch("view", {"viewport": invalid})


def test_image_histogram_uses_all_source_pixels_not_preview_sampling():
    from mantis_xray.core.session import image_record
    full = np.zeros((514, 303), dtype=float)
    full[1::2, :] = 7.0
    image = image_record("Intensity", full)
    assert image["width"] == 256 and image["height"] == 256
    assert sum(image["histogram_counts"]) == full.size
    np.testing.assert_allclose(image["mean"], full.mean())
    assert image["minimum"] == 0.0 and image["maximum"] == 7.0
    constant = image_record("Constant", np.full((3, 5), 2.5))
    assert sum(constant["histogram_counts"]) == 15
    assert np.all(np.diff(constant["histogram_edges"]) > 0)


def test_near_constant_histogram_preserves_values_and_representable_edges(tmp_path):
    from mantis_xray.core.session import image_record
    data = np.full((3, 2, 2), 10.0)
    data[0, 0, :] = np.nextafter(10.0, np.inf)
    original = data.copy()
    image = image_record("Near constant", data[:, :, 0])
    assert sum(image["histogram_counts"]) == 6
    assert np.all(np.diff(image["histogram_edges"]) > 0)
    assert image["minimum"] == data[:, :, 0].min()
    assert image["maximum"] == data[:, :, 0].max()
    assert image["values"] == data[:, :, 0].T.ravel().tolist()
    session = session_class()()
    path, _, _ = fixture_file(tmp_path, data=data)
    session.dispatch("open", {"path": str(path)})
    selected = session.dispatch("view", {"roi": [0, 0, 3, 2]})["images"][0]
    assert sum(selected["roi_histogram_counts"]) == 6
    assert np.all(np.diff(selected["roi_histogram_edges"]) > 0)
    assert session.stack is not None
    np.testing.assert_array_equal(session.stack.absdata, original)


def test_coordinate_resolution_survives_single_pixel_crop(tmp_path):
    source, _, _ = fixture_file(tmp_path, x=np.array([1391.7, 1391.75, 1391.8]),
                                y=np.array([1541.2, 1541.3]), spatial_unit="µm")
    session = session_class()()
    opened = session.dispatch("open", {"path": str(source)})
    assert opened["spatial"]["x_pixel_size"] == abs(1391.75 - 1391.7)
    assert opened["spatial"]["y_pixel_size"] == abs(1541.3 - 1541.2)
    cropped = session.dispatch("crop", {"bounds": [1, 0, 2, 1]})
    assert cropped["spatial"]["x_pixel_size"] == opened["spatial"]["x_pixel_size"]
    assert cropped["spatial"]["y_pixel_size"] == opened["spatial"]["y_pixel_size"]


def test_spatial_axis_unit_is_only_reported_for_known_plugin_metadata(tmp_path):
    Session = session_class()
    source, _, _ = fixture_file(tmp_path)
    session = Session()
    assert session.dispatch("open", {"path": str(source)})["spatial"]["unit"] is None


def test_spatial_unit_roundtrips_through_numeric_exports(tmp_path):
    import h5py
    Session = session_class()
    data = np.arange(4 * 3 * 2, dtype=float).reshape(4, 3, 2) + 1
    source = tmp_path / "with-units.hdf5"
    with h5py.File(source, "w") as archive:
        exchange = archive.create_group("exchange")
        exchange.create_dataset("data", data=data)
        exchange.create_dataset("energy", data=[625., 626.])
        exchange.create_dataset("x", data=[0., 0.05, 0.1, 0.15]).attrs["units"] = "µm"
        exchange.create_dataset("y", data=[0., 0.1, 0.2]).attrs["units"] = "µm"
    session = Session()
    result = session.dispatch("open", {"path": str(source)})
    assert result["spatial"]["unit"] == "µm"
    for fmt in ("npz", "hdf5"):
        target = tmp_path / f"roundtrip.{fmt}"
        session.dispatch("export", {"path": str(target), "format": fmt})
        restored = Session().dispatch("open", {"path": str(target)})
        assert restored["spatial"] == result["spatial"]
        assert restored["images"][0]["values"] == result["images"][0]["values"]


def test_normalize_roi_validates_and_preserves_data(tmp_path):
    Session = session_class()
    path, data, energies = fixture_file(tmp_path)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    result = session.dispatch("normalize", {"mode": "roi", "bounds": [0, 0, 1, 1]})
    expected = -np.log(data / data[0, 0])
    assert result["normalized"]
    np.testing.assert_allclose(session.stack.od3d, expected)
    np.testing.assert_array_equal(session.stack.absdata, data)
    np.testing.assert_array_equal(session.stack.ev, energies)
    np.testing.assert_array_equal(session.stack.evi0, energies)
    np.testing.assert_allclose(session.stack.od, expected.reshape(-1, 5, order="F"))
    before = session.stack.od.copy()
    with pytest.raises(ValueError, match="positive"):
        bad_path = tmp_path / "bad.csv"
        np.savetxt(bad_path, np.column_stack([energies, np.zeros(5)]), delimiter=",")
        session.dispatch("normalize", {"mode": "file", "path": str(bad_path)})
    np.testing.assert_array_equal(session.stack.od, before)


def test_normalize_file_histogram_and_pre_normalized(tmp_path):
    Session = session_class()
    path, data, energies = fixture_file(tmp_path)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    i0path = tmp_path / "i0.xas"
    np.savetxt(i0path, np.column_stack([energies, np.full(5, 100.0)]))
    session.dispatch("normalize", {"mode": "file", "path": str(i0path)})
    np.testing.assert_allclose(session.stack.od3d, -np.log(data / 100))
    session.dispatch("normalize", {"mode": "histogram", "min": 0, "max": 100})
    np.testing.assert_allclose(session.stack.od3d, -np.log(data / data.mean(axis=(0, 1))))
    session.dispatch("open", {"path": str(path), "pre_normalized": True})
    np.testing.assert_array_equal(session.stack.od3d, data)
    assert session.normalized


def test_pca_cluster_matches_original_algorithms_and_seed(tmp_path):
    Session = session_class()
    rng = np.random.default_rng(13)
    path, data, _ = fixture_file(tmp_path, data=rng.uniform(0.1, 2, (9, 7, 5)))
    session = Session()
    session.dispatch("open", {"path": str(path), "pre_normalized": True})
    result = session.dispatch("pca", {"components": 3})
    assert result["pca_ready"]
    from mantis_xray.analysis.analyze import analyze
    original = analyze(session.stack)
    original.calculate_pca()
    np.testing.assert_allclose(session.analysis.eigenvals, original.eigenvals)
    np.testing.assert_allclose(session.analysis.pcaimages, original.pcaimages)
    state = np.random.get_state()
    result = session.dispatch("cluster", {"clusters": 3, "components": 3, "seed": 17})
    assert result["clusters_ready"]
    assert len([s for s in result["spectra"] if s["name"].startswith("Cluster")]) == 3
    np.testing.assert_array_equal(np.random.get_state()[1], state[1])
    original.numsigpca = 3
    np.random.seed(17)
    original.calculate_clusters(3)
    np.random.set_state(state)
    np.testing.assert_array_equal(session.analysis.cluster_indices, original.cluster_indices)
    np.testing.assert_allclose(session.analysis.clusterspectra, original.clusterspectra)
    assert "pca" in session.results and "cluster" in session.results
    assert result["history"][-1]["params"]["seed"] == 17
    before = session.analysis
    with pytest.raises(ValueError):
        session.dispatch("cluster", {"clusters": 10000, "components": 2})
    assert session.analysis is before


def test_pca_default_component_count_is_json_safe(tmp_path):
    """The GUI runs PCA without an explicit component count (scree test decides)."""
    import json
    Session = session_class()
    x, y, e = np.indices((12, 9, 7))
    data = 0.3 + 0.02 * x + 0.03 * y + np.exp(-((e - 3 - (x > 5)) / 1.6) ** 2)
    path, _, _ = fixture_file(tmp_path, data=data, energies=np.linspace(280, 295, 7))
    session = Session()
    session.dispatch("open", {"path": str(path), "pre_normalized": True})
    result = session.dispatch("pca", {})
    json.dumps(result, allow_nan=False)
    entry = result["history"][-1]
    assert entry["method"] == "pca"
    assert type(entry["params"]["components"]) is int
    assert result["pca_ready"]
    assert 1 <= result["metrics"].get("components", 1) if "components" in result["metrics"] else True


def test_roi_shapes_and_clear_restore_default_views(tmp_path):
    Session = session_class()
    data = np.arange(4 * 4 * 3, dtype=float).reshape(4, 4, 3) + 1
    path, _, _ = fixture_file(tmp_path, data=data)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    rois = [{"bounds": [1, 1, 2, 2], "label": "[1] ROI 1"},
            {"polygon": [[0, 0], [2, 0], [2, 2], [0, 2]], "label": "[2] ROI 2"}]
    selected = session.dispatch("view", {"rois": rois, "roi": [1, 1, 2, 2]})
    assert [s["name"] for s in selected["spectra"]] == ["Pixel", "[1] ROI 1", "[2] ROI 2"]
    np.testing.assert_allclose(selected["spectra"][1]["y"], data[1, 1, :])
    assert selected["images"][0]["roi_histogram_counts"] is not None
    assert sum(selected["images"][0]["roi_histogram_counts"]) == 1
    cleared = session.dispatch("view", {"rois": [], "roi": None, "polygon": None})
    assert not any("ROI" in s["name"] for s in cleared["spectra"])
    assert "Full image" in [s["name"] for s in cleared["spectra"]]
    np.testing.assert_allclose(next(s["y"] for s in cleared["spectra"] if s["name"] == "Full image"), data.mean(axis=(0, 1)))
    assert cleared["images"][0].get("roi_histogram_counts") is None
    assert session.rois == [] and session.roi_mask is None
    # Deselecting the active mask while retaining saved ROIs must not reuse
    # the previous ROI's histogram or spectra selection.
    session.dispatch("view", {"rois": rois, "roi": [1, 1, 2, 2]})
    deselected = session.dispatch("view", {"rois": rois, "roi": None, "polygon": None})
    assert deselected["images"][0].get("roi_histogram_counts") is None
    assert session.roi_mask is None
    for invalid in ([{"bounds": [0, 0, 1, 1], "polygon": [[0, 0], [1, 0], [1, 1]]}],
                    [{"polygon": [[0, 0], [1, 0], [2, 0]]}],
                    [{"polygon": [[0, 0], [1, 0], [float("nan"), 1]]}]):
        with pytest.raises(ValueError):
            session.dispatch("view", {"rois": invalid})


def test_view_roi_and_processing_invalidation_reset(tmp_path):
    Session = session_class()
    path, data, _ = fixture_file(tmp_path)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    result = session.dispatch("view", {"energy_index": 3, "x": 2, "y": 1, "roi": [0, 0, 2, 2]})
    np.testing.assert_allclose(result["spectra"][1]["y"], data[:2, :2].mean(axis=(0, 1)))
    assert result["spectra"][0]["y"] == data[2, 1].tolist()
    assert result["images"][0]["values"] == data[:, :, 3].T.ravel().tolist()
    result = session.dispatch("view", {"polygon": [[0,0],[2,0],[2,2],[0,2]]})
    assert "ROI" in result["spectra"][1]["name"]
    # Multi-ROI test (up to 10 ROIs)
    multi_res = session.dispatch("view", {
        "rois": [
            {"bounds": [0, 0, 2, 2], "label": "[1] ROI 1"},
            {"bounds": [1, 1, 3, 2], "label": "[2] ROI 2"}
        ]
    })
    assert len(multi_res["spectra"]) == 3
    assert multi_res["spectra"][1]["name"] == "[1] ROI 1"
    assert multi_res["spectra"][2]["name"] == "[2] ROI 2"
    np.testing.assert_allclose(multi_res["spectra"][1]["y"], data[:2, :2].mean(axis=(0, 1)))
    np.testing.assert_allclose(multi_res["spectra"][2]["y"], data[1:3, 1:2].mean(axis=(0, 1)))
    with pytest.raises(ValueError, match="empty"):
        session.dispatch("view", {"roi": [0, 0, 0, 1]})
    # Computed OD is invalidated by raw-intensity processing; OD-only inputs
    # retain their semantics instead (covered separately above).
    session.dispatch("normalize", {"mode": "roi", "bounds": [0, 0, 1, 1]})
    session.dispatch("pca", {"components": 2})
    result = session.dispatch("crop", {"bounds": [1, 0, 3, 2], "energy_range": [1, 4]})
    assert result["shape"] == [2, 2, 3]
    assert not result["pca_ready"] and not session.results
    np.testing.assert_array_equal(session.stack.absdata, data[1:3, :, 1:4])
    assert not result["normalized"]
    session.dispatch("dark", {"value": 2})
    np.testing.assert_array_equal(session.stack.absdata, data[1:3, :, 1:4] - 2)
    session.dispatch("remove_image", {"index": 1})
    assert session.stack.ev.tolist() == [281, 283]
    result = session.dispatch("reset", {})
    np.testing.assert_array_equal(session.stack.absdata, data)
    assert not result["normalized"] and not result["pca_ready"]
    with pytest.raises(ValueError, match="positive"):
        session.dispatch("dark", {"value": 1000})
    np.testing.assert_array_equal(session.stack.absdata, data)


def test_alignment_and_despike_keep_original(tmp_path):
    Session = session_class()
    data = np.ones((12, 9, 3), dtype=float) * 10
    data[5, 4, :] = 10000
    path, _, _ = fixture_file(tmp_path, data=data)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    result = session.dispatch("despike", {"sigma": 5})
    assert session.stack.absdata[5, 4, 0] < 10000
    assert result["history"][-1]["params"]["sigma"] == 5
    result = session.dispatch("align", {"reference": 0, "upsample_factor": 1,
                                         "manual_shifts": [[0, 0], [1, 0], [0, -1]], "crop": True})
    assert result["shape"] == [11, 8, 3]
    assert "alignment" in session.results
    assert session.results["alignment"]["shifts"].shape == (3, 2)
    session.dispatch("reset", {})
    np.testing.assert_array_equal(session.stack.absdata, data)


def test_exports_full_resolution_hdf5_npz_roundtrip_and_graphics(tmp_path):
    import h5py
    Session = session_class()
    data = np.random.default_rng(4).uniform(10, 20, (270, 3, 4))
    path, _, _ = fixture_file(tmp_path, data=data)
    session = Session()
    session.dispatch("open", {"path": str(path)})
    session.dispatch("dark", {"value": 1})
    session.dispatch("normalize", {"mode": "histogram", "fraction_min": 0.98})
    session.dispatch("pca", {"components": 2})
    for fmt in ("hdf5", "npz", "csv", "png", "pdf", "svg"):
        target = tmp_path / "out" / f"result.{fmt}"
        result = session.dispatch("export", {"path": str(target), "format": fmt})
        assert result["exported_path"] == str(target)
        assert target.stat().st_size > 0
        with pytest.raises(ValueError, match="exist"):
            session.dispatch("export", {"path": str(target), "format": fmt})
    with h5py.File(tmp_path / "out/result.hdf5") as f:
        np.testing.assert_array_equal(f["raw/data"], data)
        np.testing.assert_array_equal(f["exchange/data"], data-1)
        np.testing.assert_allclose(f["results/pca/eigenvals"], session.analysis.eigenvals)
        assert "normalize" in f["provenance/history"][()].decode()
    fresh = Session()
    fresh.dispatch("open", {"path": str(tmp_path / "out/result.hdf5")})
    np.testing.assert_array_equal(fresh.stack.absdata, data-1)
    assert fresh.normalized
    with np.load(tmp_path / "out/result.npz") as f:
        np.testing.assert_array_equal(f["raw_data"], data)
        np.testing.assert_array_equal(f["data"], data-1)
        assert "results/pca/eigenvals" in f
    with pytest.raises(ValueError, match="input"):
        session.dispatch("export", {"path": str(path), "format": "npz", "overwrite": True})


def test_export_selected_data_groups_and_rejects_empty_selection(tmp_path):
    session = session_class()()
    source, data, _ = fixture_file(tmp_path, data=np.ones((3, 3, 4)))
    session.dispatch("open", {"path": str(source)})
    target = tmp_path / "selected.npz"
    session.dispatch("export", {"path": str(target), "format": "npz", "include": ["raw", "spectra"]})
    with np.load(target) as output:
        assert "raw_data" in output and "raw_energies" in output
        assert "data" not in output and "results/pca/eigenvals" not in output
        assert "spectra/y/0" in output and "spectra/x/0" in output
        np.testing.assert_array_equal(output["raw_data"], data)
    with pytest.raises(ValueError, match="include"):
        session.dispatch("export", {"path": str(tmp_path / "empty.npz"), "format": "npz", "include": []})
    with pytest.raises(ValueError, match="include"):
        session.dispatch("export", {"path": str(tmp_path / "unknown.npz"), "format": "npz", "include": ["fabricated"]})
    with pytest.raises(ValueError, match="include"):
        session.dispatch("export", {"path": str(tmp_path / "duplicate.npz"), "format": "npz", "include": ["raw", "raw"]})
    with pytest.raises(ValueError, match="normalization"):
        session.dispatch("export", {"path": str(tmp_path / "od.npz"), "format": "npz", "include": ["normalization"]})
    with pytest.raises(ValueError, match="include"):
        session.dispatch("export", {"path": str(tmp_path / "wrong.csv"), "format": "csv", "include": ["raw"]})
    assert not (tmp_path / "empty.npz").exists()
    assert not (tmp_path / "unknown.npz").exists()


def test_export_one_roi_spectrum_does_not_mislabel_all_spectra(tmp_path):
    session = session_class()()
    data = np.arange(3 * 3 * 4, dtype=float).reshape(3, 3, 4) + 1
    source, _, _ = fixture_file(tmp_path, data=data)
    session.dispatch("open", {"path": str(source)})
    session.dispatch("view", {"rois": [
        {"bounds": [0, 0, 1, 1], "label": "[1] ROI 1"},
        {"bounds": [2, 2, 3, 3], "label": "[2] ROI 2"},
    ]})
    output = tmp_path / "ROI1.npz"
    session.dispatch("export", {"path": str(output), "format": "npz",
                                "include": ["spectra"], "spectrum_name": "[1] ROI 1"})
    with np.load(output) as archive:
        assert archive["spectra/name/0"].item() == "[1] ROI 1"
        np.testing.assert_array_equal(archive["spectra/y/0"], data[0, 0, :])
        assert "spectra/name/1" not in archive
    missing = tmp_path / "missing.npz"
    with pytest.raises(ValueError, match="spectrum_name"):
        session.dispatch("export", {"path": str(missing), "format": "npz",
                                    "include": ["spectra"], "spectrum_name": "ROI 404"})
    assert not missing.exists()


def test_export_selected_hdf5_without_processed_dataset(tmp_path):
    import h5py
    session = session_class()()
    source, data, _ = fixture_file(tmp_path, data=np.ones((3, 3, 4)))
    session.dispatch("open", {"path": str(source)})
    target = tmp_path / "raw_only.hdf5"
    session.dispatch("export", {"path": str(target), "format": "hdf5", "include": ["raw"]})
    with h5py.File(target) as f:
        assert "raw/data" in f
        assert "exchange/data" not in f
        np.testing.assert_array_equal(f["raw/data"], data)
    reloaded = session_class()()
    with pytest.raises(ValueError, match="Unsupported file format"):
        reloaded.dispatch("open", {"path": str(target)})


def test_export_custom_dpi_and_workflow_logs_json_markdown(tmp_path):
    Session = session_class()
    data = np.ones((10, 8, 4))
    source, _, _ = fixture_file(tmp_path, data=data)
    session = Session()
    session.dispatch("open", {"path": str(source)})
    session.dispatch("view", {"energy_index": 1, "x": 2, "y": 3})

    # Custom DPI image export
    img_target = tmp_path / "figure.png"
    res = session.dispatch("export", {"path": str(img_target), "format": "png", "dpi": 300})
    assert img_target.is_file() and img_target.stat().st_size > 0

    # Workflow log JSON export
    json_target = tmp_path / "workflow.json"
    res_json = session.dispatch("export", {"path": str(json_target), "format": "json"})
    assert json_target.is_file()
    log_data = json.loads(json_target.read_text())
    assert log_data["source"] == str(source)
    assert len(log_data["history"]) >= 2
    assert log_data["history"][0]["method"] == "open"
    assert log_data["history"][1]["method"] == "export"

    # Workflow log Markdown (.md) export
    md_target = tmp_path / "workflow.md"
    res_md = session.dispatch("export", {"path": str(md_target), "format": "md"})
    assert md_target.is_file()
    md_text = md_target.read_text()
    assert "# MANTiS" in md_text
    assert "open" in md_text and "export" in md_text


def test_reference_input_cannot_be_replaced_by_direct_session_export(tmp_path):
    session = session_class()()
    energies = np.linspace(280, 290, 11)
    source, _, _ = fixture_file(tmp_path, data=np.ones((3, 3, 11)), energies=energies)
    reference = tmp_path / "reference.csv"
    np.savetxt(reference, np.column_stack((energies, np.linspace(0.2, 1.0, 11))), delimiter=",")
    original = reference.read_bytes()
    session.dispatch("open", {"path": str(source), "pre_normalized": True})
    session.dispatch("spectral", {"paths": [str(reference)]})
    with pytest.raises(ValueError, match="input"):
        session.dispatch("export", {"path": str(reference), "format": "csv", "overwrite": True})
    assert reference.read_bytes() == original


def test_reference_input_is_protected_even_if_advanced_result_fails(tmp_path):
    session = session_class()()
    energies = np.linspace(280, 290, 11)
    source, _, _ = fixture_file(tmp_path, data=np.ones((3, 3, 11)), energies=energies)
    reference = tmp_path / "reference.csv"
    np.savetxt(reference, np.column_stack((energies, np.zeros(11))), delimiter=",")
    original = reference.read_bytes()
    session.dispatch("open", {"path": str(source), "pre_normalized": True})
    with pytest.raises(ValueError):
        session.dispatch("spectral", {"paths": [str(reference)]})
    with pytest.raises(ValueError, match="input"):
        session.dispatch("export", {"path": str(reference), "format": "csv", "overwrite": True})
    assert reference.read_bytes() == original


def test_plugins_inspect_and_build_tiff_stack(tmp_path):
    from PIL import Image
    Session = session_class()
    session = Session()
    paths = []
    frames = []
    for i in range(3):
        path = tmp_path / f"frame{i}.tif"
        frame = (np.arange(6).reshape(2, 3) + 10 + i).astype(np.uint16)
        Image.fromarray(frame).save(path)
        paths.append(str(path))
        frames.append(frame.T)
    info = session.dispatch("inspect_file", {"path": paths[0]})
    assert "Tiff" in info["plugin"]
    result = session.dispatch("build_stack", {"paths": paths, "energies": [280,281,282]})
    assert result["shape"] == [3,2,3]
    np.testing.assert_array_equal(session.stack.absdata, np.stack(frames, axis=2))
    assert len(result["history"][0]["params"]["sha256"]) == 3
    # Real STK binary layout: big-endian header/axes and Fortran-order data.
    stkpath = tmp_path / "real.stk"
    with stkpath.open("wb") as stream:
        np.asarray([3,2,3], dtype=">i4").tofile(stream)
        for array in (session.stack.x_dist, session.stack.y_dist, session.stack.ev,
                      np.ones(3), session.stack.absdata.ravel(order="F")):
            np.asarray(array, dtype=">f4").tofile(stream)
    fresh = Session()
    fresh.dispatch("open", {"path": str(stkpath)})
    np.testing.assert_allclose(fresh.stack.absdata, session.stack.absdata)
    assert fresh.dispatch("inspect_file", {"path": str(stkpath)})["plugin"]


@pytest.mark.parametrize("energies,data", [([1,1], np.ones((3,2,2))), ([2,1], np.ones((3,2,2))),
                                         ([1,2], np.full((3,2,2), np.nan)), ([1], np.ones((3,2,2)))])
def test_bad_scientific_input_is_transactional(tmp_path, energies, data):
    session = session_class()()
    good, original, _ = fixture_file(tmp_path)
    session.dispatch("open", {"path": str(good)})
    bad = tmp_path / "bad.npz"
    np.savez(bad, data=data, energies=energies)
    with pytest.raises(ValueError):
        session.dispatch("open", {"path": str(bad)})
    np.testing.assert_array_equal(session.stack.absdata, original)


def test_4d_i0_and_unknown_format(tmp_path):
    session = session_class()()
    data = np.random.default_rng(4).uniform(10, 20, (4,3,4,5))
    path, _, _ = fixture_file(tmp_path, data=data, theta=np.linspace(0, 160, 5), i0=np.full(4, 100.))
    result = session.dispatch("open", {"path": str(path)})
    assert result["normalized"]
    np.testing.assert_allclose(session.stack.od4d, -np.log(data/100))
    bad = tmp_path / "unknown.xyz"
    bad.write_text("not supported")
    with pytest.raises(ValueError, match="Unsupported"):
        session.dispatch("open", {"path": str(bad)})


def test_exchange_hdf5_explicit_i0_and_unordered_axis(tmp_path):
    import h5py
    session = session_class()()
    data = np.arange(24, dtype=float).reshape(3, 2, 4) + 20
    path = tmp_path / "exchange.h5"
    def save(energies, incident=False):
        with h5py.File(path, "w") as archive:
            archive.create_dataset("implements", data="information:exchange:spectromicroscopy")
            archive.create_dataset("version", data="1.0")
            dataset = archive.create_dataset("exchange/data", data=data)
            dataset.attrs["axes"] = "x:y:energy"
            archive.create_dataset("exchange/energy", data=energies)
            if incident:
                archive.create_dataset("spectromicroscopy/normalization/white_spectrum", data=np.full(4, 100.))
                archive.create_dataset("spectromicroscopy/normalization/white_spectrum_energy", data=energies)
    save([280, 281, 282, 283])
    result = session.dispatch("open", {"path": str(path)})
    assert not result["normalized"]
    np.testing.assert_array_equal(session.stack.absdata, data)
    save([280, 281, 282, 283], incident=True)
    result = session.dispatch("open", {"path": str(path)})
    assert result["normalized"]
    np.testing.assert_allclose(session.stack.od3d, -np.log(data / 100))
    before = session.stack
    save([283, 282, 281, 280])
    with pytest.raises(ValueError, match="increasing"):
        session.dispatch("open", {"path": str(path)})
    assert session.stack is before


def test_nexus_selection_is_explicit_and_never_normalizes_ring_current(tmp_path):
    import h5py
    data = np.arange(24.).reshape(4, 2, 3) + 20
    path = tmp_path / "nexus.hdf5"
    with h5py.File(path, "w") as archive:
        entry = archive.create_group("entry")
        entry.attrs["NX_class"] = "NXentry"
        entry.create_dataset("definition", data=np.array([b"NXstxm"]))
        for index in range(2):
            group = entry.create_group(f"detector{index}")
            group.attrs["NX_class"] = "NXdata"
            group.attrs["axes"] = np.array([b"energy", b"sample_y", b"sample_x"])
            group.create_dataset("data", data=data + index)
            group.create_dataset("energy", data=[280, 281, 282, 283])
            group.create_dataset("sample_x", data=[0, 1, 2])
            group.create_dataset("sample_y", data=[0, 1])
            group.create_dataset("count_time", data=np.ones(4))
    session = session_class()()
    info = session.dispatch("inspect_file", {"path": str(path)})
    assert [row["selection"] for row in info["selections"]] == [[0, 0], [0, 1]]
    assert info["file_size"] > 0
    assert "beamline" in info
    assert info["format"] == "HDF5"
    assert info["selections"][0]["shape"] == [4, 2, 3]
    assert info["selections"][0]["axes"] == ["energy", "sample_y", "sample_x"]
    with pytest.raises(ValueError, match="selection"):
        session.dispatch("open", {"path": str(path)})
    result = session.dispatch("open", {"path": str(path), "selection": [[0, 1]]})
    assert not result["normalized"]
    np.testing.assert_array_equal(session.stack.absdata, (data + 1).transpose(2, 1, 0))
    for selection in ([], [[0]], [[True, 0]], [[0, 9]], [[0, 0, 1]]):
        with pytest.raises(ValueError, match="selection"):
            session.dispatch("open", {"path": str(path), "selection": selection})


@pytest.mark.parametrize("fmt", ["npz", "hdf5"])
def test_reexport_preserves_original_data_axes_and_incident_spectrum(tmp_path, fmt):
    import h5py
    session = session_class()()
    data = np.arange(3 * 2 * 4 * 2, dtype=float).reshape(3, 2, 4, 2) + 10
    path, _, energies = fixture_file(tmp_path, data=data, theta=[0, 90], i0=np.full(4, 100.))
    session.dispatch("open", {"path": str(path)})
    session.dispatch("crop", {"bounds": [1, 0, 3, 2], "energy_range": [1, 4]})
    session.dispatch("normalize", {"mode": "roi", "bounds": [0, 0, 1, 1]})
    first, second = tmp_path / f"first.{fmt}", tmp_path / f"second.{fmt}"
    session.dispatch("export", {"path": str(first), "format": fmt})
    reopened = session_class()()
    reopened.dispatch("open", {"path": str(first)})
    np.testing.assert_array_equal(reopened.stack.i0data, session.stack.i0data)
    reopened.dispatch("export", {"path": str(second), "format": fmt})
    if fmt == "npz":
        with np.load(second) as archive:
            np.testing.assert_array_equal(archive["raw_data"], data)
            np.testing.assert_array_equal(archive["raw_energies"], energies)
            np.testing.assert_array_equal(archive["raw_theta"], [0, 90])
            np.testing.assert_array_equal(archive["od"], session.stack.od4d)
    else:
        with h5py.File(second) as archive:
            np.testing.assert_array_equal(archive["raw/data"], data)
            np.testing.assert_array_equal(archive["raw/energy"], energies)
            np.testing.assert_array_equal(archive["raw/theta"], [0, 90])
            np.testing.assert_array_equal(archive["normalization/od"], session.stack.od4d)


def test_build_stack_protects_every_source_and_failed_build_is_atomic(tmp_path):
    from PIL import Image
    files = []
    for index in range(2):
        path = tmp_path / f"frame{index}.tif"
        Image.fromarray(np.full((2, 3), index + 10, dtype=np.uint16)).save(path)
        files.append(str(path))
    originals = [open(path, "rb").read() for path in files]
    session = session_class()()
    session.dispatch("build_stack", {"paths": files, "energies": [280, 281]})
    before = session.stack
    for energies in ([280, 280], [281, 280], [280]):
        with pytest.raises(ValueError):
            session.dispatch("build_stack", {"paths": files, "energies": energies})
        assert session.stack is before
    for path in files:
        with pytest.raises(ValueError, match="input"):
            session.dispatch("export", {"path": path, "format": "npz", "overwrite": True})
    assert [open(path, "rb").read() for path in files] == originals


def test_inspect_file_resolves_mistral_and_signature_beamline():
    from pathlib import Path
    session = session_class()()
    mistral_path = (
        Path(__file__).resolve().parent.parent
        / "docs/Datasets/ALBA_BL09_MISTRAL/mistral_hdf5/20230629_E1A_749.7x177.5y_specnorm_aliOF.hdf5"
    )
    if mistral_path.exists():
        info = session.dispatch("inspect_file", {"path": str(mistral_path)})
        assert info["format"] == "HDF5"
        assert info["plugin"] == "MISTRAL-ALBA"
        assert info["beamline"] == "MISTRAL (BL09) - ALBA"

