#!/usr/bin/env python3
"""Build a self-contained comparison from actual prototype screenshots."""
import argparse
import base64
import html
from pathlib import Path


def uri(path):
    return 'data:image/png;base64,' + base64.b64encode(path.read_bytes()).decode()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--before-dir', required=True, type=Path, help='Preserved 0.3 screenshots')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    reports = root / 'reports'
    views = []
    for key, label, filename in [('flight', 'Voo', 'preview.png'), ('inventory', 'Inventário', 'inventory.png')]:
        views.append(f'''<div class="comparison" data-view="{key}" {'hidden' if key != 'flight' else ''}>
<img src="{uri(reports / filename)}" alt="Versão 0.4 com recursos originais: {label}">
<div class="before"><img src="{uri(args.before_dir / filename)}" alt="Versão 0.3 com nave e mundo provisórios: {label}"></div>
<div class="divider"></div><span class="tag old">0.3 · antes</span><span class="tag new">0.4 · recursos originais</span></div>''')
    cards = []
    for label, filename, resource in [('B-Gear', 'gear-b.png', '12000100'), ('M-Gear', 'gear-m.png', '12001100'), ('I-Gear', 'inventory.png', '12003100')]:
        cards.append(f'<figure><div class="crop"><img src="{uri(reports / filename)}" alt="{html.escape(label)} original no inventário Godot"></div><figcaption>{label} · recurso {resource}</figcaption></figure>')
    page = '''<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ACE Modern 0.4 · recursos originais</title><style>
:root{color-scheme:dark;font:16px system-ui,sans-serif;color:#d9e7f1;background:#101921}*{box-sizing:border-box}
body{margin:0 auto;max-width:1400px;padding:30px 24px 50px}h1{font-size:clamp(24px,4vw,38px);margin:0 0 8px;color:#fff}
p{max-width:1000px;line-height:1.55;color:#b9cbd8}nav{display:flex;gap:10px;margin:24px 0 12px}
button{font:inherit;color:#d5e7f1;background:#1b2d3b;border:1px solid #3a566a;border-radius:7px;padding:9px 18px;cursor:pointer}
button[aria-pressed=true]{background:#316b88;border-color:#91c9e7;color:white}.comparison{position:relative;aspect-ratio:8/5;overflow:hidden;border:1px solid #547080;border-radius:8px}
.comparison>img,.before,.before>img{position:absolute;inset:0;width:100%;height:100%}.comparison img{object-fit:contain}
.before{clip-path:inset(0 50% 0 0)}.divider{position:absolute;top:0;bottom:0;left:50%;width:2px;background:#d6e8f2}
.tag{position:absolute;top:12px;padding:5px 9px;background:#10222cdd;border-radius:4px;font-size:13px}.old{left:12px}.new{right:12px}
label{display:block;margin:14px 0 6px}input{width:100%;accent-color:#a9dcf0;height:28px}.small{font-size:14px}.gallery{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:24px}
figure{margin:0;border:1px solid #3a5262;border-radius:7px;overflow:hidden;background:#172733}.crop{position:relative;aspect-ratio:379/506;overflow:hidden}.crop img{display:block;position:absolute;width:379.947%;max-width:none;left:-140.106%;top:-38.933%}figcaption{padding:10px;font-size:14px}
ul{padding-left:21px;line-height:1.65}a{color:#a4d9ef}h2{margin-top:32px;font-size:23px}[hidden]{display:none!important}
@media(max-width:700px){body{padding:20px 12px}.gallery{grid-template-columns:1fr}.tag{font-size:10px;top:6px}.old{left:6px}.new{right:6px}}
</style><h1>ACE Modern 0.4 · recursos originais</h1>
<p>Naves, terreno, céu e nuvens recuperados do cliente oficial e convertidos para Godot. A interface azul da versão anterior foi preservada.</p>
<nav aria-label="Tipo de comparação"><button type="button" data-target="flight" aria-pressed="true">Voo</button><button type="button" data-target="inventory" aria-pressed="false">Inventário</button></nav>
''' + ''.join(views) + '''<label for="split">Arraste para comparar a 0.3 com a 0.4</label><input id="split" type="range" min="0" max="100" value="50" aria-label="Porcentagem da imagem anterior">
<p class="small">Ambas as imagens são do protótipo, em 1440 × 900, com o voo parado no ponto inicial. O enquadramento da câmera foi ajustado às dimensões da nave original. Nenhuma captura desta página é do cliente original em execução.</p>
<h2>Três modelos reais, com suas texturas</h2><div class="gallery">''' + ''.join(cards) + '''</div>
<h2>O que foi integrado</h2><ul><li>B-Gear, M-Gear e I-Gear, com materiais vinculados às imagens originais. F2 alterna os modelos no treino.</li>
<li>Geometria do terreno 3002: 131.072 triângulos e 16 texturas JPEG originais.</li><li>723 objetos do cenário nas posições do mapa, usando três modelos originais.</li><li>Malhas e texturas originais de céu e nuvens, com adaptação ao renderer do Godot.</li>
<li>531 imagens originais da interface e composição selecionada do cliente azul.</li></ul>
<p>Origem: pacote oficial Masang de 09/07/2025. Os hashes e as transformações estão nos manifestos incluídos nos fontes. A seleção de céu e terreno é uma composição adaptada: o vínculo atual no banco do jogo não foi confirmado.</p>
<p>O protótipo continua offline. Animações originais, os demais objetos do mapa, água, efeitos, colisões, combate e servidores ainda precisam de adaptação. Os pacotes macOS e Windows foram exportados; a execução desta entrega foi validada em Linux.</p>
<script>
const slider=document.querySelector('#split');function update(){document.querySelectorAll('.before').forEach(x=>x.style.clipPath=`inset(0 ${100-slider.value}% 0 0)`);document.querySelectorAll('.divider').forEach(x=>x.style.left=slider.value+'%')};slider.addEventListener('input',update);
document.querySelectorAll('button[data-target]').forEach(button=>button.addEventListener('click',()=>{document.querySelectorAll('button[data-target]').forEach(b=>b.setAttribute('aria-pressed',b===button?'true':'false'));document.querySelectorAll('[data-view]').forEach(v=>v.hidden=v.dataset.view!==button.dataset.target)}));update();
</script></html>'''
    out = root / 'docs/comparacao-assets.html'
    out.write_text(page)
    print(out)


if __name__ == '__main__':
    main()
