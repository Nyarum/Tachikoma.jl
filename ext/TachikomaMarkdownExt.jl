module TachikomaMarkdownExt

using Tachikoma
using CommonMark

# ── Public entry point ───────────────────────────────────────────────

function Tachikoma.markdown_to_spans(md::AbstractString, width::Int;
                                      h1_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SKY.c400, bold=true),
                                      h2_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SKY.c500, bold=true),
                                      h3_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SKY.c600, bold=true),
                                      bold_style::Tachikoma.Style = Tachikoma.Style(bold=true),
                                      emph_style::Tachikoma.Style = Tachikoma.Style(dim=true),
                                      code_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.GREEN.c400,
                                                                                     bg=Tachikoma.SLATE.c800),
                                      link_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.BLUE.c400),
                                      quote_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SLATE.c400),
                                      text_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SLATE.c200),
                                      hr_style::Tachikoma.Style = Tachikoma.Style(fg=Tachikoma.SLATE.c600),
                                      # Finer-grained roles; defaults keep the shared styles above.
                                      code_block_style::Tachikoma.Style = code_style,
                                      quote_border_style::Tachikoma.Style = quote_style,
                                      # Text inside quotes; `nothing` keeps text_style (quote_style is the bar).
                                      quote_text_style::Union{Nothing,Tachikoma.Style} = nothing,
                                      list_marker_style::Tachikoma.Style = text_style,
                                      table_head_style::Tachikoma.Style = Tachikoma.Style(fg=text_style.fg, bold=true),
                                      table_border_style::Tachikoma.Style = hr_style,
                                      # TokenKind -> Style for highlighted code; NoColor fg keeps the code color.
                                      token_style::Function = Tachikoma.token_style,
                                      table_overflow::Symbol = :truncate,
                                      show_link_urls::Bool = false)
    table_overflow in (:truncate, :wrap) || throw(ArgumentError("invalid table_overflow"))
    width < 1 && return [Tachikoma.Span[]]
    parser = CommonMark.Parser()
    CommonMark.enable!(parser, CommonMark.TableRule())
    if isdefined(CommonMark, :TaskListRule)
        CommonMark.enable!(parser, CommonMark.TaskListRule())
    end
    ast = parser(md)
    ctx = WalkContext(width, h1_style, h2_style, h3_style,
                      bold_style, emph_style, code_style, link_style,
                      quote_style, text_style, hr_style, table_overflow, show_link_urls,
                      code_block_style, quote_border_style, list_marker_style,
                      table_head_style, table_border_style, token_style, quote_text_style)
    _walk_blocks!(ctx, ast)
    # Remove trailing blank line if present
    if !isempty(ctx.lines) && _is_blank_line(ctx.lines[end])
        pop!(ctx.lines)
    end
    isempty(ctx.lines) ? [Tachikoma.Span[]] : ctx.lines
end

# ── Context ──────────────────────────────────────────────────────────

struct WalkContext
    width::Int
    h1::Tachikoma.Style
    h2::Tachikoma.Style
    h3::Tachikoma.Style
    bold::Tachikoma.Style
    emph::Tachikoma.Style
    code::Tachikoma.Style
    link::Tachikoma.Style
    quote_s::Tachikoma.Style
    text::Tachikoma.Style
    hr::Tachikoma.Style
    table_overflow::Symbol
    show_link_urls::Bool
    code_block::Tachikoma.Style
    quote_border::Tachikoma.Style
    list_marker::Tachikoma.Style
    table_head::Tachikoma.Style
    table_border::Tachikoma.Style
    token_style::Function
    quote_text::Union{Nothing,Tachikoma.Style}
    lines::Vector{Vector{Tachikoma.Span}}
    prefix::Vector{String}         # stack of line prefixes (blockquote nesting)
    prefix_style::Vector{Tachikoma.Style}
end

function WalkContext(width, h1, h2, h3, bold, emph, code, link, quote_s, text, hr, table_overflow, show_link_urls,
                     code_block=code, quote_border=quote_s, list_marker=text,
                     table_head=Tachikoma.Style(fg=text.fg, bold=true), table_border=hr,
                     token_style=Tachikoma.token_style, quote_text=nothing)
    WalkContext(width, h1, h2, h3, bold, emph, code, link, quote_s, text, hr, table_overflow, show_link_urls,
                code_block, quote_border, list_marker, table_head, table_border, token_style, quote_text,
                Vector{Tachikoma.Span}[], String[], Tachikoma.Style[])
