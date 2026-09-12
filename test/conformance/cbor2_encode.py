#!/usr/bin/env python3
"""Encode the conformance corpus with cbor2 (canonical=True) and print `name hex` per case.

The corpus is corpus.json: a list of {"name", "value"} where a value is a typed
node — {"t": "int", "v": "<decimal>"}, {"t": "float", "v": "<16 hex digits of the
IEEE binary64 bits>"}, {"t": "text", "v": "<string>"}, {"t": "bytes", "v": "<hex>"},
{"t": "bool", "v": true|false}, {"t": "null"}, {"t": "array", "v": [node, …]},
{"t": "map", "v": [[key, node], …]}. Bits for floats so -0.0, NaN payloads and
exact doubles survive JSON.
"""
import json, struct, sys
import cbor2

def build(node):
    t = node["t"]
    if t == "int":
        return int(node["v"])
    if t == "float":
        return struct.unpack(">d", bytes.fromhex(node["v"]))[0]
    if t == "text":
        return node["v"]
    if t == "bytes":
        return bytes.fromhex(node["v"])
    if t == "bool":
        return bool(node["v"])
    if t == "null":
        return None
    if t == "array":
        return [build(x) for x in node["v"]]
    if t == "map":
        return {k: build(v) for k, v in node["v"]}
    raise ValueError(t)

corpus = json.load(open(sys.argv[1]))
for case in corpus:
    print(case["name"], cbor2.dumps(build(case["value"]), canonical=True).hex())
