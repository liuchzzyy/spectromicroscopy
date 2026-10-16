"""Comprehensive test suite for data, image, and workflow log exports."""
import csv
import json
from pathlib import Path

import h5py
import numpy as np
from PIL import Image
import pytest

from mantis_xray.core.session import Session


@pytest.fixture
def sample_session(tmp_path):
    """Fixture providing an active session with loaded data, ROIs, and analysis."""
    # Synthetic transmission stack (values ~ 0.2 to 0.9)
    data = np.linspace(0.2, 0.9, 12 * 10 * 6, dtype=float).reshape(12, 10, 6)
    energies = np.linspace(630.0, 660.0, 6)
    source = tmp_path / "sample_stack.npz"
    np.savez(source, data=data, energies=energies)

    session = Session()
    session.dispatch("open", {"path": str(source), "pre_normalized": False})

    # Add ROIs
    session.dispatch("view", {
        "energy_index": 2,
        "rois": [
            {"bounds": [1, 1, 5, 5], "label": "[1] ROI 1"},
            {"bounds": [6, 6, 10, 9], "label": "[2] ROI 2"}
        ]
    })

    # Normalize stack to enable OD and run PCA / Clustering
    session.dispatch("normalize", {"mode": "roi", "bounds": [0, 0, 2, 2]})
    session.dispatch("pca", {"components": 2})
    session.dispatch("cluster", {"clusters": 2, "components": 2, "seed": 42})

    return session, source, data, energies


# =========================================================================
# 1. 数据导出功能测试 (Data Export Tests)
# =========================================================================

def test_data_export_npz_full_and_selective(sample_session, tmp_path):
    session, source, data, energies = sample_session

    # 1.1 Full NPZ export
    target_all = tmp_path / "all_data.npz"
    res_all = session.dispatch("export", {"path": str(target_all), "format": "npz", "overwrite": True})
    assert target_all.is_file() and target_all.stat().st_size > 0
    with np.load(target_all) as archive:
        assert "data" in archive
        assert "raw_data" in archive
        assert "energies" in archive
        assert "od" in archive
        assert "results/pca/eigenvals" in archive
        assert "results/cluster/cluster_indices" in archive
        np.testing.assert_allclose(archive["raw_data"], data)
        np.testing.assert_allclose(archive["energies"], energies)
        # Stored OD should match session computed OD
        assert archive["od"].shape == data.shape
        np.testing.assert_allclose(archive["od"], session.stack.od3d)

    # 1.2 Processed-only NPZ export
    target_proc = tmp_path / "processed_only.npz"
    session.dispatch("export", {"path": str(target_proc), "format": "npz", "include": ["processed"], "overwrite": True})
    with np.load(target_proc) as archive:
        assert "data" in archive and "energies" in archive
        assert "raw_data" not in archive
        assert "od" not in archive

    # 1.3 Spectra-only NPZ export
    target_spec = tmp_path / "spectra_only.npz"
    session.dispatch("export", {"path": str(target_spec), "format": "npz", "include": ["spectra"], "overwrite": True})
    with np.load(target_spec) as archive:
        assert "spectra/y/0" in archive
        assert "spectra/x/0" in archive
        assert "spectra/name/0" in archive

    # 1.4 Single spectrum NPZ export (matches a displayed spectrum)
    target_cluster1 = tmp_path / "cluster1_spectrum.npz"
    session.dispatch("export", {"path": str(target_cluster1), "format": "npz", "include": ["spectra"], "spectrum_name": "Cluster 1", "overwrite": True})
    with np.load(target_cluster1) as archive:
        assert archive["spectra/name/0"].item() == "Cluster 1"
        assert "spectra/name/1" not in archive


def test_data_export_hdf5_full_and_selective(sample_session, tmp_path):
    session, source, data, energies = sample_session

    # 2.1 Full HDF5 export (standard Exchange layout)
    target_all = tmp_path / "full_export.hdf5"
    session.dispatch("export", {"path": str(target_all), "format": "hdf5", "overwrite": True})
    assert target_all.is_file() and target_all.stat().st_size > 0
    with h5py.File(target_all, "r") as f:
        assert "exchange/data" in f
        assert "exchange/energy" in f
        assert "raw/data" in f
        assert "normalization/od" in f
        assert "provenance/source" in f
        assert "provenance/history" in f
        assert f.attrs["mantis_session_version"] == 1
        np.testing.assert_allclose(f["raw/data"][:], data)
        np.testing.assert_allclose(f["exchange/energy"][:], energies)

    # 2.2 Raw-only HDF5 export
    target_raw = tmp_path / "raw_only.hdf5"
    session.dispatch("export", {"path": str(target_raw), "format": "hdf5", "include": ["raw"], "overwrite": True})
    with h5py.File(target_raw, "r") as f:
        assert "raw/data" in f
        assert "exchange/data" not in f


