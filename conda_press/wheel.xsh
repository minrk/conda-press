"""Tools for representing wheels in-memory"""
import os
import base64
from hashlib import sha256
from zipfile import ZipFile, ZipInfo
from collections.abc import Sequence, MutableSequence

from tqdm import tqdm

from conda_press import __version__ as VERSION


def urlsafe_b64encode_nopad(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def urlsafe_b64decode_nopad(data):
    pad = b'=' * (4 - (len(data) & 3))
    return base64.urlsafe_b64decode(data + pad)


def record_hash(data):
    dig = sha256(data).digest()
    b64 = urlsafe_b64encode_nopad(dig)
    return 'sha256=' + b64.decode('utf8')


def _normalize_path_mappings(value, basedir, arcbase='.'):
    # try to operate in place if we can.
    if isinstance(value, Sequence) and not isinstance(value, MutableSequence):
        value = list(value)
    elif isinstance(value, MutableSequence):
        pass
    else:
        raise TypeError(f'cannot convert pathlist, wrong type for {value!r}')
    # make sure base dir is a path
    if basedir is None:
        raise TypeError('basedir must be a str, cannot be None')
    # make alterations and return
    for i in range(len(value)):
        elem = value[i]
        if isinstance(elem, str):
            fsname = arcname = elem
        elif isinstance(elem, Sequence) and len(elem) == 2:
            fsname, arcname = elem
        else:
            raise TypeError(f'{elem!r} (value[{i}]) has the wrong type')
        # normalize fsname
        if os.path.isabs(fsname):
            fsname = os.path.relpath(fname, basedir)
        # normalize arcpath
        if arcbase == '.':
            arcname = fsname
        else:
            arcname = os.path.join(arcbase, os.path.basename(arcname))
        # repack
        value[i] = (fsname, arcname)
    return value


class Wheel:
    """A wheel representation that knows how to write itself out."""

    def __init__(self, distribution, version, build_tag=None, python_tag='py3',
                 abi_tag='none', platform_tag='any'):
        """
        Parameters
        ----------
        distribution : str
            The 'distribution name', or the package name, e.g. "numpy"
        version : str
            The version string for the package
        build_tag : str or int, optional
            The build number, must start with a digit, See PEP #427
        python_tag : str, optional
            The Python version tag, see PEP #425
        abi_tag : str, optional
            The Python ABI tag, see PEP #425
        platform_tag : str, optional
            The platform tag, see PEP #425

        Attributes
        ----------
        noarch_python : bool
            Whether the package is a 'noarch: python' conda package.
        basedir : str or None,
            Location on filesystem where real files exist.
        scripts : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the scripts/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        includes : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the includes/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        files : sequence of (filesystem-str, archive-str) tuples or None
            This maps filesystem paths to the path/to/filename.ext in the archive.
            If an entry is a filesystem path, it will be converted to the correct
            tuple. The filesystem path will be relative to the basedir.
        """
        self.distribution = distribution
        self.version = version
        self.build_tag = build_tag
        self.python_tag = python_tag
        self.abi_tag = abi_tag
        self.platform_tag = platform_tag
        self.noarch_python = False
        self.basedir = None
        self._records = [(f"{distribution}-{version}.dist-info/RECORD", "", "")]
        self._scripts = []
        self._includes = []
        self._files = []

    def __repr__(self):
        return f'{self.__class__.__name__}({self.filename})'

    @property
    def filename(self):
        parts = [self.distribution, self.version]
        if self.build_tag is not None:
            parts.append(self.build_tag)
        parts.extend([self.python_tag, self.abi_tag, self.platform_tag])
        return '-'.join(parts) + '.whl'

    @property
    def compatibility_tag(self):
        return "-".join([self.python_tag, self.abi_tag, self.platform_tag])

    @property
    def scripts(self):
        return self._scripts

    @scripts.setter
    def scripts(self, value):
        self._scripts = _normalize_path_mappings(value, self.basedir, 'scripts')

    @scripts.deleter
    def scripts(self):
        self._scripts = None

    @property
    def includes(self):
        return self._includes

    @includes.setter
    def includes(self, value):
        self._includes = _normalize_path_mappings(value, self.basedir, 'includes')

    @includes.deleter
    def includes(self):
        self._includes = None

    @property
    def files(self):
        return self._files

    @files.setter
    def files(self, value):
        self._files = _normalize_path_mappings(value, self.basedir)

    @files.deleter
    def files(self):
        self._files = None

    def write(self):
        with ZipFile(self.filename, 'w') as zf:
            self.zf = zf
            self.write_from_filesystem('scripts')
            self.write_from_filesystem('includes')
            self.write_from_filesystem('files')
            self.write_metadata()
            self.write_wheel_metadata()
            self.write_record() # This *has* to be the last write
            del self.zf

    def _writestr_and_record(self, arcname, data, zinfo=None):
        if isinstance(data, str):
            data = data.encode('utf-8')
        if zinfo is None:
            self.zf.writestr(arcname, data)
        else:
            self.zf.writestr(zinfo, data)
        record = (arcname, record_hash(data), len(data))
        self._records.append(record)

    def write_metadata(self):
        print('Writing metadata')
        lines = ["Metadata-Version: 2.1", "Name: " + self.distribution,
                 "Version: " + self.version]
        content = "\n".join(lines) + "\n"
        arcname = f"{self.distribution}-{self.version}.dist-info/METADATA"
        self._writestr_and_record(arcname, content)

    def write_wheel_metadata(self):
        print('Writing wheel metadata')
        lines = ["Wheel-Version: 1.0", "Generator: conda-press " + VERSION]
        lines.append("Root-Is-Purelib: " + str(self.noarch_python).lower())
        lines.append("Tag: " + self.compatibility_tag)
        if self.build_tag is not None:
            lines.append("Build: " + self.build_tag)
        content = "\n".join(lines) + "\n"
        arcname = f"{self.distribution}-{self.version}.dist-info/WHEEL"
        self._writestr_and_record(arcname, content)

    def write_from_filesystem(self, name):
        print(f'Writing {name}')
        files = getattr(self, name)
        if not files:
            print('Nothing to write!')
            return
        for fsname, arcname in tqdm(files):
            absname = os.path.join(self.basedir, fsname)
            if not os.path.isfile(absname):
                continue
            elif os.path.islink(absname):
                # symbolic link, see https://gist.github.com/kgn/610907
                data = os.readlink(absname).encode('utf-8')
                zinfo = ZipInfo.from_file(absname, arcname=arcname)
                zinfo.external_attr = 0xA1ED0000
            else:
                with open(absname, 'br') as f:
                    data = f.read()
                zinfo = ZipInfo.from_file(absname, arcname=arcname)
            self._writestr_and_record(arcname, data, zinfo=zinfo)

    def write_record(self):
        print('Writing record')
        lines = [f"{f},{h},{s}" for f, h, s in reversed(self._records)]
        content = "\n".join(lines)
        arcname = f"{self.distribution}-{self.version}.dist-info/RECORD"
        self.zf.writestr(arcname, content)
