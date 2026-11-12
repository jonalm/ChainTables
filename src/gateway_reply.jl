# A gateway's reply is JSON `{"code": …, "message": …}`, read without a JSON dependency
# (ADR-0027).

const REPLY_CODE = r"\"code\"\s*:\s*\"([A-Za-z0-9_]*)\""

# Lambda's own replies carry `Message`, capitalised, and never `code`; that text is read
# as the message, so a bare 403 says why AWS refused.
const REPLY_MESSAGE = r"\"[Mm]essage\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""

const JSON_ESCAPES = Dict('n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\b', 'f' => '\f')

"""
    gateway_reply(body)

Return `(code, message)` of a gateway's JSON reply, each `nothing` when absent; the code
is a plain identifier, the message a JSON string with its escapes undone.
"""
function gateway_reply(body::Vector{UInt8})
    text = String(copy(body))
    code = match(REPLY_CODE, text)
    message = match(REPLY_MESSAGE, text)
    return (
        code === nothing ? nothing : String(code.captures[1]),
        message === nothing ? nothing : json_unescape(message.captures[1]),
    )
end

"""
    json_unescape(s)

Return the JSON string body `s` with its escapes undone. A `\\uXXXX` pair of UTF-16
surrogates, how Python's `json.dumps` writes a character outside the BMP, is joined into
one character. A malformed or lone escape is kept as written, so reading a message never
hides the error it explains.
"""
function json_unescape(s::AbstractString)
    io = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        text, i = json_piece(s, i)
        write(io, text)
    end
    return String(take!(io))
end

# The text of the character or escape at `i` of `s`, and the index after it.
function json_piece(s::AbstractString, i::Int)
    (s[i] == '\\' && i < lastindex(s)) || return string(s[i]), nextind(s, i)
    escaped = s[i + 1]
    escaped == 'u' && return unicode_escape(s, i + 1)
    return string(get(JSON_ESCAPES, escaped, escaped)), nextind(s, i + 1)
end

# `iu` is the byte of the `u`. Indices step in bytes here: the escape is ASCII.
function unicode_escape(s::AbstractString, iu::Int)
    u = utf16_escape(s, iu)
    u === nothing && return "\\u", iu + 1
    low = 0xd800 <= u <= 0xdbff ? low_surrogate_after(s, iu + 5) : nothing
    low === nothing || return string(surrogate_pair_char(u, low)), iu + 11
    0xd800 <= u <= 0xdfff && return "\\u" * s[(iu + 1):(iu + 4)], iu + 5
    return string(Char(u)), iu + 5
end

surrogate_pair_char(high, low) = Char(0x00010000 + ((high - 0xd800) << 10) + (low - 0xdc00))

# The low surrogate escaped at byte `i` of `s` (`\uDC00` to `\uDFFF`), or `nothing`.
function low_surrogate_after(s::AbstractString, i::Int)
    (checkbounds(Bool, codeunits(s), i) && codeunit(s, i) == UInt8('\\')) || return nothing
    low = utf16_escape(s, i + 1)
    (low !== nothing && 0xdc00 <= low <= 0xdfff) || return nothing
    return low
end

# The UTF-16 code unit spelled by the four hex digits after a `u` at byte `i` of `s`, or
# `nothing` when there is no `u` there or fewer than four hex digits follow it.
function utf16_escape(s::AbstractString, i::Integer)
    (checkbounds(Bool, codeunits(s), i:(i + 4)) && codeunit(s, i) == UInt8('u')) ||
        return nothing
    u = UInt32(0)
    for j in (i + 1):(i + 4)
        digit = Char(codeunit(s, j))
        (isascii(digit) && isxdigit(digit)) || return nothing
        u = u << 4 | UInt32(parse(Int, digit; base = 16))
    end
    return u
end
