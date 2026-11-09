    # ═════════════════════════════════════════════════════════════════
    # Allocation-free cell writes and widths, checked against the previous
    # String/graphemes-iterator implementation kept here as the oracle.
    # ═════════════════════════════════════════════════════════════════

    function ref_grapheme_width(g::AbstractString)
        if occursin('\ufe0f', g) && occursin(T._EMOJI, g) ||
           occursin('\u200d', g) && occursin(T._PICTOGRAPH, g) ||
           any(c -> '\U0001f3fb' <= c <= '\U0001f3ff', g) && occursin(T._MODIFIER_BASE, g) ||
           occursin('\u20e3', g) && first(g) in "#*0123456789"
            return 2
        end
        textwidth(g)
    end
    ref_display_width(s) = T._is_simple_latin(s) ? textwidth(s) : sum(ref_grapheme_width, Base.Unicode.graphemes(s); init=0)
    function ref_set_string!(buf, x, y, str, style; max_x=T.right(buf.area))
        clean = T._strip_controls(T._strip_ansi(str))
        col = x
        clip = min(max_x, T.right(buf.area))
        if T._is_simple_latin(clean)
            for ch in clean
                col > clip && break
                T.in_bounds(buf, col, y) && T.set_char!(buf, col, y, ch, style)
                col += 1
            end
            return col
        end
        last_drawn_col = x - 1
        for grapheme in Base.Unicode.graphemes(clean)
            glyph = String(grapheme)
            col > clip && break
            w = ref_grapheme_width(glyph)
            if w == 0
                last_drawn_col >= x && T._append_glyph!(buf, last_drawn_col, y, glyph)
                continue
            end
            if w == 2
                if col + 1 > clip
                    T.in_bounds(buf, col, y) && T.set_char!(buf, col, y, T.EMPTY_CHAR, style)
                    col += 1
                    continue
                end
                T.in_bounds(buf, col, y) && T._set_glyph!(buf, col, y, glyph, style)
                T.in_bounds(buf, col + 1, y) && T.set_char!(buf, col + 1, y, T.WIDE_CHAR_PAD, style)
            else
                T.in_bounds(buf, col, y) && T._set_glyph!(buf, col, y, glyph, style)
            end
            last_drawn_col = col
            col += max(w, 1)
        end
        col
    end

    @testset "Single codepoint width equals the cluster rules, all of Unicode" begin
        mismatches = 0
        for u in 0x0:0x10FFFF
            0xD800 <= u <= 0xDFFF && continue
            ch = Char(u)
            g = string(ch)
            mismatches += !(T.grapheme_width(g) == ref_grapheme_width(g) == textwidth(ch) ==
                            T.cell_width(T.Cell(ch)))
        end
        @test mismatches == 0
    end

    # Text mixing every class the width policy distinguishes.
    pieces = ["a", "Ж", "ё", "中", "가", " ", "e\u0301", "\u0301", "👍", "👍🏽", "❤\ufe0f", "👩\u200d💻",
              "1\ufe0f\u20e3", "#\u20e3", "\u200d", "\ufe0f", "🇷🇺", "\t", "\e[31m", "x\e]8;;u\e\\y", "\u00ad", "ﾊ"]
    text_gen = map(ix -> join(pieces[i] for i in ix), Data.Vectors(Data.Integers(1, length(pieces)); max_size=24))
    width_gen = Data.Integers(1, 30)
    @testset "PBT: set_string! and display_width match the graphemes oracle" begin
        Supposition.@check max_examples=3000 function same_cells(s=text_gen, w=width_gen, pre=text_gen)
            style = T.Style(fg=T.ColorRGB(1, 2, 3))
            a = T.Buffer(T.Rect(1, 1, 32, 1)); b = T.Buffer(T.Rect(1, 1, 32, 1))
            # Pre-existing content exercises the wide-char cleanup paths.
            T.set_string!(a, 1, 1, pre, style); ref_set_string!(b, 1, 1, pre, style)
            ca = T.set_string!(a, 2, 1, s, style; max_x=w)
            cb = ref_set_string!(b, 2, 1, s, style; max_x=w)
            ca == cb && a.content == b.content && T.display_width(s) == ref_display_width(s)
        end
    end
    @testset "Cell writes allocate nothing" begin
        buf = T.Buffer(T.Rect(1, 1, 80, 2)); style = T.Style(fg=T.ColorRGB(1, 2, 3))
        write_row(buf, style, s) = T.set_string!(buf, 1, 1, s, style)
        for s in ("plain ascii text", "Сообщение · кириллица", "中文 and 가 wide", "mixed é ё")
            write_row(buf, style, s)
            @test @allocated(write_row(buf, style, s)) == 0
        end
        chars(buf, style) = (for x in 1:80; T.set_char!(buf, x, 2, 'ж', style); end)
        chars(buf, style)
        @test @allocated(chars(buf, style)) == 0
        @test @allocated(T.display_width("Привет, мир")) == 0
    end
