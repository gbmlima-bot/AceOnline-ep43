#!/usr/bin/env python3
"""Regression tests for authenticated wider-world import boundaries."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
import numpy as np
from import_available_worlds import placements, verify_source
from import_world_profile import parse_resource
from import_scenery_assimp import evaluated_meshes
from convert_original_terrain import Terrain, FormatError
from import_non_tile_worlds import selected_rows, props_layout, visual_profile


class WideImportTests(unittest.TestCase):
    def test_extended_opaque_tail_is_hashed_not_interpreted(self):
        tail = b"opaque" * 200000
        payload = b"plain-model-data"
        raw = struct.pack("<5i",1000,1000,len(payload),1,0)+struct.pack("<3i10s2s",17,len(payload),0,b"17",b"\0\0")+payload+tail
        entries, report = parse_resource(raw)
        self.assertEqual(entries["17"].data,payload)
        self.assertEqual(report["opaque_trailing"]["size"],len(tail))
        self.assertEqual(report["opaque_trailing"]["offset"],44+len(payload))
        broken = bytearray(raw)
        struct.pack_into("<i",broken,24,len(raw)+1)
        with self.assertRaises(FormatError):parse_resource(bytes(broken))
        struct.pack_into("<i",broken,0,999)
        with self.assertRaises(FormatError):parse_resource(bytes(broken))

    def test_source_crc_and_size_reject_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"source.dat";raw=b"authenticated original data"
            path.write_bytes(raw)
            inventory={"Res-map/17.dat":{"Size":str(len(raw)),"CRC":f"{zlib.crc32(raw)&0xffffffff:08X}"}}
            self.assertEqual(verify_source(path,"Res-map/17.dat",inventory)["size"],len(raw))
            path.write_bytes(raw[:-1]+b"x")
            with self.assertRaises(FormatError):verify_source(path,"Res-map/17.dat",inventory)
            with self.assertRaises(FormatError):verify_source(path,"Res-map/missing.dat",inventory)

    def test_pose_center_is_derived_from_each_native_grid(self):
        # A128tile terrain has a2560unit half-width, not the old5120constant.
        terrain=Terrain(40,128,tuple(),1,((0,0,0),(5120,0,5120)))
        start=36+128*128*24
        payload=bytearray(start+112)
        struct.pack_into("<I",payload,start,3002200)
        struct.pack_into("<3f",payload,start+8,2560,123,2560)
        struct.pack_into("<3f",payload,start+20,0,0,1)
        struct.pack_into("<3f",payload,start+32,0,1,0)
        poses,errors=placements(bytes(payload),44,terrain)
        self.assertEqual(errors,[])
        self.assertEqual(poses[0]["transform_columns"][9:],[0,123,0])
        self.assertEqual(poses[0]["source_record_offset"],44+start)
        struct.pack_into("<3f",payload,start+32,0,0,2)
        poses,errors=placements(bytes(payload),44,terrain)
        self.assertEqual(poses,[])
        self.assertEqual(len(errors),1)
        self.assertIn("parallel",errors[0]["reason"])

    def test_cpp_fallback_evaluates_weighted_skin_without_actor_heading(self):
        binary=bytearray();views=[];accessors=[]
        def add(array,kind,ctype=5126):
            binary.extend(b"\0"*(-len(binary)%4))
            encoded=np.asarray(array,dtype={5126:"<f4",5123:"<u2"}[ctype])
            views.append({"buffer":0,"byteOffset":len(binary),"byteLength":encoded.nbytes})
            binary.extend(encoded.tobytes())
            accessors.append({"bufferView":len(views)-1,"count":len(encoded),"type":kind,"componentType":ctype})
            return len(accessors)-1
        pos=add([[0,0,0],[1,0,0],[0,1,0]],"VEC3")
        norm=add([[0,0,1]]*3,"VEC3")
        uv=add([[0,0],[1,0],[0,1]],"VEC2")
        joints=add([[0,0,0,0]]*3,"VEC4",5123)
        weights=add([[1,0,0,0]]*3,"VEC4")
        indices=add([0,1,2],"SCALAR",5123)
        inverse=np.eye(4);inverse[0,3]=-10
        ibm=add([inverse.reshape(-1,order="F")],"MAT4")
        doc={"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"children":[1,2]},{"mesh":0,"skin":0},{"translation":[20,0,0]}],"skins":[{"joints":[2],"inverseBindMatrices":ibm}],"meshes":[{"primitives":[{"attributes":{"POSITION":pos,"NORMAL":norm,"TEXCOORD_0":uv,"JOINTS_0":joints,"WEIGHTS_0":weights},"indices":indices}]}],"bufferViews":views,"accessors":accessors}
        result=evaluated_meshes(doc,binary)
        np.testing.assert_allclose(result[0]["positions"],[[10,0,0],[11,0,0],[10,1,0]])
        np.testing.assert_allclose(result[0]["normals"],[[0,0,1]]*3)
        np.testing.assert_array_equal(result[0]["indices"],[0,1,2])
        doc["nodes"][0]["children"].append(0)
        with self.assertRaises(FormatError):evaluated_meshes(doc,binary)


class NativeNonTileImportTests(unittest.TestCase):
    def test_only_native_flag_zero_may_omit_map_texture_pack(self):
        rows=[{'MapIndex':1,'Dat':1,'TileRenderingFlag':0},{'MapIndex':2,'Dat':2,'TileRenderingFlag':1},{'MapIndex':3,'Dat':3,'TileRenderingFlag':0}]
        inventory={'Res-map/1.dat':{},'Res-map/2.dat':{}}
        self.assertEqual([row['MapIndex']for row in selected_rows(rows,inventory)],[1])

    def test_missing_prop_stays_a_gap_without_generic_replacement(self):
        row={'MapIndex':3351,'Dat':3351}
        poses=[{'code':123,'source_record_index':0,'transform_columns':[1,0,0,0,1,0,0,0,1,10,20,30]},{'code':456,'source_record_index':1}]
        models={123:{'code':123,'available':True,'scene':'res://assets/original_library/props/123.glb','sha256':'verified','source_mapobjectinfo':{'collision':1}},456:{'available':False,'reason':'unsupported native X compression','source_mapobjectinfo':{'collision':1}}}
        layout=props_layout(row,{'sha256':'native-dat'},poses,[],models)
        self.assertEqual((layout['instance_count'],layout['model_count']),(1,1))
        self.assertEqual(layout['models'][0]['placements'][0],poses[0])
        self.assertEqual(layout['omitted'][0]['code'],456)
        self.assertTrue(layout['omitted'][0]['collision_expected'])

    def test_native_sky_flag_zero_does_not_create_a_substitute_sky(self):
        row={'SkyRenderingFlag':0,'SunRenderingFlag':0,'FogRenderingFlag':1,'DaySunDirection':[0,1,0],'DayFogColor':0,'DayFogEndDistance':3000}
        gaps=[]
        profile=visual_profile(row,{},'res://assets/native-layout.json',{},gaps)
        self.assertEqual(profile['terrain'],{});self.assertEqual(profile['sky'],{})
        self.assertEqual(profile['clouds'],{});self.assertEqual(gaps,[])
        self.assertEqual(profile['environment']['native_sun_rendering_flag'],0)

    def test_all_published_non_tile_maps_use_exact_native_flag_and_no_terrain(self):
        root=Path(__file__).resolve().parents[1]
        native={row['MapIndex']:row for row in json.loads((root/'client/assets/legacy_rules/maps.json').read_text())['records']}
        catalog=json.loads((root/'client/assets/original_worlds/catalog.json').read_text())
        worlds=[row for row in catalog['records']if row.get('native_non_tile_world')]
        self.assertEqual(len(worlds),59)
        self.assertEqual(sum(row['props_imported']for row in worlds),2565)
        for row in worlds:
            self.assertEqual(native[row['map_index']]['TileRenderingFlag'],0)
            self.assertEqual(row['terrain_path'],'');self.assertEqual(row['visual_profile']['terrain'],{})
            self.assertTrue(row['available']);self.assertFalse(row['terrain_available'])
            self.assertTrue((root/'client'/row['height_path'].removeprefix('res://')).exists())
        self.assertEqual(catalog['coverage']['available_maps'],217)


if __name__=="__main__":unittest.main()
