#!/usr/bin/env python3
"""Convert three bounded, hash-checked original ACE packs to static glTF 2 GLB.

No original executable or script is run. Assimp imports only model data.
X import already reflects Z and reverses faces; glTF UV V is restored here.
"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import math
from numbers import Real
import struct
import sys

import numpy as np
from PIL import Image
import pyassimp
from pyassimp import postprocess

SOURCE_ROOT = Path('/workspace/targets/ace-assets-extracted/unpacked')
OUTPUT_ROOT = Path('/workspace/ace-modern/client/assets/original_3d')
REPORT_ROOT = Path('/workspace/analysis/ace-original-assets')
MODELS = {'12000100': 'B-GEAR', '12001100': 'M-GEAR', '12003100': 'I-GEAR'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def convert(model_id, gear_class, *, source_model_entry=None, profile='gear',
            alpha_mode=None, alpha_cutoff=None, texture_entry_override=None,
            generate_zero_normals=False):
    if profile not in {'gear', 'actor', 'sky', 'cloud', 'scenery'}:
        raise ValueError('Unknown explicit conversion profile')
    if alpha_mode is not None and (not isinstance(alpha_mode, str) or alpha_mode not in {'OPAQUE', 'MASK', 'BLEND'}):
        raise ValueError('alpha_mode must be OPAQUE, MASK, BLEND or None')
    if alpha_cutoff is not None:
        if isinstance(alpha_cutoff, bool) or not isinstance(alpha_cutoff, Real) or not math.isfinite(alpha_cutoff) or not 0 <= alpha_cutoff <= 1:
            raise ValueError('alpha_cutoff must be a finite number in [0, 1]')
        if alpha_mode != 'MASK':
            raise ValueError('Explicit alpha_cutoff requires explicit alpha_mode=MASK')
        alpha_cutoff = float(alpha_cutoff)
    source_model_entry = source_model_entry or model_id
    source_dir = SOURCE_ROOT / model_id
    manifest = json.loads((source_dir / 'manifest.json').read_text())
    if sha(Path(manifest['source_pack']).read_bytes()) != manifest['source_pack_sha256']:
        raise ValueError('Source container hash mismatch')
    entries = {e['entry_name']: e for e in manifest['entries']}
    for e in entries.values():
        raw = Path(e['path']).read_bytes()
        if len(raw) != e['size'] or sha(raw) != e['source_sha256']:
            raise ValueError('Source hash/size mismatch: ' + e['entry_name'])
    x_path = Path(entries[source_model_entry]['path'])
    flags = postprocess.aiProcess_Triangulate | postprocess.aiProcess_ValidateDataStructure
    binary = bytearray()
    document = {'asset': {'version': '2.0', 'generator': 'ACE original static converter; Assimp X importer 5.4.3',
        'extras': {'source_model_id': model_id, 'source_pack_sha256': manifest['source_pack_sha256'],
                   'coordinate_system': ('right-handed +Y up, forward -Z; Assimp X conversion then 180deg Y heading normalization' if profile in {'gear', 'actor'} else 'right-handed +Y up; Assimp X conversion only; no ship heading or runtime placement baked' if profile == 'scenery' else 'right-handed +Y up; Assimp X conversion only; no runtime sky orientation/scale baked'),
                   'unit_scale': 1, 'unit_meaning': 'original model units; meters not established'}},
        'scene': 0, 'scenes': [{'nodes': [0]}],
        'nodes': [{'name': gear_class + '_' + model_id, 'children': []}],
        'meshes': [], 'materials': [], 'accessors': [], 'bufferViews': [],
        'images': [], 'textures': [],
        'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}]}
    texture_by_entry = {}
    texture_records = []
    all_positions = []
    mesh_records = []
    source_animation_count = 0
    nodes_with_meshes = []

    def add_view(raw, target=None):
        binary.extend(b'\0' * ((-len(binary)) % 4))
        record = {'buffer': 0, 'byteOffset': len(binary), 'byteLength': len(raw)}
        if target is not None:
            record['target'] = target
        binary.extend(raw)
        document['bufferViews'].append(record)
        return len(document['bufferViews']) - 1

    def add_accessor(array, kind, component, target, bounds=False):
        a = np.ascontiguousarray(array, dtype='<f4' if component == 5126 else '<u4')
        index = len(document['accessors'])
        record = {'bufferView': add_view(a.tobytes(), target), 'componentType': component,
                  'count': len(a), 'type': kind}
        if bounds:
            record['min'] = a.min(axis=0).tolist()
            record['max'] = a.max(axis=0).tolist()
        document['accessors'].append(record)
        return index

    def add_texture(entry_name):
        if entry_name in texture_by_entry:
            return texture_by_entry[entry_name]
        if entry_name not in entries or entries[entry_name]['kind'] != 'image':
            raise ValueError('Unresolved exact material texture entry: ' + entry_name)
        e = entries[entry_name]
        p = Path(e['path'])
        raw = p.read_bytes()
        with Image.open(io.BytesIO(raw)) as im:
            im.load()
            dimensions = list(im.size)
            original_pixels = np.array(im.convert('RGBA'))
            source_pixel_sha256 = sha(original_pixels.tobytes())
            if im.format == 'JPEG':
                image_bytes, mime, transform = raw, 'image/jpeg', 'none; exact original JPEG bytes embedded'
            else:
                out = io.BytesIO()
                im.convert('RGBA').save(out, format='PNG')
                image_bytes, mime, transform = out.getvalue(), 'image/png', 'lossless RGBA decode and PNG encode; no image flip'
                with Image.open(io.BytesIO(image_bytes)) as verify:
                    assert np.array_equal(original_pixels, np.array(verify.convert('RGBA')))
        image_index = len(document['images'])
        document['images'].append({'name': entry_name, 'bufferView': add_view(image_bytes), 'mimeType': mime})
        texture_index = len(document['textures'])
        document['textures'].append({'name': entry_name, 'source': image_index, 'sampler': 0})
        texture_by_entry[entry_name] = texture_index
        texture_records.append({'entry_name': entry_name, 'source': str(p), 'source_sha256': sha(raw),
            'embedded_sha256': sha(image_bytes), 'dimensions': dimensions, 'mimeType': mime, 'transform': transform,
            'decoded_rgba_sha256': source_pixel_sha256, 'pixel_hash_layout': 'row-major top-to-bottom RGBA8',
            'alpha_min': int(original_pixels[:, :, 3].min()), 'alpha_max': int(original_pixels[:, :, 3].max()),
            'embedded_pixels_match_source': True})
        return texture_index

    with pyassimp.load(str(x_path), processing=flags) as scene:
        source_animation_count = len(scene.animations)
        source_mesh_count = len(scene.meshes)
        source_bone_count = sum(len(m.bones) for m in scene.meshes)
        if source_bone_count:
            raise ValueError('Static converter does not silently discard skin weights')
        for i, material in enumerate(scene.materials):
            props = material.properties
            reference = props.get(('file', 1))
            source_material_reference = reference
            if texture_entry_override is not None:
                reference = texture_entry_override
            diffuse = list(props.get(('diffuse', 0), [1, 1, 1, 1]))
            if len(diffuse) == 3:
                diffuse.append(1)
            shininess = float(props.get(('shininess', 0), 0))
            roughness = math.sqrt(2 / (shininess + 2))
            pbr = {'baseColorFactor': diffuse, 'metallicFactor': 0.0, 'roughnessFactor': roughness}
            if reference:
                pbr['baseColorTexture'] = {'index': add_texture(reference)}
            glmat = {'name': f'{model_id}_material_{i}', 'pbrMetallicRoughness': pbr,
                'emissiveFactor': list(props.get(('emissive', 0), [0, 0, 0]))[:3],
                'doubleSided': False, 'extras': {'source_phong_shininess': shininess,
                    'source_phong_specular': props.get(('specular', 0)),
                    'source_texture_entry_name': reference,
                    'material_conversion': 'Phong diffuse/emissive preserved; nonmetallic PBR roughness sqrt(2/(shininess+2)) approximation'}}
            if texture_entry_override is not None:
                glmat['extras']['source_material_texture_reference'] = source_material_reference
            if profile == 'sky':
                glmat['extensions'] = {'KHR_materials_unlit': {}}
                document['extensionsUsed'] = ['KHR_materials_unlit']
                glmat['extras']['lighting_evidence'] = 'ETCRender.cpp:203 sets D3DRS_LIGHTING FALSE for sky.'
            if profile == 'cloud':
                glmat['extras']['lighting_evidence'] = 'ETCRender.cpp:253 restores LIGHTING TRUE; :261-262 enables straight-alpha SRCALPHA/INVSRCALPHA blending. No double-sided cull override found.'
            if diffuse[3] < 1 or profile == 'cloud':
                glmat['alphaMode'] = 'BLEND'
            if alpha_mode is not None:
                glmat['alphaMode'] = alpha_mode
                if alpha_cutoff is not None:
                    glmat['alphaCutoff'] = alpha_cutoff
                glmat['extras']['alpha_override_origin'] = 'Explicit caller override; not inferred from texture pixels or asserted as original MAPOBJECTINFO.Alpha.'
            document['materials'].append(glmat)

        def walk(node, parent_matrix):
            matrix = parent_matrix @ np.array(node.transformation, dtype=np.float64)
            if not np.all(np.isfinite(matrix)):
                raise ValueError('Nonfinite node transform')
            for mesh in node.meshes:
                nodes_with_meshes.append(node.name)
                vertices = np.array(mesh.vertices, dtype=np.float64)
                positions = (matrix @ np.column_stack([vertices, np.ones(len(vertices))]).T).T[:, :3]
                normal_matrix = np.linalg.inv(matrix[:3, :3]).T
                normals = (normal_matrix @ np.array(mesh.normals, dtype=np.float64).T).T
                faces = np.array(mesh.faces, dtype=np.uint32)
                if faces.ndim != 2 or faces.shape[1] != 3:
                    raise ValueError('Non-triangle primitive after Assimp triangulation')
                determinant = float(np.linalg.det(matrix[:3, :3]))
                if determinant < 0:
                    faces = faces[:, [0, 2, 1]]
                lengths = np.linalg.norm(normals, axis=1)
                zero_normals = lengths < 1e-10
                generated_normal_count = int(zero_normals.sum())
                if generated_normal_count and generate_zero_normals:
                    geometric = np.cross(positions[faces[:, 1]] - positions[faces[:, 0]], positions[faces[:, 2]] - positions[faces[:, 0]])
                    weighted = np.zeros_like(normals)
                    for corner in range(3):
                        np.add.at(weighted, faces[:, corner], geometric)
                    normals[zero_normals] = weighted[zero_normals]
                    lengths = np.linalg.norm(normals, axis=1)
                if np.any(lengths < 1e-10):
                    raise ValueError('Missing or zero source normals')
                normals /= lengths[:, None]
                uv = np.array(mesh.texturecoords[0, :, :2], dtype=np.float64)
                uv[:, 1] = 1 - uv[:, 1]  # Assimp lower-left -> glTF upper-left.
                if faces.max() >= len(positions) or not all(np.isfinite(a).all() for a in [positions, normals, uv]):
                    raise ValueError('Invalid geometry bounds/numeric values')
                geometric_normals = np.cross(positions[faces[:, 1]] - positions[faces[:, 0]],
                    positions[faces[:, 2]] - positions[faces[:, 0]])
                averaged_normals = normals[faces].mean(axis=1)
                dots = np.einsum('ij,ij->i', geometric_normals, averaged_normals)
                nondegenerate = np.linalg.norm(geometric_normals, axis=1) > 1e-10
                attributes = {'POSITION': add_accessor(positions, 'VEC3', 5126, 34962, True),
                    'NORMAL': add_accessor(normals, 'VEC3', 5126, 34962),
                    'TEXCOORD_0': add_accessor(uv, 'VEC2', 5126, 34962)}
                primitive = {'attributes': attributes, 'indices': add_accessor(faces.reshape(-1), 'SCALAR', 5125, 34963),
                    'material': int(mesh.materialindex), 'mode': 4}
                mesh_index = len(document['meshes'])
                document['meshes'].append({'name': mesh.name, 'primitives': [primitive]})
                node_index = len(document['nodes'])
                document['nodes'].append({'name': node.name, 'mesh': mesh_index})
                document['nodes'][0]['children'].append(node_index)
                mesh_records.append({'name': mesh.name, 'source_node': node.name, 'vertices': len(positions),
                    'triangles': len(faces), 'source_world_matrix_baked': matrix.tolist(),
                    'matrix_determinant': determinant,
                    'derived_zero_normal_vertices': generated_normal_count if generate_zero_normals else 0,
                    'normal_winding_agreement': int(np.sum(dots[nondegenerate] > 0)),
                    'nondegenerate_triangles': int(np.sum(nondegenerate)),
                    'aabb_min': positions.min(axis=0).tolist(), 'aabb_max': positions.max(axis=0).tolist(),
                    'uv_min': uv.min(axis=0).tolist(), 'uv_max': uv.max(axis=0).tolist()})
                all_positions.append(positions)
            for child in node.children:
                walk(child, matrix)
        # Source ShuttleChild.cpp:1278,8405 uses inverse LookAtRH(pos,pos+velocity).
        # Thus the original model forward is local -Z. Assimp's Z reflection makes
        # it +Z; a proper 180-degree Y rotation restores Godot's -Z forward.
        # This rotation has determinant +1, so no additional winding reversal.
        walk(scene.rootnode, np.diag([-1.0, 1.0, -1.0, 1.0]) if profile in {'gear', 'actor'} else np.eye(4))

    positions = np.vstack(all_positions)
    minimum, maximum = positions.min(axis=0), positions.max(axis=0)
    document['buffers'] = [{'byteLength': len(binary)}]
    json_bytes = json.dumps(document, separators=(',', ':'), allow_nan=False).encode()
    json_bytes += b' ' * ((-len(json_bytes)) % 4)
    binary += b'\0' * ((-len(binary)) % 4)
    total_size = 12 + 8 + len(json_bytes) + 8 + len(binary)
    glb = struct.pack('<4sII', b'glTF', 2, total_size)
    glb += struct.pack('<I4s', len(json_bytes), b'JSON') + json_bytes
    glb += struct.pack('<I4s', len(binary), b'BIN\0') + binary
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    out = OUTPUT_ROOT / (model_id + '.glb')
    out.write_bytes(glb)
    report = {'model_id': model_id, 'gear_class': gear_class, 'conversion_profile': profile, 'source_model_entry': source_model_entry, 'output': str(out), 'output_size': len(glb),
        'output_sha256': sha(glb), 'source_manifest': str(source_dir / 'manifest.json'),
        'source_x_sha256': entries[source_model_entry]['source_sha256'], 'source_pack_sha256': manifest['source_pack_sha256'],
        'importer': 'libassimp 5.4.3 with pyassimp 5.2.5 binding',
        'source_mesh_count': source_mesh_count, 'source_bone_count': source_bone_count,
        'source_animation_count': source_animation_count, 'exported_animation_count': 0,
        'pose': 'Static original frame transforms; animation tracks omitted explicitly; no skinned bones present.',
        'coordinate_transform': 'Assimp X importer reflects original Z for vertices/normals/node transforms and reverses winding. Then proper rotation Y=180deg restores original ship forward -Z to output -Z. Combined original point transform is (-x,y,z) before frame hierarchy. +Y retained.',
        'forward_axis': '-Z',
        'heading_evidence': {'path': '/workspace/targets/ace-online-ep35/Client/DataRenderLib/main/ShuttleChild.cpp', 'lines': [1278,1279,8405,8406,8431,8434], 'explanation': 'inverse LookAtRH(pos,pos+velocity) orients model local -Z along travel; weapon velocity is negated matrix Z basis.'},
        'hierarchy': 'All original static frame transforms baked in vertices. Normals use inverse transpose and renormalization. Negative determinant transforms reverse triangle winding.',
        'uv_transform': 'X importer V=1-sourceV; glTF exporter V=1-AssimpV (matches official Assimp glTF2Exporter). No pixel image flip.',
        'units': 'One output unit equals one original model unit. Physical meter calibration is unknown. No centering/scaling applied.',
        'aabb_min': minimum.tolist(), 'aabb_max': maximum.tolist(), 'aabb_size': (maximum - minimum).tolist(),
        'aabb_center': ((minimum + maximum) / 2).tolist(), 'vertices': len(positions),
        'triangles': sum(m['triangles'] for m in mesh_records), 'meshes': mesh_records,
        'textures': texture_records,
        'unused_image_entries': sorted(e for e, v in entries.items() if v['kind'] == 'image' and e not in texture_by_entry),
        'external_resources': [], 'validation': 'Source hashes/sizes, geometry numeric bounds/indices, finite unit normals and exact texture entry binding checked.'}
    if profile in {'sky', 'cloud'}:
        report['asset_kind'] = profile
        del report['gear_class']
        report['forward_axis'] = 'Not normalized; sky has no ship heading.'
        report['coordinate_transform'] = 'Assimp X importer reflects original Z for vertices/normals/node transforms and reverses winding. Original hierarchy transforms baked; no ship heading, runtime sky orientation, scale or camera translation baked.'
        report['heading_evidence'] = {'path': '/workspace/targets/ace-online-ep35/Client/DataRenderLib/main/ETCRender.cpp', 'lines': [205,207,209,210,212,213,216,217,218], 'explanation': 'Runtime original column rotation R=RotY(-90deg), from inverse LookAtRH(+X), has RH-converted equivalent H*R*H=RotY(+90deg), H=diag(1,1,-1). Apply outside asset.'}
        report['runtime_source_profile'] = {'rotation_y_degrees_after_assimp_rh': 90,
            'original_rotation_column_matrix': [[0,0,-1],[0,1,0],[1,0,0]],
            'converted_rotation_column_matrix': [[0,0,1],[0,1,0],[-1,0,0]],
            'scale': 'fogEnd / 133.0 (ETCRender.cpp:16,212)',
            'translation': 'camera eye follows X/Y/Z (ETCRender.cpp:216-218)',
            'depth': 'D3DRS_ZENABLE FALSE for entire SkyRender (ETCRender.cpp:202); GLB does not encode depth-test/render-order policy.',
            'day_cloud_alpha': 'Source applies saturated textureAlpha - (1 - m_fAlphaSky), ETCRender.cpp:256-259; GLB preserves original image alpha only. Runtime day/night fade is not baked.',
            'map_binding': 'MapInfo Sky/Cloud fields select each pack independently (ETCRender.cpp:66,107); matching terrain map is not established.',
            'composition': 'Using these assets with a terrain requires an explicitly adapted composition until original MapInfo binding is confirmed.'}
        report['material_profile'] = {'unlit': profile == 'sky', 'alphaMode': 'BLEND' if profile == 'cloud' else 'OPAQUE',
            'doubleSided': False, 'source': 'ETCRender.cpp:203,253,261,262; original mesh normals/winding preserved.'}
    if profile == 'actor':
        report['asset_kind'] = 'monster'
        del report['gear_class']
        report['coordinate_transform'] = 'Assimp X importer reflects Z and reverses winding; proper Y180 rotation restores source actor local -Z forward. Static hierarchy baked, units unchanged.'
        report['heading_evidence'] = {'path': '/workspace/targets/ace-online-ep35/Client/DataRenderLib/main/MonsterData.cpp', 'lines': [231,832,836], 'explanation': 'inverse LookAtRH(pos,pos+velocity) orients model local -Z along travel.'}
    if profile == 'scenery':
        report['asset_kind'] = profile
        del report['gear_class']
        del report['forward_axis']
        del report['heading_evidence']
        report['coordinate_transform'] = 'Assimp X importer reflects original Z for vertices/normals/node transforms and reverses winding. Original hierarchy transforms baked; no ship heading, sky orientation, runtime placement, centering or scale baked.'
        report['material_profile'] = {'unlit': False, 'doubleSided': False,
            'alpha_mode_origin': 'Only an explicit caller alpha_mode overrides the imported material default; texture alpha does not select render policy.',
            'material_alpha_modes': [m.get('alphaMode', 'OPAQUE') for m in document['materials']],
            'source_selected_mapobjectinfo_alpha': 'Unconfirmed; no per-model Alpha value inferred.',
            'source_conditional_alpha_policy': {
                'path': '/workspace/targets/ace-online-ep35/Client/DataRenderLib/main/ObjRender.cpp',
                'lines': [65,67,69,70,72,73,74], 'condition': 'MAPOBJECTINFO.Alpha != 0',
                'combined_alpha_test_blend': True, 'alpha_test': 'GREATEREQUAL', 'alpha_reference': 127,
                'blend': 'SRCALPHA / INVSRCALPHA',
                'gltf_limitation': 'Core glTF supports either MASK or BLEND per material; it cannot encode this combined source policy exactly.'}}
    if alpha_mode is not None:
        report['alpha_override'] = {'origin': 'Explicit caller choice, not proof of original MAPOBJECTINFO.Alpha.',
            'alphaMode': alpha_mode, 'alphaCutoff': alpha_cutoff,
            'effective_mask_cutoff': (0.5 if alpha_cutoff is None else alpha_cutoff) if alpha_mode == 'MASK' else None}
    if texture_entry_override is not None:
        report['texture_override'] = {'entry_name': texture_entry_override,
            'origin': 'Explicit caller texture selection; caller must record source AnotherTexture(index) evidence. No basename guessing.'}
    if generate_zero_normals:
        report['normal_repair'] = {'policy': 'Only exactly zero source normals replaced with normalized area-weighted incident face cross products after baked transforms/winding. Nonzero normals retained. Degenerate-only vertices are rejected.',
            'derived_vertices': sum(m['derived_zero_normal_vertices'] for m in mesh_records),
            'limitation': 'Derived geometry normals adapt malformed source normal data to valid glTF; this is not an exact source lighting match.'}
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    (REPORT_ROOT / (model_id + '-conversion.json')).write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=SOURCE_ROOT)
    parser.add_argument('--output-root', type=Path, default=OUTPUT_ROOT)
    parser.add_argument('--report-root', type=Path, default=REPORT_ROOT)
    args = parser.parse_args()
    SOURCE_ROOT, OUTPUT_ROOT, REPORT_ROOT = args.source_root, args.output_root, args.report_root
    REPORT_ROOT.mkdir(parents=True, exist_ok=True)
    reports = [convert(model_id, gear_class) for model_id, gear_class in MODELS.items()]
    (REPORT_ROOT / 'gear-glb-conversion.json').write_text(json.dumps(reports, indent=2, allow_nan=False) + '\n')
    for r in reports:
        print(json.dumps({k: r[k] for k in ['model_id', 'output', 'vertices', 'triangles', 'aabb_min', 'aabb_max', 'aabb_size']}))
