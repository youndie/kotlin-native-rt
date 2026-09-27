#!/usr/bin/env python3
"""Replace the classes one Kotlin source file compiled to inside a jar.

    python3 scripts/swap_classes.py <jar> <classes-dir> <SourceFile name> <package/path/>

Which entries belong to the file is read from the jar itself - every class under the package whose
SourceFile attribute names that file - and the recompiled directory must produce exactly that set of
class names; anything else means the recompilation is not the file JetBrains compiled (a different
lambda strategy, a missing class) and the jar is left untouched. The jar is rewritten in place,
entries in their original order, new classes at the end.
"""
import os, struct, sys, zipfile


def source_file(data):
    """The SourceFile attribute of a class file, read from its constant pool and attributes."""
    cp_count = struct.unpack(">H", data[8:10])[0]
    pool, i, n = {}, 10, 1
    while n < cp_count:
        tag = data[i]
        if tag == 1:
            ln = struct.unpack(">H", data[i + 1:i + 3])[0]; pool[n] = data[i + 3:i + 3 + ln].decode("utf-8", "replace"); i += 3 + ln
        elif tag in (7, 8, 16, 19, 20): i += 3
        elif tag == 15: i += 4
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18): i += 5
        elif tag in (5, 6): i += 9; n += 1
        else: raise ValueError(f"constant pool tag {tag}")
        n += 1
    i += 6
    ifc = struct.unpack(">H", data[i:i + 2])[0]; i += 2 + 2 * ifc
    for _ in range(2):  # fields, then methods
        cnt = struct.unpack(">H", data[i:i + 2])[0]; i += 2
        for _ in range(cnt):
            i += 6
            ac = struct.unpack(">H", data[i:i + 2])[0]; i += 2
            for _ in range(ac):
                i += 2; i += 4 + struct.unpack(">I", data[i:i + 4])[0]
    ac = struct.unpack(">H", data[i:i + 2])[0]; i += 2
    for _ in range(ac):
        name = pool.get(struct.unpack(">H", data[i:i + 2])[0]); ln = struct.unpack(">I", data[i + 2:i + 6])[0]
        if name == "SourceFile":
            return pool.get(struct.unpack(">H", data[i + 6:i + 8])[0])
        i += 6 + ln
    return None


jar, classes, source, package = sys.argv[1:]
new = {}
for root, _, files in os.walk(classes):
    for f in files:
        if f.endswith(".class"):
            p = os.path.join(root, f)
            new[os.path.relpath(p, classes).replace(os.sep, "/")] = open(p, "rb").read()
with zipfile.ZipFile(jar) as zi:
    entries = zi.infolist()
    old = {e.filename for e in entries if e.filename.startswith(package) and e.filename.endswith(".class")
           and "/" not in e.filename[len(package):] and source_file(zi.read(e.filename)) == source}
    if set(new) != old:
        sys.exit(f"class sets differ for {source}: only recompiled {sorted(set(new) - old)}, only in the jar {sorted(old - set(new))}")
    tmp = jar + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zo:
        for e in entries:
            if e.filename not in old:
                zo.writestr(e, zi.read(e.filename))
        for name in sorted(new):
            zo.writestr(zipfile.ZipInfo(name, (1980, 2, 1, 0, 0, 0)), new[name])
os.replace(tmp, jar)
print(f"{os.path.basename(jar)}: replaced the {len(old)} classes of {source}")
