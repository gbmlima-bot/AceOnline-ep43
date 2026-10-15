"""Offline framing for the documented legacy unencoded envelope subset."""

from .framing import (
    HEADER_SIZE,
    LEGACY_RECEIVE_BODY_CEILING,
    MAX_PAYLOAD_SIZE,
    Frame,
    FrameError,
    PlainFrameParser,
    encode_unencoded,
)

__all__ = [
    "HEADER_SIZE",
    "LEGACY_RECEIVE_BODY_CEILING",
    "MAX_PAYLOAD_SIZE",
    "Frame",
    "FrameError",
    "PlainFrameParser",
    "encode_unencoded",
]
