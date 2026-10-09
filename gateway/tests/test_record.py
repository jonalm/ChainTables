"""Check 3: the gateway refuses a body the Julia reader (src/cbor.jl) would refuse, so it never
fills a slot with a record that no client can read. cbor2 alone accepts most of these."""

import cbor2
import pytest

from tests.conftest import event, parse, record

GOOD = record()  # canonical, as the Julia encoder writes it


def h(s):
    return bytes.fromhex(s.replace(" ", ""))


def refused(gateway, body):
    status, out = parse(gateway.handle(event(body=body)))
    assert (status, out["code"]) == (400, "not_cbor_map")
    return out["message"]


def test_canonical_record_is_accepted(gateway, s3):
    s3.put_succeeds("teams/alpha/000000000003", GOOD)
    status, out = parse(gateway.handle(event(body=GOOD)))
    assert (status, out["code"]) == (200, "created")


def test_trailing_bytes_are_refused(gateway):
    assert cbor2.loads(GOOD + b"\x00") == cbor2.loads(GOOD)  # what cbor2 alone lets through
    assert "trailing bytes" in refused(gateway, GOOD + b"\x00")


def test_duplicate_map_key_is_refused(gateway):
    # {"client": {"user": "alice@example.com"}, "client": <same>}: cbor2 keeps the last one.
    client = cbor2.dumps({"user": "alice@example.com"})
    body = h("a2") + cbor2.dumps("client") + client + cbor2.dumps("client") + client
    assert cbor2.loads(body) == {"client": {"user": "alice@example.com"}}
    assert "duplicate" in refused(gateway, body)


def test_unsorted_map_keys_are_refused(gateway):
    body = cbor2.dumps({"format_version": 1, "client": {"user": "alice@example.com"}})  # insertion order
    assert body != cbor2.dumps(cbor2.loads(body), canonical=True)
    assert "unsorted" in refused(gateway, body)


def test_indefinite_length_map_is_refused(gateway):
    body = h("bf") + GOOD[1:]  # GOOD is a 4-entry map, a4; bf ... ff is the same map, indefinite
    body = h("bf") + body[1:] + h("ff")
    assert cbor2.loads(body) == cbor2.loads(GOOD)
    assert "indefinite" in refused(gateway, body)


@pytest.mark.parametrize("extra, why", [
    (h("18 05"), "non-shortest integer"),          # 5 in a one-byte argument
    (h("fa 3f800000"), "non-shortest"),            # 1.0 as float32, fits float16
    (h("f9 7e01"), "NaN"),                         # a NaN with a payload
    (h("c1 00"), "tag"),                           # tag 1 (epoch time) around an integer 0
    (h("c2 41 05"), "tag"),                        # bignum 5, which cbor2 decodes to a plain int
])
def test_non_deterministic_value_is_refused(gateway, extra, why):
    # {"client": {...}, "x": <extra>}: canonical except for the one value.
    body = h("a2") + cbor2.dumps("client") + cbor2.dumps({"user": "alice@example.com"}) + cbor2.dumps("x") + extra
    assert why in refused(gateway, body)


@pytest.mark.parametrize("value, why", [
    (2**63, "int64"),
    (-(2**63) - 1, "int64"),
    ("a\x00b", "U+0000"),
    ({"k": cbor2.undefined}, "not a value of the format"),
    (cbor2.CBORSimpleValue(16), "not a value of the format"),
])
def test_value_outside_the_format_domain_is_refused(gateway, value, why):
    body = cbor2.dumps({"client": {"user": "alice@example.com"}, "x": value}, canonical=True)
    assert why in refused(gateway, body)


def test_non_text_map_key_is_refused(gateway):
    body = cbor2.dumps({"client": {"user": "alice@example.com"}, 1: 2}, canonical=True)
    assert "not text" in refused(gateway, body)


def test_nesting_limit_matches_the_julia_reader(gateway, s3):
    def nested(levels):  # the innermost 0 sits at depth `levels`, the map at depth 0
        return {"client": {"user": "alice@example.com"}, "x": [0] if levels == 2 else [nested_list(levels - 2)]}

    def nested_list(n):
        return 0 if n == 0 else [nested_list(n - 1)]

    ok = cbor2.dumps({"client": {"user": "alice@example.com"}, "x": nested_list(63)}, canonical=True)  # 0 at depth 64
    s3.put_succeeds("teams/alpha/000000000003", ok)
    assert parse(gateway.handle(event(body=ok)))[0] == 200
    deep = cbor2.dumps({"client": {"user": "alice@example.com"}, "x": nested_list(64)}, canonical=True)
    assert "deeper than 64" in refused(gateway, deep)


def test_shared_reference_cycle_is_refused(gateway):
    # tag 28 marks the map shareable, tag 29 refers back to it: a cycle in cbor2's result.
    body = h("d8 1c a1") + cbor2.dumps("x") + h("d8 1d 00")
    assert "not in the record format" in refused(gateway, body)