end

# Same output buffers and prefixes, different body text style.
_with_text(ctx::WalkContext, text::Tachikoma.Style) =
    WalkContext((f === :text ? text : getfield(ctx, f) for f in fieldnames(WalkContext))...)

_current_prefix(ctx::WalkContext) = Tachikoma.truncate_to_width(join(ctx.prefix), max(0, ctx.width - 2); ellipsis="")
_current_prefix_len(ctx::WalkContext) = Tachikoma.display_width(_current_prefix(ctx))

function _push_line!(ctx::WalkContext, spans::Vector{Tachikoma.Span})
    pfx = _current_prefix(ctx)
    if !isempty(pfx)
        pstyle = isempty(ctx.prefix_style) ? ctx.text : ctx.prefix_style[end]
        spans = [Tachikoma.Span(pfx, pstyle); spans]
    end
    # Safety net for tiny widths and deeply nested decorative prefixes.
    if sum(s -> Tachikoma.display_width(s.content), spans; init=0) > ctx.width
        append!(ctx.lines, _wrap_spans(spans, ctx.width, ctx.text; word_wrap=false))
    else
        push!(ctx.lines, spans)
    end
end

function _push_blank!(ctx::WalkContext)
    _push_line!(ctx, Tachikoma.Span[])
end

_is_blank_line(spans::Vector{Tachikoma.Span}) =
    isempty(spans) || all(s -> isempty(strip(s.content)), spans)

# ── Block-level walker ───────────────────────────────────────────────

function _walk_blocks!(ctx::WalkContext, node)
    child = node.first_child
    while !CommonMark.isnull(child)
        _handle_block!(ctx, child)
        child = child.nxt
    end
end

function _handle_block!(ctx::WalkContext, node)
    t = node.t
    if t isa CommonMark.Heading
        _handle_heading!(ctx, node)
    elseif t isa CommonMark.Paragraph
        _handle_paragraph!(ctx, node)
    elseif t isa CommonMark.CodeBlock
        _handle_codeblock!(ctx, node)
    elseif t isa CommonMark.BlockQuote
        _handle_blockquote!(ctx, node)
    elseif t isa CommonMark.List
        _handle_list!(ctx, node)
    elseif t isa CommonMark.ThematicBreak
        _handle_hr!(ctx)
    elseif t isa CommonMark.Table
        _handle_table!(ctx, node)
    elseif t isa CommonMark.Document
        _walk_blocks!(ctx, node)
    else
        # Unknown literal blocks (including HTML) remain visible, never executed.
        if !isempty(node.literal)
            _emit_wrapped!(ctx, [Tachikoma.Span(node.literal, ctx.text)])
            _push_blank!(ctx)
        else
            _walk_blocks!(ctx, node)
        end
    end
end

# ── Heading ──────────────────────────────────────────────────────────

function _handle_heading!(ctx::WalkContext, node)
    level = node.t.level
    style = level == 1 ? ctx.h1 : level == 2 ? ctx.h2 : ctx.h3
    spans = _collect_inlines(ctx, node, style)
    _emit_wrapped!(ctx, spans)
    _push_blank!(ctx)
end

# ── Paragraph ────────────────────────────────────────────────────────

function _handle_paragraph!(ctx::WalkContext, node)
    spans = _collect_inlines(ctx, node, ctx.text)
    avail = ctx.width - _current_prefix_len(ctx)
    wrapped = _wrap_spans(spans, avail, ctx.text)
    for line in wrapped
        _push_line!(ctx, line)
    end
    _push_blank!(ctx)
end

# ── CodeBlock ────────────────────────────────────────────────────────

# Syntax highlighting for fenced code blocks.
# Uses tokenizers from Tachikoma core (codeeditor.jl + tokenizers.jl).
# Supported: Julia, Python, Shell, TypeScript/JavaScript.
# Other languages fall back to uniform code_style.

