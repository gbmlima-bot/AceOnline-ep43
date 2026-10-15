import collections
import json
from pathlib import Path
import unittest
from build_services import derive,compile_native_shops,table_records,SHOP_COMPATIBILITY_FIELDS
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
        if 'native_shops' in result:
            tables={name:json.loads((ROOT/'client/assets/native_server'/(name+'.json')).read_text()) for name in ('ti_Shop','ti_BuildingNPC','ti_Item')}
            buildings=json.loads((ROOT/'client/assets/original_library/catalogs/npc_services.json').read_text())['records']
            compiled=compile_native_shops(self.items,buildings,tables['ti_Shop'],tables['ti_BuildingNPC'],tables['ti_Item'])
            self.assertEqual(result['native_shops']['shops'],compiled['shops'])
            self.assertEqual(result['stock_item_nums'],sorted({r['item_num'] for s in compiled['shops'] for r in s['entries']}))
        else:
            self.assertEqual(result['stock_item_nums'],self.stock)
        self.assertEqual(result['recipes'],self.compiled)

class RecoveredShopTests(unittest.TestCase):
    @staticmethod
    def table(records):
        columns=list(records[0])
        return {'columns':columns,'rows':[[r[c] for c in columns] for r in records]}
    def setUp(self):
        self.items=[dict(ItemNum=n,Kind=0,SourceIndex=n,Position=2,ReqUnitKind=1,
                         ReqMinLevel=1,ReqMaxLevel=0,MinTradeQuantity=1,Price=100,
                         Caliber=1,ItemAttribute=0) for n in (101,102,103)]
        self.buildings=[dict(BuildingIndex=9001,BuildingKind=0,MapIndex=2001,NPCIndex=101),
                        dict(BuildingIndex=9999,BuildingKind=100,MapIndex=0,NPCIndex=0)]
        self.shops=[dict(ShopOrder=20,UniqueNumber=9001,ItemNum=101),
                    dict(ShopOrder=10,UniqueNumber=9001,ItemNum=102),
                    dict(ShopOrder=30,UniqueNumber=9999,ItemNum=103)]
    def compile(self,**changes):
        return compile_native_shops(changes.get('items',self.items),changes.get('current_buildings',self.buildings),
            self.table(changes.get('shops',self.shops)),self.table(changes.get('buildings',self.buildings)),
            self.table(changes.get('legacy',self.items)))
    def test_native_membership_order_and_cash_exclusion(self):
        result=self.compile()
        self.assertEqual([r['item_num'] for r in result['shops'][0]['entries']],[102,101])
        self.assertEqual(result['summary']['unique_items'],2)
        self.assertEqual(result['summary']['rejected_rows'],{'non_spi_shop_kind':1})
        self.assertNotIn(103,[r['item_num'] for s in result['shops'] for r in s['entries']])
    def test_reused_ids_and_repriced_items_do_not_mix_versions(self):
        for field in SHOP_COMPATIBILITY_FIELDS:
            with self.subTest(field=field):
                legacy=[dict(r) for r in self.items]
                legacy[0][field]+=1
                self.assertEqual(self.compile(legacy=legacy)['summary']['rejected_rows']['item_version_mismatch'],1)
    def test_npc_map_kind_or_identity_mismatch_blocks_membership(self):
        for field in ('MapIndex','BuildingKind','NPCIndex'):
            with self.subTest(field=field):
                current=[dict(r) for r in self.buildings];current[0][field]+=1
                result=self.compile(current_buildings=current)
                self.assertEqual(result['shops'],[])
                self.assertEqual(result['summary']['rejected_rows']['building_version_mismatch'],2)
    def test_proven_ep43_shop_title_migration_keeps_npc_identity(self):
        for category in (35,36,37):
            current=[dict(r) for r in self.buildings];current[0]['BuildingKind']=category
            result=self.compile(current_buildings=current)
            self.assertEqual(result['shops'][0]['building_kind'],category)
            self.assertEqual(result['shops'][0]['legacy_building_kind'],0)
            self.assertEqual([r['item_num'] for r in result['shops'][0]['entries']],[102,101])
    def test_null_legacy_item_key_is_an_anomaly_not_an_item(self):
        legacy=[dict(r) for r in self.items];legacy.append(dict(legacy[0],ItemNum=None))
        result=self.compile(legacy=legacy)
        self.assertEqual(result['summary']['invalid_legacy_item_ids'],1)
        self.assertEqual(result['summary']['unique_items'],2)
    def test_restricted_legacy_or_current_flags_never_become_stock(self):
        for source in ('items','legacy'):
            rows=[dict(r) for r in self.items];rows[0]['ItemAttribute']=0x800
            result=self.compile(**{source:rows})
            self.assertEqual(result['summary']['rejected_rows']['restricted_item_flags'],1)
            self.assertEqual([r['item_num'] for r in result['shops'][0]['entries']],[102])
    def test_malformed_table_fails_closed(self):
        for fixture in ({'columns':['ItemNum','ItemNum'],'rows':[[1,2]]},
                        {'columns':['ItemNum'],'rows':[[1,2]]}):
            with self.assertRaises(ValueError):table_records(fixture)
if __name__=='__main__':unittest.main()
