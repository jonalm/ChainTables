const MT_UINT = 0x00
const MT_NEG = 0x20
const MT_BYTES = 0x40
const MT_TEXT = 0x60
const MT_ARRAY = 0x80
const MT_MAP = 0xa0
const MT_TAG = 0xc0
const MT_SIMPLE = 0xe0

const SIMPLE_FALSE = 0xf4
const SIMPLE_TRUE = 0xf5
const SIMPLE_NULL = 0xf6
const HEAD_FLOAT16 = 0xf9
const HEAD_FLOAT32 = 0xfa
const HEAD_FLOAT64 = 0xfb

# The one NaN the format admits, as float16 bits (encoded f97e00, ADR-0025): the decoder
# rejects every other NaN, so the model only ever holds `NaN` proper.
const CANONICAL_NAN_BITS = 0x7e00

# The record cap (ADR-0006): no string in the format is longer, and the bound keeps a
# corrupt length byte from becoming an allocation the size of the address space.
const MAX_STRING_BYTES = 64 * 1024 * 1024

# The format's deepest item is a row inside rows inside an op inside ops inside a
# record, five levels: 64 is far outside anything legitimate and inside any stack.
const MAX_DEPTH = 64

# The smallest argument each additional-information value 24 to 27 may carry: a smaller
# one fits a shorter head, which RFC 8949 §4.2.1 rule 1 requires.
const SHORTEST_ARGUMENT = (UInt64(24), UInt64(2)^8, UInt64(2)^16, UInt64(2)^32)

const NOT_FLOAT64 = "is not exactly representable as Float64; " *
    "the float64 domain is IEEE binary64"
const TEXT_NOT_UTF8 = "text is not well-formed UTF-8"
const TEXT_HAS_NUL = "text contains U+0000, which the format excludes"
const NOTHING_IS_NOT_NULL = "nothing is not a value of the format; " *
    "null is spelled missing"
const CARRIED_TYPES = "the format carries int64, float64, text, bytes, bool, null, " *
    "arrays and text-keyed maps"
const UNEXPECTED_BREAK = "unexpected break (0xff); indefinite lengths are not in the format"
const UNSORTED_KEY = "is not in RFC 8949 §4.2.1 order (bytewise on the encoded key)"
const NAN_NOT_CANONICAL = "NaN must be encoded as f97e00"
const NOT_SHORTEST = "is not in its shortest form"

# A map entry on its way out: the key as text for a message, and as the encoded bytes
# the entries sort by.
const MapEntry = @NamedTuple{key::String, bytes::Vector{UInt8}, value::Any}
