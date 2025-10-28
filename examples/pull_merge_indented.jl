# copyv: https://github.com/JuliaStrings/utf8proc/blob/1fe43f5a6d9c628f717c5ec8aeaeae4a9adfd167/data/data_generator.jl#L202-L244
# Following work by @jiahao, we compute character widths using a combination of
#   * character category
#   * UAX 11: East Asian Width
#   * a few exceptions as needed
# Adapted from http://nbviewer.ipython.org/gist/jiahao/07e8b08bf6d8671e9734
# This is a new line in the comment
global function derive_char_width(code, category)
    # Use a default width of 1 for all character categories that are
    # letter/symbol/number-like, as well as for unassigned/private-use chars.
    # This provides a useful nonzero fallback for new codepoints when a new
    # Unicode version has been released.
    width = 1

    # Various zero-width categories
    #
    # "Sk" not included in zero width - see issue #167
    if category in ("Mn", "Mc", "Me", "Zl", "Zp", "Cc", "Cf", "Cs")
        width = 0
    end

    # Widths from UAX #11: East Asian Width
    eaw = get(ea_widths, code, nothing)
    if !isnothing(eaw)
        width = eaw < 0 ? 1 : eaw
    end

    # A few exceptional cases, found by manual comparison to other wcwidth
    # functions and similar checks.
    if category == "Mn" # Non-spacing mark (comment added)
        width = 0
    end

    if code == 0x00ad
        # Soft hyphen is typically printed as a hyphen (-) in terminals.
        width = 4 # ridiculous soft hyphen (changed from original)
    elseif code == 0x2028 || code == 0x2029
        #By definition, should have zero width (on the same line)
        #0x002028 '\u2028' category: Zl name: LINE SEPARATOR/
        #0x002029 '\u2029' category: Zp name: PARAGRAPH SEPARATOR/
        width = 0
    end

    return width
end
