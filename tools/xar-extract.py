#!/usr/bin/env python3
"""xar-extract.py - list or extract members of a XAR archive (Apple .pkg files).

Dependency-free (standard library only). Used by lib/firmware.sh to pull the
`Payload` member out of Apple's EmbeddedOSFirmware.pkg; pipe it into pbzx.py.

    xar-extract.py --list ARCHIVE
    xar-extract.py --member Payload --output - ARCHIVE | pbzx.py -C DIR -
    xar-extract.py -C DIR ARCHIVE                  # extract every member

Every member's archived and extracted checksums recorded in the table of
contents are verified; a mismatch is an error (exit 1).
"""
import argparse
import bz2
import hashlib
import lzma
import struct
import sys
import zlib
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

MAGIC = b"xar!"
CHUNK = 1 << 20


class XarError(Exception):
    pass


def _hasher(style):
    style = (style or "").lower()
    if style in ("", "none"):
        return None
    try:
        return hashlib.new(style)
    except ValueError:
        raise XarError("unsupported checksum style %r" % style)


def _decoder(style):
    style = (style or "application/octet-stream").lower()
    if style == "application/octet-stream":
        return None
    if style in ("application/x-gzip", "application/gzip"):
        return zlib.decompressobj()
    if style == "application/x-bzip2":
        return bz2.BZ2Decompressor()
    if style in ("application/x-lzma", "application/x-xz"):
        return lzma.LZMADecompressor()
    raise XarError("unsupported member encoding %r" % style)


def read_toc(fh):
    """Return (toc_element, heap_offset) for the open archive."""
    head = fh.read(28)
    if len(head) < 28 or head[:4] != MAGIC:
        raise XarError("not a XAR archive (bad magic)")
    header_size, version, toc_clen, toc_ulen, _cksum_alg = struct.unpack(">HHQQI", head[4:28])
    if version != 1:
        raise XarError("unsupported XAR version %d" % version)
    fh.seek(header_size)
    toc_xml = zlib.decompress(fh.read(toc_clen))
    if len(toc_xml) != toc_ulen:
        raise XarError("table of contents length mismatch")
    root = ET.fromstring(toc_xml)
    toc = root.find("toc")
    if toc is None:
        raise XarError("table of contents has no <toc> element")
    return toc, header_size + toc_clen


def walk(node, prefix, out):
    """Flatten the TOC into a list of member dicts (files with data only)."""
    for f in node.findall("file"):
        name = f.findtext("name") or ""
        path = prefix + name
        ftype = f.findtext("type") or "file"
        data = f.find("data")
        if data is not None and ftype == "file":
            enc = data.find("encoding")
            ac = data.find("archived-checksum")
            ec = data.find("extracted-checksum")
            out.append({
                "path": path,
                "offset": int(data.findtext("offset")),
                "length": int(data.findtext("length")),
                "size": int(data.findtext("size")),
                "encoding": enc.get("style") if enc is not None else "application/octet-stream",
                "archived": (ac.get("style"), ac.text.strip()) if ac is not None and ac.text else None,
                "extracted": (ec.get("style"), ec.text.strip()) if ec is not None and ec.text else None,
            })
        walk(f, path + "/", out)


def extract_member(fh, heap, member, dst):
    """Copy one member to the writable binary stream `dst`, verifying checksums."""
    fh.seek(heap + member["offset"])
    remaining = member["length"]
    dec = _decoder(member["encoding"])
    h_arch = _hasher(member["archived"][0]) if member["archived"] else None
    h_ext = _hasher(member["extracted"][0]) if member["extracted"] else None
    written = 0
    while remaining > 0:
        buf = fh.read(min(CHUNK, remaining))
        if not buf:
            raise XarError("archive truncated inside member %s" % member["path"])
        remaining -= len(buf)
        if h_arch:
            h_arch.update(buf)
        out = dec.decompress(buf) if dec else buf
        if out:
            dst.write(out)
            written += len(out)
            if h_ext:
                h_ext.update(out)
    if dec is not None and hasattr(dec, "flush"):
        out = dec.flush()
        if out:
            dst.write(out)
            written += len(out)
            if h_ext:
                h_ext.update(out)
    if written != member["size"]:
        raise XarError("%s: extracted %d bytes, expected %d" % (member["path"], written, member["size"]))
    if h_arch and h_arch.hexdigest() != member["archived"][1].lower():
        raise XarError("%s: archived checksum mismatch" % member["path"])
    if h_ext and h_ext.hexdigest() != member["extracted"][1].lower():
        raise XarError("%s: extracted checksum mismatch" % member["path"])
    return written


def safe_relpath(path):
    p = PurePosixPath(path)
    parts = [x for x in p.parts if x not in ("", "/", ".")]
    if any(x == ".." for x in parts):
        raise XarError("refusing member path with '..': %s" % path)
    return Path(*parts) if parts else None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n", 1)[1])
    ap.add_argument("archive", help="XAR archive (.pkg)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("-l", "--list", action="store_true", help="list members and exit")
    g.add_argument("-C", "--directory", metavar="DIR", help="extract into DIR (all members, or --member)")
    g.add_argument("-o", "--output", metavar="FILE", help="write the single --member to FILE ('-' = stdout)")
    ap.add_argument("-m", "--member", metavar="NAME", help="member path inside the archive (e.g. Payload)")
    args = ap.parse_args(argv)

    with open(args.archive, "rb") as fh:
        toc, heap = read_toc(fh)
        members = []
        walk(toc, "", members)

        if args.list or not (args.directory or args.output):
            print("%12s %12s  %-28s %s" % ("size", "stored", "encoding", "path"))
            for m in members:
                print("%12d %12d  %-28s %s" % (m["size"], m["length"], m["encoding"], m["path"]))
            return 0

        if args.member:
            members = [m for m in members if m["path"] == args.member]
            if not members:
                raise XarError("member not found: %s" % args.member)

        if args.output:
            if len(members) != 1:
                raise XarError("--output needs exactly one member (use --member)")
            if args.output == "-":
                extract_member(fh, heap, members[0], sys.stdout.buffer)
                sys.stdout.buffer.flush()
            else:
                with open(args.output, "wb") as dst:
                    extract_member(fh, heap, members[0], dst)
            return 0

        base = Path(args.directory)
        base.mkdir(parents=True, exist_ok=True)
        for m in members:
            rel = safe_relpath(m["path"])
            if rel is None:
                continue
            target = base / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "wb") as dst:
                extract_member(fh, heap, m, dst)
            print("extracted %s (%d bytes)" % (m["path"], m["size"]), file=sys.stderr)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except XarError as e:
        print("xar-extract: %s" % e, file=sys.stderr)
        sys.exit(1)
    except BrokenPipeError:
        sys.exit(1)
