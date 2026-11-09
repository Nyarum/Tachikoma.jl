# ═══════════════════════════════════════════════════════════════════════
# Cell ── one character + style on the terminal grid
# ═══════════════════════════════════════════════════════════════════════

const EMPTY_CHAR = ' '
const WIDE_CHAR_PAD = '\0'   # sentinel for the trailing cell of a double-width character
const _ANSI_RE = r"\e(?:\[[?=>!]?[0-9;:]*[\x20-\x2f]*[A-Za-z@~]|\][^\x07\e]*(?:\x07|\e\\)|\([A-Za-z0-9]|[P^_][^\e]*\e\\|[A-Za-z0-9=<>])"
_strip_ansi(s::AbstractString) = contains(s, '\e') ? replace(s, _ANSI_RE => "") : s

# A C0 control char (0x00–0x1F) or DEL (0x7F). These have no printable glyph: written
# to a cell they either move the terminal cursor when flushed raw (a lone \r/\n/\b jumps
# to column 0 / a new line and smears the row) or break layout math (`textwidth` returns
# -1 for them). `_strip_ansi` only removes ESC-based SEQUENCES, so a bare \r survives it.
@inline _is_c0_control(c::AbstractChar) = c <= '\x1f' || c == '\x7f'

# Replace every C0/DEL control char with a space, so set_string! can never emit one to the
# terminal (space keeps token separation and the cell footprint; dropping would glue
# tokens and shorten the row). Fast path returns the input untouched when it's clean.
function _strip_controls(s::AbstractString)
    any(_is_c0_control, s) || return s
    io = IOBuffer(sizehint = ncodeunits(s))
    for c in s
        print(io, _is_c0_control(c) ? ' ' : c)
    end
    return String(take!(io))
end

struct Cell
    char::Char
    style::Style
    suffix::String
end

Cell() = Cell(EMPTY_CHAR, RESET, "")
Cell(ch::Char, style::Style=RESET) = Cell(ch, style, "")
Cell(ch::Char, style::Style, suffix::AbstractString) = Cell(ch, style, String(suffix))

Base.:(==)(a::Cell, b::Cell) = (
    a.char == b.char && a.suffix == b.suffix && a.style == b.style
)

@inline function cell_glyph(c::Cell)
    return isempty(c.suffix) ? string(c.char) : string(c.char, c.suffix)
end

# Terminal columns are grapheme widths, not the sum of codepoint widths.
# PCRE's Unicode properties distinguish emoji sequences from ordinary combining
# text (including non-emoji ZWJ). Ambiguous-width text keeps Julia's narrow policy.
const _EMOJI = r"\p{Emoji}"
const _PICTOGRAPH = r"\p{Extended_Pictographic}"
const _MODIFIER_BASE = r"\p{Emoji_Modifier_Base}"

function grapheme_width(g::AbstractString)
    # One codepoint: every emoji-sequence rule below needs two, so the width is
    # the character's own (checked for all of Unicode in test_buffer_width.jl).
    i = firstindex(g)
    i <= ncodeunits(g) && nextind(g, i) > ncodeunits(g) && return textwidth(g[i])
    if occursin('\ufe0f', g) && occursin(_EMOJI, g) ||
       occursin('\u200d', g) && occursin(_PICTOGRAPH, g) ||
       any(c -> '\U0001f3fb' <= c <= '\U0001f3ff', g) && occursin(_MODIFIER_BASE, g) ||
       occursin('\u20e3', g) && first(g) in "#*0123456789"
        return 2
    end
    textwidth(g)
end

# Base.Unicode.graphemes without its per-grapheme allocations: the grapheme
# starting at `i` ends at `j` and the next one starts at `k`. `state` carries
# the segmentation state across graphemes exactly as GraphemeIterator does.
@inline function _grapheme_span(s::AbstractString, i::Int, state::Ref{Int32})
    c0, k = iterate(s, i)::Tuple{Char,Int}
    j = i
    n = ncodeunits(s)
    while k <= n
        c, l = iterate(s, k)::Tuple{Char,Int}
        Base.Unicode.isgraphemebreak!(state, c0, c) && break
        j, k, c0 = k, l, c
    end
    j, k
