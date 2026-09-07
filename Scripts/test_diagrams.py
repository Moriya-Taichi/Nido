#!/usr/bin/env python3
"""Verify CLI views, self-contained SVG, and reproducible documented examples."""
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
subprocess.run(['swift', 'build', '--jobs', '2'], cwd=root, check=True)
bin_dir = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=root, text=True).strip())
with tempfile.TemporaryDirectory() as tmp:
    for product, document in [('nido-aws-example', 'aws-architecture.svg'),
                              ('nido-architecture-example', 'multi-region-architecture.svg')]:
        directory = Path(tmp) / product
        subprocess.run([bin_dir / product, '--nido-output', directory], check=True)
        graph = directory / 'nido.graph.json'
        for view in ['architecture', 'dependencies']:
            for fmt in ['svg', 'mermaid', 'dot']:
                output = subprocess.check_output([bin_dir / 'nido', 'diagram', '--from', graph,
                                                   '--view', view, '--format', fmt], text=True)
                if fmt == 'svg':
                    element = ET.fromstring(output)
                    assert element.tag == '{http://www.w3.org/2000/svg}svg'
                    assert not any('href' in key for child in element.iter() for key in child.attrib)
                    if view == 'architecture':
                        assert output == (root / 'Docs' / document).read_text(), f'Regenerate {document}'
        if product == 'nido-architecture-example':
            assert 'resource' not in json.loads((directory / 'main.tf.json').read_text())
print('Diagram CLI, SVG, and documentation checks passed')