function _tokens_to_spans(chars::Vector{Char}, tokens::Vector{Tachikoma.Token},
                           code_style::Tachikoma.Style, token_style::Function=Tachikoma.token_style)
    code_bg = code_style.bg
    isempty(tokens) && return [Tachikoma.Span(String(chars), code_style)]
    spans = Tachikoma.Span[]
    pos = 1
    for tok in tokens
        if tok.start > pos
            push!(spans, Tachikoma.Span(String(chars[pos:tok.start-1]),
                                        code_style))
        end
        ts = token_style(tok.kind)
        merged = Tachikoma.Style(fg=ts.fg isa Tachikoma.NoColor ? code_style.fg : ts.fg, bg=code_bg,
                                  bold=ts.bold, dim=ts.dim,
                                  italic=ts.italic, underline=ts.underline)
        push!(spans, Tachikoma.Span(String(chars[tok.start:tok.stop]), merged))
        pos = tok.stop + 1
    end
    if pos <= length(chars)
        push!(spans, Tachikoma.Span(String(chars[pos:end]),
                                    code_style))
    end
    spans
end

function _highlight_code_line(line::AbstractString, code_style::Tachikoma.Style,
                               lang::AbstractString, token_style::Function=Tachikoma.token_style)
    chars = collect(Char, line)
    tokens = Tachikoma.tokenize_code(lang, chars)
    tokens === nothing && return nothing
    _tokens_to_spans(chars, tokens, code_style, token_style)
end

function _handle_codeblock!(ctx::WalkContext, node)
    info = node.t.info
    lang = isempty(strip(string(info))) ? "" : lowercase(first(split(string(info))))

    code_text = node.literal
    code_text === nothing && (code_text = "")
    # CommonMark supplies one structural final newline; preserve all other
    # whitespace, including trailing spaces and blank lines in the code.
    code_lines = split(code_text, '\n'; keepempty=true)
    endswith(code_text, "\n") && pop!(code_lines)
    isempty(code_lines) && push!(code_lines, "")
    for line in code_lines
        spans = _highlight_code_line(line, ctx.code_block, lang, ctx.token_style)
        spans === nothing && (spans = [Tachikoma.Span(string(line), ctx.code_block)])
        _emit_wrapped!(ctx, spans; word_wrap=false)
    end
    _push_blank!(ctx)
end

# ── BlockQuote ───────────────────────────────────────────────────────

function _handle_blockquote!(ctx::WalkContext, node)
    start = length(ctx.lines)
    push!(ctx.prefix, "│ ")
    push!(ctx.prefix_style, ctx.quote_border)
    _walk_blocks!(ctx.quote_text === nothing ? ctx : _with_text(ctx, ctx.quote_text), node)
    _drop_trailing_blank!(ctx, start)
    pop!(ctx.prefix)
    pop!(ctx.prefix_style)
    _push_blank!(ctx)
end

# Inner blocks end with a blank carrying the container prefix ("│ ", list
# indent). Call while that prefix is active; the caller then pushes one blank
# at the container's own level.
function _drop_trailing_blank!(ctx::WalkContext, start::Int)
    length(ctx.lines) > start || return
    text = rstrip(join(s.content for s in ctx.lines[end]))
    (isempty(text) || text == rstrip(_current_prefix(ctx))) && pop!(ctx.lines)
    nothing
end

# ── List ─────────────────────────────────────────────────────────────

function _handle_list!(ctx::WalkContext, node)
    is_ordered = node.t.list_data.type === :ordered
    start_num = node.t.list_data.start
    idx = start_num
    start = length(ctx.lines)
    child = node.first_child
    while !CommonMark.isnull(child)
        if child.t isa CommonMark.Item || _is_task_item(child.t)
            _handle_list_item!(ctx, child, is_ordered, idx)
            idx += 1
        end
        child = child.nxt
    end
    # A sublist that closes its parent item stays tight with the next item.
    parent = node.parent
    nested = !CommonMark.isnull(parent) && (parent.t isa CommonMark.Item || _is_task_item(parent.t))
    if !nested || !CommonMark.isnull(node.nxt)
        _drop_trailing_blank!(ctx, start)
        _push_blank!(ctx)
    end
end

_is_task_item(t) = isdefined(CommonMark, :TaskItem) && t isa CommonMark.TaskItem

