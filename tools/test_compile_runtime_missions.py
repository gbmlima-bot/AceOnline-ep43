#!/usr/bin/env python3
"""Semantic compiler regressions using original records and hostile mutations."""
import copy
import json
from pathlib import Path
import unittest
from compile_runtime_missions import compile_one, compile_catalog, definitions

ROOT=Path(__file__).resolve().parents[1]

class MissionCompilerTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.values=definitions(ROOT/'docs/evidence/quest-native.tex')
  cls.catalog=json.loads((ROOT/'client/assets/legacy_rules/missions.json').read_text())
  cls.by_id={int(q['id']):q for q in cls.catalog['records']}
 def compile(self,identifier):return compile_one(self.by_id[identifier],self.values)
 def test_full_catalog_and_stable_original_rewards(self):
  result=compile_catalog(self.catalog,self.values)
  self.assertEqual(result['summary'],{'total':597,'supported':537,'blocked':60})
  q=self.compile(102)
  self.assertTrue(q['runtime_supported']);self.assertEqual(q['event_map_id'],3302)
  self.assertEqual(q['reward']['credits'],320);self.assertEqual(q['reward']['experience'],91)
  self.assertEqual([(x['target_code'],x['required']) for x in q['objectives']],[(2028200,1),(2028100,3)])
 def test_new_native_mission_and_navigation_and_bonus(self):
  q=self.compile(103)
  self.assertTrue(q['runtime_supported']);self.assertEqual(q['required_level_min'],2)
  self.assertEqual(q['event_map_id'],3303);self.assertEqual(q['prerequisites'],[102])
  q=self.compile(104)
  self.assertTrue(q['runtime_supported']);self.assertEqual(q['reward']['bonus_stats'],1)
  self.assertIn({'kind':'visit_event','event_id':1005,'map_id':3351,'required':1},q['objectives'])
 def test_direct_monster_condition_and_native_item_reward(self):
  q=self.compile(116)
  self.assertTrue(q['runtime_supported'])
  self.assertEqual(q['required_level_min'],15)
  self.assertEqual([(o['target_code'],o['required']) for o in q['objectives']],[(2008000,5),(2001600,5)])
  self.assertEqual(q['reward']['items'],[{'item_num':7009390,'count':1,'gear_mask':65535}])
  self.assertEqual((q['reward']['credits'],q['reward']['experience']),(8030,25361))
 def test_start_items_preserve_per_class_masks(self):
  q=self.compile(113)
  self.assertTrue(q['runtime_supported'])
  self.assertEqual([(i['item_num'],i['count'],i['gear_mask']) for i in q['on_accept']['items']],[(7000300,1,15),(7000300,1,61440),(7000300,1,240),(7002020,1,3840)])
 def test_unknown_clause_blocks_whole_mission(self):
  q=copy.deepcopy(self.by_id[102]);q['dsl_ast'][3]['children'].append({'name':'C_REQ_EXECUTE','tokens':['unsafe','(',')']})
  result=compile_one(q,self.values)
  self.assertFalse(result['runtime_supported']);self.assertIn('C_REQ_EXECUTE:unsupported_clause',result['blocked_reasons'])
 def test_native_random_drop_area_and_missing_skill_semantics(self):
  q=self.compile(105)
  self.assertTrue(q['runtime_supported'])
  self.assertEqual(q['objectives'][0]['drop_probability'],800000)
  self.assertEqual(q['objectives'][0]['source_area'],{'map_id':3002,'x':61,'y':191,'radius':20000})
  self.assertFalse(self.compile(110)['runtime_supported'])
  self.assertTrue(any('C_REQ_USE_ITEM' in reason for reason in self.compile(110)['blocked_reasons']))
 def test_deleted_arbitrary_inventory_is_not_treated_as_proof(self):
  q=copy.deepcopy(self.by_id[102]);q['dsl_ast'][-1]['children'].append({'name':'C_DEL_ITEM','tokens':['7000000','(','ALL',')']})
  result=compile_one(q,self.values)
  self.assertFalse(result['runtime_supported'])
  self.assertIn('C_DEL_ITEM:not_an_all_mission_proof_item',result['blocked_reasons'])
 def test_timers_per_item_and_native_weighted_rewards(self):
  q=self.compile(109)
  self.assertTrue(q['runtime_supported']);self.assertEqual(q['time_limit_seconds'],300)
  self.assertEqual(q['per_item_rewards'][0]['credits'],200)
  self.assertEqual(q['per_item_rewards'][0]['source_item_num'],7002690)
  q=self.compile(163)
  self.assertTrue(q['runtime_supported'])
  self.assertEqual([x['weight']for x in q['random_item_rewards'][0]['choices']],[36,34,30])
 def test_native_inventory_mix_overrides_consumed_ingredient_possession(self):
  q=self.compile(118)
  self.assertTrue(q['runtime_supported']);self.assertTrue(q['inventory_objectives_override_drops'])
  self.assertEqual(q['objectives'][-1],{'kind':'inventory','item_num':7901560,'required':1})
  q=self.compile(155)
  self.assertTrue(q['runtime_supported']);self.assertIn({'kind':'inventory','item_num':7005400,'required':4},q['objectives'])
 def test_native_party_pvp_and_unknown_skill_semantics_still_block(self):
  for identifier in [110,112,132,2012]:self.assertFalse(self.compile(identifier)['runtime_supported'])
  self.assertIn('C_REQ_USE_ITEM:native_clause_semantics_absent_from_pinned_sources',self.compile(110)['blocked_reasons'])
 def test_bad_area_and_ranges_cannot_partially_execute(self):
  raw=copy.deepcopy(self.by_id[105]);raw['dsl_ast'][3]['children'][0]['tokens'][-4]='EXEC'
  self.assertFalse(compile_one(raw,self.values)['runtime_supported'])
  raw=copy.deepcopy(self.by_id[108]);tokens=raw['dsl_ast'][3]['children'][0]['tokens'];tokens[tokens.index('~')+1]='0'
  self.assertFalse(compile_one(raw,self.values)['runtime_supported'])
 def test_start_proof_item_deletion_is_explicit(self):
  q=self.compile(107)
  self.assertTrue(q['runtime_supported']);self.assertEqual(q['delete_items'],[{'item_num':7011340,'count':-1,'gear_mask':65535}])
 def test_levels_and_gear_mask_and_symbol_resolution(self):
  q=self.compile(104)
  self.assertEqual(q['required_level_min'],3);self.assertEqual(q['required_gear_mask'],65535)
  self.assertEqual(q['required_influence'],1)
  for raw in self.catalog['records']:
   result=compile_one(raw,self.values)
   if result['runtime_supported']:
    self.assertGreater(result['required_level_max'],result['required_level_min'])
    self.assertIsInstance(result['required_gear_mask'],int)
 def test_item_rewards_exist_in_native_omi(self):
  items={int(row['ItemNum']) for row in json.loads((ROOT/'client/assets/original_library/catalogs/items.json').read_text())['records']}
  for raw in self.catalog['records']:
   result=compile_one(raw,self.values)
   for item in result['reward']['items']+result['on_accept']['items']:
    self.assertIn(item['item_num'],items)
 def test_compiler_reproducible_and_no_partial_execution(self):
  fresh=compile_catalog(self.catalog,self.values)
  published=json.loads((ROOT/'client/assets/local_world/mission_support.json').read_text())
  self.assertEqual(fresh['records'],published['records'])
  for q in fresh['records']:
   self.assertEqual(q['runtime_supported'],not bool(q['blocked_reasons']))

if __name__=='__main__':unittest.main()
