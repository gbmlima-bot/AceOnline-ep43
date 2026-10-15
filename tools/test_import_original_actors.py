"""Actor/appearance import invariants, including full shipped GLB verification."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

import import_original_actors as actors


ROOT=Path(__file__).resolve().parents[1]


class ActorImportTests(unittest.TestCase):
    def test_empty_mesh_removal_preserves_nonempty_bytes(self):
        prefix=b"xof 0303txt 0032\nFrame x { FrameTransformMatrix {1;}\n"
        empty=b'Mesh {0; ; 0; ; MeshNormals {0; ; 0; ;} Material {"}";} /*}*/ }'
        visible=b'Mesh real {3; 0;0;0;,1;0;0;,0;1;0;; 1;3;0,1,2;;}'
        output,count=actors.omit_empty_x_meshes(prefix+empty+visible+b'}')
        self.assertEqual(count,1)
        self.assertIn(visible,output)
        self.assertIn(b"FrameTransformMatrix {1;}",output)
        self.assertNotIn(empty,output)

    def test_empty_mesh_inconsistent_faces_rejected(self):
        with self.assertRaisesRegex(ValueError,"face array"):
            actors.omit_empty_x_meshes(b"xof 0303txt 0032\nMesh {0; ; 1; 3;0,1,2;;}")

    def test_compressed_payload_never_rewritten(self):
        raw=b"xof 0303bzip0032"+b"Mesh {0; ; 0; ;}"
        self.assertEqual(actors.omit_empty_x_meshes(raw),(raw,0))

    def test_native_affine_matrix_keeps_shear(self):
        original=np.array([[1,.35,0,8],[0,1,.2,4],[0,0,1,-6],[0,0,0,1]],dtype=float)
        actual=actors.node_matrix({"matrix":original.flatten(order="F").tolist()})
        np.testing.assert_array_equal(actual,original)
        self.assertAlmostEqual(np.linalg.det(actual[:3,:3]),1)

    def test_nonfinite_transform_rejected(self):
        with self.assertRaisesRegex(ValueError,"Nonfinite"):
            actors.node_matrix({"translation":[float("nan"),0,0]})

    def test_missing_monsters_remain_unavailable(self):
        source={"MonsterUnitKind":20,"SourceIndex":20,"TextureIndex":1,"AlphaBlending":0,
                "ScaleValue":1,"Level":1,"HP":40,"Size":4,"_source":{"sha256":"a"*64}}
        result=actors.registry([source],[],{20:"missing"},True,{})
        self.assertFalse(result["by_monster_code"])
        self.assertEqual(result["unavailable"],[{"monster_code":20,"source_code":20,"reason":"missing"}])

    def test_all_published_models_are_finite_self_contained_and_bound(self):
        totals={}
        for folder,name in (("actors","actors.json"),("gears","gears.json")):
            root=ROOT/"client/assets/original_library"/folder
            path=root/name
            self.assertTrue(path.is_file(),str(path))
            registry=json.loads(path.read_text())
            self.assertTrue(registry["complete"],folder+" import is unfinished")
            self.assertGreater(len(registry["models"]),300)
            files=set()
            for model in registry["models"]:
                target=root/model["filename"]
                self.assertNotIn(target.name,files);files.add(target.name)
                with self.subTest(folder=folder,model=target.name):
                    validation=actors.validate_actor_glb(target)
                    self.assertEqual(validation["sha256"],model["sha256"])
                    self.assertEqual(validation["triangles"],model["triangles"])
                    self.assertEqual(validation["images"][0]["decoded_rgba_sha256"],model["texture"]["decoded_rgba_sha256"])
                    np.testing.assert_allclose(validation["bounds"]["min"],model["bounds"]["min"],atol=1e-5)
                    np.testing.assert_allclose(validation["bounds"]["max"],model["bounds"]["max"],atol=1e-5)
                    self.assertEqual(model["animation_tracks_exported"],0)
            self.assertEqual(files,{p.name for p in root.glob("*.glb")})
            totals[folder]=len(files)
        self.assertGreater(sum(totals.values()),800)

    def test_gear_compatibility_matches_every_native_item(self):
        root=ROOT/"client/assets/original_library"
        registry=json.loads((root/"gears/gears.json").read_text())
        catalog=json.loads((root/"catalogs/items.json").read_text())
        self.assertEqual(registry["native_armor_items"],7980)
        checked=0
        for item in catalog["records"]:
            if item["Kind"]!=16:continue
            visual=registry["by_item_num"].get(str(item["ItemNum"]))
            if visual is None:continue
            self.assertEqual(visual["model_id"],item["SourceIndex"]+4000000)
            self.assertEqual(visual["req_unit_kind"],item["ReqUnitKind"])
            source=registry["by_source_index"][str(item["SourceIndex"])]
            self.assertEqual(source["resource_path"],visual["scene_path"])
            self.assertEqual(source["unit_kind_mask"]&item["ReqUnitKind"],item["ReqUnitKind"])
            checked+=1
        self.assertEqual(checked,registry["available_item_count"])


if __name__=="__main__":unittest.main()
