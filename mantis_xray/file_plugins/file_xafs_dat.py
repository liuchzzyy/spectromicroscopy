"""Lossless ASCII XAFS spectra; no implicit detector-to-absorption formula.

``read_spectra`` returns a labelled table, not an image stack or incident I0.
Unknown energy units stay unknown. The legacy stack API cannot represent these
semantics and deliberately refuses conversion rather than inventing pixels/OD.
"""
from pathlib import Path
import re

import numpy as np


title = 'XAFS ASCII spectra'
extension = ['*.dat', '*.xdi']
read_types = ['spectrum']
write_types = []


def _column(name, unit=None):
    semantic = ('provided_absorption' if name.lower() in
                {'mu', 'mu_ref', 'mutrans', 'mufluor', 'xmu', 'mu01', 'mu12', 'mu23'}
                else 'source_channel')
    return {'name': name, 'unit': unit, 'semantic': semantic}


def _table(lines, start, width):
    rows = []
    for number, line in enumerate(lines[start:], start + 1):
        text = line.strip()
        if not text or text.startswith(('#', ';')) or text == '\x1a':
            continue
        try:
            row = [float(value) for value in text.replace(',', ' ').split()]
        except ValueError as exc:
            raise ValueError(f'Invalid numeric data at line {number}') from exc
        if len(row) != width:
            raise ValueError(f'Column count mismatch at line {number}: header declares {width}, data has {len(row)}')
        rows.append(row)
    data = np.asarray(rows, dtype=float)
    if data.ndim != 2 or not len(data) or not np.isfinite(data).all():
        raise ValueError('XAFS data must be a nonempty finite numeric table')
    return data


def _dat_layout(lines):
    """Recognize header dialects by content, never the file's location."""
    first = lines[0].strip() if lines else ''
    if 'KEK-PF' in first and first.startswith('9809'):
        raise ValueError('KEK-PF angle-based data requires an explicit Bragg-angle and detector-mode adapter; no absorption formula inferred')
    if sum(line.startswith('#S ') for line in lines) > 1:
        raise ValueError('Multiple SPEC scans require explicit scan selection and energy-column unit metadata')
    if first.startswith('SSRL') and 'Data Collector' in first:
        match = re.search(r'COLS:\s*(\d+)', lines[2]) if len(lines) > 2 else None
        starts = [i + 1 for i, line in enumerate(lines) if line.strip() == 'Data:']
        if match is None or len(starts) != 1:
            raise ValueError('Invalid SSRL column header')
        width, start = int(match[1]), starts[0]
        labels = [line.strip() for line in lines[start:start + width]]
        energy = labels.index('Achieved Energy') if 'Achieved Energy' in labels else labels.index('Requested Energy')
        return [_column(label) for label in labels], start + width, energy
    if first == '# CLS Data Acquisition':
        labels = re.findall(r'"([^"]+)"', lines[1])
        return [_column(label) for label in labels], 6, labels.index('BL1606-ID-1:Energy')
    if first.startswith('; Epics Scan'):
        definitions = {}
        for i, line in enumerate(lines):
            match = re.match(r';\s*([PD]\d+)\s*=\s*\{([^}]+)\}', line)
            if match:
                definitions[match[1]] = match[2]
            tokens = line.lstrip('; ').split()
            if tokens and all(token in definitions for token in tokens):
                labels = [definitions[token] for token in tokens]
                return [_column(label) for label in labels], i + 1, labels.index('Energy')
    for i, line in enumerate(lines):
        text = line.strip()
        if re.match(r'#C\s+1_Energy\s+\(keV\)', text):
            fields = re.findall(r'(\d+)_([^\s]+)(?:\s+\(([^)]+)\))?', text)
            if [int(field[0]) for field in fields] != list(range(1, len(fields) + 1)):
                raise ValueError('Noncontiguous numbered DAT columns')
            return [_column(name, unit or None) for _, name, unit in fields], i + 1, 0
        if first.startswith('MRCAT_XAFS') and text.split() == ['energy', 'Io', 'It', 'Iref', 'If']:
            return [_column(name) for name in text.split()], i + 1, 0
        if first.startswith('#1-D Scan File') and text.startswith('#Mono Energy *'):
            pieces = text[1:].split('*')
            labels = [part.strip() for part in pieces[:2]] + pieces[2].split()
            return [_column(name) for name in labels], i + 1, 0
        if i == 0 and text.startswith('#eBraggEnergy '):
            return [_column(name) for name in text[1:].split()], 1, 0
        if first == '# Facility: NSLS-II' and text.startswith('# # energy '):
            return [_column(name) for name in text.lstrip('# ').split()], i + 1, 0
        if i == 0 and re.match(r'#\s+Energy_c1\s', text):
            fields = [re.fullmatch(r'(.+)_c(\d+)', token) for token in text[1:].split()]
            if not all(fields) or [int(m[2]) for m in fields] != list(range(1, len(fields) + 1)):
                raise ValueError('Invalid numbered channel definitions')
            return [_column(m[1]) for m in fields], 1, 0
    raise ValueError('Unsupported XAFS ASCII header: explicit column definitions required')


