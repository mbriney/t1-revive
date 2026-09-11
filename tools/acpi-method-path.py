#!/usr/bin/env python3
"""acpi-method-path.py - find the full namespace path of ACPI methods in raw AML tables.

    acpi-method-path.py [--method NAME] [--list] [--objects] [--verbose] TABLE...

Reads DSDT/SSDT binaries (the files under /sys/firmware/acpi/tables, or a dump of them)
and prints, one per line, the full path of every Method whose 4-character name matches
NAME (default: FRST), e.g.

    \\_SB.PCI0.XHC1.RHUB.ASOC.FRST

It is a namespace walker, not a full AML interpreter: it parses the namespace-defining
opcodes (Scope, Device, Processor, PowerResource, ThermalZone, Method, Name, Alias,
OperationRegion, Field, Mutex, Event, External, If/Else at scope level), skips method
bodies and data objects by their encoded length, and resynchronises byte by byte on
anything it does not know. Pass all tables of a machine in one run, DSDT first, so that
`Scope()` references into objects defined by another table resolve.

It never executes, calls or writes anything. Standard library only.

Exit codes: 0 at least one match printed (or --list/--objects), 1 no match, 2 usage / unreadable table.
"""

import sys

# One-byte opcodes
ZERO_OP, ONE_OP, ALIAS_OP, NAME_OP = 0x00, 0x01, 0x06, 0x08
BYTE_PREFIX, WORD_PREFIX, DWORD_PREFIX, STRING_PREFIX, QWORD_PREFIX = 0x0A, 0x0B, 0x0C, 0x0D, 0x0E
SCOPE_OP, BUFFER_OP, PACKAGE_OP, VAR_PACKAGE_OP, METHOD_OP, EXTERNAL_OP = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
DUAL_NAME_PREFIX, MULTI_NAME_PREFIX = 0x2E, 0x2F
ROOT_CHAR, PARENT_PREFIX_CHAR = 0x5C, 0x5E
EXT_OP_PREFIX = 0x5B
IF_OP, ELSE_OP, WHILE_OP, ONES_OP = 0xA0, 0xA1, 0xA2, 0xFF
# Extended (0x5B xx) opcodes
EXT_MUTEX, EXT_EVENT, EXT_OPREGION, EXT_FIELD, EXT_DEVICE = 0x01, 0x02, 0x80, 0x81, 0x82
EXT_PROCESSOR, EXT_POWERRES, EXT_THERMALZONE, EXT_INDEXFIELD, EXT_BANKFIELD, EXT_DATAREGION = 0x83, 0x84, 0x85, 0x86, 0x87, 0x88

