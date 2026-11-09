using CommonMark

# ── Helpers ──────────────────────────────────────────────────────────

function _spans_text(lines)
    join((join(s.content for s in line) for line in lines), "\n")
end

function _is_blank_line_test(spans)
    isempty(spans) || all(s -> isempty(strip(s.content)), spans)
end

# ── Tests ────────────────────────────────────────────────────────────

@testset "Markdown extension" begin

    @testset "markdown_extension_loaded after using CommonMark" begin
        @test T.markdown_extension_loaded()
    end

    @testset "Empty string" begin
        lines = T.markdown_to_spans("", 80)
        @test length(lines) >= 1
    end

    @testset "Single paragraph" begin
        lines = T.markdown_to_spans("Hello world", 80)
        text = _spans_text(lines)
        @test occursin("Hello world", text)
    end

    @testset "Heading levels" begin
        md = "# H1\n\n## H2\n\n### H3"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("H1", text)
        @test occursin("H2", text)
        @test occursin("H3", text)
    end

    @testset "Heading style applied" begin
        lines = T.markdown_to_spans("# Title", 80)
        line = first(l for l in lines if !isempty(l))
        @test any(s -> s.style.bold, line)
    end

    @testset "Bold text" begin
        lines = T.markdown_to_spans("Some **bold** text", 80)
        all_spans = vcat(lines...)
        bold_spans = filter(s -> s.style.bold && occursin("bold", s.content), all_spans)
        @test !isempty(bold_spans)
    end

    @testset "Inline code" begin
        lines = T.markdown_to_spans("Use `code` here", 80)
        all_spans = vcat(lines...)
        code_spans = filter(s -> s.content == "code", all_spans)
        @test !isempty(code_spans)
        # Code spans should have a background color set (not NoColor)
        @test !(code_spans[1].style.bg isa T.NoColor)
    end

    @testset "Code block" begin
        md = "```julia\nfoo()\nbar()\n```"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("foo()", text)
        @test occursin("bar()", text)
        # Language label is not rendered as text — it's used for syntax highlighting
    end

    @testset "Blockquote" begin
        md = "> quoted text"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("│", text)
        @test occursin("quoted text", text)
    end

    @testset "Nested blockquote" begin
        md = "> outer\n> > inner"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("inner", text)
        # Should have double prefix
        inner_line = first(l for l in lines if any(s -> occursin("inner", s.content), l))
        prefix_text = join(s.content for s in inner_line)
        @test count("│", prefix_text) >= 2
    end

    @testset "Unordered list" begin
        md = "- Item A\n- Item B\n- Item C"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("Item A", text)
        @test occursin("Item B", text)
        @test occursin("Item C", text)
        @test occursin("*", text)
    end

    @testset "Ordered list" begin
        md = "1. First\n2. Second\n3. Third"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("1.", text)
        @test occursin("First", text)
        @test occursin("2.", text)
    end

    @testset "Thematic break" begin
        md = "Above\n\n---\n\nBelow"
        lines = T.markdown_to_spans(md, 40)
        all_spans = vcat(lines...)
        hr_spans = filter(s -> occursin("─", s.content), all_spans)
        @test !isempty(hr_spans)
        @test length(hr_spans[1].content) >= 30  # fills width
    end

    @testset "Link text preserved" begin
        md = "Click [here](https://example.com) please"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("here", text)
    end

    @testset "Image fallback" begin
        md = "![Alt text](img.png)"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("[Image:", text)
        @test occursin("Alt text", text)
    end

    @testset "Word wrap at width" begin
        md = "alpha bravo chars delta echo foxt golf hotel india juliet"
        lines = T.markdown_to_spans(md, 20)
        non_blank = filter(l -> !all(s -> isempty(strip(s.content)), l), lines)
        @test length(non_blank) >= 3
        for line in non_blank
            line_len = sum(length(s.content) for s in line)
            @test line_len <= 25  # some tolerance for word boundaries
        end
    end

    @testset "Word wrap preserves all words" begin
        md = "one two three four five six"
        lines = T.markdown_to_spans(md, 10)
        text = _spans_text(lines)
        for word in ["one", "two", "three", "four", "five", "six"]
            @test occursin(word, text)
        end
    end

    @testset "Long single word not dropped" begin
        md = "supercalifragilisticexpialidocious"
        lines = T.markdown_to_spans(md, 10)
        text = _spans_text(lines)
        @test replace(text, "\n"=>"") == "supercalifragilisticexpialidocious"
        @test all(l -> sum(textwidth(s.content) for s in l; init=0) <= 10, lines)
    end

    @testset "Width=1 does not infinite loop" begin
        lines = T.markdown_to_spans("test", 1)
        @test !isempty(lines)
    end

    @testset "Custom styles" begin
        custom_h1 = T.Style(fg=T.RED.c400, bold=true)
        lines = T.markdown_to_spans("# Red Title", 80; h1_style=custom_h1)
        line = first(l for l in lines if !isempty(l))
        @test any(s -> s.style.fg == T.RED.c400, line)
    end

    @testset "ScrollPane integration" begin
        md = "# Hello\n\nA paragraph.\n\n- Item 1\n- Item 2"
        lines = T.markdown_to_spans(md, 40)
        sp = T.ScrollPane(lines)
        tb = T.TestBackend(60, 20)
        T.render_widget!(tb, sp)
        rendered = T.row_text(tb, 1)
        @test length(strip(rendered)) > 0
    end

    @testset "Multiple paragraphs separated" begin
        md = "Para one.\n\nPara two."
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("Para one", text)
        @test occursin("Para two", text)
        blank_count = count(_is_blank_line_test, lines)
        @test blank_count >= 1
    end

    @testset "Code block with no language" begin
        md = "```\nplain code\n```"
        lines = T.markdown_to_spans(md, 80)
        text = _spans_text(lines)
        @test occursin("plain code", text)
    end

    @testset "Mixed inline formatting" begin
        md = "Normal **bold** and `code` and *emph*"
        lines = T.markdown_to_spans(md, 80)
        all_spans = vcat(lines...)
        @test any(s -> s.content == "bold" && s.style.bold, all_spans)
        @test any(s -> s.content == "code", all_spans)
        @test any(s -> s.content == "emph" && s.style.dim, all_spans)
    end

    @testset "Tables" begin
        _line_width(line) = sum(s -> textwidth(s.content), line; init = 0)
        md = """
        | name | count | note |
        |:-----|------:|:----:|
        | alpha | 1 | first |
        | b | 22 | **bold** |
        """
        lines = filter(!_is_blank_line_test, T.markdown_to_spans(md, 80))
        texts = [join(s.content for s in l) for l in lines]
        @test length(lines) == 4   # header, rule, two rows
        @test occursin("name", texts[1]) && occursin("count", texts[1])
        @test all(s -> s.style.bold, filter(s -> occursin("name", s.content), lines[1]))
        @test occursin("┼", texts[2])
        @test occursin("alpha", texts[3]) && occursin("first", texts[3])
        @test any(s -> s.content == "bold" && s.style.bold, lines[4])
        @test length(unique(_line_width.(lines))) == 1   # every row is the same width
        # Right-aligned column: the shorter number is padded on the left.
        @test occursin(" 1 │", texts[3]) && occursin("22 │", texts[4])

        narrow = filter(!_is_blank_line_test, T.markdown_to_spans(md, 16))
        @test length(narrow) == 4
        @test all(l -> _line_width(l) <= 16, narrow)
        @test any(l -> any(s -> occursin("…", s.content), l), narrow)
    end
