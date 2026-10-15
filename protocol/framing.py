"""Offline, incremental framing of legacy envelopes with encoding bit clear.

This module accepts the ORIGINAL four-byte header of an unencoded envelope.
It does not accept encoded traffic, or reconstruct headers around decoded bodies.
The body stays opaque: no message, credential, checksum or session interpretation.
Little-endian is an explicit profile derived from Windows x86 native operations;
these synthetic vectors are not evidence of compatibility with captured traffic.
See README.txt for provenance, differing sender/receiver limits and limitations.
"""

from dataclasses import dataclass
import struct

HEADER_SIZE = 4
MAX_PAYLOAD_SIZE = 1492
LEGACY_RECEIVE_BODY_CEILING = 1496
_HEADER = struct.Struct("<HBB")
_BytesLike = bytes | bytearray | memoryview


class FrameError(ValueError):
    """A deterministic framing error; ``code`` is shared with GDScript tests."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class Frame:
    """An opaque body and raw header metadata, without session semantics."""

    payload: bytes
    raw_sequence: int
    raw_flags: int


def _bytes(value: _BytesLike) -> bytes:
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise TypeError("expected bytes, bytearray or memoryview")
    return bytes(value)


def encode_unencoded(payload: _BytesLike) -> bytes:
    """Build a synthetic unencoded envelope like the legacy sender's raw branch.

    The sender accepts 1..1492 body bytes and always writes flags=sequence=0.
    This is not an encoder for protected/encoded traffic or game messages.
    """
    body = _bytes(payload)
    if not 1 <= len(body) <= MAX_PAYLOAD_SIZE:
        raise FrameError("invalid_length")
    return _HEADER.pack(len(body), 0, 0) + body


class PlainFrameParser:
    """Reassemble unencoded envelopes from arbitrary OFFLINE byte fragments.

    The receive limit is 1496, following the inspected legacy receiver (different
    from the sender limit). Encoding bit 0x80 is rejected; lower flag bits and
    sequence are retained only as raw metadata. ``finish`` detects truncation.
    A framing error poisons the parser until ``reset``. Each feed is atomic:
    if a later envelope in that call is invalid, that call returns no frames.
    Pending storage is bounded to one header plus one accepted body, 1500 bytes.
    """

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        """Discard a partial envelope and any latched error."""
        self._pending = bytearray()
        self._body_length: int | None = None
        self._failed = False

    @property
    def pending_size(self) -> int:
        """Bytes of the partial envelope held internally, including its header."""
        return len(self._pending)

    def _check_ready(self) -> None:
        if self._failed:
            raise FrameError("parser_failed")

    def _fail(self, code: str) -> None:
        self._failed = True
        raise FrameError(code)

    def feed(self, chunk: _BytesLike) -> list[Frame]:
        """Consume an offline fragment and return complete unencoded envelopes."""
        self._check_ready()
        data = _bytes(chunk)
        frames: list[Frame] = []
        offset = 0
        while offset < len(data):
            target = HEADER_SIZE
            if self._body_length is not None:
                target += self._body_length
            take = min(target - len(self._pending), len(data) - offset)
            self._pending.extend(data[offset : offset + take])
            offset += take

            if self._body_length is None and len(self._pending) == HEADER_SIZE:
                body_length, flags, _sequence = _HEADER.unpack(self._pending)
                if not 1 <= body_length <= LEGACY_RECEIVE_BODY_CEILING:
                    self._fail("invalid_length")
                if flags & 0x80:
                    self._fail("unsupported_encoded_frame")
                self._body_length = body_length

            if self._body_length is not None:
                frame_size = HEADER_SIZE + self._body_length
                if len(self._pending) == frame_size:
                    frames.append(
                        Frame(
                            payload=bytes(self._pending[HEADER_SIZE:]),
                            raw_sequence=self._pending[3],
                            raw_flags=self._pending[2],
                        )
                    )
                    self._pending.clear()
                    self._body_length = None
        return frames

    def finish(self) -> None:
        """Report truncated headers/bodies at the end of an offline byte source."""
        self._check_ready()
        if self._pending:
            self._fail("truncated_frame")