function _handle_list_item!(ctx::WalkContext, node, is_ordered::Bool, idx::Int)
    bullet = if _is_task_item(node.t)
        hasproperty(node.t, :checked) && node.t.checked ? "  [x] " : "  [ ] "
    elseif is_ordered
        "  $idx. "
    else
        "  * "
    end
    # First child paragraph gets the bullet prefix inline
    first_block = true
    child = node.first_child
    while !CommonMark.isnull(child)
        if first_block && child.t isa CommonMark.Paragraph
            spans = _collect_inlines(ctx, child, ctx.text)
            indent_width = min(Tachikoma.display_width(bullet), max(0, ctx.width - _current_prefix_len(ctx) - 2))
            marker = Tachikoma.truncate_to_width(bullet, indent_width; ellipsis="")
            avail = ctx.width - _current_prefix_len(ctx) - Tachikoma.display_width(marker)
            wrapped = _wrap_spans(spans, avail, ctx.text)
            for (i, line) in enumerate(wrapped)
                prefix = i == 1 ? Tachikoma.Span(marker, ctx.list_marker) :
                    Tachikoma.Span(" "^Tachikoma.display_width(marker), ctx.text)
                _push_line!(ctx, [prefix; line])
            end
            first_block = false
        else
            if first_block
                _push_line!(ctx, [Tachikoma.Span(bullet, ctx.list_marker)])
                first_block = false
            end
            # Indent continuation
            indent = " "^length(bullet)
            push!(ctx.prefix, indent)
            push!(ctx.prefix_style, ctx.text)
            _handle_block!(ctx, child)
            pop!(ctx.prefix)
            pop!(ctx.prefix_style)
        end
        child = child.nxt
    end
    first_block && _emit_wrapped!(ctx, [Tachikoma.Span(bullet, ctx.list_marker)])
end

# ── Thematic break ───────────────────────────────────────────────────

function _handle_hr!(ctx::WalkContext)
    avail = ctx.width - _current_prefix_len(ctx)
    _push_line!(ctx, [Tachikoma.Span("─"^max(1, avail), ctx.hr)])
    _push_blank!(ctx)
end

# ── Table ────────────────────────────────────────────────────────────

# Columns shrink widest-first. Legacy :truncate preserves the original API;
# :wrap keeps values complete, stacking labelled cells on very narrow screens.
function _handle_table!(ctx::WalkContext, node)
    header_style = ctx.table_head
    rows = Tuple{Bool,Vector{Tuple{Vector{Tachikoma.Span},Symbol}}}[]
    for (n, entering) in node
        (entering && n.t isa CommonMark.TableRow) || continue
        cells = Tuple{Vector{Tachikoma.Span},Symbol}[]
        header = false
        c = n.first_child
        while !CommonMark.isnull(c)
            if c.t isa CommonMark.TableCell
                header |= c.t.header
                push!(cells, (_collect_inlines(ctx, c, c.t.header ? header_style : ctx.text), c.t.align))
            end
            c = c.nxt
        end
        push!(rows, (header, cells))
    end
    isempty(rows) && return

    ncols = maximum(r -> length(r[2]), rows)
    ncols == 0 && return
    widths = zeros(Int, ncols)
    for (_, cells) in rows, (j, (spans, _)) in enumerate(cells)
        widths[j] = max(widths[j], _spans_width(spans))
    end
    widths .= max.(widths, 1)
    sep = " │ "
    avail = ctx.width - _current_prefix_len(ctx)
    if ctx.table_overflow == :wrap && avail < sum(min.(widths, 8)) + Tachikoma.display_width(sep) * (ncols - 1)
        # Too narrow even for useful columns: stack labelled cells per row.
        headers = rows[1][1] ? rows[1][2] : nothing
        for (header, cells) in rows
            header && continue
            for (j, (cell, _)) in enumerate(cells)
                label = headers === nothing ? [Tachikoma.Span("$j: ", header_style)] :
                    [headers[j][1]; Tachikoma.Span(": ", ctx.text)]
                _emit_wrapped!(ctx, [label; cell])
            end
            _push_blank!(ctx)
        end
        # A table consisting only of headers must remain visible as well.
        if all(first, rows)
            for (cell, _) in rows[1][2]
                _emit_wrapped!(ctx, cell)
            end
            _push_blank!(ctx)
        end
        return
    end
    while sum(widths) + Tachikoma.display_width(sep) * (ncols - 1) > avail && maximum(widths) > 1
        widths[argmax(widths)] -= 1
    end

    for (i, (header, cells)) in enumerate(rows)
        cell_lines = [j <= length(cells) ?
            (ctx.table_overflow == :wrap ? _wrap_spans(cells[j][1], widths[j], ctx.text) : [cells[j][1]]) :
            [Tachikoma.Span[]] for j in 1:ncols]
        for k in 1:maximum(length, cell_lines)
            line = Tachikoma.Span[]
            for j in 1:ncols
                j > 1 && push!(line, Tachikoma.Span(sep, ctx.table_border))
                spans = k <= length(cell_lines[j]) ? cell_lines[j][k] : Tachikoma.Span[]
                align = j <= length(cells) ? cells[j][2] : :left
                append!(line, _fit_cell(spans, widths[j], align, ctx.text))
            end
            _push_line!(ctx, line)
        end
        # Wrapped logical rows need a visible boundary, not just the header.
        if (header && (i == length(rows) || !rows[i + 1][1])) ||
           (ctx.table_overflow == :wrap && !header && i < length(rows))
            _push_line!(ctx, [Tachikoma.Span(join(("─"^w for w in widths), "─┼─"), ctx.table_border)])
        end
    end
    _push_blank!(ctx)
