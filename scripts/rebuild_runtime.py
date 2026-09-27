#!/usr/bin/env python3
"""Rebuild every runtime bitcode module of a Kotlin/Native distribution from source and compare
each with what the distribution ships.

The recipe reproduces the shipped linux_x64 modules of 2.4.20 byte for byte: compile every
translation unit of a module from `runtime/src` with relative paths (.cpp AND .mm, no *Test /
*TestSupport), one bitcode per unit, then one llvm-link in source order, with the dev LLVM bundle the
runtime was built with (not the essentials bundle the compiler uses for user code).

    KOTLIN_SRC=~/kotlin-src KONAN_DIST=~/.konan/kotlin-native-prebuilt-linux-x86_64-2.4.20 \
    OUT=/tmp/sweep python3 scripts/rebuild_runtime.py

Prints one line per module (OK = identical to the shipped one, DIFF = differs) and a summary line
"identical N, different M, not built K" that scripts/build-dist.sh reads.
"""
import os, re, subprocess, sys, hashlib, pathlib

HOME = os.path.expanduser("~")
DIST = os.environ.get("KONAN_DIST", f"{HOME}/.konan/kotlin-native-prebuilt-linux-x86_64-2.4.20")
SHIPPED = f"{DIST}/konan/targets/linux_x64/native"
DEPS = os.environ.get("KONAN_DEPS", f"{HOME}/.konan/dependencies")
DEV = f"{DEPS}/llvm-21-x86_64-linux-dev-116/bin"
G = f"{DEPS}/x86_64-unknown-linux-gnu-gcc-8.3.0-glibc-2.19-kernel-4.9-2"
TC = f"{G}/x86_64-unknown-linux-gnu"
KSRC = os.environ.get("KOTLIN_SRC", f"{HOME}/kotlin-src")
SRC = f"{KSRC}/kotlin-native/runtime/src"
BUILD = f"{KSRC}/kotlin-native/runtime/build.gradle.kts"
OUT = os.environ.get("OUT", "/tmp/sweep")

BASE = ["-emit-llvm", "-c", "-fPIC", "-std=c++17", "-O2", "-fno-aligned-allocation",
        "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror",
        "-DKONAN_X64=1", "-DKONAN_LINUX=1", "-DUSE_ELF_SYMBOLS=1", "-DELFSIZE=64",
        "-DUSE_GCC_UNWIND=1",
        "--target=x86_64-unknown-linux-gnu", f"--sysroot={TC}/sysroot", f"--gcc-toolchain={G}"]

def modules():
    """Every `module("x") { ... }` block, with its srcRoot override and headersDirs."""
    text = pathlib.Path(BUILD).read_text()
    found = {}
    for m in re.finditer(r'module\("([^"]+)"\)\s*\{', text):
        name = m.group(1)
        # the block: balance braces from the opening one
        i, depth = m.end() - 1, 0
        while i < len(text):
            if text[i] == "{": depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0: break
            i += 1
        block = text[m.end():i]
        root = re.search(r'srcRoot\.set\(layout\.projectDirectory\.dir\("([^"]+)"\)\)', block)
        heads = re.findall(r'"((?:src|\.\./)[^"]*)"', block)
        found[name] = (root.group(1) if root else f"src/{name}", heads)
    return found

def sources(root):
    d = pathlib.Path(SRC).parent / root / "cpp"
    if not d.is_dir(): return []
    # RECURSIVE: the plugin globs "**/*.cpp", and `main` keeps dlmalloc, dtoa, math and snprintf
    # in subdirectories. A flat listing builds a module that links and is simply missing symbols.
    return sorted(str(p.relative_to(SRC)) for p in d.rglob("*")
                  if p.suffix in (".cpp", ".mm")
                  and not p.name.endswith(("Test.cpp", "Test.mm", "TestSupport.cpp", "TestSupport.mm")))

def build(name, root, heads):
    srcs = sources(root)
    if not srcs: return ("no sources under %s/cpp" % root, None)
    root_rel = root[4:] if root.startswith("src/") else root   # every path here is relative to src/
    inc = ["-I", f"{root_rel}/cpp"]   # the plugin adds the module's own source dir, CompileToBitcodePlugin.kt:246
    for h in heads:
        rel = h[4:] if h.startswith("src/") else h
        if (pathlib.Path(SRC) / rel).is_dir(): inc += ["-I", rel]
    parts = []
    for n, f in enumerate(srcs, 1):
        o = f"{OUT}/{name}-{n}.bc"
        r = subprocess.run([f"{DEV}/clang++"] + BASE + inc + [f, "-o", o],
                           cwd=SRC, capture_output=True, text=True)
        if r.returncode != 0:
            first = (r.stderr.strip().splitlines() or ["?"])[0]
            return (f"compile failed on {f}: {first[:110]}", None)
        parts.append(o)
    out = f"{OUT}/{name}.bc"
    r = subprocess.run([f"{DEV}/llvm-link"] + parts + ["-o", out], capture_output=True, text=True)
    if r.returncode != 0:
        return (f"link failed: {(r.stderr.strip().splitlines() or ['?'])[0][:110]}", None)
    return (None, out)

def md5(p): return hashlib.md5(pathlib.Path(p).read_bytes()).hexdigest()

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    mods = modules()
    shipped = sorted(p.stem for p in pathlib.Path(SHIPPED).glob("*.bc"))
    print(f"{len(shipped)} modules ship for linux_x64; the build file declares {len(mods)}\n")
    same, diff, skip = [], [], []
    for s in shipped:
        name = "main" if s == "runtime" else s
        if name not in mods:
            skip.append((s, "not declared in build.gradle.kts under this name")); continue
        root, heads = mods[name]
        err, out = build(name, root, heads)
        if err:
            skip.append((s, err)); continue
        a, b = md5(out), md5(f"{SHIPPED}/{s}.bc")
        (same if a == b else diff).append((s, a, b, os.path.getsize(out), os.path.getsize(f"{SHIPPED}/{s}.bc")))
        print(("OK   " if a == b else "DIFF ") + f"{s:28} {a[:12]} vs {b[:12]}")
    print(f"\nidentical {len(same)}, different {len(diff)}, not built {len(skip)}")
    for s, why in skip: print(f"  skip {s:28} {why}")
