#!/usr/bin/env python3
"""pbzx.py - decompress an Apple pbzx stream and, optionally, unpack the cpio inside.

Dependency-free (standard library + lzma). The Payload member of an Apple .pkg
is a pbzx container: a sequence of chunks, each either an xz stream or stored
raw, that concatenate to a cpio archive (odc or newc format). This tool
reproduces `pbzx FILE | cpio -idm --no-absolute-filenames`:

    pbzx.py -C DIR Payload          # unpack the cpio archive into DIR
    pbzx.py -C DIR -                # same, reading the pbzx stream from stdin
    pbzx.py -o payload.cpio Payload # only decompress; write the raw cpio
    pbzx.py --list Payload          # list the cpio entries

Leading '/' and './' are stripped from entry names; names containing '..'
are refused. Regular files, directories and symlinks are restored with their
mode bits (setuid/setgid dropped) and modification time.
"""
import argparse
import lzma
import os
import stat
import struct
import sys
from pathlib import Path, PurePosixPath

MAGIC = b"pbzx"
XZ_MAGIC = b"\xfd7zXZ\x00"
FLAG_MORE = 1 << 24


class PbzxError(Exception):
    pass


def _readexact(fh, n):
    buf = b""
    while len(buf) < n:
        part = fh.read(n - len(buf))
        if not part:
            raise PbzxError("unexpected end of pbzx stream")
        buf += part
    return buf


def pbzx_chunks(fh):
    """Yield the decompressed chunks of a pbzx stream in order."""
    if _readexact(fh, 4) != MAGIC:
        raise PbzxError("not a pbzx stream (bad magic)")
    (flags,) = struct.unpack(">Q", _readexact(fh, 8))
    while flags & FLAG_MORE:
        flags, size = struct.unpack(">QQ", _readexact(fh, 16))
        chunk = _readexact(fh, size)
        if chunk[:6] == XZ_MAGIC:
            yield lzma.decompress(chunk)
        else:
            yield chunk


class PbzxReader:
    """File-like sequential reader over the decompressed pbzx payload."""

    def __init__(self, fh):
        self._chunks = pbzx_chunks(fh)
        self._buf = b""
        self._pos = 0
        self._eof = False

    def read(self, n):
        out = []
        need = n
        while need > 0:
            avail = len(self._buf) - self._pos
            if avail == 0:
                if self._eof:
                    break
                try:
                    self._buf = next(self._chunks)
                except StopIteration:
                    self._eof = True
                    break
                self._pos = 0
                continue
            take = min(avail, need)
            out.append(self._buf[self._pos:self._pos + take])
            self._pos += take
            need -= take
        return b"".join(out)

    def skip(self, n):
        while n > 0:
            got = self.read(min(n, 1 << 20))
            if not got:
                raise PbzxError("unexpected end of cpio data")
            n -= len(got)


def _rel(name):
    parts = [p for p in PurePosixPath(name).parts if p not in ("", "/", ".")]
    if any(p == ".." for p in parts):
        raise PbzxError("refusing cpio entry with '..': %s" % name)
    return Path(*parts) if parts else None


def _read_header(r):
    """Return (name, mode, mtime, filesize, pad_after_data, dev, ino, nlink) or None at end."""
    magic = r.read(6)
    if not magic:
        return None
    if magic == b"070707":  # odc (POSIX.1 portable ASCII)
        h = _readexact(r, 70)
        dev = int(h[0:6], 8)
        ino = int(h[6:12], 8)
        mode = int(h[12:18], 8)
        nlink = int(h[30:36], 8)
        mtime = int(h[42:53], 8)
        namesize = int(h[53:59], 8)
        filesize = int(h[59:70], 8)
        name = _readexact(r, namesize)[:-1].decode("utf-8", "replace")
        return name, mode, mtime, filesize, 0, dev, ino, nlink
    if magic in (b"070701", b"070702"):  # newc / crc
        h = _readexact(r, 104)
        f = [int(h[i:i + 8], 16) for i in range(0, 104, 8)]
        ino, mode, _uid, _gid, nlink, mtime, filesize = f[0:7]
        dev = (f[7] << 32) | f[8]
        namesize = f[11]
        name = _readexact(r, namesize)[:-1].decode("utf-8", "replace")
        r.skip((4 - (110 + namesize) % 4) % 4)
        return name, mode, mtime, filesize, (4 - filesize % 4) % 4, dev, ino, nlink
    raise PbzxError("bad cpio magic %r (not odc/newc)" % magic)


