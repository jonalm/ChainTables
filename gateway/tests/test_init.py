"""In Lambda the gateway is configured at import, not at the first request."""

import json
import os
import subprocess
import sys
from pathlib import Path

from tests.conftest import BUCKET, POLICY

HERE = Path(__file__).resolve().parent.parent
PROBE = "import handler; print(handler._gateway is not None and handler._gateway.bucket)"


def run_import(tmp_path, lambda_env: bool) -> str:
    (tmp_path / "policy.json").write_text(json.dumps(POLICY))
    env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
    env.update(CHAINTABLES_BUCKET=BUCKET, CHAINTABLES_POLICY=str(tmp_path / "policy.json"),
               AWS_DEFAULT_REGION="eu-north-1", PYTHONPATH=str(HERE))
    if lambda_env:
        env["AWS_LAMBDA_FUNCTION_NAME"] = "test-gateway"
    out = subprocess.run([sys.executable, "-c", PROBE], env=env, cwd=HERE, capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


def test_in_lambda_the_gateway_is_built_at_import(tmp_path):
    assert run_import(tmp_path, lambda_env=True) == BUCKET


def test_outside_lambda_import_builds_nothing(tmp_path):
    assert run_import(tmp_path, lambda_env=False) == "False"


def test_in_lambda_a_misconfiguration_fails_the_import(tmp_path):
    env = {k: v for k, v in os.environ.items() if not k.startswith("AWS_")}
    env.update(AWS_LAMBDA_FUNCTION_NAME="test-gateway", PYTHONPATH=str(HERE))
    out = subprocess.run([sys.executable, "-c", "import handler"], env=env, cwd=HERE, capture_output=True, text=True)
    assert out.returncode != 0
    assert "CHAINTABLES_BUCKET is not set" in out.stderr