end

_spans_width(spans) = Tachikoma.display_width(join(s.content for s in spans))

# `spans` cut to `w` display columns (ending in "…" if cut) and padded to exactly `w` per `align`.
function _fit_cell(spans::Vector{Tachikoma.Span}, w::Int, align::Symbol, pad_style::Tachikoma.Style)
    out = spans
    if _spans_width(spans) > w
        out = Tachikoma.Span[]
        budget = w - 1   # room for the ellipsis
        for s in spans
            budget <= 0 && break
            sw = Tachikoma.display_width(s.content)
            if sw <= budget
                push!(out, s)
                budget -= sw
            else
                cut = Tachikoma.truncate_to_width(s.content, budget; ellipsis = "")
                isempty(cut) || push!(out, Tachikoma.Span(cut, s.style))
                budget = 0
            end
        end
        push!(out, Tachikoma.Span("…", isempty(out) ? pad_style : out[end].style))
    end
    gap = w - _spans_width(out)
    gap <= 0 && return out
    left = align === :right ? gap : align === :center ? gap ÷ 2 : 0
    padded = Tachikoma.Span[]
    left > 0 && push!(padded, Tachikoma.Span(" "^left, pad_style))
    append!(padded, out)
    gap - left > 0 && push!(padded, Tachikoma.Span(" "^(gap - left), pad_style))
    return padded
end

# ── Inline collector ─────────────────────────────────────────────────

function _collect_inlines(ctx::WalkContext, node, base_style::Tachikoma.Style)
    spans = Tachikoma.Span[]
    style_stack = Tachikoma.Style[base_style]
    for (n, entering) in node
        n === node && continue  # skip the node itself
        _t = n.t
        if _t isa CommonMark.Text
            push!(spans, Tachikoma.Span(n.literal, style_stack[end]))
        elseif _t isa CommonMark.Code
            push!(spans, Tachikoma.Span(n.literal, _merge_style(style_stack[end], ctx.code)))
        elseif _t isa CommonMark.Strong
            if entering
                push!(style_stack, _merge_style(style_stack[end], ctx.bold))
            else
                length(style_stack) > 1 && pop!(style_stack)
            end
        elseif _t isa CommonMark.Emph
            if entering
                push!(style_stack, _merge_style(style_stack[end], ctx.emph))
            else
                length(style_stack) > 1 && pop!(style_stack)
            end
        elseif _t isa CommonMark.Link
            if entering
                push!(style_stack, _merge_style(style_stack[end], ctx.link))
            else
                length(style_stack) > 1 && pop!(style_stack)
                if ctx.show_link_urls && !isempty(n.t.destination)
                    label = join(child.literal for (child, enter) in n if enter && child.t isa CommonMark.Text)
                    label == n.t.destination || push!(spans, Tachikoma.Span(" (" * n.t.destination * ")", _merge_style(style_stack[end], ctx.link)))
                end
            end
        elseif _t isa CommonMark.Image
            if entering
                push!(spans, Tachikoma.Span("[Image: ", ctx.text))
            else
                push!(spans, Tachikoma.Span("]", ctx.text))
            end
        elseif _t isa CommonMark.SoftBreak
            push!(spans, Tachikoma.Span(" ", style_stack[end]))
        elseif _t isa CommonMark.LineBreak
            push!(spans, Tachikoma.Span("\n", style_stack[end]))
        elseif entering && !isempty(n.literal)
            # Preserve unknown literal inline nodes, including raw HTML.
            push!(spans, Tachikoma.Span(n.literal, style_stack[end]))
        end
    end
    spans