def unpack_cpio(r, base, listing=False, out=sys.stderr):
    """Unpack the cpio archive readable from `r` into `base` (or just list it)."""
    count = 0
    pending_links = {}  # (dev, ino) -> [paths seen with size 0, newc hard links]
    first_data = {}     # (dev, ino) -> path that holds the data
    while True:
        hdr = _read_header(r)
        if hdr is None:
            break
        name, mode, mtime, size, pad, dev, ino, nlink = hdr
        if name == "TRAILER!!!":
            r.skip(size + pad)
            break
        count += 1
        kind = stat.S_IFMT(mode)
        if listing:
            print("%o %10d %s" % (mode, size, name), file=sys.stdout)
            r.skip(size + pad)
            continue
        rel = _rel(name)
        if rel is None:  # the "." entry
            r.skip(size + pad)
            continue
        target = base / rel
        if kind == stat.S_IFDIR:
            target.mkdir(parents=True, exist_ok=True)
            r.skip(size + pad)
        elif kind == stat.S_IFREG:
            target.parent.mkdir(parents=True, exist_ok=True)
            key = (dev, ino)
            if nlink > 1 and size == 0 and key not in first_data:
                pending_links.setdefault(key, []).append(target)
                r.skip(pad)
                continue
            with open(target, "wb") as dst:
                left = size
                while left > 0:
                    buf = r.read(min(left, 1 << 20))
                    if not buf:
                        raise PbzxError("unexpected end of data in %s" % name)
                    dst.write(buf)
                    left -= len(buf)
            r.skip(pad)
            if nlink > 1:
                first_data.setdefault(key, target)
                for other in pending_links.pop(key, []):
                    if other.exists() or other.is_symlink():
                        other.unlink()
                    os.link(target, other)
        elif kind == stat.S_IFLNK:
            target.parent.mkdir(parents=True, exist_ok=True)
            dest = _readexact(r, size).decode("utf-8", "replace")
            r.skip(pad)
            if target.is_symlink() or target.exists():
                target.unlink()
            os.symlink(dest, target)
            continue  # no chmod/utime on symlinks
        else:
            # device nodes, fifos, sockets: not part of a firmware package; skip the data
            r.skip(size + pad)
            print("skipped special entry %s" % name, file=out)
            continue
        try:
            os.chmod(target, stat.S_IMODE(mode) & 0o777)
            os.utime(target, (mtime, mtime))
        except OSError:
            pass
    # hard links whose data never arrived become empty files (matches GNU cpio)
    for paths in pending_links.values():
        for p in paths:
            p.parent.mkdir(parents=True, exist_ok=True)
            p.touch()
    return count


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n", 1)[1])
    ap.add_argument("input", help="pbzx stream ('-' = stdin)")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("-C", "--directory", metavar="DIR", help="unpack the cpio archive into DIR")
    g.add_argument("-o", "--output", metavar="FILE", help="write the decompressed cpio to FILE ('-' = stdout)")
    g.add_argument("-l", "--list", action="store_true", help="list the cpio entries")
    args = ap.parse_args(argv)

    fh = sys.stdin.buffer if args.input == "-" else open(args.input, "rb")
    try:
        if args.output:
            dst = sys.stdout.buffer if args.output == "-" else open(args.output, "wb")
            try:
                for chunk in pbzx_chunks(fh):
                    dst.write(chunk)
            finally:
                if dst is not sys.stdout.buffer:
                    dst.close()
                else:
                    dst.flush()
            return 0
        reader = PbzxReader(fh)
        if args.list:
            n = unpack_cpio(reader, None, listing=True)
            print("%d entries" % n, file=sys.stderr)
            return 0
        base = Path(args.directory)
        base.mkdir(parents=True, exist_ok=True)
        n = unpack_cpio(reader, base)
        print("unpacked %d entries into %s" % (n, base), file=sys.stderr)
        return 0
    finally:
        if fh is not sys.stdin.buffer:
            fh.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PbzxError as e:
        print("pbzx: %s" % e, file=sys.stderr)
        sys.exit(1)
    except BrokenPipeError:
        sys.exit(1)
