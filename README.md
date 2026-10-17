# k8s-canary-argo-rollouts

![ci](https://github.com/Sup3rMar10/k8s-canary-argo-rollouts/actions/workflows/ci.yml/badge.svg)

Canary releases with [Argo Rollouts](https://argoproj.github.io/rollouts/): a new version gets a small share of pods, an **analysis** judges it, and a bad release is **aborted automatically** while the stable version keeps serving.

> **What is verified.** On 2026-10-17 the pipeline ran green on GitHub Actions (kind cluster, Argo Rollouts v1.10.1): **12 of 12 checks** across three releases: a first deploy, a good release that is promoted, a broken release that is aborted, and a recovery. Nothing here ran on a real cluster, and there is no real traffic or metrics system behind it.

## How it works

- `manifests/rollout.yaml` defines a `Rollout` with `stableService` and `canaryService`, 4 replicas, and these steps: **25%**, then an **analysis**, then **50%**, a 10 second pause, **100%**.
- The analysis (`AnalysisTemplate api-check`) is a Kubernetes **Job**: three `curl` checks, 5 seconds apart, against the *canary* Service only, with `failureLimit: 0`. One failed check fails the analysis.
- The app is stock nginx. A ConfigMap holds an nginx template and two environment variables decide what a "release" does: `APP_VERSION` and `API_STATUS`. A broken release is `API_STATUS=500`.
- **A broken release still passes its readiness probe** (`/healthz` is always 200). That is the point: a readiness probe cannot catch a service that is up but wrong; analysis can.

## What `scripts/canary-test.sh` proves

| Release | Expected | Result |
|---|---|---|
| v1, first deploy | rollout Healthy, stable serves only v1 | pass |
| v2, good (`API_STATUS=200`) | analysis Succeeded, rollout Healthy, stable serves only v2 | pass |
| v3, broken (`API_STATUS=500`) | analysis **Failed**, rollout `Degraded` with message `RolloutAborted: ... Metric "api-check" assessed Failed due to failed (1) > failureLimit (0)`, stable still serves only v2, stable ReplicaSet still has all 4 replicas ready | pass |
| back to v2 | rollout returns to Healthy, stable serves only v2 | pass |

## Honest limits

- **No traffic router.** There is no ingress or service mesh, so "25%" means 1 pod of 4, not 25% of requests. The analysis calls the canary Service directly, which is not the same as real users hitting a mix of versions.
- **The analysis is a synthetic check**: three requests to one endpoint. Production canaries usually judge error rate and latency from a metrics provider such as Prometheus over minutes. This is the mechanism, not a production policy.
- The first deploy of a Rollout skips the steps (there is nothing to compare against), which is Argo Rollouts' normal behaviour.
- I did not test the manual `promote`/`abort` commands or the Argo Rollouts dashboard.
- Argo Rollouts is installed from the release manifest (v1.10.1), not Helm, and needs `kubectl apply --server-side` because its CRDs exceed the 256 KiB client-side annotation limit; my first CI run failed on exactly that.
- My first complete run failed one check because the first request from a freshly started `curl` pod returned nothing; the helper now retries.
- Timings (the pauses, the analysis count) are short so CI is fast.

## Run it locally

With a cluster (kind is fine) and kubectl:

```
kubectl create namespace argo-rollouts
kubectl apply --server-side -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/install.yaml
scripts/canary-test.sh
```

I did not run it locally (Docker was not running on my machine); the CI runs are the evidence.