end

"""Display columns under the narrow ambiguous-width, emoji-cluster terminal policy."""
function display_width(s::AbstractString)
    _is_simple_latin(s) && return textwidth(s)
    state = Ref{Int32}(0)
    i, n, width = firstindex(s), ncodeunits(s), 0
    while i <= n
        j, k = _grapheme_span(s, i, state)
        width += j == i ? textwidth(s[i]) : grapheme_width(SubString(s, i, j))
        i = k
    end
    width
end

@inline function cell_width(c::Cell)
    return isempty(c.suffix) ? textwidth(c.char) : grapheme_width(cell_glyph(c))
end

# Truncate `s` to fit at most `w` DISPLAY columns (wide/CJK chars count as 2),
# appending `ellipsis` when it doesn't fit. Grapheme-aware, so combining marks and
# wide chars are measured exactly the way `set_string!` renders them. Returns ""
# for `w <= 0`. Widgets budget columns in display width, not character count — using
# `length`/`first` here overflows a column by one per wide char and shears the layout,
# so table/header/label truncation must go through this.
function truncate_to_width(s::AbstractString, w::Integer; ellipsis::AbstractString = "…")
    w <= 0 && return ""
    display_width(s) <= w && return String(s)
    budget = max(0, w - display_width(ellipsis))
    io = IOBuffer()
    acc = 0
    for g in Base.Unicode.graphemes(s)
        gw = grapheme_width(g)
        acc + gw > budget && break
        print(io, g)
        acc += gw
    end
    return String(take!(io)) * ellipsis
end

# ═══════════════════════════════════════════════════════════════════════
# Buffer ── 2D grid of cells, the framebuffer
# ═══════════════════════════════════════════════════════════════════════

mutable struct Buffer
    area::Rect
    content::Vector{Cell}
end

function Buffer(rect::Rect)
    n = max(0, area(rect))
    Buffer(rect, fill(Cell(), n))
end

@inline function buf_index(buf::Buffer, x::Int, y::Int)
    (y - buf.area.y) * buf.area.width + (x - buf.area.x) + 1
end

@inline function in_bounds(buf::Buffer, x::Int, y::Int)
    x >= buf.area.x && x <= right(buf.area) &&
    y >= buf.area.y && y <= bottom(buf.area)
end

function set!(buf::Buffer, x::Int, y::Int, cell::Cell)
    in_bounds(buf, x, y) || return
    @inbounds buf.content[buf_index(buf, x, y)] = cell
end

function set_char!(buf::Buffer, x::Int, y::Int, ch::Char,
                   style::Style=RESET)
    in_bounds(buf, x, y) || return
    @inbounds begin
        i = buf_index(buf, x, y)
        old = buf.content[i]
        # Preserve existing cell bg when new style has no bg (NoColor).
        # Prevents "black fringe" inside semi-transparent FloatingWindows.
        if style.bg isa NoColor && !(old.style.bg isa NoColor)
            style = Style(fg=style.fg, bg=old.style.bg, bold=style.bold, dim=style.dim,
                          italic=style.italic, underline=style.underline)
        end
        # Clean up adjacent wide-char state before overwriting
        if old.char != WIDE_CHAR_PAD && cell_width(old) == 2
            # Overwriting the leading cell of a wide char → orphaned pad at x+1
            if in_bounds(buf, x + 1, y)
                j = buf_index(buf, x + 1, y)
                if buf.content[j].char == WIDE_CHAR_PAD
                    buf.content[j] = Cell(EMPTY_CHAR, buf.content[j].style)
                end
            end
        elseif old.char == WIDE_CHAR_PAD
            # Overwriting the pad cell → broken leading char at x-1
            if in_bounds(buf, x - 1, y)
                j = buf_index(buf, x - 1, y)
                buf.content[j] = Cell(EMPTY_CHAR, buf.content[j].style)
            end
        end
        buf.content[i] = Cell(ch, style)
    end
    nothing # not the stored Cell: returning it would box one per write
