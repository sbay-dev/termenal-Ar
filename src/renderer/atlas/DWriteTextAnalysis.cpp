// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include "pch.h"
#include "DWriteTextAnalysis.h"

#pragma warning(disable : 4100) // '...': unreferenced formal parameter
#pragma warning(disable : 26481) // Don't use pointer arithmetic. Use span instead (bounds.1).

using namespace Microsoft::Console::Render::Atlas;

namespace
{
    // Strong-RTL Unicode codepoint ranges (bidi class R or AL).
    // Conservative coverage of the major scripts the terminal will encounter:
    // Hebrew, Arabic + Supplement + Extended-A/B/C, Syriac (+ Supplement),
    // Thaana, N'Ko, Samaritan, Mandaic, Arabic Presentation Forms-A/B,
    // and the SMP RTL ancient scripts. Mark ranges (Mn) are intentionally
    // excluded so they do not falsely trigger RTL detection on a stray
    // combining mark inside an LTR line.
    struct RtlRange
    {
        char32_t lo;
        char32_t hi;
    };
    constexpr RtlRange g_rtlRanges[] = {
        { 0x000590, 0x0005FF }, // Hebrew
        { 0x000600, 0x0006FF }, // Arabic
        { 0x000700, 0x00074F }, // Syriac
        { 0x000750, 0x00077F }, // Arabic Supplement
        { 0x000780, 0x0007BF }, // Thaana
        { 0x0007C0, 0x0007FF }, // N'Ko
        { 0x000800, 0x00083F }, // Samaritan
        { 0x000840, 0x00085F }, // Mandaic
        { 0x000860, 0x00086F }, // Syriac Supplement
        { 0x0008A0, 0x0008FF }, // Arabic Extended-A
        { 0x00FB1D, 0x00FB4F }, // Hebrew Presentation Forms
        { 0x00FB50, 0x00FDFF }, // Arabic Presentation Forms-A
        { 0x00FE70, 0x00FEFF }, // Arabic Presentation Forms-B
        { 0x010800, 0x010FFF }, // Cypriot, Aramaic, Phoenician, etc.
        { 0x01E800, 0x01EFFF }, // Mende Kikakui, Adlam, Arabic Math
    };

    constexpr bool isHighSurrogate(wchar_t c) noexcept { return c >= 0xD800 && c <= 0xDBFF; }
    constexpr bool isLowSurrogate(wchar_t c) noexcept { return c >= 0xDC00 && c <= 0xDFFF; }
}

namespace Microsoft::Console::Render::Atlas
{
    bool IsStrongRtlChar(char32_t cp) noexcept
    {
        // Branchless-ish linear scan: the table is small and modern branch
        // predictors handle this well. The function is also called only after
        // HasAnyStrongRtl returns true, so it sits off the hot LTR path.
        for (const auto& r : g_rtlRanges)
        {
            if (cp >= r.lo && cp <= r.hi)
            {
                return true;
            }
        }
        return false;
    }

    bool HasAnyStrongRtl(const wchar_t* text, size_t length) noexcept
    {
        if (text == nullptr || length == 0)
        {
            return false;
        }

        // Fast pre-filter: every BMP RTL codepoint we care about is >= U+0590,
        // and every supplementary-plane RTL codepoint requires a high surrogate
        // (>= U+D800). So any wchar with the high byte set is a candidate; we
        // skip the full range check when it is not.
        for (size_t i = 0; i < length; ++i)
        {
            const wchar_t w = text[i];
            if (w < 0x0590)
            {
                continue; // ASCII / Latin / control / Greek / Cyrillic: never strong RTL
            }
            char32_t cp = w;
            if (isHighSurrogate(w) && (i + 1) < length && isLowSurrogate(text[i + 1]))
            {
                cp = 0x10000u + ((static_cast<char32_t>(w) - 0xD800u) << 10) +
                     (static_cast<char32_t>(text[i + 1]) - 0xDC00u);
                ++i; // consume the trailing surrogate
            }
            if (IsStrongRtlChar(cp))
            {
                return true;
            }
        }
        return false;
    }
}

