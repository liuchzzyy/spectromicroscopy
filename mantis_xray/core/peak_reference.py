"""Peak-ID reference values preserved verbatim from the original Qt page.

Source: mantis_xray/gui/pages/peak_id.py, PagePeakID.initUI, lines 33–34.
That page supplied no per-peak citations. None are invented here. These labels
are a comparison guide, not automatic chemical attribution or fit certainty.
"""
PEAK_REFERENCE = tuple(
    {'energy': energy, 'label': label, 'unit': 'eV', 'citation': None,
     'source': 'mantis_xray/gui/pages/peak_id.py:33-34 (original GUI)'}
    for energy, label in zip(
        (285.0, 286.5, 288.5, 289.5, 290.5),
        ('aromatic', 'phenolic', 'carboxyl', 'alkyl', 'carbonyl'))
)
