# A record-shaped map and its bytes, written out by hand from RFC 8949 Appendix A and the
# §4.2.1 key order: bytewise on the encoded key, so "ops" < "slot" < "client", since the
# head byte 0x60 + length sorts before the text. The one check of the encoder against
# the standard and not against itself (ADR-0006).

const HAND_WRITTEN_RECORD = Dict{String, Any}(
    "format_version" => 1,
    "chain_id" => UInt8.(0:15),
    "slot" => 0,
    "state_fingerprint" => UInt8.(0:31),
    "client" => Dict{String, Any}(
        "host" => "h", "user" => "u", "lib" => "ChainTables 0.1.0",
        "julia" => "1.12.7", "time_ms" => 1000
    ),
    "comment" => "ü",
    "ops" => Any[
        Dict{String, Any}(
            "op" => "insert", "table" => "t",
            "rows" => Any[
                Any[1, -0.0, "水", UInt8[1, 2, 3, 4], true, missing, -1, 1.1, 100000.0],
            ]
        ),
    ],
)
const HAND_WRITTEN_HEX = replace(
    join(
        [
            "a7",  # map(7)
            "63 6f7073",  # "ops"
            "81",  # array(1)
            "a3",  # map(3)
            "62 6f70", "66 696e73657274",  # "op": "insert"
            "64 726f7773",  # "rows"
            "81", "89",  # [[ 9 cells ]]
            "01",  # 1 (App. A)
            "f9 8000",  # -0.0 (App. A)
            "63 e6b0b4",  # "水" (App. A)
            "44 01020304",  # h'01020304' (App. A)
            "f5", "f6",  # true, null (App. A)
            "20",  # -1 (App. A)
            "fb 3ff199999999999a",  # 1.1 (App. A)
            "fa 47c35000",  # 100000.0 (App. A)
            "65 7461626c65", "61 74",  # "table": "t"
            "64 736c6f74", "00",  # "slot": 0
            "66 636c69656e74",  # "client"
            "a5",  # map(5)
            # "lib": "ChainTables 0.1.0"
            "63 6c6962", "71 436861696e5461626c657320302e312e30",
            "64 686f7374", "61 68",  # "host": "h"
            "64 75736572", "61 75",  # "user": "u"
            "65 6a756c6961", "66 312e31322e37",  # "julia": "1.12.7"
            "67 74696d655f6d73", "19 03e8",  # "time_ms": 1000 (App. A)
            "67 636f6d6d656e74", "62 c3bc",  # "comment": "ü" (App. A)
            # "chain_id": 16 bytes
            "68 636861696e5f6964", "50 000102030405060708090a0b0c0d0e0f",
            "6e 666f726d61745f76657273696f6e", "01",  # "format_version": 1
            "71 73746174655f66696e6765727072696e74",  # "state_fingerprint"
            "5820 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        ]
    ), " " => ""
)