TextAnalysisSource::TextAnalysisSource(const wchar_t* locale, const wchar_t* text, const UINT32 textLength) noexcept :
    _locale{ locale },
    _text{ text },
    _textLength{ textLength }
{
}

// TextAnalysisSource will be allocated on the stack and reference counting is pointless because of that.
// The debug version will assert that we don't leak any references though.
#ifdef NDEBUG
ULONG __stdcall TextAnalysisSource::AddRef() noexcept
{
    return 1;
}

ULONG __stdcall TextAnalysisSource::Release() noexcept
{
    return 1;
}
#else
TextAnalysisSource::~TextAnalysisSource()
{
    assert(_refCount == 1);
}

ULONG __stdcall TextAnalysisSource::AddRef() noexcept
{
    return ++_refCount;
}

ULONG __stdcall TextAnalysisSource::Release() noexcept
{
    return --_refCount;
}
#endif

HRESULT TextAnalysisSource::QueryInterface(const IID& riid, void** ppvObject) noexcept
{
    __assume(ppvObject != nullptr);

    if (IsEqualGUID(riid, __uuidof(IDWriteTextAnalysisSource)))
    {
        *ppvObject = this;
        return S_OK;
    }

    *ppvObject = nullptr;
    return E_NOINTERFACE;
}

HRESULT TextAnalysisSource::GetTextAtPosition(UINT32 textPosition, const WCHAR** textString, UINT32* textLength) noexcept
{
    // Writing to address 0 is a crash in practice. Just what we want.
    __assume(textString != nullptr);
    __assume(textLength != nullptr);

    textPosition = std::min(textPosition, _textLength);
    *textString = _text + textPosition;
    *textLength = _textLength - textPosition;
    return S_OK;
}

HRESULT TextAnalysisSource::GetTextBeforePosition(UINT32 textPosition, const WCHAR** textString, UINT32* textLength) noexcept
{
    // Writing to address 0 is a crash in practice. Just what we want.
    __assume(textString != nullptr);
    __assume(textLength != nullptr);

    textPosition = std::min(textPosition, _textLength);
    *textString = _text;
    *textLength = textPosition;
    return S_OK;
}

DWRITE_READING_DIRECTION TextAnalysisSource::GetParagraphReadingDirection() noexcept
{
    if (_text == nullptr || _textLength == 0)
    {
        return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }

    size_t strongRtl = 0;
    size_t strongLtr = 0;
    std::optional<bool> firstStrongRtl;

    for (UINT32 i = 0; i < _textLength; ++i)
    {
        const wchar_t w = _text[i];

        if ((w >= L'A' && w <= L'Z') || (w >= L'a' && w <= L'z'))
        {
            ++strongLtr;
            if (!firstStrongRtl)
            {
                firstStrongRtl = false;
            }
            continue;
        }

        if (w < 0x0590)
        {
            continue; // numbers, punctuation, whitespace, control: weak/neutral
        }

        char32_t cp = w;
        if (isHighSurrogate(w) && (i + 1) < _textLength && isLowSurrogate(_text[i + 1]))
        {
            cp = 0x10000u + ((static_cast<char32_t>(w) - 0xD800u) << 10) +
                 (static_cast<char32_t>(_text[i + 1]) - 0xDC00u);
            ++i;
        }

        if (IsStrongRtlChar(cp))
        {
            ++strongRtl;
            if (!firstStrongRtl)
            {
                firstStrongRtl = true;
            }
        }
    }

    if (strongRtl != strongLtr)
    {
        return strongRtl > strongLtr ? DWRITE_READING_DIRECTION_RIGHT_TO_LEFT : DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }

    if (firstStrongRtl.value_or(false))
    {
        return DWRITE_READING_DIRECTION_RIGHT_TO_LEFT;
    }

    return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
}

