"""Meaningful boundary/provenance checks for the pinned rules exporter."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest

import export_original_rules as rules


ASSETS=Path('/workspace/analysis/ace-original-assets')
OMI=ASSETS/'props-source/Res-tex/omi.tex'
WORKSPACE=ASSETS/'terrain-source/Res-map/ms.wok'
TERRAIN=ASSETS/'terrain-source/Res-map/3002.dat'


@unittest.skipUnless(OMI.is_file(), 'Original pinned source is not available')
class RulesTest(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.catalog=rules.load_omi(OMI)

 def test_native_engine_gear_compatibility_and_burn_units(self):
  items={r['ItemNum']:r for r in self.catalog['ITEM']}
  for gear,mask in [('12000100',15),('12001100',240),('12003100',61440),('12002100',3840)]:
   item=items[rules.GEARS[gear]]
   self.assertEqual(item['ReqUnitKind'],mask)
   self.assertEqual(item['ReqMinLevel'],1)
   self.assertEqual((item['AbilityMin'],item['AbilityMax'],item['Range'],item['Time']), (130.0,160.0,220,20000))
   self.assertGreater(item['BoosterAngle'],0)

 def test_map_vectors_are_short_not_float_and_altitude_is_runtime_field(self):
  row=next(r for r in self.catalog['MAP_INFO'] if r['MapIndex']==3002)
  self.assertEqual(row['DaySunDirection'],[1,-2,1])
  self.assertEqual(row['WaterHeight'],-170)
  self.assertEqual(row['ClientMaxAltitudeHeight'],2400)
  self.assertEqual(row['WaterType'],1)
  self.assertEqual(row['Dat'],3002)
  self.assertEqual(row['_source']['offset'],10024608)

 def test_absent_server_monster_fields_are_null(self):
  row=next(r for r in self.catalog['MEX_MONSTER_INFO'] if r['MonsterUnitKind']==2000000)
  self.assertEqual((row['HP'],row['Level'],row['SourceIndex']),(303,9,2000000))
  for field in ['Defense','DefenseProbability','Speed','Shield','weapons']:
   self.assertIsNone(row[field])

 def test_unknown_metadata_hash_does_not_publish_output(self):
  with tempfile.TemporaryDirectory() as directory:
   base=Path(directory);bad=base/'omi.tex';data=bytearray(OMI.read_bytes());data[-1]^=1;bad.write_bytes(data)
   args=argparse.Namespace(metadata=bad,output=base/'output')
   with self.assertRaisesRegex(ValueError,'Unsupported OMI'):
    rules.export(args)
   self.assertFalse(args.output.exists())

 def test_events_preserve_warp_destination_and_do_not_turn_patterns_into_portals(self):
  source,events=rules.load_terrain_events(TERRAIN)
  self.assertEqual(len(events),4)
  warps=[r for r in events if r['event_type']==1]
  self.assertEqual({r['destination_map_id'] for r in warps},{3003,9999})
  event=next(r for r in warps if r['event_id']==203)
  self.assertEqual(event['destination_event_id'],300)
  self.assertEqual(event['position'],[-3920.0,800.0,4310.0])
  self.assertTrue(all(r['destination_map_id'] is None for r in events if r['event_type']==8))
  self.assertEqual(source['opaque_trailing_size'],560)

 def test_workspace_count_must_match_file_extent(self):
  with tempfile.TemporaryDirectory() as directory:
   bad=Path(directory)/'ms.wok';raw=bytearray(WORKSPACE.read_bytes());count=struct.unpack_from('<i',raw,60)[0]
   struct.pack_into('<i',raw,60,count+1);bad.write_bytes(raw)
   with self.assertRaisesRegex(ValueError,'size/count'):
    rules.load_workspace(bad)

 def test_terrain_entry_cannot_extend_outside_container(self):
  with tempfile.TemporaryDirectory() as directory:
   bad=Path(directory)/'3002.dat';raw=bytearray(TERRAIN.read_bytes());struct.pack_into('<i',raw,24,len(raw)+1);bad.write_bytes(raw)
   with self.assertRaisesRegex(ValueError,'bounds'):
    rules.load_terrain_events(bad)

 def test_export_is_reproducible_and_manifest_matches_artifacts(self):
  with tempfile.TemporaryDirectory() as directory:
   outputs=[Path(directory)/'first',Path(directory)/'second']
   for output in outputs:
    args=argparse.Namespace(metadata=OMI,output=output,workspace_data=WORKSPACE,terrain=[TERRAIN],source_root=None,archive_listing=None,mission_catalog=None)
    with contextlib.redirect_stdout(io.StringIO()):rules.export(args)
   self.assertEqual({p.name for p in outputs[0].iterdir()},{p.name for p in outputs[1].iterdir()})
   for first in outputs[0].iterdir():
    self.assertEqual(first.read_bytes(),(outputs[1]/first.name).read_bytes())
   manifest=json.loads((outputs[0]/'manifest.json').read_text())
   for name,entry in manifest['files'].items():
    self.assertEqual(entry['sha256'],rules.digest((outputs[0]/name).read_bytes()))
   world=json.loads((outputs[0]/'world_rules.json').read_text())
   self.assertEqual(len(world['maps']),238)
   self.assertEqual(len(world['npcs']),215)
   self.assertEqual(len(world['portals']),2)
   self.assertEqual(world['spawn_points'],[])

 def test_mission_import_preserves_native_fields_and_rejects_duplicate_ids(self):
  with tempfile.TemporaryDirectory() as directory:
   source=Path(directory)/'catalog.json'
   document={'schema_version':1,'source':{'sha256':'example_test_fixture'},
    'records':[{'QuestIndex':101,'QuestName':'Native quest','TargetMonsterVector':[[2028200,1]]}]}
   source.write_text(json.dumps(document))
   result,provenance=rules.load_mission_catalog(source)
   self.assertEqual(result['records'],document['records'])
   self.assertEqual(provenance['sha256'],rules.digest(source.read_bytes()))
   document['records'].append(document['records'][0]);source.write_text(json.dumps(document))
   with self.assertRaisesRegex(ValueError,'unique'):
    rules.load_mission_catalog(source)

 def test_mission_import_requires_provenance_and_native_identity(self):
  with tempfile.TemporaryDirectory() as directory:
   source=Path(directory)/'catalog.json'
   source.write_text(json.dumps({'schema_version':1,'records':[{'QuestIndex':True,'QuestName':'not an integer ID'}]}))
   with self.assertRaisesRegex(ValueError,'unique and positive'):
    rules.load_mission_catalog(source)
   source.write_text(json.dumps({'schema_version':1,'records':[]}))
   with self.assertRaisesRegex(ValueError,'provenance'):
    rules.load_mission_catalog(source)


if __name__=='__main__':unittest.main()
