#!/usr/bin/env python3
"""Exercise bounds, non-execution and native quest101/102 provenance."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import export_original_quests as quests
from convert_original_terrain import FormatError

ROOT = Path(__file__).resolve().parents[1]


class QuestParserTests(unittest.TestCase):
    def test_unknown_input_rejected_before_decode(self):
        with self.assertRaises(FormatError):
            quests.decode(b'unknown game bytes')

    def test_xor_resets_at_native_block_boundary(self):
        plain = bytes((i * 13 + 47) % 256 for i in range(65536 + 300))
        encoded = bytearray()
        for start in range(0, len(plain), 65536):
            block = plain[start:start + 65536]
            encoded.extend(v ^ quests.KEY[i % len(quests.KEY)] for i, v in enumerate(block))
        with patch.object(quests, 'SOURCE_SHA', hashlib.sha256(encoded).hexdigest()):
            self.assertEqual(quests.decode(bytes(encoded)), plain)

    def test_quoted_comments_and_declarative_unknown_expression(self):
        text = "$name = 'value # not a comment;()'; # actual comment\nquest(7){BASIC_INFO{QUEST_NAME=$name;};COMPLETION_REQ{C_REQ_ITEM=12(3) FROM MONSTER(5,1~1,1000000);};};"
        definitions, records = quests.Parser(text).parse()
        values = quests.Values(definitions)
        record = quests.normalize(records[0], values)
        self.assertEqual(record['title'], 'value # not a comment;()')
        self.assertEqual(record['objectives'][0]['target_code'], 5)
        self.assertEqual(record['objectives'][0]['required'], 3)

    def test_integer_precedence_aliases_cycles_and_unsafe_calls(self):
        values = quests.Values({'$a':['2','+','3','*','4'],'$b':['$a'],'$loop':['$loop']})
        self.assertEqual(values.scalar(['$b']), 14)
        self.assertEqual(values.scalar(['-','7','/','2']), -3)
        for tokens in [['$loop'], ['1','/','0'], ['__import__','(','\'os\'',')']]:
            with self.subTest(tokens=tokens), self.assertRaises(ValueError):
                values.scalar(tokens)

    def test_unterminated_or_unbalanced_dsl_rejected(self):
        for text in ["quest(1){BASIC_INFO{QUEST_NAME='oops;};};", 'quest(1){BASIC_INFO{QUEST_INDEX=(1;};};', 'quest(1){', "eval('x');"]:
            with self.subTest(text=text), self.assertRaises(FormatError):
                quests.Parser(text).parse()

    def test_nonguaranteed_monster_drops_are_not_misreported_as_kills(self):
        _, records = quests.Parser('quest(7){COMPLETION_REQ{C_REQ_ITEM=12(3) FROM MONSTER(5,1~2,500000);};};').parse()
        record = quests.normalize(records[0], quests.Values({}))
        self.assertFalse(record['supported_objectives'])
        self.assertEqual(record['objectives'], [])
        self.assertEqual(len(record['unsupported_requirements']), 1)

    def test_actual_original_dataset_reproduces_published_records(self):
        original = ROOT / 'docs/evidence/quest-native.tex'
        with tempfile.TemporaryDirectory() as temporary:
            out = Path(temporary) / 'catalog.json'
            result = quests.export(original, out)
        self.assertEqual(len(result['records']), 597)
        self.assertEqual(result['definition_count'], 3014)
        published = json.loads((ROOT / 'client/assets/legacy_rules/missions.json').read_text())
        records = {int(row['QuestIndex']):row for row in result['records']}
        delivered = {int(row['QuestIndex']):row for row in published['records']}
        for identifier in [101,102]:
            self.assertEqual(records[identifier], delivered[identifier])
        q = records[102]
        self.assertEqual(q['prerequisites'], [101])
        self.assertEqual([(o['target_code'],o['required']) for o in q['objectives']], [(2028200,1),(2028100,3)])
        self.assertEqual(q['reward'], {'credits':320,'experience':91})
        self.assertEqual(q['on_accept']['warp_map_id'], 3302)
        self.assertEqual(q['on_complete']['warp_map_id'], 9999)


if __name__ == '__main__':
    unittest.main()
