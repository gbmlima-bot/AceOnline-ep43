import json
from pathlib import Path
import struct
import unittest

from protocol.framing import (
    HEADER_SIZE,
    LEGACY_RECEIVE_BODY_CEILING,
    MAX_PAYLOAD_SIZE,
    Frame,
    FrameError,
    PlainFrameParser,
    encode_unencoded,
)

FIXTURES = json.loads(
    (Path(__file__).parents[1] / "fixtures" / "framing.json").read_text(encoding="utf-8")
)


class FramingTests(unittest.TestCase):
    def assert_error(self, code, function, *args):
        with self.assertRaises(FrameError) as raised:
            function(*args)
        self.assertEqual(code, raised.exception.code)

    def expected(self, case):
        return Frame(
            bytes.fromhex(case["payload_hex"]),
            case["raw_sequence"],
            case["raw_flags"],
        )

    def test_source_metadata_and_explicit_limits(self):
        self.assertEqual(4, HEADER_SIZE)
        self.assertEqual(1492, MAX_PAYLOAD_SIZE)
        self.assertEqual(1496, LEGACY_RECEIVE_BODY_CEILING)
        self.assertEqual("7c3e47ac47844e5c415d356a94d6201a0b9a38c4", FIXTURES["source_commit"])
        self.assertEqual(3, len(FIXTURES["sources"]))
        for source in FIXTURES["sources"]:
            self.assertEqual(64, len(source["sha256"]))

    def test_shared_valid_vectors_and_every_split_point(self):
        for case in FIXTURES["valid"]:
            data = bytes.fromhex(case["frame_hex"])
            for split in range(len(data) + 1):
                with self.subTest(case=case["id"], split=split):
                    parser = PlainFrameParser()
                    result = parser.feed(data[:split]) + parser.feed(data[split:])
                    self.assertEqual([self.expected(case)], result)
                    self.assertEqual(0, parser.pending_size)
                    parser.finish()

    def test_header_little_endian_and_sender_zeroes_raw_metadata(self):
        payload = bytes(256)
        encoded = encode_unencoded(payload)
        self.assertEqual(b"\x00\x01\x00\x00", encoded[:HEADER_SIZE])
        for case in FIXTURES["valid"]:
            frame = encode_unencoded(bytes.fromhex(case["payload_hex"]))
            self.assertEqual(b"\x00\x00", frame[2:4])
            if case["raw_sequence"] == 0 and case["raw_flags"] == 0:
                self.assertEqual(bytes.fromhex(case["frame_hex"]), frame)

    def test_multiple_frames_and_byte_at_a_time_fragments(self):
        data = b"".join(bytes.fromhex(case["frame_hex"]) for case in FIXTURES["valid"])
        expected = [self.expected(case) for case in FIXTURES["valid"]]
        parser = PlainFrameParser()
        self.assertEqual(expected, parser.feed(data))
        parser.finish()
        parser.reset()
        actual = []
        for byte in data:
            actual.extend(parser.feed(bytes([byte])))
            self.assertLessEqual(parser.pending_size, 1500)
        self.assertEqual(expected, actual)
        parser.finish()

    def test_shared_invalid_vectors_poison_until_reset(self):
        for case in FIXTURES["invalid"]:
            with self.subTest(case=case["id"]):
                parser = PlainFrameParser()
                self.assert_error(case["error"], parser.feed, bytes.fromhex(case["frame_hex"]))
                self.assert_error("parser_failed", parser.feed, b"")
                self.assert_error("parser_failed", parser.finish)
                parser.reset()
                self.assertEqual([Frame(b"x", 0, 0)], parser.feed(encode_unencoded(b"x")))
                parser.finish()

    def test_shared_truncated_vectors_require_explicit_end_of_input(self):
        for case in FIXTURES["truncated"]:
            with self.subTest(case=case["id"]):
                parser = PlainFrameParser()
                data = bytes.fromhex(case["frame_hex"])
                self.assertEqual([], parser.feed(data))
                self.assertEqual(len(data), parser.pending_size)
                self.assert_error("truncated_frame", parser.finish)
                self.assert_error("parser_failed", parser.finish)

    def test_truncation_at_every_nonempty_prefix(self):
        frame = encode_unencoded(b"opaque-data")
        for end in range(1, len(frame)):
            with self.subTest(end=end):
                parser = PlainFrameParser()
                self.assertEqual([], parser.feed(frame[:end]))
                self.assert_error("truncated_frame", parser.finish)

    def test_sender_and_receiver_limits_are_distinct(self):
        for length in (1, 2, 1492, 1493, 1496):
            with self.subTest(length=length):
                payload = bytes([0xA5]) * length
                envelope = struct.pack("<HBB", length, 0, 42) + payload
                parser = PlainFrameParser()
                actual = []
                for byte in envelope:
                    actual.extend(parser.feed(bytes([byte])))
                    self.assertLessEqual(parser.pending_size, 1500)
                self.assertEqual([Frame(payload, 42, 0)], actual)
                parser.finish()
                if length <= MAX_PAYLOAD_SIZE:
                    self.assertEqual(payload, encode_unencoded(payload)[HEADER_SIZE:])
                else:
                    self.assert_error("invalid_length", encode_unencoded, payload)
        self.assert_error("invalid_length", encode_unencoded, b"")
        self.assert_error("invalid_length", encode_unencoded, bytes(1497))

    def test_invalid_header_is_rejected_as_soon_as_four_bytes_arrive(self):
        parser = PlainFrameParser()
        self.assertEqual([], parser.feed(b"\xd9\x05\x00"))
        self.assert_error("invalid_length", parser.feed, b"\x00")
        self.assertEqual(HEADER_SIZE, parser.pending_size)

    def test_feed_is_atomic_when_later_frame_is_invalid(self):
        parser = PlainFrameParser()
        self.assert_error("invalid_length", parser.feed, encode_unencoded(b"first") + b"\0\0\0\0")
        self.assert_error("parser_failed", parser.feed, encode_unencoded(b"second"))
        parser.reset()
        self.assertEqual([Frame(b"second", 0, 0)], parser.feed(encode_unencoded(b"second")))

    def test_empty_input_and_reset_discard_partial_data(self):
        parser = PlainFrameParser()
        self.assertEqual([], parser.feed(b""))
        parser.finish()
        parser.feed(b"\x01")
        parser.reset()
        self.assertEqual(0, parser.pending_size)
        parser.finish()

    def test_bytes_like_input_without_integer_or_text_coercion(self):
        for value in (bytearray(b"a"), memoryview(b"a")):
            parser = PlainFrameParser()
            self.assertEqual([Frame(b"a", 0, 0)], parser.feed(encode_unencoded(value)))
        for value in (1, "a", None):
            with self.subTest(value=value):
                self.assertRaises(TypeError, encode_unencoded, value)
                self.assertRaises(TypeError, PlainFrameParser().feed, value)


if __name__ == "__main__":
    unittest.main()
