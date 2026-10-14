"""Exercise actual JSON-line process on a clearly synthetic fixture, without CLI.

Usage: python scripts/smoke_engine.py /path/to/mantis-engine

Covers what the native app advertises: handshake, open, PCA with the scree-selected
component count, clustering, numeric export and every graphics export format. A
missing matplotlib backend in a frozen build must fail here, not in the GUI.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np

GRAPHICS = {"png": b"\x89PNG\r\n\x1a\n", "pdf": b"%PDF", "svg": b"<svg"}


def is_graphics(path, fmt):
    """matplotlib writes SVG with an XML prolog, so check the body, not byte 0."""
    head = path.read_bytes()[:1024]
    return head.startswith(GRAPHICS[fmt]) if fmt != "svg" else GRAPHICS[fmt] in head


def main():
    executable = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='mantis-engine-smoke-') as directory:
        root = Path(directory)
        x, y, e = np.indices((8, 6, 12))
        data = 0.2 + 0.01 * x + 0.03 * y + np.exp(-((e - 3 - (x > 3)) / 2) ** 2)
        source = root / 'synthetic-only.npz'
        np.savez(source, data=data, energies=np.linspace(280, 310, 12))
        output = root / 'result.npz'
        graphics = {fmt: root / f'view.{fmt}' for fmt in GRAPHICS}
        methods = [('hello', {}), ('open', {'path': str(source), 'pre_normalized': True}),
                   ('pca', {}),
                   ('cluster', {'clusters': 2, 'components': 2, 'seed': 0}),
                   ('export', {'path': str(output), 'format': 'npz'})]
        methods += [('export', {'path': str(path), 'format': fmt}) for fmt, path in graphics.items()]
        requests = [{'id': i, 'protocol': 1, 'method': name, 'params': params}
                    for i, (name, params) in enumerate(methods)]
        environment = dict(os.environ)
        for key in ('PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV'):
            environment.pop(key, None)
        environment['MPLBACKEND'] = 'Agg'
        result = subprocess.run([str(executable)], input=''.join(json.dumps(r) + '\n' for r in requests),
                                text=True, capture_output=True, cwd=root, env=environment, timeout=180)
        assert result.returncode == 0, result.stderr
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(responses) == len(requests), result.stdout
        for request, response in zip(requests, responses):
            assert response['id'] == request['id'], response
            assert response['protocol'] == 1, response
            assert response['ok'] is True, response
        assert responses[1]['result']['shape'] == [8, 6, 12]
        # No explicit component count: the scree test decides, as in the GUI.
        assert responses[2]['result']['pca_ready'] is True, responses[2]
        assert output.is_file() and output.stat().st_size > 0
        with np.load(output, allow_pickle=False) as exported:
            assert exported.files
            assert exported['raw_data'].shape == (8, 6, 12)
        for fmt, path in graphics.items():
            assert path.is_file() and path.stat().st_size > 0, f'Missing {fmt} export'
            assert is_graphics(path, fmt), f'{fmt} export is not a {fmt} file'
        print('PASS: standalone engine handshake → synthetic NPZ → PCA → clustering → numeric and '
              + '/'.join(GRAPHICS) + ' exports; no CLI/PYTHONPATH')


if __name__ == '__main__':
    main()
