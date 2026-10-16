from __future__ import print_function
#
#   This file is part of Mantis, a Multivariate ANalysis Tool for Spectromicroscopy.
#
#   Copyright (C) 2011 Mirna Lerotic, 2nd Look
#   http://2ndlookconsulting.com
#   License: GNU GPL v3
#
#   Mantis is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   any later version.
#
#   Mantis is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details <http://www.gnu.org/licenses/>.

import numpy as np
from PIL import Image
import os


title = 'Tiff'
extension = ['*.tif','*.tiff']
read_types = ['image','stack']
write_types = ['image','stack','results']


def identify(filename):
    try:
        import tifffile
        with tifffile.TiffFile(filename) as tif:
            return bool(tif.pages)
    except:
        return False

def GetFileStructure(FileName):
    return None


#-----------------------------------------------------------------------
def read(filename, self, selection=None, *args, **kwargs):
    """Read calibrated TIFF exports without inventing an energy axis.

    The named sidecars are export-schema conventions, not beamline guesses.
    Ni_eng_list.txt is the TXM-XANES keV convention. Other supported lists
    use eV. Spatial calibration is unknown: coordinates remain pixels.
    """
    from pathlib import Path
    import tifffile
    path = Path(filename)
    sidecars = [(path.with_suffix('.txt'), 1.0),
                (path.parent / 'Energy.txt', 1.0),
                (path.parent / 'energy_list_corr.txt', 1.0),
                (path.parent / 'Ni_eng_list.txt', 1000.0)]
    found = [(p, factor) for p, factor in sidecars if p.is_file()]
    if not found:
        raise ValueError('TIFF has no energy calibration sidecar; cannot load as an energy stack')
    if len(found) != 1:
        raise ValueError('Ambiguous TIFF energy calibration sidecars')
    source, factor = found[0]
    with source.open() as stream:
        energies = np.loadtxt((line for line in stream if not line.lstrip().startswith('*')), ndmin=1)
    if energies.ndim != 1 or not energies.size or not np.all(np.isfinite(energies)) or np.any(energies <= 0):
        raise ValueError('Invalid TIFF energy calibration')
    energies = energies * factor
    with tifffile.TiffFile(path) as tif:
        raw = tif.asarray()
    if raw.ndim == 2 and energies.size == 1:
        cube = raw.T[:, :, None]
    elif raw.ndim == 3:
        candidates = [i for i, size in enumerate(raw.shape) if size == energies.size]
        if len(candidates) != 1:
            raise ValueError('TIFF energy axis is ambiguous or does not match calibration')
        axis = candidates[0]
        if axis == 0:
            cube = raw.transpose(2, 1, 0)  # page, row, column
        elif axis == 2 and source.name == 'Energy.txt':
            cube = raw.transpose(1, 0, 2)  # aXis export: row, column, energy
        else:
            raise ValueError('Unsupported TIFF energy axis layout')
    else:
        raise ValueError('TIFF dimensions do not match energy calibration')
    self.absdata = cube
    self.n_cols, self.n_rows, self.n_ev = cube.shape
    self.ev = energies  # preserve acquisition order, including repeats
    self.x_dist = np.arange(self.n_cols, dtype=float)
    self.y_dist = np.arange(self.n_rows, dtype=float)
    self.data_dwell = np.full(self.n_ev, np.nan)  # not recorded
    self.fill_h5_struct_from_stk()
    self.data_struct.exchange.energy_units = 'eV'
    self.data_struct.exchange.x_units = 'pixel'
    self.data_struct.exchange.y_units = 'pixel'


def read_tif_info(filename):
    img = Image.open(filename)
    arr = np.array(img)
    n_cols = arr.shape[1]
    n_rows = arr.shape[0]
    return n_cols, n_rows

#-----------------------------------------------------------------------
def write(filename, data_object, data_type):
    """Switchyard for writing different types of data."""
    if data_type in ['stack']:
        write_tif(filename, data_object.absdata, data_object.ev)

#-----------------------------------------------------------------------
def write_tif(filename, data, energies = []):

    dims = data.shape
    for i in range(dims[2]):
        basename, extension = os.path.splitext(filename)
        thisfn = basename + '_' + str(i+1) + extension

        img1 = Image.fromarray(data[:,:,i])
        img1.save(thisfn)


    if len(energies) > 0:
        thisfn = basename + '.txt'
        f = open(thisfn, 'w')
        for i in range(len(energies)):
            print('%.6f' %(energies[i]), file=f)
        f.close()



