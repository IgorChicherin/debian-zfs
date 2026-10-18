"""Import this first in every test so the installer and script modules are importable."""
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
for _dir in ("install", "scripts"):
    sys.path.insert(0, os.path.join(_here, "..", _dir))
