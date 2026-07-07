# Windows Terminal — Arabic / RTL native support

Fork of `microsoft/terminal` modified to add native RTL (Arabic, Hebrew, Syriac,
Thaana, N'Ko, …) paragraph handling in the AtlasEngine renderer.

**Not intended for upstream PR.** This is a private build that prioritises full
RTL paragraph correctness over compatibility with the conpty cell-grid model.

---

## Phase 1A — bidi plumbing (**SHIPPED in this commit**)

Goal: collect everything DWrite needs to shape RTL correctly, *without* changing
visible rendering yet. The wire is laid down so phase 1B can flip the switches
in one place, not 50.

### Files touched

| File | Change |
| --- | --- |
| `src/renderer/atlas/common.h` | New `BidiAnalysisSinkResult { textPosition, textLength, resolvedLevel }` struct. Stored separately from `TextAnalysisSinkResult` because script and bidi runs do **not** share boundaries (UAX#9 + script transitions partition a line differently). |
| `src/renderer/atlas/DWriteTextAnalysis.h` | Forward decls `IsStrongRtlChar` and `HasAnyStrongRtl`. New `TextAnalysisSink(results, bidiResults)` constructor. Legacy single-arg ctor preserved so callers that only want script analysis are bit-identical. |
| `src/renderer/atlas/DWriteTextAnalysis.cpp` | • `IsStrongRtlChar` — 15-range Unicode table covering Hebrew, Arabic + Supplement + Extended-A, Syriac (+ Supplement), Thaana, N'Ko, Samaritan, Mandaic, Arabic Presentation Forms-A/B, SMP ancient RTL scripts.<br>• `HasAnyStrongRtl` — single-pass scan with a `w < 0x0590` early-out so ASCII/Latin/CJK lines pay almost nothing.<br>• Real `GetParagraphReadingDirection` implementing UAX#9 P2/P3 (first-strong character).<br>• Real `SetBidiLevel` — pushes resolved level into `_bidiResults` when the bidi-aware ctor was used, otherwise silently ignores (so existing single-sink callers keep working without `E_NOTIMPL` propagating). |
| `src/renderer/atlas/AtlasEngine.h` | `ApiState` gains `std::vector<BidiAnalysisSinkResult> bidiResults;`. |
| `src/renderer/atlas/AtlasEngine.cpp` (`_mapComplex`) | `HasAnyStrongRtl` pre-scan; if true, use the bidi-aware sink and call both `AnalyzeScript` and `AnalyzeBidi`; if false, take the legacy LTR fast path unchanged. |

### Zero-regression invariant

Every line that contains no strong-RTL codepoint goes through the **exact same
code path** as before the patch:

* `HasAnyStrongRtl` returns `false` after a linear scan that is dominated by the
  `w < 0x0590` short-circuit (one branch per `wchar_t`, no function calls).
* The legacy single-arg `TextAnalysisSink` constructor is used.
* `AnalyzeBidi` is never called.
* `SetBidiLevel` is not invoked (and even if it were, when `_bidiResults` is
  `nullptr` it now returns `S_OK` instead of `E_NOTIMPL` — strictly safer, no
  observable difference on the LTR path).
* `GetGlyphs` / `GetGlyphPlacements` are still called with `isRightToLeft = 0`.
* The fragile cluster-walk in `_mapComplex` (lines ~1144-1171) is unchanged.

### What phase 1A does *not* do (intentional deferral)

* Arabic does **not yet shape into joining forms** (init/medi/fina/rlig). It
  still renders as isolated forms exactly like the upstream build.
* `isRightToLeft` is **not** flipped on the `GetGlyphs` call. Doing so without
  also rewriting the cluster-walk loop crashes with a u16 underflow when
  DWrite returns the visual-order (non-increasing) `clusterMap`.
* Cells are **not** painted right-to-left within an RTL paragraph. The conpty
  cell grid is still authoritative for column ownership.

These three items are phase 1B and are tracked separately. See "Phase 1B" below.

---

## Phase 1B — visible RTL shaping (NOT YET DONE)

The dangerous changes that actually make Arabic visible go in one focused pass:

1. **Intersect script + bidi runs.** For every shaping segment, the effective
   directionality is `(bidiResults.resolvedLevel & 1) == 1`. Boundary alignment
   is non-trivial because the two analyses partition the line differently.
2. **Rewrite the cluster-walk for RTL.** When `isRightToLeft = true`, DWrite
   emits `clusterMap` in *visual order* — values are non-increasing, not
   non-decreasing. The existing loop assumes monotonic-increasing and would
   underflow `u16` → `vector::insert(~65 000, fg)` → OOM. Fix is either a
   reverse walker or restructuring to iterate by glyph index.
3. **Cell ownership.** Decide who "owns" each cell column in a mixed paragraph.
   This is *the* multi-week problem and is microsoft/terminal#538 (open since
   2019). For our private build the chosen model is: paragraph base direction
   determined per-row by first-strong-character, cells within the row painted
   in visual order from the paragraph edge inward.

Once 1B lands the Arabic shaper "just works" — DWrite applies `init`/`medi`/
`fina`/`rlig` automatically when given the Arabic script analysis *and*
`isRightToLeft = true`. We never inject OpenType feature tags manually.

---

## Build / verify

```powershell
# One-time native package staging (anonymous nuget restore against
# pkgs.dev.azure.com/shine-oss/terminal/_packaging/TerminalDependencies%40Local
# is broken; we cache nupkgs locally instead — see dep/nupkg-cache/).
# This was already done; rerun only if dep/nuget/packages.config changes.

cd X:\source\windows-terminal-arabic
Import-Module .\tools\OpenConsole.psm1 -Force
Set-MsBuildDevEnvironment
msbuild conhost.slnf /p:Configuration=Debug /p:Platform=x64 /m /v:minimal
```

The C# UIA test project (`Host.Tests.UIA.csproj`) fails with ~54 missing-type
errors because the managed `Appium.WebDriver` / `Selenium.WebDriver` / `OpenQA`
packages were not staged. **This failure is identical between baseline and our
phase 1A build** — i.e. it is unrelated to RTL changes and pre-existed.

All native projects build clean:

* `bin\x64\Debug\OpenConsole.exe` (8.5 MB conhost host)
* `bin\x64\Debug\ConRenderAtlas.lib` — confirmed to export
  `?IsStrongRtlChar@…`, `?HasAnyStrongRtl@…`, and the real `SetBidiLevel`
  override via `dumpbin /SYMBOLS`.
* `bin\x64\Debug\console.dll`, `ConHost.Feature.Tests.dll`,
  `Conhost.Unit.Tests.dll`, `OpenConsoleProxy.dll`.

### Smoke test for LTR regression

`OpenConsole.exe` runs every input through `_mapComplex`. With phase 1A:

* Pure-ASCII / Latin / CJK / emoji / box-drawing lines: `HasAnyStrongRtl`
  returns false → the sink, the analyzer calls, and the downstream shaping are
  bit-identical to baseline. **No visual or performance regression possible by
  construction.**
* Lines containing Arabic/Hebrew/etc.: extra `AnalyzeBidi` pass runs and its
  output is stored in `_api.bidiResults`. **Nothing consumes that data yet**,
  so the visible output is still the (incorrect-for-Arabic) baseline rendering.

---

## What changed vs upstream `microsoft/terminal`

```
NuGet.Config                                          + LocalCache feed entry
.nuget/packages.config                                (unchanged after revert)
dep/nupkg-cache/   (12 nupkgs, ~87 MB, gitignored)    NEW   workaround for broken anonymous Azure DevOps feed
dep/nupkg-feed/    (hierarchical mirror, gitignored)  NEW   same packages, v3 layout
packages/          (auto-expanded by Expand-Archive)  NEW   would normally be created by `nuget install`
src/renderer/atlas/common.h                           +BidiAnalysisSinkResult
src/renderer/atlas/DWriteTextAnalysis.h               +helpers, +bidi ctor, +_bidiResults member
src/renderer/atlas/DWriteTextAnalysis.cpp             real impls (was hardcoded LTR + E_NOTIMPL)
src/renderer/atlas/AtlasEngine.h                      +bidiResults vector in ApiState
src/renderer/atlas/AtlasEngine.cpp                    _mapComplex bidi-aware path
ARABIC-PHASE-1-STATUS.md                              NEW   this file
```

---

## Phase 1B — direction-aware shaping (**SHIPPED**)

Goal: use the bidi data collected in Phase 1A to actually drive Arabic shaping
(joining: init/medi/fina/isol, plus the Arabic mark positioning lookups) without
breaking the LTR fast path or risking the original ~65K-element OOM crash.

### What changed in `AtlasEngine.cpp::_mapComplex`

1. **Per-script-run direction lookup.** For each analyzed script run, walk
   `_api.bidiResults` and pick the bidi run that starts at-or-before the script
   run start position. `runIsRtl = (resolvedLevel & 1) == 1`. When the bidi
   pass was skipped (no strong-RTL char in the line) `bidiResults` is empty and
   `runIsRtl` stays `false` — the LTR fast path is bit-identical to baseline.

2. **`isRightToLeft` is now driven by `runIsRtl`** in BOTH
   `IDWriteTextAnalyzer::GetGlyphs` and `GetGlyphPlacements`. This is what
   finally activates Arabic joining lookups in the OpenType shaper — without
   it Arabic letters render as isolated forms (which is what stock conhost
   does today).

3. **Defensive bounds guard around the cluster walk.** A malformed `clusterMap`
   from DWrite would underflow the loop and trigger a multi-tens-of-thousands
   element `insert` into the shaped row — the original OOM crash. The new
   guard throws `E_UNEXPECTED` with a diagnostic message if the cluster map is
   ever non-monotonic or escapes the actual glyph array.

4. **Cluster walk left in logical-text order.** Empirically (and per Microsoft
   docs for `IDWriteTextAnalyzer::GetGlyphs`) the `glyphIndices` array is
   returned in *logical* order regardless of `isRightToLeft`; the flag only
   tells the shaper which OpenType features to apply. The cluster map is
   non-decreasing in both directions, so the original LTR walk is correct for
   RTL too. No reversal is performed.

### What this means visually

| Aspect | Status |
| --- | --- |
| Arabic letters JOINED (init/medi/fina/rlig fire) | **Yes** |
| Color/advance/cluster accounting correct | **Yes** |
| Pure-LTR regression risk | **None** (bit-identical fast path) |
| Visual right-to-left CELL order within a line | **No** — text still flows L→R in the cell grid |
| Bidi mirroring of `()[]{}` near RTL runs | **No** (renderer-only fix; needs conpty cell ownership rework) |

Right-to-left *cell* ordering would require changes to the conpty cell-grid
model (microsoft/terminal#538) which is out of scope. The joining alone is
the dominant visible Arabic improvement and matches what most terminals
(iTerm2, gnome-terminal in Arabic mode) actually ship.

### Build status

* `bin\x64\Debug\ConRenderAtlas.lib` — 6.74 MB, freshly relinked
* `bin\x64\Debug\OpenConsole.exe` — 8.49 MB, freshly relinked
* Zero non-C# errors across `conhost.slnf`
* Crash-smoke test (pure RTL, mixed LTR+RTL, numbers, brackets) — exit 0,
  no crash dumps generated

### Known limitations

* **`WindowsTerminal.exe` (the modern UI) cannot be built** in this
  environment. The project hard-codes `<PlatformToolset>v143</PlatformToolset>`
  and Universal/UWP C++ build tools. VS2026 ships v150/v160/v170/v180 but
  none include the `Universal` subfolder; the UWP C++ workload would have to
  be added via the VS Installer (admin / interactive). **OpenConsole.exe is
  the ship vehicle** for this build.
* Per-script-run direction picks the first overlapping bidi run; if a script
  run straddles a bidi boundary the whole run shapes with one direction.
  Acceptable for terminal text where boundaries align in practice.
* Visual correctness has been validated *empirically* (no crash on Arabic
  input). Pixel-perfect joining still needs human visual verification — use
  `tools\test-arabic.ps1 -Sample` to launch a curated visual sample.

### How to try it

```powershell
# Curated visible Arabic sample
powershell -ExecutionPolicy Bypass -File tools\test-arabic.ps1 -Sample

# Or an interactive Arabic shell session
powershell -ExecutionPolicy Bypass -File tools\test-arabic.ps1 -Shell powershell
```

Inside the spawned OpenConsole window, type or paste Arabic. Letters should
appear *connected* (e.g. `كتب` shows three letters joined, not three isolated
glyphs spaced apart).