end

# ── MarkdownPane widget tests ──────────────────────────────────────

@testset "MarkdownPane widget" begin

    @testset "Construction" begin
        mp = T.MarkdownPane("# Hello\n\nWorld")
        @test mp.source == "# Hello\n\nWorld"
        @test mp.pane isa T.ScrollPane
        @test mp.last_width == 80
    end

    @testset "Construction with custom width" begin
        mp = T.MarkdownPane("test"; width=40)
        @test mp.last_width == 40
    end

    @testset "focusable returns true" begin
        mp = T.MarkdownPane("test")
        @test T.focusable(mp) == true
    end

    @testset "Render with TestBackend" begin
        mp = T.MarkdownPane("# Title\n\nSome text here";
            block=T.Block(title="MD"))
        tb = T.TestBackend(60, 15)
        T.render_widget!(tb, mp)
        found = T.find_text(tb, "Title")
        @test found !== nothing
    end

    @testset "set_markdown! updates source" begin
        mp = T.MarkdownPane("old content")
        T.set_markdown!(mp, "new content")
        @test mp.source == "new content"
    end

    @testset "set_markdown! updates width" begin
        mp = T.MarkdownPane("test"; width=80)
        T.set_markdown!(mp, "test"; width=40)
        @test mp.last_width == 40
    end

    @testset "Responsive reflow changes last_width" begin
        mp = T.MarkdownPane("Some long text that should reflow";
            width=80,
            block=T.Block(title="MD"))
        # Render into a narrow area — should trigger reflow
        tb = T.TestBackend(30, 10)
        T.render_widget!(tb, mp)
        # last_width should now reflect the narrower content area
        # 30 - 2 (borders) - 1 (scrollbar) = 27
        @test mp.last_width == 27
    end

    @testset "handle_key! delegation" begin
        mp = T.MarkdownPane("line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10")
        # Render first to set up last_area
        tb = T.TestBackend(40, 5)
        T.render_widget!(tb, mp)
        # Scroll down
        result = T.handle_key!(mp, T.KeyEvent(:down, '\0'))
        @test result == true
    end

    @testset "Custom styles" begin
        custom_h1 = T.Style(fg=T.RED.c400, bold=true)
        mp = T.MarkdownPane("# Red Title"; h1_style=custom_h1)
        @test mp.h1_style.fg == T.RED.c400
    end

    @testset "handle_mouse! delegation" begin
        mp = T.MarkdownPane("test content")
        # Without rendering, mouse events should return false (no area set)
        evt = T.MouseEvent(1, 1, T.mouse_scroll_down, T.mouse_press, false, false, false)
        result = T.handle_mouse!(mp, evt)
        @test result == false
    end
