#!/usr/bin/env bash
# Asserts on the rendered Alloy Role and RoleBinding: off by default, names and namespaces.
set -euo pipefail
cd "$(dirname "$0")/.."

render() { helm template gatekeeper-constraints . -n gatekeeper-system "$@"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
# our objects only: the Gatekeeper subchart renders Roles of its own
mine() { awk '/^# Source: /{keep = ($0 ~ /templates\/alloy-rbac\.yaml/)} keep'; }

# 1. off by default
[ -z "$(render | mine)" ] || fail "default render must not contain the Alloy Role"

# 2. on: Role and RoleBinding in the release namespace, bound to the ServiceAccount elsewhere
out=$(render --set alloyAccess.enabled=true --set alloyAccess.serviceAccount.namespace=infra-dev | mine)
[ "$(grep -c '^kind: Role$' <<<"$out")" = 1 ] || fail "expected one Role"
[ "$(grep -c '^kind: RoleBinding$' <<<"$out")" = 1 ] || fail "expected one RoleBinding"
role=$(awk 'BEGIN{RS="---"} /\nkind: Role\n/' <<<"$out")
grep -q 'namespace: gatekeeper-system' <<<"$role" || fail "Role must be in the release namespace"
grep -q 'name: alloy-kube-api' <<<"$role" || fail "Role must default to alloy-kube-api"
grep -q '"pods/log"' <<<"$role" || fail "Role must allow reading Pod logs"
grep -qE 'secrets' <<<"$role" && fail "Role must not touch Secrets"
bind=$(awk 'BEGIN{RS="---"} /\nkind: RoleBinding\n/' <<<"$out")
grep -q 'namespace: infra-dev' <<<"$bind" || fail "subject must be the ServiceAccount in infra-dev"

# 3. custom ServiceAccount name is used for the Role, binding and subject
out=$(render --set alloyAccess.enabled=true --set alloyAccess.serviceAccount.namespace=x --set alloyAccess.serviceAccount.name=my-alloy | mine)
[ "$(grep -c 'name: my-alloy' <<<"$out")" = 4 ] || fail "custom name must be used everywhere"

echo "OK"
