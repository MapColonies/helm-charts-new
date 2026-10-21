#!/usr/bin/env bash
# Asserts on the rendered config.alloy: logFilters is off by default and, when
# set, keeps/drops lines per namespace before the OTel conversion.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template alloy . "$@" | sed -n '/config.alloy: |-/,$p'; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. off by default: nothing but the age filter in loki.process
out=$(render)
grep -q 'stage.match' <<<"$out" && fail "default render must not contain stage.match"

# 2. keep: one drop stage per regex, selecting the namespace's lines that do NOT match
out=$(render -f tests/values-log-filters.yaml)
grep -qF 'selector = "{k8s_namespace_name=\"gatekeeper-system\"} !~ \"\\\"event_type\\\":\\\\s*\\\"violation\\\"\""' <<<"$out" \
  || fail "keep regex 1 not rendered as drop-if-not-matching"
grep -qF 'selector = "{k8s_namespace_name=\"gatekeeper-system\"} !~ \"\\\"constraint_name\\\":\\\\s*\\\"workload-[^\\\"]*\\\"\""' <<<"$out" \
  || fail "keep regex 2 not rendered as drop-if-not-matching"

# 3. drop: drop lines of the namespace that match
grep -qF 'selector = "{k8s_namespace_name=\"infra-dev\"} |~ \"healthcheck\""' <<<"$out" \
  || fail "drop regex not rendered"

# 4. a filter without namespace applies to every namespace
grep -qF 'selector = "{k8s_namespace_name=~\".+\"} |~ \"noisy\""' <<<"$out" \
  || fail "namespace-less drop not rendered"

# 5. stages are action = drop and sit before the OTel receiver
awk '/stage.match/{m=NR} /otelcol.receiver.loki "default"/{r=NR} END{exit !(m && m<r)}' <<<"$out" \
  || fail "filter stages must come before otelcol.receiver.loki"

echo "OK"
