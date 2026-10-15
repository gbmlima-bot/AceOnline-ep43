#!/usr/bin/env python3
"""Build a self-contained visual comparison; never label a reconstruction as original."""
import argparse
import base64
import hashlib
import json
from pathlib import Path


def picture(path, title, description, url=None):
    suffix = path.suffix.lower()
    mime = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif'}[suffix]
    data = path.read_bytes()
    return {'title': title, 'description': description, 'url': url,
            'sha256': hashlib.sha256(data).hexdigest(),
            'src': 'data:' + mime + ';base64,' + base64.b64encode(data).decode('ascii')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--before-dir', required=True, type=Path)
    parser.add_argument('--after-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    records = json.loads((root / 'docs/visual-references.json').read_text())['records']
    order = ['reference-suba-ep46-4.jpg', 'reference-masang-img3_01.png',
             'reference-suba-tutorial-inventory-shop.jpg', 'reference-masang-trd4.png']
    references = []
    for name in order:
        row = next(row for row in records if Path(row['project_path']).name == name)
        references.append(picture(root / row['project_path'], {
            'reference-suba-ep46-4.jpg': 'Original publicado · Suba, página EP4.6',
            'reference-masang-img3_01.png': 'Original publicado · guia Masang, HUD anotado',
            'reference-suba-tutorial-inventory-shop.jpg': 'Original histórico · tutorial Suba de 2009',
            'reference-masang-trd4.png': 'Original publicado · inventário interno do Trade Center'
        }[name], row['description_pt'] + ' A data/build da captura não foi comprovada.', row['context_url']))
    captures = []
    for directory, version in [(args.after_dir, '0.3 · layout revisado'), (args.before_dir, '0.2 · antes da comparação')]:
        for name, label in [('preview.png', 'HUD'), ('inventory.png', 'inventário')]:
            description = 'Reconstrução Godot local. Cenário e nave provisórios; sem sessão de servidor.'
            metadata_path = directory / (Path(name).stem + '-layout.json')
            if metadata_path.exists():
                metadata = json.loads(metadata_path.read_text())
                if metadata.get('freeze_flight_for_comparison'):
                    description += ' Captura com voo congelado no estado inicial, para comparar o layout.'
            captures.append(picture(directory / name, version + ' · ' + label,
                                    description))
    layout = json.loads((root / 'client/assets/legacy_ui/group_layout.json').read_text())
    manifest = json.loads((root / 'client/assets/legacy_ui/manifest.json').read_text())
    inventory = next(group for group in layout['groups'] if group['name'] == 'inven')
    payload = json.dumps({'references': references, 'captures': captures,
                          'layout': {'sha256': layout['source_sha256'], 'group_count': len(layout['groups']),
                                     'asset_count': len(manifest['entries']), 'inventory_bounds': inventory['image_bounds_unrotated_local']}},
                         ensure_ascii=False).replace('</', '<\\/')
    document = r'''<!doctype html>
<html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ACE Modern · comparação de layout</title>
<style>
:root{color-scheme:dark;font:16px/1.5 system-ui,sans-serif;background:#0b121a;color:#e1eaf3}*{box-sizing:border-box}
body{max-width:1600px;margin:auto;padding:32px}h1{font-size:28px;margin:0 0 10px}p{max-width:1000px;color:#b1c0cd}
.badge{display:inline-block;color:#74d6ed;border:1px solid #285261;border-radius:4px;padding:3px 8px;font-size:12px;letter-spacing:.06em;margin-bottom:16px}
.controls{display:flex;gap:18px;flex-wrap:wrap;margin:24px 0}label{display:grid;gap:6px;flex:1;min-width:240px;font-size:13px;color:#b1c0cd}
select,button{font:inherit;background:#152331;color:#e1eaf3;border:1px solid #324859;border-radius:6px;padding:10px}
button{cursor:pointer;align-self:end}button:focus-visible,select:focus-visible{outline:2px solid #74d6ed}
.panels{display:grid;grid-template-columns:1fr 1fr;gap:20px}.panel{margin:0;background:#111d28;border:1px solid #283b4a;border-radius:8px;overflow:hidden}
.panel figcaption{padding:15px}.panel h2{font-size:16px;margin:0 0 5px}.panel p{font-size:13px;margin:0 0 7px}
.stage{background:#050a0e;overflow:auto;min-height:200px}.stage img{display:block;width:100%;height:auto}
a{color:#8adbed}.hash{font:10px/1.5 ui-monospace,monospace;overflow-wrap:anywhere;color:#8298aa}
.overlay{display:none;position:relative;overflow:hidden;background:#050a0e;border:1px solid #283b4a;border-radius:8px}
.overlay img{display:block;width:100%;height:auto}.overlay #over{position:absolute;inset:0;width:100%;height:100%;object-fit:fill;opacity:.5}
.opacity{display:none;max-width:500px;margin-top:16px}input{width:100%}.note{border-left:3px solid #74d6ed;padding:8px 16px;margin-top:24px}
.zoom .stage img{width:auto;max-width:none}.zoom .stage{max-height:900px}
@media(max-width:900px){body{padding:18px}.panels{grid-template-columns:1fr}h1{font-size:23px}}
</style>
<span class="badge">REFERÊNCIAS OFICIAIS + RECONSTRUÇÃO LOCAL</span>
<h1>Comparação de layout · ACE Modern 0.3</h1>
<p>As imagens à esquerda foram publicadas pelos operadores do jogo. À direita está a reconstrução em Godot. Use as versões anteriores para conferir o que mudou.</p>
<div class="controls"><label>Referência<select id="reference"></select></label><label>Reconstrução<select id="capture"></select></label><button id="zoom">Tamanho natural</button><button id="mode">Sobrepor</button></div>
<div class="panels" id="panels"><figure class="panel"><div class="stage"><img id="ref-image" alt="Referência oficial"></div><figcaption><h2 id="ref-title"></h2><p id="ref-description"></p><a id="ref-link" target="_blank" rel="noopener">Ver publicação original</a><div class="hash" id="ref-hash"></div></figcaption></figure>
<figure class="panel"><div class="stage"><img id="capture-image" alt="Reconstrução local"></div><figcaption><h2 id="capture-title"></h2><p id="capture-description"></p><div class="hash" id="capture-hash"></div></figcaption></figure></div>
<div class="overlay" id="overlay"><img id="under" alt="Referência oficial"><img id="over" alt="Reconstrução sobreposta"></div><label class="opacity" id="opacity-label">Opacidade da reconstrução<input id="opacity" type="range" min="0" max="100" value="50"></label>
<p class="note">A comparação usa bordas da tela como referência. Cenas, resoluções, idioma e estados diferem; a sobreposição não comprova equivalência pixel a pixel. O cliente original não foi executado neste ambiente.</p>
<p id="layout-evidence"></p><div class="hash" id="layout-hash"></div>
<script>
const data=PAYLOAD;
const $=id=>document.getElementById(id);let overlay=false;
$('layout-evidence').textContent=`Composição extraída do pacote Masang de 09/07/2025: ${data.layout.group_count} grupos selecionados, ${data.layout.asset_count} imagens originais. O grupo ativo «inven» ocupa ${Math.round(data.layout.inventory_bounds[2]-data.layout.inventory_bounds[0])} × ${Math.round(data.layout.inventory_bounds[3]-data.layout.inventory_bounds[1])} pixels. A moldura «tc_inven» da versão 0.2 pertence ao Trade Center.`;
$('layout-hash').textContent='Group.tex SHA-256 '+data.layout.sha256;
for(const [id,rows] of [['reference',data.references],['capture',data.captures]])rows.forEach((row,index)=>{const o=document.createElement('option');o.value=index;o.textContent=row.title;$(id).append(o)});
function update(){const ref=data.references[$('reference').value],cap=data.captures[$('capture').value];
for(const [prefix,row] of [['ref',ref],['capture',cap]]){$(prefix+'-image').src=row.src;$(prefix+'-title').textContent=row.title;$(prefix+'-description').textContent=row.description;$(prefix+'-hash').textContent='SHA-256 '+row.sha256}
$('ref-link').href=ref.url;$('under').src=ref.src;$('over').src=cap.src;}
$('reference').onchange=update;$('capture').onchange=update;$('opacity').oninput=()=>{$('over').style.opacity=$('opacity').value/100};
$('mode').onclick=()=>{overlay=!overlay;$('panels').style.display=overlay?'none':'';$('overlay').style.display=overlay?'block':'none';$('opacity-label').style.display=overlay?'grid':'none';$('mode').textContent=overlay?'Lado a lado':'Sobrepor'};
$('zoom').onclick=()=>{document.body.classList.toggle('zoom');$('zoom').textContent=document.body.classList.contains('zoom')?'Ajustar à largura':'Tamanho natural'};update();
</script></html>'''.replace('PAYLOAD', payload)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(document)
    print(str(args.output))


if __name__ == '__main__':
    main()
