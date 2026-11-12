# Conformance corpus

The frozen corpus of `test/cbor.jl` ("frozen conformance corpus") was
differential-tested **once** (ADR-0006) against two third-party RFC 8949
§4.2.1 encoders, and the resulting hex literals are checked in. This directory
holds what that run consumed, so it can be audited or repeated.

- `corpus.json` — the 96 cases as typed nodes (`int` as decimal text, `float` as
  the 16 hex digits of the binary64 bits, `bytes` as hex), exported from the
  Julia definitions in `test/cbor.jl`.
- `cbor2_encode.py` — encodes it with [cbor2](https://pypi.org/project/cbor2/)
  `dumps(value, canonical=True)`.
- `fxamacker_encode.go` (+ `go.mod`, `go.sum`) — encodes it with
  [fxamacker/cbor](https://github.com/fxamacker/cbor) `CoreDetEncOptions()`.

Run on 2026-09-13 with cbor2 6.1.4 (Python 3) and fxamacker/cbor v2.9.3 (Go
1.23.4); both outputs were identical to this encoder's on every case.

```sh
python3 -m venv venv && ./venv/bin/pip install cbor2
./venv/bin/python cbor2_encode.py corpus.json > cbor2.txt
go build -o encode fxamacker_encode.go && ./encode corpus.json > fxamacker.txt
diff cbor2.txt fxamacker.txt
```

Each output line is `name hex`; compare against the `frozen` table in
`test/cbor.jl`. The literals never change without an ADR: a different byte is a
chain break.
