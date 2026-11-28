const GATEWAY_CODE = r"\"code\"\s*:\s*\"([A-Za-z0-9_]*)\""

# Lambda's own replies carry `Message`, capitalised, and no `code`. That text is read as
# the message too, so that a bare `403` says why AWS refused.
const GATEWAY_MESSAGE = r"\"[Mm]essage\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""

const JSON_ESCAPES = Dict('n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\b', 'f' => '\f')

# The `code` and `message` of the gateway's JSON reply, each `nothing` when absent, read
# without a JSON dependency (ADR-0027): the code is a plain identifier, and the message
# a JSON string.
function gateway_reply(body::Vector{UInt8})
    text = String(copy(body))
    code = match(GATEWAY_CODE, text)
    message = match(GATEWAY_MESSAGE, text)
    return (;
        code = code === nothing ? nothing : String(code[1]),
        message = message === nothing ? nothing : json_unescape(message[1]),
    )
end

function reply_text(reply)
    reply.code === nothing && return something(reply.message, "")
    reply.message === nothing && return reply.code
    return reply.code * ": " * reply.message
end

# A malformed or lone escape is kept as written, so that reading the message never hides
# the failure it explains.
function json_unescape(text::AbstractString)
    occursin('\\', text) || return String(text)
    io = IOBuffer()
    i = firstindex(text)
    while i <= lastindex(text)
        i = write_unescaped(io, text, i)
    end
    return String(take!(io))
end

# Write the character at `i`, or the escape that starts there, and return the index
# after it.
function write_unescaped(io::IO, text::AbstractString, i::Int)
    _is_escape = text[i] == '\\' && i < lastindex(text)
    _is_escape || return write_text(io, text[i], nextind(text, i))
    j = nextind(text, i)
    text[j] == 'u' && return write_unicode_escape(io, text, j)
    return write_text(io, get(JSON_ESCAPES, text[j], text[j]), nextind(text, j))
end

# Python's `json.dumps` writes a character outside the BMP as a pair of UTF-16
# surrogates, which become one character.
function write_unicode_escape(io::IO, text::AbstractString, j::Int)
    unit = utf16_escape(text, j)
    unit === nothing && return write_text(io, "\\u", j + 1)
    low = 0xd800 <= unit <= 0xdbff ? low_surrogate_after(text, j + 5) : nothing
    low === nothing || return write_text(io, surrogate_pair(unit, low), j + 11)
    0xd800 <= unit <= 0xdfff && return write_text(io, "\\" * text[j:(j + 4)], j + 5)
    return write_text(io, Char(unit), j + 5)
end

function write_text(io::IO, text, next::Int)
    print(io, text)
    return next
end

function low_surrogate_after(text::AbstractString, i::Int)
    checkbounds(Bool, codeunits(text), i) && codeunit(text, i) == UInt8('\\') ||
        return nothing
    unit = utf16_escape(text, i + 1)
    return (unit !== nothing && 0xdc00 <= unit <= 0xdfff) ? unit : nothing
end

surrogate_pair(high, low) = Char(0x00010000 + ((high - 0xd800) << 10) + (low - 0xdc00))

# The UTF-16 code unit of the four hex digits after a `u` at byte `i`, or `nothing`
# when there is no `u` there or fewer than four hex digits follow it.
function utf16_escape(text::AbstractString, i::Int)
    checkbounds(Bool, codeunits(text), i:(i + 4)) && codeunit(text, i) == UInt8('u') ||
        return nothing
    unit = UInt32(0)
    for j in (i + 1):(i + 4)
        digit = Char(codeunit(text, j))
        isascii(digit) && isxdigit(digit) || return nothing
        unit = unit << 4 | UInt32(parse(Int, digit; base = 16))
    end
    return unit
end
