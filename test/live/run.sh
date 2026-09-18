#!/usr/bin/env bash
# The one entry point of the live suite (ADR-0030):
#
#     test/live/run.sh [s3] [gateway]        # no argument: all
#
# Reads the configuration from the file CHAINTABLES_LIVE_ENV names, default env/live.env
# (git-ignored; copy test/live/live.env.example), checks the login session of every profile
# it will use, and runs test/live/runtests.jl, which prints what it is about to write to.
# It holds no values. Nothing but that file configures the run: CHAINTABLES_LIVE_* and AWS_*
# credential, profile and region variables exported in the shell are dropped first.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
example="test/live/live.env.example"
env_file="${CHAINTABLES_LIVE_ENV:-env/live.env}"
julia="${JULIA:-julia}"

die() { echo "test/live/run.sh: $*" >&2; exit 1; }

[ -f "$env_file" ] || die "no configuration file at $env_file (relative to $root). Copy $example there and fill it in, or name another file with CHAINTABLES_LIVE_ENV."
command -v aws >/dev/null || die "the AWS CLI (aws) is not on PATH"
command -v "$julia" >/dev/null || die "$julia is not on PATH (set JULIA)"

# only the file configures the run: no ambient configuration, credentials, profile or region
for name in $(compgen -v | grep -E '^CHAINTABLES_LIVE_' || true); do
    [ "$name" = CHAINTABLES_LIVE_ENV ] || unset "$name"
done
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION

# the file is read, never executed: NAME=value lines, blank lines and # comments
n=0
while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^(CHAINTABLES_LIVE_[A-Z0-9_]+)=(.*)$ ]] ||
        die "$env_file:$n: expected CHAINTABLES_LIVE_<NAME>=<value>, a comment or a blank line"
    name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    [[ "$value" == *"<"*">"* ]] && die "$env_file:$n: $name still holds a placeholder from $example"
    export "$name=$value"
done < "$env_file"
export JULIA_LOAD_PATH="@:@stdlib"      # the package's own environment and the standard libraries

# every variable of the selection is present, or stop here; then one session check per profile
sessions="$("$julia" --startup-file=no test/live/config.jl "$@")"
while IFS=$'\t' read -r profile region; do
    aws sts get-caller-identity --profile "$profile" --region "$region" >/dev/null ||
        die "no valid session for profile '$profile'. Run: aws sso login --profile $profile   (--use-device-code if the browser balks)"
done < <(printf '%s\n' "$sessions" | sort -u)

exec "$julia" --startup-file=no --project="$root" test/live/runtests.jl "$@"
