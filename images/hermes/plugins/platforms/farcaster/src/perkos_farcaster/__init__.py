"""perkos_farcaster — Hermes platform adapter for Farcaster.

Exposes :class:`FarcasterAdapter` and the :func:`register` entry point
called by Hermes's plugin loader. See ``plugin.yaml`` for the contract.
"""

from .adapter import FarcasterAdapter
from .plugin import register

__all__ = ["FarcasterAdapter", "register"]
__version__ = "0.1.0"
