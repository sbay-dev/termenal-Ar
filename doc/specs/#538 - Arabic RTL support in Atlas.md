---
author: RTL-VT contributors
created on: 2026-06-04
last updated: 2026-06-04
issue id: 538
---

# Arabic RTL support in the Atlas renderer

## Abstract

This spec documents the RTL-VT Arabic rendering work for Windows Terminal's Atlas renderer. The change teaches the DirectWrite shaping path to recognize strong right-to-left text, collect bidi levels, shape Arabic text with `isRightToLeft`, and present RTL paragraphs in visual token order without changing the underlying console buffer contents.

The goal is to make Arabic text readable in the terminal: joined Arabic forms should appear connected, RTL-only rows should display from the right side of the viewport, and the cursor should mirror to the visual position for RTL rows.

## Inspiration

Arabic text in terminal grids historically fails in two visible ways:

1. Arabic letters are shaped as isolated forms instead of initial/medial/final connected forms.
2. RTL paragraphs are painted in logical left-to-right cell order, so Arabic words appear visually reversed and the caret remains on the left edge.

Windows Terminal already uses DirectWrite in the Atlas path, but the fast/simple glyph path and LTR shaping defaults prevent Arabic shaping from being used reliably. This work keeps the existing LTR path intact while routing only strong RTL text through the bidi-aware shaping path.

## Solution Design

The implementation is intentionally staged around the Atlas renderer:

1. `DWriteTextAnalysis` gains helpers for strong RTL detection and a bidi-aware `TextAnalysisSink` constructor.
2. `TextAnalysisSource::GetParagraphReadingDirection` implements first-strong paragraph direction for the analyzed run.
3. `TextAnalysisSink::SetBidiLevel` records resolved bidi levels when the bidi-aware constructor is used.
4. `AtlasEngine::_mapRegularText` never lets strong RTL runs take the `GetTextComplexity` simple path. Those runs always go through `_mapComplex`.
5. `AtlasEngine::_mapComplex` calls both `AnalyzeScript` and `AnalyzeBidi` for strong RTL runs, then passes `isRightToLeft` to both `GetGlyphs` and `GetGlyphPlacements`.
6. Rows whose first strong character is RTL are segmented into whitespace and non-whitespace spans. The spans are mapped from right to left for Atlas' left-to-right painter. Glyphs and clusters inside each shaped span are not reversed, so ligatures and marks remain in DirectWrite's order.
7. `ShapedRow::rtl` records that the row's first strong character is RTL. The row also stores a logical-to-visual column boundary map, so caret painting follows the same visual token order as the glyph stream instead of mirroring the entire viewport.
8. `ControlCore::_repositionCursorWithMouse` applies the same visual-to-logical column model only for the click-to-reposition path. VT mouse input, wheel events, and ordinary selection are not remapped by this first pass.

The console text buffer remains logical. The renderer owns only visual presentation.

## UI/UX Design

Pure Arabic rows should display from the right edge and Arabic letters should join:

```text
مرحبا بالعالم من الطرفية العربية
كتب  كاتب  مكتوب  كتاب
```

Mixed rows keep the terminal cell model. The current implementation is a practical renderer-level step, not a complete UAX #9 terminal model. More advanced neutral mirroring, selection mapping, search highlighting, and mixed LTR/RTL cell ownership remain future work.

## Capabilities

### Accessibility

The logical text buffer is unchanged, so screen readers and copy operations continue to consume the same text order they receive today. Visual cursor mirroring only affects the rendered caret rectangle.

### Security

The change does not parse external data beyond existing terminal text. The shaping code validates cluster map bounds before appending glyph ranges, preventing underflow or over-large vector insertions if DirectWrite returns an unexpected topology.

### Reliability

Pure LTR rows follow the existing path:

* `HasAnyStrongRtl` returns `false`.
* `AnalyzeBidi` is skipped.
* `GetGlyphs` and `GetGlyphPlacements` keep `isRightToLeft = false`.
* Existing simple and complex LTR glyph handling remains unchanged.