end

@testset "Markdown correctness regressions" begin
    widthof(line) = sum(s -> textwidth(s.content), line; init=0)
    textof(lines) = join((join(s.content for s in line) for line in lines), "\n")
    md = "# Привет 世界 e\u0301\n\n***bolditalic*** abc**def**ghi\n\n> quote 世界 世界\n> > deep\n\n- long list of words to wrap correctly\n  - child\n\n```python\nx = 12345678901234567890  \n\n```\n\n|A|B|C|\n|-|-|-|\n|世界|value|long-value|\n\n<div>safe</div>"
    for w in (1, 2, 3, 5, 12, 20, 80)
        lines = T.markdown_to_spans(md, w; table_overflow=:wrap)
        @test all(l -> widthof(l) <= w, lines)
    end
    # A formatting boundary cannot act as a word boundary.
    lines = T.markdown_to_spans("xx abc**def**ghi", 10)
    @test textof(lines) == "xx\nabcdefghi"
    styled = T.markdown_to_spans("***both***", 80; emph_style=T.Style(italic=true), text_style=T.Style(fg=T.RED.c400))
    both = only(filter(s -> s.content == "both", vcat(styled...)))
    @test both.style.bold && both.style.italic
    @test both.style.fg == T.RED.c400
    @test textof(T.markdown_to_spans("first  \nsecond", 80)) == "first\nsecond"
    @test textof(T.markdown_to_spans("<div>safe</div>", 80)) == "<div>safe</div>"
    @test occursin("<b>", textof(T.markdown_to_spans("a <b>b</b>", 80)))
    @test textof(T.markdown_to_spans("```unknown\na  \n\n```", 80)) == "a  \n"
    @test textof(T.markdown_to_spans("```unknown\n\tvalue\n```", 80)) == "    value"
    link = textof(T.markdown_to_spans("[here](https://example.com)", 80; show_link_urls=true))
    @test link == "here (https://example.com)"
    @test textof(T.markdown_to_spans("[https://example.com](https://example.com)", 80; show_link_urls=true)) == "https://example.com"
    list = T.markdown_to_spans("- one two three four five six", 14)
    @test length(list) > 1
    @test all(l -> startswith(join(s.content for s in l), "    "), list[2:end])
    # Combining marks crossing a formatting boundary stay in one grapheme.
    lines = T.markdown_to_spans("ab**c**\u0301d", 3)
    @test textof(lines) == "abc\u0301\nd"
    table = "|Name|Value|\n|---|---|\n|alpha|complete-value|"
    for w in (5, 14, 80)
        lines = T.markdown_to_spans(table, w; table_overflow=:wrap)
        @test all(l -> widthof(l) <= w, lines)
        @test !occursin('…', textof(lines))
        @test occursin("complete-value", replace(textof(lines), r"[\s│]"=>""))
    end
    @test_throws ArgumentError T.markdown_to_spans("a", 80; table_overflow=:invalid)
