"""Standardized Beamline Hash Dictionary & Signature Resolver for spectromicroscopy / Mantis.

Provides O(1) string lookup and automatic file signature detection (format, plugin, beamline).
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

_CORE_DIR = Path(__file__).resolve().parent
_DATA_FILE = _CORE_DIR / "beamline_hash_map.json"

with open(_DATA_FILE, "r", encoding="utf-8") as _f:
    _PAYLOAD = json.load(_f)

BEAMLINE_HASH_MAP: Dict[str, Dict[str, Any]] = _PAYLOAD["hash_map"]
BEAMLINE_ENTRIES: List[Dict[str, Any]] = _PAYLOAD["entries"]
FILE_SIGNATURES: List[Dict[str, Any]] = _PAYLOAD["file_signatures"]


def resolve_beamline(raw: Optional[str]) -> str:
    """Lookup a raw beamline string (e.g. 'PolLux', 'X07DA', 'MISTRAL', 'BL09', 'BL08U1-A')
    and return the standardized '线站缩写/ID - 设施, 国家' label.
    """
    if not raw:
        return "Default"
    stripped = raw.strip()
    if not stripped:
        return "Default"
    key = stripped.upper()
    if key in BEAMLINE_HASH_MAP:
        return BEAMLINE_HASH_MAP[key]["formatted"]
    return stripped


def get_beamline_dataset_id(raw: Optional[str]) -> str:
    """Returns the unique dataset directory ID or 'Default'."""
    if not raw:
        return "Default"
    key = raw.strip().upper()
    if key in BEAMLINE_HASH_MAP:
        return BEAMLINE_HASH_MAP[key].get("dataset_id", "Default")
    return "Default"


def get_beamline_info(raw: Optional[str]) -> Optional[Dict[str, Any]]:
    """Returns full metadata for the given beamline key or dataset ID."""
    if not raw:
        return None
    return BEAMLINE_HASH_MAP.get(raw.strip().upper())


def inspect_data_file(filepath: Union[str, Path]) -> Dict[str, Any]:
    """Inspects an unknown data file, matches its unique internal fields/signatures,
    and returns format, file plugin, and beamline provenance.
    """
    path = Path(filepath)
    if not path.is_file():
        return {
            "format": "Default",
            "plugin": "Default",
            "beamline": "Default",
            "facility": "Default",
            "country": "Default",
            "matched": False,
        }

    ext = path.suffix.lower()

    # 1. HDF5 / NeXus inspection
    if ext in [".h5", ".hdf5", ".nxs", ".stxm"]:
        try:
            import h5py

            with h5py.File(path, "r") as f:
                # MISTRAL ALBA Cryo-TXM
                if "SpecNormalized" in f:
                    return {
                        "format": "MISTRAL Cryo-TXM HDF5",
                        "plugin": "file_mistral_hdf5",
                        "beamline": "MISTRAL (BL09) - ALBA, Spain",
                        "facility": "ALBA",
                        "country": "Spain",
                        "matched_signature": "ALBA_MISTRAL_HDF5",
                        "matched_field": "Group: /SpecNormalized",
                        "matched": True,
                    }

                # NeXus NXstxm with collection/beamline
                for entry_name in f:
                    entry = f[entry_name]
                    if hasattr(entry, "__getitem__"):
                        bl_path = f"{entry_name}/collection/beamline"
                        if bl_path in f:
                            try:
                                bl_val = str(f[bl_path][()])
                                if "PolLux" in bl_val:
                                    return {
                                        "format": "NeXus NXstxm HDF5",
                                        "plugin": "file_nexus_hdf5",
                                        "beamline": "PolLux (X07DA) - SLS, Switzerland",
                                        "facility": "SLS",
                                        "country": "Switzerland",
                                        "matched_signature": "SLS_POLLUX_NXSTXM",
                                        "matched_field": f"{bl_path} == {bl_val}",
                                        "matched": True,
                                    }
                                elif "Hermes" in bl_val:
                                    return {
                                        "format": "NeXus NXstxm HDF5",
                                        "plugin": "file_nexus_hdf5",
                                        "beamline": "HERMES - SOLEIL, France",
                                        "facility": "SOLEIL",
                                        "country": "France",
                                        "matched_signature": "SOLEIL_HERMES_NXSTXM",
                                        "matched_field": f"{bl_path} == {bl_val}",
                                        "matched": True,
                                    }
                            except Exception:
                                pass

                # Data Exchange HDF5
                if "exchange" in f:
                    impl = str(f["implements"][()]) if "implements" in f else ""
                    if "spectromicroscopy" in impl:
                        return {
                            "format": "Data Exchange HDF5",
                            "plugin": "file_dataexch_hdf5",
                            "beamline": "I14 - DLS, UK",
                            "facility": "DLS",
                            "country": "UK",
                            "matched_signature": "DIAMOND_I14_DATAEXCH",
                            "matched_field": "implements: spectromicroscopy",
                            "matched": True,
                        }
                    return {
                        "format": "Data Exchange TXM HDF5",
                        "plugin": "file_dataexch_hdf5",
                        "beamline": "TXM (32-ID) - APS, USA",
                        "facility": "APS",
                        "country": "USA",
                        "matched_signature": "APS_32ID_DATAEXCH",
                        "matched_field": "Group: /exchange",
                        "matched": True,
                    }

                # ALS Micro-CT HDF5
                if "facility" in f.attrs and "end_station" in f.attrs:
                    fac_attr = str(f.attrs["facility"])
                    end_attr = str(f.attrs["end_station"])
                    if "als" in fac_attr.lower() and "bl832" in end_attr.lower():
                        return {
                            "format": "ALS Micro-CT HDF5",
                            "plugin": "file_hdf5",
                            "beamline": "8.3.2 - ALS, USA",
                            "facility": "ALS",
                            "country": "USA",
                            "matched_signature": "ALS_832_MICROCT",
                            "matched_field": f"attrs: facility={fac_attr}, end_station={end_attr}",
                            "matched": True,
                        }
        except Exception:
            pass

    # 2. SDF (.hdr) inspection
    elif ext == ".hdr":
        try:
            content = path.read_text(errors="ignore")
            m = re.search(r'Label\s*=\s*"([^"]+)"', content)
            label = m.group(1) if m else path.name
            if label.startswith("Sol_"):
                return {
                    "format": "aXis2000 SDF (HDR + XIM)",
                    "plugin": "file_sdf",
                    "beamline": "DEMETER - SOLARIS, Poland",
                    "facility": "SOLARIS",
                    "country": "Poland",
                    "matched_signature": "SOLARIS_DEMETER_SDF",
                    "matched_field": f"HDR Label prefix Sol_ ({label})",
                    "matched": True,
                }
            elif label.startswith("532_"):
                return {
                    "format": "aXis2000 SDF (HDR + XIM)",
                    "plugin": "file_sdf",
                    "beamline": "STXM (5.3.2) - ALS, USA",
                    "facility": "ALS",
                    "country": "USA",
                    "matched_signature": "ALS_532_SDF",
                    "matched_field": f"HDR Label prefix 532_ ({label})",
                    "matched": True,
                }
            elif label.startswith("Max_"):
                return {
                    "format": "aXis2000 SDF (HDR + XIM)",
                    "plugin": "file_sdf",
                    "beamline": "SoftiMAX - MAX IV, Sweden",
                    "facility": "MAX IV",
                    "country": "Sweden",
                    "matched_signature": "MAXIV_SOFTIMAX_SDF",
                    "matched_field": f"HDR Label prefix Max_ ({label})",
                    "matched": True,
                }
            elif re.match(r"^\d{8}\.hdr$", label):
                return {
                    "format": "aXis2000 SDF (HDR + XIM)",
                    "plugin": "file_sdf",
                    "beamline": "STXM (11.0.2.2) - ALS, USA",
                    "facility": "ALS",
                    "country": "USA",
                    "matched_signature": "ALS_1102_SDF",
                    "matched_field": f"HDR 8-digit scan ({label})",
                    "matched": True,
                }
        except Exception:
            pass

    # 3. Text / XAFS inspection (.dat, .xdi, .txt)
    elif ext in [".dat", ".xdi", ".txt"]:
        try:
            lines = path.read_text(errors="ignore").splitlines()[:25]
            head = "\n".join(lines)
            if "KEK-PF" in head:
                return {
                    "format": "KEK-PF EXAFS ASCII",
                    "plugin": "file_xafs_dat",
                    "beamline": "XRD (BL-12C) - PF, Japan",
                    "facility": "PF",
                    "country": "Japan",
                    "matched_signature": "PF_BL12C_EXAFS",
                    "matched_field": "Header: KEK-PF",
                    "matched": True,
                }
            elif "CLS Data Acquisition" in head:
                return {
                    "format": "CLS Data Acquisition ASCII",
                    "plugin": "file_xafs_dat",
                    "beamline": "HXMA (06ID-1) - CLS, Canada",
                    "facility": "CLS",
                    "country": "Canada",
                    "matched_signature": "CLS_06ID1_HXMA",
                    "matched_field": "Header: CLS Data Acquisition",
                    "matched": True,
                }
            elif "APS 10BM" in head or "MRCAT_XAFS" in head:
                return {
                    "format": "MRCAT XAFS ASCII",
                    "plugin": "file_xafs_dat",
                    "beamline": "XAS (10-BM-B) - APS, USA",
                    "facility": "APS",
                    "country": "USA",
                    "matched_signature": "APS_10BM_MRCAT",
                    "matched_field": "Header: APS 10BM",
                    "matched": True,
                }
            elif "13IDE:" in head:
                return {
                    "format": "XDI Epics StepScan",
                    "plugin": "file_xafs_dat",
                    "beamline": "XAS (13-ID-C) - APS, USA",
                    "facility": "APS",
                    "country": "USA",
                    "matched_signature": "APS_13IDC_XDI",
                    "matched_field": "Header: 13IDE:En:Energy.VAL",
                    "matched": True,
                }
            elif "04BM-BMB" in head or "XF:04BM" in head:
                return {
                    "format": "XDI Epics StepScan",
                    "plugin": "file_xdi",
                    "beamline": "XFM (4-BM) - NSLS-II, USA",
                    "facility": "NSLS-II",
                    "country": "USA",
                    "matched_signature": "NSLS2_4BM_XFM",
                    "matched_field": "Header: XF:04BM-BMB",
                    "matched": True,
                }
            elif "BMM (06BM)" in head or "ISS (8-ID)" in head:
                return {
                    "format": "XDI BlueSky ASCII",
                    "plugin": "file_xafs_dat",
                    "beamline": "BMM (6-BM) - NSLS-II, USA",
                    "facility": "NSLS-II",
                    "country": "USA",
                    "matched_signature": "NSLS2_6BM_BMM",
                    "matched_field": "Header: BMM (06BM)",
                    "matched": True,
                }
            elif "SOLEIL ROCK Quick-EXAFS" in head:
                return {
                    "format": "SOLEIL ROCK Quick-EXAFS",
                    "plugin": "file_xafs_txt",
                    "beamline": "ROCK - SOLEIL, France",
                    "facility": "SOLEIL",
                    "country": "France",
                    "matched_signature": "SOLEIL_ROCK_QEXAFS",
                    "matched_field": "Header: SOLEIL ROCK Quick-EXAFS",
                    "matched": True,
                }
        except Exception:
            pass

    # 4. Zeiss Xradia (.xrm, .txrm)
    elif ext in [".xrm", ".txrm"]:
        return {
            "format": "Zeiss Xradia TXRM",
            "plugin": "file_xrm",
            "beamline": "TXRM (Xradia) - Laboratory, USA",
            "facility": "Laboratory",
            "country": "USA",
            "matched_signature": "ZEISS_XRADIA_TXRM",
            "matched_field": "OLE2 container (.xrm/.txrm)",
            "matched": True,
        }

    return {
        "format": "Default",
        "plugin": "Default",
        "beamline": "Default",
        "facility": "Default",
        "country": "Default",
        "matched": False,
    }