Strong RTL rows opt into the additional DirectWrite bidi pass and guarded cluster handling.

### Compatibility

This is a renderer-only change. It does not alter conpty, VT input, command-line parsing, shell behavior, or the stored text buffer. The main compatibility risk is visual behavior for mixed LTR/RTL rows, because terminals expose a fixed cell grid rather than a rich text layout surface.

### Performance, Power, and Efficiency

The hot LTR path pays only a linear pre-scan with a cheap `wchar_t < 0x0590` fast path. Bidi analysis and RTL cluster handling run only when a row contains at least one strong RTL codepoint.

## CLI application script

`tools\Apply-RTLArabicSupport.ps1` applies the current RTL-VT solution from a patched checkout into another Windows Terminal checkout:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Apply-RTLArabicSupport.ps1 `
  -SourceRoot X:\source\windows-terminal-arabic `
  -RepositoryRoot X:\source\terminal-clean `
  -Branch rtl-arabic-atlas-support
```

Optional build:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Apply-RTLArabicSupport.ps1 `
  -SourceRoot X:\source\windows-terminal-arabic `
  -RepositoryRoot X:\source\terminal-clean `
  -Branch rtl-arabic-atlas-support `
  -BuildOpenConsole `
  -Configuration Release `
  -Platform x64
```

The script is deliberately conservative:

* It copies only the renderer files by default.
* Private OpenConsole defaults and local build fixes are opt-in switches.
* It refuses to modify a dirty target checkout unless `-AllowDirty` is supplied.
* It supports `-CheckOnly` and `-WhatIf`.

## Measurement contract

The contribution should include a transparent size and performance report generated by `tools\Measure-RTLArabicImpact.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Measure-RTLArabicImpact.ps1 `
  -RepositoryRoot X:\source\windows-terminal-arabic `
  -BaselineRef origin/main `
  -Configuration Release `
  -Platform x64
```

The report compares the patched checkout against a detached baseline worktree for:

* `ConRenderAtlas.lib`
* `Microsoft.Terminal.ControlLib.lib`
* `Microsoft.Terminal.Control.dll`

The performance expectation is:

* LTR rows: no bidi analysis, no RTL row map allocation, no ControlCore remap.
* Numeric-only rows: first-strong scan may inspect the row because digits are bidi-weak; no shaping or row-map allocation occurs unless a strong RTL codepoint is found.
* RTL rows: one bidi pass, one row-local visual column map, and token-order mapping proportional to the viewport row width.
* Mouse remap: only click-to-reposition uses the visual-to-logical conversion; VT mouse input and wheel paths remain unchanged.

## Potential Issues

* Mixed LTR/RTL rows need more review. The renderer can present a useful visual order, but the terminal buffer still owns logical cell coordinates.
* Selection, search highlights, hyperlink spans, and full mouse event mapping may need follow-up work for complex mixed rows. This pass remaps only cursor paint and click-to-reposition.
* Font fallback must be available for Arabic glyph coverage. Cascadia Mono is acceptable as the terminal face when DirectWrite fallback supplies Arabic glyphs.
* The private prototype forces Atlas for OpenConsole; an upstream contribution should avoid changing global defaults unless the maintainers explicitly request it.

## Future considerations

* Add unit coverage for `TextAnalysisSource::GetParagraphReadingDirection` and `TextAnalysisSink::SetBidiLevel`.
* Add an Atlas renderer test that verifies Arabic text enters `_mapComplex` and receives RTL shaping flags.
* Define a terminal-specific bidi cell ownership model for selection, search, hyperlink spans, and cursor navigation.
* Decide whether RTL row presentation should be automatic, profile-controlled, or feature-flagged during rollout.

## Resources

* DirectWrite `IDWriteTextAnalyzer::AnalyzeBidi`
* DirectWrite `IDWriteTextAnalyzer::GetGlyphs`
* DirectWrite `IDWriteTextAnalyzer::GetGlyphPlacements`
* Unicode Bidirectional Algorithm, first-strong paragraph direction
* Windows Terminal issue #538: RTL / bidi terminal rendering
