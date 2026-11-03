"""Kompatibilitäts-Shim für mflux 0.23 mit Pillow 13.

Pillow 13 hat ``PIL._typing`` entfernt; mflux importiert daraus noch
``StrOrBytesPath``. Dieses Modul wird über PYTHONPATH nur für den
mflux-Subprozess geladen und stellt den Namen bereit, ohne Pillow zu patchen.
"""

import sys
import types
from os import PathLike
from typing import Union

try:  # Pillow 12 und älter
    import PIL._typing  # noqa: F401
except (ModuleNotFoundError, ImportError):
    module = types.ModuleType("PIL._typing")
    module.StrOrBytesPath = Union[str, bytes, PathLike]  # type: ignore[attr-defined]
    sys.modules["PIL._typing"] = module
