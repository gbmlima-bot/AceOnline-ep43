import collections
import json
from pathlib import Path
import unittest
from build_services import derive
ROOT=Path(__file__).resolve().parents[1]
class NativeServicesCompilerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        b=ROOT/'client/assets/original_library/catalogs'
        cls.items=json.loads((b/'items.json').read_text())['records']
        cls.recipes=json.loads((b/'mixing_recipes.json').read_text())['records']
        cls.stock,cls.compiled=derive(cls.items,cls.recipes)
    def test_frozen_real_catalog_coverage(self):
        self.assertEqual((len(self.stock),len(self.compiled),sum(r['supported'] for r in self.compiled)),(2596,39230,304))
        self.assertEqual(len(self.stock),len(set(self.stock)))
        self.assertEqual(len(self.compiled),len({r['recipe_id'] for r in self.compiled}))
    def test_all_supported_recipes_preserve_native_economy(self):
        native_items={r['ItemNum']:r for r in self.items}
        for r in self.compiled:
            n=self.recipes[r['source_record_index']]
            self.assertEqual((r['item_num'],r['cost'],r['probability_10k'],r['source_record_sha256']),
                             (n['TargetItemNum'],n['MixingCost'],n['MixingProbability'],n['_source']['sha256']))
            if not r['supported']:continue
            self.assertEqual(r['native_visible'],n['opaque_tail_hex']=='01000000')
            self.assertTrue(r['ingredients'])
            self.assertEqual(r['count'],1)
            for part in r['ingredients']:
                self.assertIn(part['item_num'],native_items)
                self.assertGreater(part['count'],0)
                self.assertNotIn(native_items[part['item_num']]['Kind'],set(range(18))|{25,26,31,32,35,36,37,38})
    def test_missing_or_unknown_recipe_data_never_succeeds(self):
        fixture=self.recipes[10].copy()
        fixture['opaque_tail_hex']='02000000'
        self.assertFalse(derive(self.items,[fixture])[1][0]['supported'])
        fixture=self.recipes[10].copy()
        fixture['SourceItem']=[{'ItemNum':1234,'Count':1}]
        self.assertIn('invalid_source_item',derive(self.items,[fixture])[1][0]['blocking_reasons'])
    def test_derived_file_reproducible(self):
        result=json.loads((ROOT/'client/assets/local_services/economy.json').read_text())
        self.assertEqual(result['stock_item_nums'],self.stock)
        self.assertEqual(result['recipes'],self.compiled)
if __name__=='__main__':unittest.main()
