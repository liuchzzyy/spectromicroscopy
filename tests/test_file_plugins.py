"""File-plugin coverage for the MISTRAL-ALBA HDF5 variants.

The beamline writes two normalized layouts: `spectroscopy_normalized_aligned`
(with a per-energy transform matrix) and the plain `spectroscopy_normalized`
without it. Both are the same spectromicroscopy stack and both must load.
"""
import h5py
import json
import numpy as np
import pytest

from mantis_xray.file_plugins import file_mistral_hdf5 as mistral


def write_stack(path, dataset_name, shape=(6, 5, 4), with_transform=True):
    """Create a small MISTRAL-shaped file; shape is (n_energy, y, x)."""
    n_energy, rows, cols = shape
    energies = np.linspace(640.0, 660.0, n_energy)
    data = np.arange(n_energy * rows * cols, dtype="float32").reshape(shape) / 100.0 + 0.5
    with h5py.File(path, "w") as f:
        group = f.create_group("SpecNormalized")
        group.create_dataset(dataset_name, data=data)
        group.create_dataset("energy", data=energies)
        group.create_dataset("x_pixel_size", data=np.array([0.013]))
        group.create_dataset("y_pixel_size", data=np.array([0.013]))
        group.create_dataset("Currents", data=np.full(n_energy, 250.0))
        group.create_dataset("ExpTimes", data=np.full(n_energy, 1.0))
        group.create_dataset("rotation_angle", data=np.zeros(n_energy))
        if with_transform:
            group.create_dataset("spectroscopy_normalized_trans",
                                 data=np.tile(np.eye(3), (n_energy, 1, 1)))
    return data, energies


@pytest.mark.parametrize("dataset_name", ["spectroscopy_normalized_aligned", "spectroscopy_normalized"])
def test_identify_accepts_both_normalized_layouts(tmp_path, dataset_name):
    path = tmp_path / "stack.hdf5"
    write_stack(path, dataset_name)
    assert mistral.identify(str(path)) is True


def test_session_opens_plain_normalized_variant_with_correct_axes(tmp_path):
    """MANTiS stores (x, y, energy); the file stores (energy, y, x). No value may change."""
    from mantis_xray.core.session import Session

    path = tmp_path / "stack.hdf5"
    data, energies = write_stack(path, "spectroscopy_normalized")

    session = Session()
    result = session.dispatch("open", {"path": str(path)})

    assert result["shape"] == [4, 5, 6]                     # (x, y, energy)
    np.testing.assert_array_equal(session.stack.ev, energies)
    assert result["spatial"]["unit"] == "µm"
    np.testing.assert_allclose(np.diff(result["spatial"]["x"]), 0.013)
    np.testing.assert_allclose(np.diff(result["spatial"]["y"]), 0.013)
    display = result["images"][0]
    width, height = display["width"], display["height"]
    assert (width, height) == (4, 5)                        # columns x, rows y
    # The displayed frame must reproduce the file's energy-0 slice unchanged.
    np.testing.assert_allclose(
        np.array(display["values"]).reshape(height, width), data[0], rtol=0, atol=1e-6)
    json.dumps(result, allow_nan=False)


def test_mistral_reader_closes_file_when_dataset_is_malformed(tmp_path, monkeypatch):
    from mantis_xray.core.session import Session
    path = tmp_path / 'broken.hdf5'
    write_stack(path, 'spectroscopy_normalized')
    with h5py.File(path, 'r+') as file:
        del file['SpecNormalized/x_pixel_size']
        file.create_dataset('SpecNormalized/x_pixel_size', data=[])
    opened = []
    real_file = h5py.File

    def tracked_file(*args, **kwargs):
        handle = real_file(*args, **kwargs)
        opened.append(handle)
        return handle

    monkeypatch.setattr(h5py, 'File', tracked_file)
    with pytest.raises((IndexError, ValueError)):
        Session().open(path)
    assert opened
    assert all(not handle.id.valid for handle in opened)


def test_mistral_probe_closes_file_on_malformed_structure(tmp_path, monkeypatch):
    path = tmp_path / 'malformed.hdf5'
    with h5py.File(path, 'w') as file:
        file.create_dataset('SpecNormalized', data=1)
    opened = []
    real_file = h5py.File

    def tracked_file(*args, **kwargs):
        handle = real_file(*args, **kwargs)
        opened.append(handle)
        return handle

    monkeypatch.setattr(h5py, 'File', tracked_file)
    assert mistral.identify(str(path)) is False
    assert mistral.GetFileStructure(str(path)) is None
    assert opened and all(not handle.id.valid for handle in opened)


def test_missing_required_dataset_is_not_claimed(tmp_path):
    path = tmp_path / "broken.hdf5"
    with h5py.File(path, "w") as f:
        group = f.create_group("SpecNormalized")
        group.create_dataset("energy", data=np.arange(4.0))
    assert mistral.identify(str(path)) is False
