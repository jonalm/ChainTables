"""The attachment keys as IAM resource patterns (policies.py) against the keys the gateway
classifies: every attachment key it mints for matches a pattern, and no slot key it fills
does, so DenyPresignedSlotPuts covers every slot (ADR-0046, #92)."""

import random
import re

import pytest

import handler as gw
import policies

BUCKET_ARN = "arn:aws:s3:::bkt"
H = "0123456789abcdef" * 4


def iam_matches(pattern: str, arn: str) -> bool:
    """IAM's resource-pattern match: '*' any run of characters, '/' included; '?' exactly one."""
    regex = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern)
    return re.fullmatch(regex, arn, re.DOTALL) is not None


def covered(key: str) -> bool:
    return any(iam_matches(p, f"{BUCKET_ARN}/{key}") for p in policies.attachments(BUCKET_ARN))


def gateway_fills_slot(key: str) -> bool:
    prefix, is_attachment = gw.classify(key)
    return not is_attachment and gw.SLOT_KEY.fullmatch(key) is not None and gw.prefix_problem(prefix) is None


def gateway_mints(key: str) -> bool:
    prefix, is_attachment = gw.classify(key)
    return is_attachment and gw.prefix_problem(prefix) is None


def test_the_matcher_is_iams():
    assert iam_matches("a/*/b", "a/x/y/b") and iam_matches("a?c", "abc")
    assert not iam_matches("a?c", "ac") and not iam_matches("a?c", "abbc")


# The gap #92 closed: a slot whose last 64 characters span a '/' after an `_attachments` segment.
CONTRIVED = "p/_attachments/" + "x" * 51 + "/000000000000"


def test_the_contrived_slot_key_matches_the_pattern_but_the_gateway_refuses_its_prefix():
    assert covered(CONTRIVED)
    assert not gateway_fills_slot(CONTRIVED)
    assert "'_attachments'" in gw.prefix_problem(gw.classify(CONTRIVED)[0])


@pytest.mark.parametrize("key", [f"_attachments/{H}", f"teams/alpha/_attachments/{H}", f"a/b/c/_attachments/{H}"])
def test_every_attachment_key_the_gateway_mints_for_matches_a_pattern(key):
    assert gateway_mints(key) and covered(key)


SEGMENT_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789._-"


def random_prefix(rng: random.Random) -> str:
    segments = []
    for _ in range(rng.randint(0, 6)):
        if rng.random() < 0.3:
            segments.append("_attachments")
        else:
            segments.append("".join(rng.choice(SEGMENT_CHARS) for _ in range(rng.randint(1, 60))))
    return "/".join(segments)


def test_no_slot_key_the_gateway_fills_matches_a_pattern():
    rng = random.Random(92)
    filled = gap = 0
    for _ in range(20000):
        prefix = random_prefix(rng)
        key = (prefix + "/" if prefix else "") + f"{rng.randrange(10 ** 12):012d}"
        if gateway_fills_slot(key):
            filled += 1
            assert not covered(key), key
        else:
            # a slot key the patterns cover is one the gateway refuses
            assert not covered(key) or gw.prefix_problem(gw.classify(key)[0]) is not None, key
            gap += covered(key)
    assert filled > 1000 and gap > 50  # the sample reached both kinds of key that matter
