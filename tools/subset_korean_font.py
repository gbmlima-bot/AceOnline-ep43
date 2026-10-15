#!/usr/bin/env python3
"""Build the optional bundled CJK fallback; fontTools is a build dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from fontTools import subset
from fontTools.ttLib import TTFont


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--license',type=Path,required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    characters = set(chr(i) for i in range(32,592))
    inputs = []
    for directory in ['legacy_rules', 'original_library/catalogs', 'local_world']:
        for path in (root/'client/assets'/directory).glob('*.json'):
            # Decode JSON first: some source manifests preserve escaped CJK.
            characters.update(str(json.loads(path.read_text())))
            inputs.append(path.relative_to(root).as_posix())
    options = subset.Options()
    options.name_IDs = ['*']
    options.name_legacy = True
    options.name_languages = ['*']
    font = TTFont(args.source,fontNumber=1)
    builder = subset.Subsetter(options=options)
    builder.populate(unicodes=[ord(c) for c in characters])
    builder.subset(font)
    for record in font['name'].names:
        if record.nameID in [1,3,4,6,16,17]:
            value = 'Regular' if record.nameID==17 else ('ACE-Korean-Regular' if record.nameID==6 else 'ACE Korean Fallback')
            record.string = value.encode(record.getEncoding(),errors='replace')
    destination = root/'client/assets/fonts/ACE-Korean.otf'
    destination.parent.mkdir(parents=True,exist_ok=True)
    font.save(destination)
    source_sha = hashlib.sha256(args.source.read_bytes()).hexdigest()
    output_sha = hashlib.sha256(destination.read_bytes()).hexdigest()
    shutil.copy2(args.license,root/'third_party/Noto-CJK-COPYRIGHT.txt')
    metadata = {'source_project':'https://github.com/notofonts/noto-cjk','source_file':args.source.name,
        'source_sha256':source_sha,'source_face':'Noto Sans CJK KR (TTC face1)',
        'license':'SIL Open Font License1.1; full original notice in Noto-CJK-COPYRIGHT.txt',
        'transformation':'fontTools subset of decoded recovered rules/catalogs plus Latin; font names renamed to ACE Korean Fallback',
        'character_inputs':inputs,
        'output':'client/assets/fonts/ACE-Korean.otf','output_sha256':output_sha,'bytes':destination.stat().st_size,
        'scope':'Bundled text fallback; not artwork from the original game.'}
    (root/'third_party/korean-font-provenance.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps({'font':str(destination),'bytes':destination.stat().st_size,'sha256':output_sha}))


if __name__ == '__main__':
    main()