HEADER_LEN = 36
LEAD_CHARS = set(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
NAME_CHARS = LEAD_CHARS | set(b"0123456789")


class Walker:
    def __init__(self, verbose=False):
        self.verbose = verbose
        self.defined = set()      # tuple of segs for every named object seen so far (all tables)
        self.methods = []         # (path_tuple, table_name)
        self.objects = []         # (kind, path_tuple, table_name)
        self.table = ""
        self.data = b""

    # ----- primitives -------------------------------------------------------------
    def pkglength(self, pos):
        """Return (length, bytes_consumed) or None. length counts from pos (includes itself)."""
        d = self.data
        if pos >= len(d):
            return None
        b0 = d[pos]
        extra = b0 >> 6
        if extra == 0:
            return b0 & 0x3F, 1
        if pos + extra >= len(d) or (b0 & 0x30):
            return None
        length = b0 & 0x0F
        for i in range(extra):
            length |= d[pos + 1 + i] << (4 + 8 * i)
        return length, 1 + extra

    def nameseg(self, pos):
        d = self.data
        if pos + 4 > len(d):
            return None
        seg = d[pos:pos + 4]
        if seg[0] not in LEAD_CHARS or any(c not in NAME_CHARS for c in seg[1:]):
            return None
        return seg.decode("ascii")

    def namestring(self, pos):
        """Return (root, parents, segs, new_pos) or None."""
        d = self.data
        n = len(d)
        root = False
        parents = 0
        if pos < n and d[pos] == ROOT_CHAR:
            root = True
            pos += 1
        else:
            while pos < n and d[pos] == PARENT_PREFIX_CHAR:
                parents += 1
                pos += 1
        if pos >= n:
            return None
        c = d[pos]
        if c == 0x00:
            return root, parents, [], pos + 1
        if c == DUAL_NAME_PREFIX:
            count, pos = 2, pos + 1
        elif c == MULTI_NAME_PREFIX:
            if pos + 1 >= n:
                return None
            count, pos = d[pos + 1], pos + 2
            if count == 0:
                return None
        else:
            count = 1
        segs = []
        for _ in range(count):
            seg = self.nameseg(pos)
            if seg is None:
                return None
            segs.append(seg)
            pos += 4
        return root, parents, segs, pos

    def resolve(self, scope, name, search):
        root, parents, segs = name
        if root:
            return tuple(segs)
        base = list(scope[:max(0, len(scope) - parents)])
        if search and len(segs) == 1 and parents == 0:
            for i in range(len(base), -1, -1):
                cand = tuple(base[:i] + segs)
                if cand in self.defined:
                    return cand
        return tuple(base + segs)

    def skip_data(self, pos, end):
        """Skip a DataRefObject / simple TermArg starting at pos. Return new pos or None."""
        d = self.data
        if pos >= end:
            return None
        op = d[pos]
        if op in (ZERO_OP, ONE_OP, ONES_OP):
            return pos + 1
        if op == BYTE_PREFIX:
            return pos + 2
        if op == WORD_PREFIX:
            return pos + 3
        if op == DWORD_PREFIX:
            return pos + 5
        if op == QWORD_PREFIX:
            return pos + 9
        if op == STRING_PREFIX:
            e = d.find(b"\x00", pos + 1, end)
            return None if e < 0 else e + 1
        if op in (BUFFER_OP, PACKAGE_OP, VAR_PACKAGE_OP):
            pl = self.pkglength(pos + 1)
            if pl is None:
                return None
            e = pos + 1 + pl[0]
            return e if e <= end else None
        ns = self.namestring(pos)
        if ns is not None and ns[2]:
            return ns[3]
        return None

    # ----- the walk ---------------------------------------------------------------
    def define(self, kind, path):
        self.defined.add(path)
        self.objects.append((kind, path, self.table))

    def scoped_block(self, pos, end, scope, kind, header_extra, search):
        """Parse '<op> PkgLength NameString <header_extra bytes> TermList'. Return end or None."""
        pl = self.pkglength(pos)
        if pl is None:
            return None
        body_end = pos + pl[0]
        if body_end > end or pl[0] < pl[1] + 1:
            return None
        ns = self.namestring(pos + pl[1])
        if ns is None or not ns[2]:
            return None
        start = ns[3] + header_extra
        if start > body_end:
            return None
        path = self.resolve(scope, ns[:3], search)
        self.define(kind, path)
        self.termlist(start, body_end, path)
        return body_end

    def termlist(self, pos, end, scope):
        d = self.data
        while pos < end:
            op = d[pos]
            nxt = None
            if op == SCOPE_OP:
                nxt = self.scoped_block(pos + 1, end, scope, "Scope", 0, True)
            elif op == METHOD_OP:
                pl = self.pkglength(pos + 1)
                if pl is not None and pos + 1 + pl[0] <= end:
                    ns = self.namestring(pos + 1 + pl[1])
                    if ns is not None and ns[2] and ns[3] + 1 <= pos + 1 + pl[0]:
                        path = self.resolve(scope, ns[:3], False)
                        self.define("Method", path)
                        self.methods.append((path, self.table))
                        nxt = pos + 1 + pl[0]          # method bodies are not walked
            elif op == EXT_OP_PREFIX and pos + 1 < end:
                ext = d[pos + 1]
                if ext == EXT_DEVICE:
                    nxt = self.scoped_block(pos + 2, end, scope, "Device", 0, False)
                elif ext == EXT_THERMALZONE:
                    nxt = self.scoped_block(pos + 2, end, scope, "ThermalZone", 0, False)
                elif ext == EXT_PROCESSOR:
                    nxt = self.scoped_block(pos + 2, end, scope, "Processor", 6, False)
                elif ext == EXT_POWERRES:
                    nxt = self.scoped_block(pos + 2, end, scope, "PowerResource", 3, False)
                elif ext in (EXT_FIELD, EXT_INDEXFIELD, EXT_BANKFIELD):
                    pl = self.pkglength(pos + 2)
                    if pl is not None and pos + 2 + pl[0] <= end:
                        nxt = pos + 2 + pl[0]
                elif ext in (EXT_MUTEX, EXT_EVENT):
                    ns = self.namestring(pos + 2)
                    if ns is not None and ns[2]:
                        self.define("Mutex" if ext == EXT_MUTEX else "Event", self.resolve(scope, ns[:3], False))
                        nxt = ns[3] + (1 if ext == EXT_MUTEX else 0)
                elif ext == EXT_OPREGION:
                    ns = self.namestring(pos + 2)
                    if ns is not None and ns[2]:
                        self.define("OperationRegion", self.resolve(scope, ns[:3], False))
                        p = ns[3] + 1
                        p = self.skip_data(p, end)
                        if p is not None:
                            p = self.skip_data(p, end)
                        nxt = p if p is not None else ns[3] + 1
                elif ext == EXT_DATAREGION:
                    ns = self.namestring(pos + 2)
                    if ns is not None and ns[2]:
                        self.define("DataTableRegion", self.resolve(scope, ns[:3], False))
                        nxt = ns[3]
            elif op == NAME_OP:
                ns = self.namestring(pos + 1)
                if ns is not None and ns[2]:
                    self.define("Name", self.resolve(scope, ns[:3], False))
                    p = self.skip_data(ns[3], end)
                    nxt = p if p is not None else ns[3]
            elif op == ALIAS_OP:
                a = self.namestring(pos + 1)
                if a is not None and a[2]:
                    b = self.namestring(a[3])
                    if b is not None and b[2]:
                        self.define("Alias", self.resolve(scope, b[:3], False))
                        nxt = b[3]
            elif op == EXTERNAL_OP:
                ns = self.namestring(pos + 1)
                if ns is not None and ns[2]:
                    nxt = ns[3] + 2
            elif op in (IF_OP, ELSE_OP):
                # If/Else at scope level may wrap object definitions: walk their body in the same scope.
                pl = self.pkglength(pos + 1)
                if pl is not None and pos + 1 + pl[0] <= end:
                    body_end = pos + 1 + pl[0]
                    start = pos + 1 + pl[1]
                    if op == IF_OP:
                        p = self.skip_data(start, body_end)
                        start = p if p is not None else start
                    self.termlist(start, body_end, scope)
                    nxt = body_end
            elif op == WHILE_OP:
                pl = self.pkglength(pos + 1)
                if pl is not None and pos + 1 + pl[0] <= end:
                    nxt = pos + 1 + pl[0]
            if nxt is None or nxt <= pos:
                pos += 1                     # unknown or malformed: resynchronise
            else:
                pos = nxt

    def walk_table(self, name, data):
        self.table = name
        self.data = data
        if len(data) < HEADER_LEN:
            raise ValueError("%s: shorter than an ACPI table header" % name)
        sig = data[0:4]
        if sig not in (b"DSDT", b"SSDT"):
            raise ValueError("%s: not a DSDT/SSDT (signature %r)" % (name, sig))
        length = int.from_bytes(data[4:8], "little")
        end = min(length, len(data))
        if self.verbose:
            sys.stderr.write("%s: %d bytes, revision %d\n" % (name, length, data[8]))
        self.termlist(HEADER_LEN, end, ())


def fmt(path):
    return "\\" + ".".join((s.rstrip("_") or "_") for s in path)


def main(argv):
    method = "FRST"
    list_methods = list_objects = verbose = False
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--method":
            i += 1
            if i >= len(argv):
                sys.stderr.write("--method needs a name\n")
                return 2
            method = argv[i]
        elif a == "--list":
            list_methods = True
        elif a == "--objects":
            list_objects = True
        elif a == "--verbose":
            verbose = True
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        elif a.startswith("-"):
            sys.stderr.write("unknown option %s\n" % a)
            return 2
        else:
            files.append(a)
        i += 1
    if not files:
        sys.stderr.write("usage: acpi-method-path.py [--method NAME] [--list] [--objects] [--verbose] TABLE...\n")
        return 2
    if len(method) > 4 or not method:
        sys.stderr.write("method names are 1-4 characters\n")
        return 2
    method = method.ljust(4, "_")
    w = Walker(verbose=verbose)
    for f in files:
        try:
            with open(f, "rb") as fh:
                data = fh.read()
            w.walk_table(f.rsplit("/", 1)[-1], data)
        except (OSError, ValueError) as e:
            sys.stderr.write("%s\n" % e)
            return 2
    if list_objects:
        for kind, path, table in w.objects:
            sys.stdout.write("%s %s %s\n" % (kind, fmt(path), table))
        return 0
    if list_methods:
        for path, table in w.methods:
            sys.stdout.write("%s %s\n" % (fmt(path), table))
        return 0
    seen = set()
    for path, _table in w.methods:
        if path and path[-1] == method and path not in seen:
            seen.add(path)
            sys.stdout.write("%s\n" % fmt(path))
    return 0 if seen else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
