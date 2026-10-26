#!/usr/bin/env bash
# Asserts on the rendered workloads: a Deployment that receives OTLP, and a StatefulSet that
# collects pod logs, splits the pods between its replicas and keeps its state on a per-replica PVC
# (of the default or a chosen StorageClass) that's deleted when the replica is scaled away.
source "$(dirname "$0")/lib.sh"

out=$(render)
deploy=$(yq 'select(.kind == "Deployment")' <<<"$out")
sts=$(yq 'select(.kind == "StatefulSet")' <<<"$out")
args() { yq '.spec.template.spec.containers[] | select(.name == "alloy") | .args[]' <<<"$1"; }

# 1. one workload of each kind, each running its own config
[[ $(yq -N 'select(.kind == "Deployment" or .kind == "StatefulSet") | .kind' <<<"$out" | sort | xargs) == "Deployment StatefulSet" ]] \
  || fail "expected exactly one Deployment and one StatefulSet"
[[ $(yq '.spec.template.spec.volumes[] | select(.name == "config") | .configMap.name' <<<"$deploy") == "$OTLP_CONFIG" ]] \
  || fail "Deployment must run $OTLP_CONFIG"
[[ $(yq '.spec.template.spec.volumes[] | select(.name == "config") | .configMap.name' <<<"$sts") == "$LOGS_CONFIG" ]] \
  || fail "StatefulSet must run $LOGS_CONFIG"

# 2. only the Deployment receives OTLP; it collects no pod logs
yq '.spec.template.spec.containers[0].ports[].name' <<<"$deploy" | grep -qx 'otlp-grpc' || fail "Deployment must expose OTLP gRPC"
yq '.spec.template.spec.containers[0].ports[].name' <<<"$sts" | grep -q 'otlp' && fail "StatefulSet must not expose OTLP ports"
otlp=$(config "$OTLP_CONFIG")
grep -q '^otelcol.receiver.otlp "default" {' <<<"$otlp" || fail "OTLP config must receive OTLP"
grep -qE '^(discovery\.kubernetes|discovery\.relabel|loki\.source\.kubernetes|loki\.process|otelcol\.receiver\.loki|otelcol\.processor\.transform) ' <<<"$otlp" \
  && fail "OTLP config must not contain the pod logs pipeline"

# 3. only the StatefulSet collects pod logs, and its replicas split the pods
logs=$(config "$LOGS_CONFIG")
grep -q '^otelcol.receiver.otlp ' <<<"$logs" && fail "pod logs config must not receive OTLP"
source_block=$(block 'loki.source.kubernetes "pod_logs"' "$logs")
[[ -n $source_block ]] || fail "pod logs config must contain loki.source.kubernetes \"pod_logs\""
grep -A1 'clustering {' <<<"$source_block" | grep -q 'enabled = true' || fail "pod_logs must enable clustering"

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
[[ $(yq '.spec.replicas' <<<"$sts") -ge 2 ]] || fail "StatefulSet should run more than one replica"
yq 'select(.kind == "HorizontalPodAutoscaler")' <<<"$out" | grep -q . && fail "nothing is autoscaled by default"

# 6. the cluster's default StorageClass unless one is set
[[ $(yq '.spec.volumeClaimTemplates[0].spec.storageClassName' <<<"$sts") == null ]] \
  || fail "PVC must use the default StorageClass when none is set"
custom=$(render -f tests/values-storage-class.yaml | yq 'select(.kind == "StatefulSet") | .spec.volumeClaimTemplates[0].spec')
[[ $(yq '.storageClassName' <<<"$custom") == fast-ssd ]] || fail "PVC must use the StorageClass set in values"
[[ $(yq '.resources.requests.storage' <<<"$custom") == 2Gi ]] || fail "PVC must use the size set in values"

echo "OK"