end

# ── Word wrapper ─────────────────────────────────────────────────────

# Grapheme-aware wrapping across Span boundaries. A formatting boundary is not
# a word boundary; styles follow the first codepoint of each display grapheme.
function _wrap_spans(spans::Vector{Tachikoma.Span}, width::Int,
                     space_style::Tachikoma.Style=Tachikoma.Style(); word_wrap::Bool=true)
    width = max(1, width)
    source = join(s.content for s in spans)
    units = Tuple{String,Tachikoma.Style}[]
    si, edge = 1, isempty(spans) ? 0 : ncodeunits(spans[1].content)
    pos = 1
    for graph in Base.Unicode.graphemes(source)
        while si < length(spans) && pos > edge
            si += 1
            edge += ncodeunits(spans[si].content)
        end
        style = isempty(spans) ? space_style : spans[si].style
        # A wide glyph cannot be represented in one terminal column. Make
        # progress with a visible replacement rather than writing out of bounds.
        g = Tachikoma.display_width(graph) > width ? "�" : String(graph)
        push!(units, (g, style))
        pos += ncodeunits(graph)
    end
    lines = Vector{Tachikoma.Span}[]
    current = Tachikoma.Span[]
    col = 0
    function emit(g, style)
        if !isempty(current) && current[end].style == style
            current[end] = Tachikoma.Span(current[end].content * g, style)
        else
            push!(current, Tachikoma.Span(g, style))
        end
        col += Tachikoma.display_width(g)
    end
    function flush()
        push!(lines, current)
        current = Tachikoma.Span[]
        col = 0
    end
    pending = Tuple{String,Tachikoma.Style}[]
    i = 1
    while i <= length(units)
        g, style = units[i]
        if g == "\n"
            empty!(pending)
            flush()
            i += 1
        elseif !word_wrap
            # Expand tabs deterministically without changing the raw source.
            chars = g == "\t" ? fill(" ", 4 - col % 4) : [g]
            for ch in chars
                col + Tachikoma.display_width(ch) > width && flush()
                emit(ch, style)
            end
            i += 1
        elseif all(isspace, g)
            push!(pending, (" ", style))
            i += 1
        else
            j = i
            while j <= length(units) && !all(isspace, units[j][1])
                j += 1
            end
            wordwidth = sum(k -> Tachikoma.display_width(units[k][1]), i:j-1; init=0)
            if col > 0 && col + length(pending) + wordwidth > width
                flush()
                empty!(pending)
            end
            for (space, ss) in pending
                col < width && emit(space, ss)
            end
            empty!(pending)
            for k in i:j-1
                ch, st = units[k]
                col + Tachikoma.display_width(ch) > width && flush()
                emit(ch, st)
            end
            i = j
        end
    end
    # Prose trailing whitespace has no visual meaning; code takes the other path.
    (!isempty(current) || isempty(lines)) && push!(lines, current)
    lines
end

function _merge_style(base::Tachikoma.Style, over::Tachikoma.Style)
    Tachikoma.Style(fg=over.fg isa Tachikoma.NoColor ? base.fg : over.fg,
        bg=over.bg isa Tachikoma.NoColor ? base.bg : over.bg,
        bold=base.bold || over.bold, dim=base.dim || over.dim,
        italic=base.italic || over.italic, underline=base.underline || over.underline,
        strikethrough=base.strikethrough || over.strikethrough,
        hyperlink=isempty(over.hyperlink) ? base.hyperlink : over.hyperlink)
end

function _emit_wrapped!(ctx::WalkContext, spans::Vector{Tachikoma.Span}; word_wrap=true)
    for line in _wrap_spans(spans, ctx.width - _current_prefix_len(ctx), ctx.text; word_wrap)
        _push_line!(ctx, line)
    end
end

function __init__()
    Tachikoma._markdown_to_spans_fn[] = Tachikoma.markdown_to_spans
    @debug "Tachikoma: Markdown rendering enabled"
end

end # module