end

# Split a rendered glyph into its base character and any remaining suffix bytes.
#
# Returns `(EMPTY_CHAR, "")` for an empty input. For non-empty input, returns
# `(first_char, suffix)`, where `suffix` is the remaining substring after the
# first character, or `""` when no suffix is present.
@inline function _split_glyph(glyph::AbstractString)
    isempty(glyph) && return (EMPTY_CHAR, "")

    i  = firstindex(glyph)
    ch = glyph[i]
    ni = nextind(glyph, i)

    if ni <= lastindex(glyph)
        return (ch, String(SubString(glyph, ni, lastindex(glyph))))
    end

    return (ch, "")
end

# Write `glyph` at `(x, y)`, splitting it into a base char and suffix metadata.
#
# Does nothing when out of bounds. Preserves the existing background color when
# `style.bg` is `NoColor`, and clears neighboring wide-character pad/lead cells
# to keep buffer state consistent before writing the new cell.
function _set_glyph!(buf::Buffer, x::Int, y::Int, glyph::AbstractString,
                     style::Style=RESET)
    ch, suffix = _split_glyph(glyph)
    in_bounds(buf, x, y) || return
    @inbounds begin
        i = buf_index(buf, x, y)
        old = buf.content[i]
        if style.bg isa NoColor && !(old.style.bg isa NoColor)
            style = Style(fg=style.fg, bg=old.style.bg, bold=style.bold,
                          dim=style.dim, italic=style.italic,
                          underline=style.underline)
        end
        if old.char != WIDE_CHAR_PAD && cell_width(old) == 2
            if in_bounds(buf, x + 1, y)
                j = buf_index(buf, x + 1, y)
                if buf.content[j].char == WIDE_CHAR_PAD
                    buf.content[j] = Cell(EMPTY_CHAR, buf.content[j].style)
                end
            end
        elseif old.char == WIDE_CHAR_PAD
            if in_bounds(buf, x - 1, y)
                j = buf_index(buf, x - 1, y)
                buf.content[j] = Cell(EMPTY_CHAR, buf.content[j].style)
            end
        end
        buf.content[i] = Cell(ch, style, suffix)
    end
    nothing # not the stored Cell: returning it would box one per write
end

# Append `glyph` to the suffix of the cell at `(x, y)`.
#
# Used for zero-width/combining graphemes. If `(x, y)` points to a wide-char pad
# cell, this rewrites the wide-char lead cell instead; if no lead is available,
# the append is ignored.
function _append_glyph!(buf::Buffer, x::Int, y::Int, glyph::AbstractString)
    in_bounds(buf, x, y) || return
    @inbounds begin
        i = buf_index(buf, x, y)
        cell = buf.content[i]
        if cell.char == WIDE_CHAR_PAD && in_bounds(buf, x - 1, y)
            i = buf_index(buf, x - 1, y)
            cell = buf.content[i]
        end
        cell.char == WIDE_CHAR_PAD && return
        buf.content[i] = Cell(cell.char, cell.style, string(cell.suffix, glyph))
    end
end

# Fast check: true if string has no multi-byte chars or combining marks.
# When true, we can skip grapheme segmentation and use the fast char path.
@inline function _is_simple_latin(s::AbstractString)
    @inbounds for i in 1:ncodeunits(s)
        codeunit(s, i) > 0x7f && return false
    end
    true
end

