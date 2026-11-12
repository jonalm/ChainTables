# RFC 8949 §4.2.1 core deterministic encoding, pinned further by ADR-0006 and ADR-0025.
# A change to what the encoder writes is a chain break.

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

# The record cap of ADR-0006: no string in the format is longer, and the bound keeps a
# corrupt length byte from becoming an allocation the size of the address space.
const MAX_STRING_BYTES = 64 * 1024 * 1024

# The format's deepest item is a row inside rows inside an op inside ops inside a record,
# five levels; 64 is far outside anything legitimate and inside any stack.
const MAX_DEPTH = 64
