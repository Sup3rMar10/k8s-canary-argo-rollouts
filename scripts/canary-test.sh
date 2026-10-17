#!/usr/bin/env bash
# Drives three releases through the canary and asserts the outcome of each:
#   v1 (first deploy) -> v2 (good, promoted) -> v3 (broken API, must be aborted) -> back to v2.
# Needs a cluster with Argo Rollouts installed. Only kubectl is used (no Argo CLI plugin).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

step() { echo; echo "== $*"; }
ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}
expect() { # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi
}

phase() { kubectl get rollout webapp -o jsonpath='{.status.phase}' 2>/dev/null || true; }

wait_phase() { # wait_phase <timeout-seconds> <phase...>: returns the phase reached, or fails on timeout
  local timeout="$1" p
  shift
  for _ in $(seq 1 "$timeout"); do
    p="$(phase)"
    for want in "$@"; do
      if [ "$p" = "$want" ]; then
        echo "$p"
        return 0
      fi
    done
    sleep 1
  done
  echo "timeout (last phase: $p)"
  return 1
}

wait_update_started() { # the phase stays Healthy for an instant after a patch; wait for it to leave
  for _ in $(seq 1 30); do
    [ "$(phase)" != "Healthy" ] && return 0
    sleep 1
  done
  return 1
}

release() { # release <version> <api-status>: change the pod template, which starts a new rollout
  kubectl patch rollout webapp --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/0/value\",\"value\":\"$1\"},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/1/value\",\"value\":\"$2\"}
  ]" >/dev/null
}

fetch() { # fetch <service> <path>: GET from inside the cluster, retried (the first pod pulls the image)
  local out
  for _ in 1 2 3 4 5; do
    out="$(kubectl run "curl-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.11.1 -- \
      curl -fsS --max-time 3 "http://$1$2" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -n "$out" ]; then
      printf '%s' "$out"
      return 0
    fi
    sleep 1
  done
  return 1
}

always_serves() { # always_serves <version>: 8 requests to the stable service, all must be this version
  local seen
  seen="$(for _ in 1 2 3 4 5 6 7 8; do fetch webapp-stable /version; echo; done | sort -u | tr '\n' ' ')"
  expect "stable service serves only $1" "$1 " "$seen"
}

analysis_phases() { kubectl get analysisrun -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' | sort | uniq -c | tr -s ' ' | tr '\n' ';'; }

step "first deploy (v1)"
kubectl apply -k "$here/../manifests"
expect "rollout becomes Healthy" "Healthy" "$(wait_phase 180 Healthy)"
always_serves v1

step "good release (v2) is promoted"
release v2 200
wait_update_started || bad "update never started"
expect "rollout finishes Healthy" "Healthy" "$(wait_phase 240 Healthy Degraded)"
always_serves v2
echo "  analysis runs so far: $(analysis_phases)"
if kubectl get analysisrun -o jsonpath='{.items[*].status.phase}' | grep -q Successful; then ok "an analysis run Succeeded"; else bad "no successful analysis run"; fi

step "broken release (v3: readiness passes, /api/check returns 500) is aborted"
release v3 500
wait_update_started || bad "update never started"
expect "rollout ends Degraded (aborted)" "Degraded" "$(wait_phase 240 Healthy Degraded)"
message="$(kubectl get rollout webapp -o jsonpath='{.status.message}')"
echo "  message: $message"
if grep -qi 'abort' <<<"$message"; then ok "status message says the rollout was aborted"; else bad "status message does not mention an abort"; fi
if kubectl get analysisrun -o jsonpath='{.items[*].status.phase}' | grep -q Failed; then ok "an analysis run Failed"; else bad "no failed analysis run"; fi
always_serves v2
expect "stable ReplicaSet still has all 4 replicas ready" "4" "$(kubectl get rollout webapp -o jsonpath='{.status.stableRS}' | xargs -I{} kubectl get rs -l rollouts-pod-template-hash={} -o jsonpath='{.items[0].status.readyReplicas}')"

step "recover by putting v2 back"
release v2 200
expect "rollout returns to Healthy" "Healthy" "$(wait_phase 240 Healthy)"
always_serves v2

echo
echo "checks passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