end

@testset "Terminal cluster coordinates and table boundaries" begin
    # Explicit expected columns, not a textwidth-derived oracle.
    for (glyph, columns) in [("✍️",2),("⚙️",2),("👩‍💻",2),("☝🏽",2),
                              ("🇷🇺",2),("1️⃣",2),("é",1),("世界",4),("⚙︎",1)]
        @test T.display_width(glyph) == columns
        b = T.Buffer(T.Rect(1,1,20,1))
        x = T.set_string!(b,1,1,glyph)
        @test x == columns + 1
        T.set_string!(b,x,1," │X")
        @test b.content[columns+2].char == '│'
        @test b.content[columns+3].char == 'X'
        if columns == 2
            @test b.content[2].char == T.WIDE_CHAR_PAD
        end
    end
    @test T.truncate_to_width("✍️X",2; ellipsis="") == "✍️"
    @test T.truncate_to_width("👩‍💻X",2; ellipsis="") == "👩‍💻"
    for (head,tail,columns) in (("✍","️ X",2),("👩","‍💻 X",2),("e","́ X",1))
        ext = Base.get_extension(T,:TachikomaMarkdownExt)
        lines = ext._wrap_spans([T.Span(head,T.Style(bold=true)),T.Span(tail)],20)
        b = T.Buffer(T.Rect(1,1,20,1))
        T.render(T.ScrollPane(lines; show_scrollbar=false),b.area,b)
        @test b.content[columns+1].char == ' '
        @test b.content[columns+2].char == 'X'
        @test !isempty(b.content[1].suffix)
        @test b.content[1].style.bold
    end
    md = "|A|B|C|\n|:-|:-:|-:|\n|✍️ words words|👩‍💻 mixed value|tail|\n|☝🏽 next|é combined|last|"
    for width in (29,30,31,45,80)
        lines = T.markdown_to_spans(md,width; table_overflow=:wrap)
        b = T.Buffer(T.Rect(1,1,width,length(lines)))
        T.render(T.ScrollPane(lines; show_scrollbar=false),b.area,b)
        coords = [[x for x in 1:width if b.content[T.buf_index(b,x,y)].char in ('│','┼')] for y in 1:length(lines)]
        nonempty = filter(!isempty,coords)
        @test !isempty(nonempty)
        @test all(==(first(nonempty)),nonempty)
        @test length(first(nonempty)) == 2
        @test count(l -> any(s -> occursin('┼',s.content),l),lines) == 2
        # Reconstruct each cell independently: do not allow a missing value to
        # pass because its text appears elsewhere in the table.
        cuts = [0; first(nonempty); width+1]
        for (j,expected) in enumerate(("✍️wordswords☝🏽next","👩‍💻mixedvalueécombined","taillast"))
            body = join(T.cell_glyph(b.content[T.buf_index(b,x,y)]) for y in 3:length(lines) for x in cuts[j]+1:cuts[j+1]-1 if b.content[T.buf_index(b,x,y)].char != T.WIDE_CHAR_PAD)
            @test replace(body,r"[\s─]"=>"") == expected
        end
    end
    # Exactly cross the readable-grid/stack threshold (3 columns of 8 + 6).
    md = "|HeaderAA|HeaderBB|HeaderCC|\n|-|-|-|\n|valueAAA|valueBBB|valueCCC|"
    for (width,grid) in ((29,false),(30,true),(31,true))
        text = _spans_text(T.markdown_to_spans(md,width; table_overflow=:wrap))
        @test occursin('│',text) == grid
        for value in ("valueAAA","valueBBB","valueCCC")
            @test occursin(value,replace(text,r"[\s│]"=>""))
        end
    end
end

@testset "Block separation after lists and quotes" begin
    rows(md) = [join(s.content for s in l) for l in T.markdown_to_spans(md, 60)]
    @test rows("Могу:\n\n- a\n- b\n\nдальше") == ["Могу:", "", "  * a", "  * b", "", "дальше"]
    @test rows("1. x\n2. y\n# H") == ["  1. x", "  2. y", "", "H"]
    # Tight sublist stays attached to the next parent item.
    @test rows("- a\n  - b\n- c\n\nдальше") == ["  * a", "      * b", "  * c", "", "дальше"]
    # Quotes end with one unprefixed blank, also when nested or holding lists.
    @test rows("> q\n\nдальше") == ["│ q", "", "дальше"]
    @test rows("> a\n> > b\n\nдальше") == ["│ a", "│ ", "│ │ b", "", "дальше"]
    @test rows("> - a\n> - b\n\nдальше") == ["│   * a", "│   * b", "", "дальше"]
    @test rows("> q") == ["│ q"]
    @test rows("- a") == ["  * a"]
