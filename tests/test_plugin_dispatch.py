"""Schema dispatch must not depend on plugin registration order."""
from types import SimpleNamespace

import pytest

from mantis_xray import file_plugins


def reader(name, extensions, matches=True, priority=0):
    return SimpleNamespace(title=name, extension=extensions,
                           identify=lambda path: matches, identify_priority=priority)


def test_ambiguous_schema_is_not_silently_selected(monkeypatch):
    monkeypatch.setattr(file_plugins, "plugins", [reader("A", ["*.h5"]), reader("B", ["*.h5"])])
    with pytest.raises(ValueError, match="Ambiguous.*A.*B"):
        file_plugins.identify("sample.h5")


def test_explicit_schema_priority_is_order_independent(monkeypatch):
    generic = reader("generic", ["*.h5"])
    specific = reader("specific", ["*.h5"], priority=10)
    for candidates in ([generic, specific], [specific, generic]):
        monkeypatch.setattr(file_plugins, "plugins", candidates)
        assert file_plugins.identify("sample.h5") is specific


def test_extension_matching_is_case_insensitive(monkeypatch):
    plugin = reader("TIFF", ["*.tif"])
    monkeypatch.setattr(file_plugins, "plugins", [plugin])
    assert file_plugins.identify("sample.TIF") is plugin


def test_extension_alone_does_not_claim_file(monkeypatch):
    monkeypatch.setattr(file_plugins, "plugins", [reader("A", ["*.h5"], matches=False)])
    assert file_plugins.identify("sample.h5") is None