function set_string!(buf::Buffer, x::Int, y::Int,
                     str::AbstractString,
                     style::Style=RESET;
                     max_x::Int=right(buf.area))
    # Strip ANSI escape SEQUENCES, then any leftover bare control chars (\r, \n, \b, …):
    # neither must ever reach a cell, or the terminal cursor jumps and smears the row.
    clean = _strip_controls(_strip_ansi(str))
    col = x
    clip = min(max_x, right(buf.area))

    # Fast path: pure ASCII — no grapheme segmentation needed
    if _is_simple_latin(clean)
        for ch in clean
            col > clip && break
            in_bounds(buf, col, y) && set_char!(buf, col, y, ch, style)
            col += 1
        end
        return col
    end

    # Slow path: grapheme-aware for combining marks and wide chars. A grapheme of
    # one codepoint (most non-ASCII text) is written as a Char without allocating;
    # only real clusters become a String glyph.
    last_drawn_col = x - 1
    state = Ref{Int32}(0)
    i, n = firstindex(clean), ncodeunits(clean)
    while i <= n
        j, k = _grapheme_span(clean, i, state)
        start, i = i, k
        col > clip && break
        single = j == start
        ch = clean[start]
        glyph = single ? "" : String(SubString(clean, start, j))
        w = single ? textwidth(ch) : grapheme_width(glyph)
        if w == 0
            last_drawn_col >= x && _append_glyph!(buf, last_drawn_col, y, single ? string(ch) : glyph)
            continue
        end
        if w == 2
            if col + 1 > clip
                # Wide char at boundary — pad won't fit, place space instead
                in_bounds(buf, col, y) && set_char!(buf, col, y, EMPTY_CHAR, style)
                col += 1
                continue
            end
            in_bounds(buf, col, y) && (single ? set_char!(buf, col, y, ch, style) : _set_glyph!(buf, col, y, glyph, style))
            in_bounds(buf, col + 1, y) && set_char!(buf, col + 1, y, WIDE_CHAR_PAD, style)
        else
            in_bounds(buf, col, y) && (single ? set_char!(buf, col, y, ch, style) : _set_glyph!(buf, col, y, glyph, style))
        end
        last_drawn_col = col
        col += max(w, 1)
    end
    col
end

function set_string!(buf::Buffer, x::Int, y::Int,
                     str::AbstractString, style::Style, area::Rect)
    set_string!(buf, x, y, str, style; max_x=right(area))
end

function set_style!(buf::Buffer, rect::Rect, style::Style)
    for row in rect.y:min(bottom(rect), bottom(buf.area))
        for col in rect.x:min(right(rect), right(buf.area))
            i = buf_index(buf, col, row)
            @inbounds buf.content[i] = Cell(
                buf.content[i].char, style, buf.content[i].suffix,
            )
        end
    end
end

function reset!(buf::Buffer)
    fill!(buf.content, Cell())
end

function resize_buf!(buf::Buffer, new_area::Rect)
    buf.area = new_area
    n = max(0, area(new_area))
    Base.resize!(buf.content, n)
    fill!(buf.content, Cell())
end

"""
    buffer_to_text(buf::Buffer, rect::Rect) → String

Extract the visible text from a rectangular region of the buffer.
Trailing spaces on each line are stripped; trailing blank lines removed.
"""
function buffer_to_text(buf::Buffer, rect::Rect)
    lines = String[]
    for row in rect.y:min(bottom(rect), bottom(buf.area))
        chunks = String[]
        for col in rect.x:min(right(rect), right(buf.area))
            if in_bounds(buf, col, row)
                cell = buf.content[buf_index(buf, col, row)]
                ch = cell.char
                ch == WIDE_CHAR_PAD && continue   # skip trailing cell of wide chars
                push!(chunks, cell_glyph(cell))
            end
        end
        push!(lines, rstrip(join(chunks)))
    end
    # Remove trailing blank lines
    while !isempty(lines) && isempty(lines[end])
        pop!(lines)
    end
    join(lines, '\n')
end
