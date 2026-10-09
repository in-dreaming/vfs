# Toolchain and validation

## Reproducible local checks

Supported compiler: official **Zig 0.16.0** ([download](https://ziglang.org/download/0.16.0/)).
The repository pin is `.zigversion`; CI requests the exact release and verifies
it against that file. No new language/package dependency is needed.

Run these commands serially from the repository root:

```sh
zig version
zig fmt --check build.zig src tests tools
zig build -j2 --summary all
zig build test -j2 --summary all
zig build -Doptimize=ReleaseSafe -j2 --summary all
zig build test -Doptimize=ReleaseSafe -j2 --summary all
zig build test-abi -Doptimize=ReleaseSafe -j2 --summary all
zig build test-heavy -Doptimize=ReleaseSafe -j2 --summary all
```

`test` retains all ordinary correctness, malformed-format, concurrency,
allocation-error, offline-publication and recovery regressions. It also runs
C11 and C++17 consumers against both static and shared DB/VFS libraries (eight
executables). Consumer fixtures are distinct by API, language and linkage.
The build compiler supplies the C/C++ front end; the C++ tests use no C++ library
facilities and do not need an additional installed C++ standard library.

`test-heavy` is the existing real process-death matrix: 5 boundaries ×
in-place/overlay × 1/4 workers. It creates an exclusively owned random
`zig-cache-vfs-patch-process-*` directory in the current checkout, terminates
only its own children, resumes in fresh children, and verifies results. This
is process-crash coverage, not a claim of power-loss durability.

For a longer reliability check, repeat `zig build test -Doptimize=ReleaseSafe`
three times **serially**, then run `test-heavy`. The test execution steps
are explicitly side-effectful, so even repeats with `--seed 0x5eed` execute
again while compilation stays cached. Do not run fixture-mutating
aggregates simultaneously in one checkout. Ordinary `zig build test` keeps its
full tests; opting out of the heavy matrix does not remove ordinary recovery
or corruption tests.

## CRC backend and CPU checks

The x86 hardware byte CRC uses an unsuffixed `crc32` instruction with a typed
`u8` general-register input and `u32` accumulator. Zig 0.16.0's native Debug
backend rejects the old `q` constraint and mis-sizes a `crc32b` suffix. The
operand-typed spelling works with that backend and LLVM without dropping
hardware CRC or changing the algorithm. Arm64 uses Zig named width modifiers
(`%[operand:w]`) for its 32-bit registers. Fixed vectors, random lengths and
alignments, continuation, and exhaustive short byte-tail tests remain enabled.

On an x86_64 host with SSE4.2:

```sh
zig test src/db/crc32c.zig -O Debug -mcpu=x86_64+sse4_2 -fno-llvm
zig test src/db/crc32c.zig -O Debug -mcpu=x86_64+sse4_2 -fllvm
zig test src/db/crc32c.zig -O ReleaseSafe -mcpu=x86_64+sse4_2
zig test src/db/crc32c.zig -O ReleaseFast -mcpu=x86_64+sse4_2
zig test src/db/crc32c.zig -O Debug -mcpu=baseline
```

The last command selects the portable CRC path on x86_64. On macOS Arm64,
baseline is Apple M1 and includes CRC; use `-mcpu=baseline-crc` to select the
portable path. Hardware features are selected at
compile time, not dynamically dispatched. Native CPU builds are not a promise
of compatibility with older CPUs. For distributable artifacts explicitly choose
an appropriate target and baseline, e.g. `-Dtarget=x86_64-linux-gnu -Dcpu=baseline`.

## Platform CI and honest coverage

`.github/workflows/ci.yml` configures native Debug and ReleaseSafe build/test
jobs for Linux x86_64 (`ubuntu-24.04`), Windows x86_64 (`windows-2025`) and
macOS Arm64 (`macos-15`). It checks formatting, installed builds, all regressions
and ABI consumers, and CRC fallback. Linux also checks explicit SSE4.2 with
native and LLVM Debug backends. Workflow actions are pinned to verified release
commits and run with read-only repository permissions; nothing is published.

`.github/workflows/reliability.yml` is manually dispatched: three serial full
suites, the process-death matrix, and an optional benchmark, on all three OSes.
No schedule or automatic performance threshold is configured.

Adding workflows is not evidence that they have run. Local stage verification
is Linux x86_64 only; see the recorded results in
[improvement progress](vfs/improvement_progress.md). Windows/macOS native runtime
behavior remains unverified until their CI jobs actually pass. Cross-compilation
checks parsing, compilation and linking only:

```sh
zig build check-abi -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe -j2
zig build check-abi -Dtarget=aarch64-macos -Doptimize=ReleaseSafe -j2
```

Native tests are still needed for DLL loading, platform file locks, rename/mmap
semantics, process termination and concurrency. The matrix is not a claim of
support for every architecture, older OS release, compiler or MSVC ABI.

## Performance entry points

```sh
zig build bench-read -Doptimize=ReleaseFast -j2 -- 8
```

The existing benchmark creates its dataset immediately before reads. Its
"cold" cases are **VFS-cache cold, generally OS-cache warm**, not uncached disk
bandwidth measurements. Warm cases include memory copies and lock costs. Record
CPU, OS, Zig version, optimization, thread count, workload and cache settings
along with output. Shared CI runner throughput is informational; there is no
machine-independent timing pass/fail threshold. The CLI also exposes
`vfs bench-patch <base> <scratch> <diff...>` for an explicit scratch-copy patch
experiment. Neither benchmark changes the correctness contract.