def read_spectra(filename, selection=0):
    """Return source columns, original values, metadata and known energy in eV.

    ``energy_eV`` is None when the header provides no energy unit; numerical
    magnitude, filename and parent directory never establish a unit or beamline.
    """
    lines = Path(filename).read_text(encoding='utf-8-sig').splitlines()
    metadata = {}
    starts = [i for i, line in enumerate(lines) if line.startswith('#S ')]
    if selection is None:
        selection = 0
    if not isinstance(selection, int) or isinstance(selection, bool) or not 0 <= selection < max(1, len(starts)):
        raise ValueError('Scan selection must be a valid zero-based integer index')
    if starts and any(line.startswith('#L ') for line in lines):
        scans = []
        for index, start in enumerate(starts):
            parts = lines[start].split(maxsplit=2)
            scans.append({'index': index, 'number': parts[1],
                          'command': parts[2] if len(parts) > 2 else ''})
        start = starts[selection]
        stop = starts[selection + 1] if selection + 1 < len(starts) else len(lines)
        block = lines[start:stop]
        label_at = next((i for i, line in enumerate(block) if line.startswith('#L ')), None)
        if label_at is None:
            raise ValueError('Missing SPEC column labels')
        labels = re.split(r'\s{2,}', block[label_at][3:].strip())
        declared = next((int(line[3:].strip()) for line in block if line.startswith('#N ')), None)
        if declared != len(labels):
            raise ValueError('SPEC column count does not match #N')
        columns = [_column(label) for label in labels]
        data = _table(block, label_at + 1, len(columns))
        energy = next((i for i, label in enumerate(labels)
                       if label.lower() in {'energy', 'zapenergy'}), None)
        return {'data': data, 'columns': columns,
                'metadata': {'format': 'SPEC', 'scans': scans, 'selected_scan': selection},
                'axis_column': energy, 'axis_kind': 'energy' if energy is not None else 'unknown',
                'energy_column': energy, 'energy_unit': None, 'energy_eV': None,
                'formula_applied': None, 'header': lines[:starts[0]] + block[:label_at + 1]}
    if lines and 'KEK-PF' in lines[0] and lines[0].strip().startswith('9809'):
        labels_at = next((i for i, line in enumerate(lines)
                          if line.strip().startswith('Angle(c)')), None)
        if labels_at is None:
            raise ValueError('Missing KEK-PF angle column header')
        start = labels_at + 3
        labels = lines[labels_at].split()
        columns = [_column(label, 'deg' if label.startswith('Angle(')
                           else 's' if label == 'time/s' else None) for label in labels]
        data = _table(lines, start, len(columns))
        metadata = {'format': 'KEK-PF 9809',
                    'detector_mode': lines[labels_at + 1].strip(),
                    'detector_offset': lines[labels_at + 2].strip(),
                    'monochromator': next((line.strip() for line in lines[:start]
                                           if line.strip().startswith('Mono :')), None)}
        return {'data': data, 'columns': columns, 'metadata': metadata,
                'axis_column': 0, 'axis_kind': 'angle',
                'energy_column': None, 'energy_unit': None, 'energy_eV': None,
                'formula_applied': None, 'header': lines[:start]}
    if not lines or not re.match(r'#\s*XDI/', lines[0].strip()):
        columns, start, energy_index = _dat_layout(lines)
        if lines and re.match(r'#\s+Energy_c1\s', lines[0]):
            numeric = next((line for line in lines[start:] if line.strip()
                            and not line.lstrip().startswith(('#', ';'))), '')
            width = len(numeric.split())
            if width != len(columns):
                metadata = {'declared_columns': columns,
                            'warnings': [f'Header declares {len(columns)} columns but data has {width}; '
                                         'column mapping is unknown. Raw numeric table retained.']}
                columns = [_column(f'column_{i + 1}') for i in range(width)]
                energy_index = None
        data = _table(lines, start, len(columns))
        unit = columns[energy_index]['unit'] if energy_index is not None else None
        factor = {'eV': 1.0, 'keV': 1000.0}.get(unit)
        return {'data': data, 'columns': columns, 'metadata': metadata,
                'energy_column': energy_index, 'energy_unit': unit,
                'energy_eV': None if factor is None else data[:, energy_index] * factor,
                'formula_applied': None, 'header': lines[:start]}

    numbered = {}
    for line in lines:
        match = re.match(r'#\s*Column\.(\d+):\s*(.*)', line.strip())
        if match:
            index, definition = int(match[1]), match[2].split('||')[0].strip().split(maxsplit=1)
            if index in numbered:
                raise ValueError('Duplicate XDI column definition')
            numbered[index] = _column(definition[0], definition[1] if len(definition) == 2 else None)
        else:
            match = re.match(r'#\s*([\w.]+):\s*(.*)', line.strip())
            if match:
                metadata[match[1]] = match[2]
    if not numbered or sorted(numbered) != list(range(1, len(numbered) + 1)):
        raise ValueError('XDI column definitions must be contiguous from 1')
    columns = [numbered[i] for i in sorted(numbered)]
    data = _table(lines, 0, len(columns))
    energy_indices = [i for i, col in enumerate(columns) if col['name'].lower() == 'energy']
    if len(energy_indices) != 1:
        raise ValueError('Exactly one explicit energy column is required')
    energy_index = energy_indices[0]
    unit = columns[energy_index]['unit']
    factor = {'eV': 1.0, 'keV': 1000.0}.get(unit)
    return {'data': data, 'columns': columns, 'metadata': metadata,
            'energy_column': energy_index, 'energy_unit': unit,
            'energy_eV': None if factor is None else data[:, energy_index] * factor,
            'formula_applied': None, 'header': [line for line in lines if line.lstrip().startswith('#')]}


def identify(filename):
    try:
        read_spectra(filename)
        return True
    except (OSError, UnicodeError, ValueError):
        return False


def GetFileStructure(filename):
    read_spectra(filename)
    return None


def preview(filename, selection=0):
    res = read_spectra(filename, selection=selection)
    columns = [col['name'] for col in res['columns']]
    axis_units = [col.get('unit') for col in res['columns']]
    metadata = dict(res.get('metadata') or {})
    metadata['formula_applied'] = res.get('formula_applied')
    if res.get('energy_unit'):
        metadata['energy_unit'] = res.get('energy_unit')
    return {
        'kind': 'table',
        'schema_version': 1,
        'columns': columns,
        'axis_units': axis_units,
        'rows': res['data'].tolist(),
        'metadata': metadata
    }


def read(filename, stack_object, selection=None, *args, **kwargs):
    read_spectra(filename)
    raise ValueError('XAFS is labelled spectrum data, not a spatial stack or I0. '
                     'Use file_xafs_dat.read_spectra(); Session spectrum support is required.')
