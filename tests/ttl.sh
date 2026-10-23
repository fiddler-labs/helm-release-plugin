#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../lib/api/ttl.sh"

# Exercise CLI parsing and rendered jobs without contacting Kubernetes.
export HELM_NAMESPACE=ttl-test
export HELM_KUBECONTEXT=test-context
assert_serviceaccount_exits() { :; }
exit_with_help() { exit 1; }
date() {
    case "$*" in
        *'+%M %H %d %m *'*) echo '00 12 24 10 *' ;;
        *--date=*) echo 200 ;;
        *) echo 100 ;;
    esac
}
kubectl() {
    if [[ "$1" == auth ]]; then
        [[ "$*" == "auth can-i delete namespace/ttl-test --as=system:serviceaccount:ttl-test:${EXPECTED_SERVICE_ACCOUNT:-default} --as-group=system:serviceaccounts --as-group=system:serviceaccounts:ttl-test --as-group=system:authenticated --context=test-context" ]] || return 99
        printf '%s\n' "${AUTH_RESPONSE:-yes}"
        return "${AUTH_EXIT_CODE:-0}"
    fi
    if [[ "$1" != apply ]]; then
        echo "Unexpected kubectl command: $*" >&2
        return 1
    fi
    cat
}

manifest=$(release_ttl sample --set=tomorrow)
grep -Fq "args: [ 'delete', 'cronjob', 'sample-ttl' ]" <<< "$manifest"
if grep -Fq "'delete', 'namespace'" <<< "$manifest"; then
    echo 'Default TTL must not delete the namespace' >&2
    exit 1
fi

manifest=$(release_ttl sample --set=tomorrow --delete-namespace)
grep -Fq "args: [ 'uninstall', 'sample', '--namespace', 'ttl-test' ]" <<< "$manifest"
grep -Fq "args: [ 'delete', 'namespace', 'ttl-test', '--wait=false', '--ignore-not-found=true' ]" <<< "$manifest"
if grep -Fq "'delete', 'cronjob'" <<< "$manifest"; then
    echo 'Namespace cleanup should cascade-delete the CronJob' >&2
    exit 1
fi

# Flags work in either order and do not leak into subsequent calls.
manifest=$(release_ttl sample --delete-namespace --set tomorrow)
grep -Fq "'delete', 'namespace', 'ttl-test'" <<< "$manifest"
manifest=$(
    release_ttl sample --delete-namespace --set tomorrow >/dev/null
    release_ttl sample --set tomorrow
)
grep -Fq "'delete', 'cronjob'" <<< "$manifest"

for namespace in '' default kube-system kube-public kube-node-lease; do
    if (export HELM_NAMESPACE="$namespace"; release_ttl sample --set=tomorrow --delete-namespace) >/dev/null; then
        echo "Namespace cleanup unexpectedly accepted '$namespace'" >&2
        exit 1
    fi
done

for action in --unset --output=yaml; do
    if (release_ttl sample "$action" --delete-namespace) >/dev/null; then
        echo "Namespace cleanup unexpectedly accepted $action" >&2
        exit 1
    fi
done

# Authorization denial and API/impersonation failures must not create a job.
for status in 1 2; do
    if output=$(AUTH_EXIT_CODE=$status release_ttl sample --set=tomorrow --delete-namespace 2>&1); then
        echo 'Namespace cleanup unexpectedly accepted a failed authorization check' >&2
        exit 1
    fi
    if grep -Fq 'kind: CronJob' <<< "$output"; then
        echo 'Failed authorization must not apply a CronJob' >&2
        exit 1
    fi
done
manifest=$(EXPECTED_SERVICE_ACCOUNT=cleanup release_ttl sample --service-account=cleanup --set=tomorrow --delete-namespace)
grep -Fq 'serviceAccountName: cleanup' <<< "$manifest"
# Release-only TTL must not require impersonation or namespace-delete access.
manifest=$(AUTH_EXIT_CODE=1 release_ttl sample --set=tomorrow)
grep -Fq "'delete', 'cronjob'" <<< "$manifest"

echo 'TTL manifest tests passed'