def test_data_export_csv_spectra(sample_session, tmp_path):
    session, source, _, energies = sample_session

    # 3.1 CSV export of currently visible cluster spectra
    target_csv = tmp_path / "cluster_spectra.csv"
    session.dispatch("export", {"path": str(target_csv), "format": "csv", "overwrite": True})
    assert target_csv.is_file() and target_csv.stat().st_size > 0

    with open(target_csv, "r", encoding="utf-8") as f:
        rows = list(csv.reader(f))
        assert rows[0] == ["spectrum", "x", "y"]
        assert len(rows) == 1 + len(energies) * 2  # header + 2 clusters * energies
        names = {row[0] for row in rows[1:]}
        assert "Cluster 1" in names
        assert "Cluster 2" in names

    # 3.2 CSV export of stack ROI spectra when viewing stack
    session.dispatch("view", {
        "energy_index": 0,
        "rois": [{"bounds": [1, 1, 3, 3], "label": "[1] ROI 1"}]
    })
    target_roi_csv = tmp_path / "roi_spectra.csv"
    session.dispatch("export", {"path": str(target_roi_csv), "format": "csv", "overwrite": True})
    with open(target_roi_csv, "r", encoding="utf-8") as f:
        roi_rows = list(csv.reader(f))
        assert roi_rows[0] == ["spectrum", "x", "y"]
        roi_names = {row[0] for row in roi_rows[1:]}
        assert "Pixel" in roi_names
        assert "[1] ROI 1" in roi_names


# =========================================================================
# 2. 图片导出功能测试 (Image Export Tests)
# =========================================================================

def test_image_export_png_resolutions_and_dpi(sample_session, tmp_path):
    session, _, _, _ = sample_session

    img_150 = (0, 0)
    img_300 = (0, 0)
    for dpi in [150, 300, 600]:
        target_png = tmp_path / f"figure_{dpi}dpi.png"
        session.dispatch("export", {"path": str(target_png), "format": "png", "dpi": dpi, "overwrite": True})
        assert target_png.is_file()
        assert target_png.stat().st_size > 0
        # Magic bytes check
        assert target_png.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
        with Image.open(target_png) as img:
            assert img.format == "PNG"
            assert img.width > 0 and img.height > 0
            if dpi == 150:
                img_150 = img.size
            elif dpi == 300:
                img_300 = img.size
                assert img.width > img_150[0] and img.height > img_150[1]
            elif dpi == 600:
                assert img.width > img_300[0] and img.height > img_300[1]


def test_image_export_pdf_and_svg(sample_session, tmp_path):
    session, _, _, _ = sample_session

    # PDF export
    target_pdf = tmp_path / "chart_export.pdf"
    session.dispatch("export", {"path": str(target_pdf), "format": "pdf", "overwrite": True})
    assert target_pdf.is_file() and target_pdf.stat().st_size > 0
    assert target_pdf.read_bytes()[:4] == b"%PDF"

    # SVG export
    target_svg = tmp_path / "chart_export.svg"
    session.dispatch("export", {"path": str(target_svg), "format": "svg", "overwrite": True})
    assert target_svg.is_file() and target_svg.stat().st_size > 0
    content = target_svg.read_text(encoding="utf-8")
    assert "<svg" in content and "</svg>" in content


# =========================================================================
# 3. 工作日志导出功能测试 (Work Log Export Tests)
# =========================================================================

def test_worklog_export_json(sample_session, tmp_path):
    session, source, data, energies = sample_session

    target_json = tmp_path / "worklog.json"
    session.dispatch("export", {"path": str(target_json), "format": "json", "overwrite": True})
    assert target_json.is_file() and target_json.stat().st_size > 0

    log = json.loads(target_json.read_text(encoding="utf-8"))
    assert log["source"] == str(source)
    assert log["shape"] == list(data.shape)
    assert log["normalized"] is True
    assert "history" in log
    methods = [step["method"] for step in log["history"]]
    assert "open" in methods
    assert "pca" in methods
    assert "cluster" in methods
    assert "export" in methods
    assert "metrics" in log
    assert log["metrics"].get("clusters") == "2"


def test_worklog_export_markdown(sample_session, tmp_path):
    session, source, data, energies = sample_session

    target_md = tmp_path / "worklog.md"
    session.dispatch("export", {"path": str(target_md), "format": "md", "overwrite": True})
    assert target_md.is_file() and target_md.stat().st_size > 0

    text = target_md.read_text(encoding="utf-8")
    assert "# MANTiS 工作日志" in text
    assert "## 数据源信息" in text
    assert str(source) in text
    assert "## 执行命令与参数历史" in text
    assert "pca" in text
    assert "cluster" in text
    assert "## 分析指标与计算结果" in text
    assert "clusters" in text
