"""Translate legacy settings, without importing GUI or altering numerical inputs."""
from pathlib import Path

FLAGS = {"ALIGN_STACK", "I0_HISTOGRAM", "SAVE_HDF5", "RUN_PCA", "RUN_CLUSTER_ANALYSIS",
         "THICKNESS_CORRECTION", "RUN_SPECTRAL_ANALYSIS", "SA_USE_CA_SPECTRA", "RUN_KEY_ENGS",
         "SAVE_PNG", "SAVE_PDF", "SAVE_SVG"}
INTEGERS = FLAGS | {"N_SPCA", "N_CLUSTERS"}
TEXT = {"VERSION", "WORK_DIR", "OUTPUT_DIR_NAME", "FILENAME", "I0_FILE", "SA_SPECTRUM"}


def parse_settings(path):
    values: dict = {"SA_SPECTRUM": []}
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"Missing colon on settings line {number}")
        key, value = (v.strip() for v in line.split(":", 1))
        if key not in INTEGERS | TEXT | {"KE_THRESHOLD"}:
            raise ValueError(f"Unknown batch setting {key} on line {number}")
        if key in values and key != "SA_SPECTRUM":
            raise ValueError(f"Duplicate batch setting {key}")
        if key in INTEGERS:
            value = int(value)
            if key in FLAGS and value not in (0, 1):
                raise ValueError(f"{key} must be 0 or 1")
            if key not in FLAGS and value < 1:
                raise ValueError(f"{key} must be positive")
        elif key == "KE_THRESHOLD":
            value = float(value)
        else:
            value = value.strip("\"'")
        if key == "SA_SPECTRUM":
            if value:
                values[key].append(value)
        else:
            values[key] = value
    return values


def to_pipeline(settings, base):
    base = Path(base).absolute()
    work = Path(settings.get("WORK_DIR") or ".").expanduser()
    work = work if work.is_absolute() else base / work
    name = settings.get("FILENAME")
    if not name:
        raise ValueError("FILENAME is required")
    steps = []
    def add(method, **params):
        steps.append({"method": method, "params": params})
    add("open", path=str(work / name))
    if settings.get("ALIGN_STACK", 0):
        add("align", reference=0, upsample_factor=1, crop=False)
    if settings.get("I0_HISTOGRAM", 0):
        # Historical automatic brightest-2%-of-maximum rule is explicit and recorded.
        add("normalize", mode="histogram", fraction_min=0.98)
    elif settings.get("I0_FILE"):
        add("normalize", mode="file", path=str(work / settings["I0_FILE"]))
    components = settings.get("N_SPCA", 4)
    if settings.get("RUN_PCA") or settings.get("RUN_CLUSTER_ANALYSIS") or settings.get("RUN_KEY_ENGS"):
        add("pca", components=components)
    if settings.get("RUN_CLUSTER_ANALYSIS"):
        add("cluster", clusters=settings.get("N_CLUSTERS", 5), components=components,
            remove_first=bool(settings.get("THICKNESS_CORRECTION", 0)), seed=0)
    if settings.get("RUN_SPECTRAL_ANALYSIS"):
        add("spectral", paths=[str(work / p) for p in settings["SA_SPECTRUM"]],
            add_clusters=bool(settings.get("SA_USE_CA_SPECTRA", 0)))
    if settings.get("RUN_KEY_ENGS"):
        add("key_energies", threshold=settings.get("KE_THRESHOLD", 0.1))
    output = work / settings.get("OUTPUT_DIR_NAME", "MantisResults")
    stem = Path(name).stem
    if settings.get("SAVE_HDF5", 0):
        add("export", path=str(output / (stem + "_analysis.hdf5")), format="hdf5")
    for fmt in ("png", "pdf", "svg"):
        if settings.get("SAVE_" + fmt.upper(), int(fmt == "png")):
            add("export", path=str(output / (stem + "_analysis." + fmt)), format=fmt)
    return {"protocol": 1, "steps": steps}
