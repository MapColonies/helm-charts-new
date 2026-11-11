#!/usr/bin/env bash
# Asserts on the rendered workloads: a Deployment that receives OTLP and the pod logs, processes and
# exports them, and a StatefulSet that tails pod logs (one replica, or several that split the pods)
# and forwards them, keeping its state on a per-replica PVC (of the default or a chosen
# StorageClass) that's deleted when the replica is scaled away.
source "$(dirname "$0")/lib.sh"

out=$(render)
deploy=$(yq 'select(.kind == "Deployment")' <<<"$out")
sts=$(yq 'select(.kind == "StatefulSet")' <<<"$out")
args() { yq '.spec.template.spec.containers[] | select(.name == "alloy") | .args[]' <<<"$1"; }

# 1. one workload of each kind, each running its own config
[[ $(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet") | .kind' <<<"$out" | sort | xargs) == "Deployment StatefulSet" ]] \
  || fail "expected exactly one Deployment and one StatefulSet"
[[ $(yq '.spec.template.spec.volumes[] | select(.name == "config") | .configMap.name' <<<"$deploy") == "$DEPLOYMENT_CONFIG" ]] \
  || fail "Deployment must run $DEPLOYMENT_CONFIG"
[[ $(yq '.spec.template.spec.volumes[] | select(.name == "config") | .configMap.name' <<<"$sts") == "$STATEFULSET_CONFIG" ]] \
  || fail "StatefulSet must run $STATEFULSET_CONFIG"

# 2. the Deployment receives OTLP and the forwarded pod logs, and does all the processing and export
ports=$(yq '.spec.template.spec.containers[0].ports[].name' <<<"$deploy")
for port in otlp-grpc otlp-http loki-push; do grep -qx "$port" <<<"$ports" || fail "Deployment must expose $port"; done
deployment=$(config "$DEPLOYMENT_CONFIG")
for component in 'otelcol.receiver.otlp "default"' 'loki.source.api "pod_logs"' 'loki.process "limit_time"' \
  'otelcol.receiver.loki "default"' 'otelcol.processor.transform "default"' 'otelcol.exporter.otlphttp "default"'; do
  grep -qF "$component {" <<<"$deployment" || fail "Deployment config must contain $component"
done
grep -qE '^ +use_incoming_timestamp += true$' <<<"$(block 'loki.source.api "pod_logs"' "$deployment")" \
  || fail "loki.source.api must keep the lines' own timestamps"
grep -qE '^(discovery\.kubernetes|loki\.source\.kubernetes) ' <<<"$deployment" && fail "Deployment must not tail pod logs"

# 3. the StatefulSet only tails pod logs, split between its replicas, and forwards them to the Deployment
yq '.spec.template.spec.containers[0].ports[].name' <<<"$sts" | grep -qE 'otlp|loki-push' && fail "StatefulSet must receive nothing"
statefulset=$(config "$STATEFULSET_CONFIG")
[[ $(grep -oE '^[a-z][a-z0-9_.]* "[^"]*"' <<<"$statefulset" | xargs) == 'discovery.kubernetes pod discovery.relabel pod_logs loki.source.kubernetes pod_logs loki.write deployment' ]] \
  || fail "StatefulSet config must only discover, tail and forward, got: $(grep -oE '^[a-z][a-z0-9_.]* "[^"]*"' <<<"$statefulset" | xargs)"
grep -q '^tracing ' <<<"$statefulset" && fail "StatefulSet must not export its own traces"
source_block=$(block 'loki.source.kubernetes "pod_logs"' "$statefulset")
grep -A1 'clustering {' <<<"$source_block" | grep -q 'enabled = true' || fail "pod_logs must enable clustering"
grep -q 'forward_to = \[loki.write.deployment.receiver\]' <<<"$source_block" || fail "pod_logs must forward to loki.write"

# 4. its own cluster, so its clustering metrics and alerts don't mix with the Deployment's
args "$sts" | grep -qx -- '--cluster.name=alloy-logs' || fail "StatefulSet must set its own cluster name"
args "$deploy" | grep -q -- '--cluster.name=alloy-logs' && fail "Deployment must not join the pod logs cluster"
[[ $(args "$sts" | grep -- '--cluster.join-addresses') != $(args "$deploy" | grep -- '--cluster.join-addresses') ]] \
  || fail "the two workloads must join different clusters"

# 5. state on a per-replica PVC, mounted at the storage path, deleted on scale-down and uninstall
storage=$(args "$sts" | sed -n 's/^--storage.path=//p')
claim=$(yq '.spec.volumeClaimTemplates[0].metadata.name' <<<"$sts")
[[ $(yq ".spec.volumeClaimTemplates[0].spec.accessModes[0]" <<<"$sts") == ReadWriteOnce ]] || fail "PVC must be ReadWriteOnce"
[[ $(yq ".spec.template.spec.containers[0].volumeMounts[] | select(.name == \"$claim\") | .mountPath" <<<"$sts") == "$storage" ]] \
  || fail "PVC $claim must be mounted at the storage path $storage"
[[ $(yq '.spec.persistentVolumeClaimRetentionPolicy | .whenScaled + " " + .whenDeleted' <<<"$sts") == "Delete Delete" ]] \
  || fail "PVCs must be deleted when scaled away and on uninstall"
yq 'select(.kind == "HorizontalPodAutoscaler")' <<<"$out" | grep -q . && fail "nothing is autoscaled by default"

# 6. the cluster's default StorageClass unless one is set
[[ $(yq '.spec.volumeClaimTemplates[0].spec.storageClassName' <<<"$sts") == null ]] \
  || fail "PVC must use the default StorageClass when none is set"
custom=$(render -f tests/values-storage-class.yaml | yq 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[0].spec')
[[ $(yq '.storageClassName' <<<"$custom") == fast-ssd ]] || fail "PVC must use the StorageClass set in values"
[[ $(yq '.resources.requests.storage' <<<"$custom") == 2Gi ]] || fail "PVC must use the size set in values"

# 7. the StatefulSet forwards to the Deployment's Service, on the port the Deployment listens on
# expect_url <helm template args...>: loki.write's URL is the rendered Deployment Service's loki-push port
expect_url() {
  local out service port listen
  out=$(render "$@")
  service=$(yq -N 'select(.kind == "Service" and .spec.clusterIP != "None" and (.spec.ports[].name == "loki-push")) | .metadata.name' <<<"$out" | sort -u)
  port=$(N=$service yq -N 'select(.kind == "Service" and .metadata.name == env(N)) | .spec.ports[] | select(.name == "loki-push") | .port' <<<"$out")
  listen=$(config "$DEPLOYMENT_CONFIG" "$@" | sed -n 's/^ *listen_port *= *//p')
  [[ $(config "$STATEFULSET_CONFIG" "$@" | sed -n 's/^ *url *= *"\(.*\)"$/\1/p') == "http://$service:$port/loki/api/v1/push" ]] \
    || fail "${*:-defaults}: loki.write must send to http://$service:$port/loki/api/v1/push"
  [[ $listen == "$(N=$service yq -N 'select(.kind == "Service" and .metadata.name == env(N)) | .spec.ports[] | select(.name == "loki-push") | .targetPort' <<<"$out")" ]] \
    || fail "${*:-defaults}: loki.source.api must listen on the loki-push targetPort"
}
expect_url
expect_url --set alloy.fullnameOverride=otel-in

# 8. one replica, with fail-safes for the time it's down
[[ $(yq '.spec.replicas' <<<"$sts") == 1 ]] || fail "StatefulSet must run one replica"
for key in node.kubernetes.io/unreachable node.kubernetes.io/not-ready; do
  [[ $(K=$key yq '.spec.template.spec.tolerations[] | select(.key == env(K) and .effect == "NoExecute") | .tolerationSeconds' <<<"$sts") == 30 ]] \
    || fail "StatefulSet must leave a $key node after 30s"
done
[[ $(yq '.spec.template.spec.containers[] | select(.name == "alloy") | .livenessProbe.httpGet.path' <<<"$sts") == /-/ready ]] \
  || fail "StatefulSet must have a liveness probe on /-/ready"
yq 'select(.kind == "PodDisruptionBudget")' <<<"$out" | grep -q alloy-logs \
  && fail "a PDB on a single replica would block node drains"
alerts=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "alloy-alerts") | .data["alloy_pod_logs.yaml"]' <<<"$out" \
  | yq '.groups[].rules[].title')
for alert in AlloyPodLogsDown AlloyPodLogsTooOld; do
  grep -qx "$alert" <<<"$alerts" || fail "the $alert alert must be provisioned"
done
# AlloyPodLogsDown watches the rendered StatefulSet, also with a fullnameOverride
for override in "" pod-logs; do
  args=()
  [[ -z $override ]] || args=(--set "alloy-logs.fullnameOverride=$override")
  rendered=$(render "${args[@]}")
  name=$(yq 'select(.kind == "StatefulSet") | .metadata.name' <<<"$rendered")
  watched=$(yq 'select(.kind == "ConfigMap" and .metadata.name == "alloy-alerts") | .data["alloy_pod_logs.yaml"]' <<<"$rendered" \
    | yq '.groups[].rules[] | select(.title == "AlloyPodLogsDown") | .data[0].model.expr' | grep -o 'statefulset="[^"]*"' | sort -u)
  [[ $watched == "statefulset=\"$name\"" ]] || fail "AlloyPodLogsDown must watch StatefulSet $name, got $watched"
done

# 9. a small send queue, so a crash loses little of what was read but not yet sent; changing
# queue_config needs the experimental stability level
write_block=$(block 'loki.write "deployment"' "$statefulset")
grep -q 'batch_size = "256KiB"' <<<"$write_block" || fail "loki.write must send 256KiB batches"
grep -q 'capacity = "256KiB"' <<<"$write_block" || fail "loki.write must queue at most 256KiB"
args "$sts" | grep -qx -- '--stability.level=experimental' || fail "StatefulSet must run at the experimental stability level"

# 10. both workloads pull from the same registry with the same pull secrets: alloy-logs doesn't
# inherit alloy.global.image, so a registry set only there fails the render
if err=$(render --set alloy.global.image.registry=acr.example.io 2>&1 >/dev/null); then
  fail "a registry set only under alloy.global.image must fail the render"
fi
grep -qF 'top-level global.image' <<<"$err" || fail "unexpected error for a registry under alloy only: $err"
images=$(render --set global.image.registry=acr.example.io --set 'global.image.pullSecrets[0].name=acr-registry' \
  | yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet") | .spec.template.spec | (.containers[].image, .imagePullSecrets[].name)')
grep -v -e '^acr.example.io/' -e '^acr-registry$' <<<"$images" && fail "a top-level global.image must apply to both workloads"
[[ $(grep -c '^acr.example.io/' <<<"$images") == 4 && $(grep -c '^acr-registry$' <<<"$images") == 2 ]] \
  || fail "both workloads must pull both images from the top-level global.image registry, got: $images"

echo "OK"