end

@testset "Fine-grained Markdown roles" begin
    md = "> quoted\n\n- item\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nuse `x`\n\n```julia\nfunction f() end\n```\n"
    span_with(lines, pred) = findfirst(pred, reduce(vcat, lines))
    spans(lines) = reduce(vcat, lines)
    text = T.Style(fg=T.ColorRGB(1, 1, 1))
    code = T.Style(fg=T.ColorRGB(2, 2, 2), bg=T.ColorRGB(3, 3, 3))
    quote_s = T.Style(fg=T.ColorRGB(4, 4, 4))
    hr = T.Style(fg=T.ColorRGB(5, 5, 5))

    # Defaults keep the shared styles.
    base = spans(T.markdown_to_spans(md, 60; text_style=text, code_style=code, quote_style=quote_s, hr_style=hr))
    @test any(s -> s.content == "│ " && s.style == quote_s, base)
    @test any(s -> strip(s.content) == "*" && s.style == text, base)
    @test any(s -> s.content == "A" && s.style == T.Style(fg=text.fg, bold=true), base)
    @test any(s -> s.content == " │ " && s.style == hr, base)
    @test any(s -> s.content == "x" && s.style.bg == code.bg, base)
    @test any(s -> s.content == "function" && s.style.fg == T.token_style(T.tok_keyword).fg && s.style.bg == code.bg, base)

    block = T.Style(fg=T.ColorRGB(6, 6, 6), bg=T.ColorRGB(7, 7, 7))
    bar = T.Style(fg=T.ColorRGB(8, 8, 8))
    marker = T.Style(fg=T.ColorRGB(9, 9, 9))
    head = T.Style(fg=T.ColorRGB(10, 10, 10), bold=true)
    border = T.Style(fg=T.ColorRGB(11, 11, 11))
    keyword = T.ColorRGB(12, 12, 12)
    tokens(kind) = kind == T.tok_keyword ? T.Style(fg=keyword, bold=true) : T.Style()
    custom = spans(T.markdown_to_spans(md, 60; text_style=text, code_style=code, quote_style=quote_s,
        hr_style=hr, code_block_style=block, quote_border_style=bar, list_marker_style=marker,
        table_head_style=head, table_border_style=border, token_style=tokens))
    @test any(s -> s.content == "│ " && s.style == bar, custom)
    # quote_style is only the bar; text inside keeps text_style unless quote_text_style is set.
    @test any(s -> s.content == "quoted" && s.style == text, custom)
    qtext = T.Style(fg=T.ColorRGB(13, 13, 13), italic=true)
    quoted = spans(T.markdown_to_spans("> quoted\n>\n> - inner\n\nafter\n", 60; text_style=text,
        quote_border_style=bar, quote_text_style=qtext))
    @test any(s -> s.content == "quoted" && s.style == qtext, quoted)
    @test any(s -> s.content == "inner" && s.style == qtext, quoted)
    @test any(s -> s.content == "after" && s.style == text, quoted)
    @test count(s -> s.content == "│ " && s.style == bar, quoted) >= 2
    @test any(s -> strip(s.content) == "*" && s.style == marker, custom)
    @test any(s -> s.content == "item" && s.style == text, custom)
    @test any(s -> s.content == "A" && s.style == head, custom)
    @test any(s -> s.content == " │ " && s.style == border, custom)
    @test any(s -> occursin("─┼─", s.content) && s.style == border, custom)
    # Inline code keeps code_style; fenced blocks use code_block_style.
    @test any(s -> s.content == "x" && s.style.bg == code.bg, custom)
    @test any(s -> s.content == "function" && s.style.fg == keyword && s.style.bold && s.style.bg == block.bg, custom)
    # NoColor token styles fall back to the block's own color.
    @test any(s -> occursin("f", s.content) && s.content != "function" && s.style.fg == block.fg && s.style.bg == block.bg, custom)
end
