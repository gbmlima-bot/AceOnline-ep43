#!/usr/bin/env python3
"""Convert exact unwrapped .sky/.cld payloads without baking runtime orientation."""
from pathlib import Path
import argparse
import json
import convert_original_gears as core

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=core.SOURCE_ROOT)
parser.add_argument('--output-root', type=Path, default=Path('/workspace/ace-modern/client/assets/original_sky'))
parser.add_argument('--report-root', type=Path, default=core.REPORT_ROOT)
args = parser.parse_args()
core.SOURCE_ROOT, core.OUTPUT_ROOT, core.REPORT_ROOT = args.source_root, args.output_root, args.report_root
core.REPORT_ROOT.mkdir(parents=True, exist_ok=True)
reports = [core.convert('3002_sky', 'SKY', source_model_entry='300200', profile='sky'),
           core.convert('3002_cloud', 'CLOUD', source_model_entry='300200', profile='cloud')]
(args.report_root / 'sky-glb-conversion.json').write_text(json.dumps(reports, indent=2, allow_nan=False) + '\n')
for report in reports:
    print(json.dumps({k: report[k] for k in ['model_id', 'output', 'vertices', 'triangles', 'aabb_min', 'aabb_max']}))
