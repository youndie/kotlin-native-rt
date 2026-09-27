#!/usr/bin/env python3
"""Build and run one of the runtime's googletest groups (default: custom_alloc_test) against whatever
runtime sources are checked out, outside JetBrains' Gradle build.

    KOTLIN_SRC=~/kotlin-src KONAN_DIST=~/.konan/kotlin-native-prebuilt-linux-x86_64-2.4.20 \\
    OUT=/tmp/alloc-tests python3 scripts/alloc_tests.py [custom_alloc_test]

It follows the build's own recipe (kotlin-native/build-tools .../cpp/CompileToExecutable.kt): every
translation unit of the tested module's main, test and testFixtures source sets and of the support
modules' main and testFixtures source sets, plus googletest and googlemock, compiled to bitcode;
llvm-link once over all of them, once more with the launcher (test_support) and -internalize; then
clang++ to an object and a link. Compilation uses rebuild_runtime.py's flags, which reproduce the
shipped runtime modules byte for byte.

Prints the gtest summary and exits with the test binary's status.
"""
import os, re, sys, subprocess, pathlib, urllib.request, zipfile

sys.path.insert(0, os.path.dirname(__file__))
import rebuild_runtime as rr  # noqa: E402  (module-level: paths and the module table)

GROUP = sys.argv[1] if len(sys.argv) > 1 else "custom_alloc_test"
OUT = pathlib.Path(os.environ.get("OUT", "/tmp/alloc-tests")); OUT.mkdir(parents=True, exist_ok=True)
SRC = pathlib.Path(rr.SRC)
TEXT = pathlib.Path(rr.BUILD).read_text()


def group(name):
    """testedModules and testSupportModules of one testsGroup block."""
    m = re.search(r'testsGroup\("%s"\)\s*\{(.*?)\n\s*\}' % re.escape(name), TEXT, re.S)
    if not m:
        sys.exit(f"no testsGroup {name} in {rr.BUILD}")
    lists = lambda key: re.findall(r'"([^"]+)"', (re.search(key + r'\.addAll\(([^)]*)\)', m.group(1)) or [None, ""])[1])
    return lists("testedModules"), lists("testSupportModules")


# googletest at the revision the runtime's build pins, fetched once.
GT_REV = re.search(r'google:googletest:([0-9a-f]{40})@zip', TEXT).group(1)
GT = OUT / f"googletest-{GT_REV}"
if not GT.exists():
    z = OUT / "googletest.zip"
    urllib.request.urlretrieve(f"https://github.com/google/googletest/archive/{GT_REV}.zip", z)
    zipfile.ZipFile(z).extractall(OUT)
GT_INC = ["-I", str(GT / "googletest/include"), "-I", str(GT / "googlemock/include")]


def compile_unit(src, includes, out, cwd):
    r = subprocess.run([f"{rr.DEV}/clang++"] + rr.BASE + includes + [src, "-o", out], cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"compile failed: {src}\n{r.stderr[-3000:]}")
    return out


def module_units(name, sets, all_fixtures=False):
    """Bitcode for the given source sets (main / test / testFixtures) of one runtime module.
    all_fixtures: the module's every file is a testFixtures file, as test_support declares."""
    root, heads = rr.modules()[name]
    d = SRC.parent / root / "cpp"
    rel = root[4:] if root.startswith("src/") else root
    inc = ["-I", f"{rel}/cpp"]
    for h in heads:
        hr = h[4:] if h.startswith("src/") else h
        if (SRC / hr).is_dir():
            inc += ["-I", hr]
    files = sorted(p for p in d.rglob("*") if p.suffix in (".cpp", ".mm"))
    kind = lambda p: "testFixtures" if all_fixtures or p.stem.endswith("TestSupport") else "test" if p.stem.endswith("Test") else "main"
    out = []
    for n, p in enumerate(f for f in files if kind(f) in sets):
        extra = GT_INC if kind(p) != "main" else []
        out.append(compile_unit(str(p.relative_to(SRC)), inc + extra, str(OUT / f"{name}-{kind(p)}-{n}.bc"), SRC))
    return out


tested, support = group(GROUP)
print(f"{GROUP}: tested {tested}; support {support}; googletest {GT_REV[:10]}")
units = []
for m in tested:
    units += module_units(m, {"main", "test", "testFixtures"})
for m in support:
    units += module_units(m, {"main", "testFixtures"})
units.append(compile_unit(str(GT / "googletest/src/gtest-all.cc"), ["-I", str(GT / "googletest")] + GT_INC, str(OUT / "gtest.bc"), SRC))
units.append(compile_unit(str(GT / "googlemock/src/gmock-all.cc"), ["-I", str(GT / "googlemock")] + GT_INC, str(OUT / "gmock.bc"), SRC))
launcher = module_units("test_support", {"testFixtures"}, all_fixtures=True)

run = lambda *a: subprocess.run(list(a), check=True)
run(f"{rr.DEV}/llvm-link", "-o", str(OUT / "first.bc"), *units)
if len(launcher) > 1:
    run(f"{rr.DEV}/llvm-link", "-o", str(OUT / "launcher.bc"), *launcher)
    main_bc = str(OUT / "launcher.bc")
else:
    main_bc = launcher[0]
run(f"{rr.DEV}/llvm-link", "-o", str(OUT / "final.bc"), main_bc, str(OUT / "first.bc"), "-internalize")
target = ["--target=x86_64-unknown-linux-gnu", f"--sysroot={rr.TC}/sysroot", f"--gcc-toolchain={rr.G}"]
run(f"{rr.DEV}/clang++", "-c", "-O2", "-fPIC", *target, str(OUT / "final.bc"), "-o", str(OUT / "final.o"))
run(f"{rr.DEV}/clang++", *target, "-fuse-ld=lld", str(OUT / "final.o"), "-o", str(OUT / GROUP),
    "-static-libstdc++", "-static-libgcc", "-lpthread", "-ldl", "-lm")
r = subprocess.run([str(OUT / GROUP)], capture_output=True, text=True)
tail = [l for l in r.stdout.splitlines() if l.startswith(("[  PASSED  ]", "[  FAILED  ]", "[==========]", "[  SKIPPED ]"))]
print("\n".join(tail[-8:]) or r.stdout[-2000:] + r.stderr[-2000:])
sys.exit(r.returncode)