HRESULT TextAnalysisSource::GetLocaleName(UINT32 textPosition, UINT32* textLength, const WCHAR** localeName) noexcept
{
    // Writing to address 0 is a crash in practice. Just what we want.
    __assume(textLength != nullptr);
    __assume(localeName != nullptr);

    *textLength = _textLength - textPosition;
    *localeName = _locale;
    return S_OK;
}

HRESULT TextAnalysisSource::GetNumberSubstitution(UINT32 textPosition, UINT32* textLength, IDWriteNumberSubstitution** numberSubstitution) noexcept
{
    return E_NOTIMPL;
}

TextAnalysisSink::TextAnalysisSink(std::vector<TextAnalysisSinkResult>& results) noexcept :
    _results{ results }
{
}

TextAnalysisSink::TextAnalysisSink(std::vector<TextAnalysisSinkResult>& results,
                                   std::vector<BidiAnalysisSinkResult>& bidiResults) noexcept :
    _results{ results },
    _bidiResults{ &bidiResults }
{
}

// TextAnalysisSource will be allocated on the stack and reference counting is pointless because of that.
// The debug version will assert that we don't leak any references though.
#ifdef NDEBUG
ULONG __stdcall TextAnalysisSink::AddRef() noexcept
{
    return 1;
}

ULONG __stdcall TextAnalysisSink::Release() noexcept
{
    return 1;
}
#else
TextAnalysisSink::~TextAnalysisSink()
{
    assert(_refCount == 1);
}

ULONG __stdcall TextAnalysisSink::AddRef() noexcept
{
    return ++_refCount;
}

ULONG __stdcall TextAnalysisSink::Release() noexcept
{
    return --_refCount;
}
#endif

HRESULT TextAnalysisSink::QueryInterface(const IID& riid, void** ppvObject) noexcept
{
    __assume(ppvObject != nullptr);

    if (IsEqualGUID(riid, __uuidof(IDWriteTextAnalysisSink)))
    {
        *ppvObject = this;
        return S_OK;
    }

    *ppvObject = nullptr;
    return E_NOINTERFACE;
}

HRESULT __stdcall TextAnalysisSink::SetScriptAnalysis(UINT32 textPosition, UINT32 textLength, const DWRITE_SCRIPT_ANALYSIS* scriptAnalysis) noexcept
try
{
    __assume(scriptAnalysis != nullptr);
    _results.emplace_back(textPosition, textLength, *scriptAnalysis);
    return S_OK;
}
CATCH_RETURN()

HRESULT TextAnalysisSink::SetLineBreakpoints(UINT32 textPosition, UINT32 textLength, const DWRITE_LINE_BREAKPOINT* lineBreakpoints) noexcept
{
    return E_NOTIMPL;
}

HRESULT TextAnalysisSink::SetBidiLevel(UINT32 textPosition, UINT32 textLength, UINT8 explicitLevel, UINT8 resolvedLevel) noexcept
try
{
    // RTL-VT phase 1: store the resolved bidi level so the renderer can later
    // consult it per shaping run. When the bidi-aware constructor was not used
    // (e.g. callers that only want script analysis) we silently ignore bidi
    // callbacks instead of returning an error -- DWrite still invokes them when
    // AnalyzeBidi runs against this sink and an E_NOTIMPL here would propagate
    // up as an unrecoverable HRESULT.
    if (_bidiResults != nullptr)
    {
        _bidiResults->emplace_back(BidiAnalysisSinkResult{ textPosition, textLength, resolvedLevel });
    }
    return S_OK;
}
CATCH_RETURN()

HRESULT TextAnalysisSink::SetNumberSubstitution(UINT32 textPosition, UINT32 textLength, IDWriteNumberSubstitution* numberSubstitution) noexcept
{
    return E_NOTIMPL;
}
