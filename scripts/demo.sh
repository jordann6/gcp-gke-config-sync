#!/usr/bin/env bash
#
# The demonstration, in six acts.
#
# The argument is that a cluster with a GitOps reconciler and an admission
# controller has two different kinds of guarantee, and that knowing which one
# you have matters more than having either.
#
# Acts 2 and 3 are the pair that carries it. The same deletion, of the same
# object, by the same person, is corrected after the fact in act 2 and refused
# outright in act 3. Nothing changed except one boolean. Reconciliation is
# eventual consistency with a window; admission control is a control. People use
# the words interchangeably and they are not the same promise.
#
#   ./scripts/demo.sh env      render .demo.env and point kubectl at the cluster
#   ./scripts/demo.sh act1     the cluster reports the commit it is running
#   ./scripts/demo.sh act2     drift is reverted, after a window
#   ./scripts/demo.sh act3     the same drift is refused, with no window
#   ./scripts/demo.sh act4     a privileged pod is rejected at admission
#   ./scripts/demo.sh act5     an unapproved registry is rejected at admission
#   ./scripts/demo.sh act6     what the dry-run constraint would break
#   ./scripts/demo.sh all      every act in order

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..72})"; }
note() { printf '  %s\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

load_env() {
  if [ ! -f "${ENV_FILE}" ]; then
    echo "No ${ENV_FILE}. Run: ./scripts/demo.sh env" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
}

# The Config Sync drift-prevention webhook, by pattern rather than by exact
# name. It has been called admission-webhook.configsync.gke.io, and matching the
# string exactly means a rename in a future Config Sync version turns acts 2 and
# 3 into confident wrong answers rather than errors.
webhook_present() {
  kubectl get validatingwebhookconfiguration -o name 2>/dev/null |
    grep -qi 'configsync'
}

# Fail fast on the one missing dependency that otherwise looks like a broken
# cluster.
#
# kubectl talks to GKE through gke-gcloud-auth-plugin, which is a separate
# gcloud component and is not installed by default. Without it every kubectl
# call fails with an exec error rather than a connection error, and the wait
# loop below, which tolerates a not-yet-ready cluster by design, swallows those
# for ten minutes and then reports that Config Sync never synced. The cluster is
# fine. Nothing ever reached it.
require_auth_plugin() {
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
    return 0
  fi
  fail "gke-gcloud-auth-plugin is not on PATH"
  note "kubectl cannot authenticate to GKE without it, and the failure looks"
  note "like an unreachable cluster rather than a missing binary."
  note ""
  note "  gcloud components install gke-gcloud-auth-plugin"
  note ""
  note "If gcloud was installed with Homebrew, components install may be"
  note "disabled, in which case:"
  note "  brew install --cask google-cloud-sdk-gke-gcloud-auth-plugin"
  return 1
}

cmd_env() {
  require_auth_plugin || return 1
  rule "Rendering ${ENV_FILE}"
  terraform -chdir="${TF_DIR}" output -raw demo_env >"${ENV_FILE}"
  note "wrote $(grep -c '=' "${ENV_FILE}") variables"
  load_env

  note "pointing kubectl at ${CLUSTER}"
  gcloud container clusters get-credentials "${CLUSTER}" \
    --zone "${ZONE}" --project "${WORKLOAD_PROJECT}" >/dev/null 2>&1

  note "waiting for Config Sync to reach a synced state"
  note "first sync after an apply takes two to four minutes: the fleet feature"
  note "has to install the reconciler before the reconciler can clone anything"

  local i commit=""
  for i in $(seq 1 60); do
    commit="$(kubectl get rootsync root-sync -n config-management-system \
      -o jsonpath='{.status.sync.commit}' 2>/dev/null || true)"
    [ -n "${commit}" ] && break
    sleep 10
  done

  if [ -z "${commit}" ]; then
    fail "Config Sync never reported a synced commit"
    note "look at why:"
    note "  kubectl get rootsync root-sync -n config-management-system -o yaml"
    note "  kubectl logs -n config-management-system -l app=reconciler -c git-sync --tail=50"
    note ""
    note "the usual cause is egress. The reconciler clones github.com over the"
    note "internet, so if Cloud NAT is missing or the router is not attached,"
    note "this hangs forever reporting a git error that reads like auth."
    return 1
  fi
  pass "synced at ${commit:0:12}"
}

# Act 1. The cluster tells you what it is running, and it is a commit.
#
# This is the property that makes the rest of it worth doing. Not that the
# config is in Git, which is just a file location, but that the running state is
# addressable by commit. "What is deployed" has an answer that is checkable
# against the repo rather than assembled from memory.
cmd_act1() {
  load_env
  rule "Act 1. The commit the cluster is running"

  local cluster_commit remote_commit
  cluster_commit="$(kubectl get rootsync root-sync -n config-management-system \
    -o jsonpath='{.status.sync.commit}')"
  remote_commit="$(git -C "${REPO_ROOT}" ls-remote "${SYNC_REPO}" "refs/heads/${SYNC_BRANCH}" | cut -f1)"

  note "cluster reports:  ${cluster_commit}"
  note "${SYNC_BRANCH} head is:      ${remote_commit}"
  note "source:           ${SYNC_REPO}/${SYNC_DIR}"

  if [ "${cluster_commit}" = "${remote_commit}" ]; then
    pass "running state matches the branch head exactly"
  else
    fail "cluster is on a different commit than the branch head"
    note "not necessarily broken. If you pushed in the last ${SYNC_WAIT_SECS} seconds,"
    note "wait one poll interval and run this again."
    return 1
  fi

  note ""
  note "objects Config Sync owns, and where each one came from:"
  kubectl get resourcegroup root-sync -n config-management-system \
    -o jsonpath='{range .spec.resources[*]}{"      "}{.kind}{"/"}{.name}{"\n"}{end}' 2>/dev/null |
    sort | head -20

  note ""
  note "the tenant namespace exists because a file in Git says so:"
  kubectl get namespace team-a -o jsonpath='{.metadata.labels}' | sed 's/^/      /'
  echo
}

# Act 2. Drift, corrected.
#
# Deleting a ResourceQuota is the realistic mistake. Nobody deletes a namespace
# by accident, they delete the object that is blocking a deploy, meaning to put
# it back.
cmd_act2() {
  load_env
  rule "Act 2. Delete a managed object with prevent_drift off"

  # Ask the cluster rather than Terraform. The webhook object either exists or
  # it does not, and that is the thing act 2 actually depends on. Reading the
  # variable would tell you what was last applied, which is not the same claim.
  if webhook_present; then
    note "the Config Sync admission webhook is currently installed, so this"
    note "delete would be refused rather than reconciled. Act 2 needs it off:"
    note "  terraform -chdir=terraform apply -var prevent_drift=false \\"
    note "    -target=google_gke_hub_feature_membership.config_sync"
    return 1
  fi

  note "deleting resourcequota/team-a-quota from namespace team-a"
  kubectl delete resourcequota team-a-quota -n team-a --wait=true
  note "gone. Confirming:"
  kubectl get resourcequota -n team-a 2>&1 | sed 's/^/      /'

  note ""
  note "nothing rejected that. The object is genuinely deleted, and the cluster"
  note "no longer matches Git. Config Sync polls every ${SYNC_WAIT_SECS}s."

  local i
  for i in $(seq 1 24); do
    if kubectl get resourcequota team-a-quota -n team-a >/dev/null 2>&1; then
      pass "reconciled back after roughly $((i * 5)) seconds"
      kubectl get resourcequota team-a-quota -n team-a -o jsonpath='{.spec.hard}' |
        sed 's/^/      /'
      echo
      note ""
      note "This is the part worth being precise about. For those seconds the"
      note "quota did not exist, and any pod admitted in that window was"
      note "admitted without it. The guarantee is eventual, and the window is"
      note "sync_wait_secs plus apply time. That is fine for a quota and it is"
      note "not fine for everything."
      return 0
    fi
    sleep 5
  done

  fail "not reconciled within two minutes"
  note "check the reconciler:"
  note "  kubectl get rootsync root-sync -n config-management-system -o yaml"
  return 1
}

# Act 3. The same drift, refused.
#
# prevent_drift installs a validating admission webhook that rejects writes to
# objects Config Sync manages. The delete never lands, so there is no window.
cmd_act3() {
  load_env
  rule "Act 3. The same deletion with prevent_drift on"

  note "enabling the Config Sync admission webhook"
  note "this is a terraform apply because the setting belongs to the fleet"
  note "feature, not to the cluster. Roughly 90 seconds."
  terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
    -var 'prevent_drift=true' \
    -target=google_gke_hub_feature_membership.config_sync >/dev/null

  note "waiting for the webhook to be serving"
  local i
  for i in $(seq 1 30); do
    webhook_present && break
    sleep 10
  done

  if ! webhook_present; then
    fail "the admission webhook never registered"
    note "kubectl get validatingwebhookconfiguration"
    return 1
  fi
  note "webhook registered. Giving it 30s to have endpoints behind it."
  sleep 30

  note ""
  note "attempting the exact same delete as act 2"

  local out rc=0
  out="$(kubectl delete resourcequota team-a-quota -n team-a 2>&1)" || rc=$?

  if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qi "configsync\|admission webhook\|denied the request"; then
    pass "refused at admission. The delete never reached etcd."
    printf '%s\n' "${out}" | sed 's/^/      /' | head -8
    note ""
    note "Same person, same permission, same object, same command. In act 2 the"
    note "cluster was briefly wrong and then corrected itself. Here it was never"
    note "wrong. The difference is not policy, it is where the policy runs."
  elif [ "${rc}" -eq 0 ]; then
    fail "the delete SUCCEEDED. The webhook is not intercepting."
    note "it may still be starting. Wait 60s and run act3 again."
    note "restoring prevent_drift=false before exiting"
    terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
      -target=google_gke_hub_feature_membership.config_sync >/dev/null
    return 1
  else
    fail "denied, but read the error before claiming the win:"
    printf '%s\n' "${out}" | sed 's/^/      /' | head -10
    return 1
  fi

  note ""
  note "restoring prevent_drift=false so act 2 is repeatable"
  terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
    -target=google_gke_hub_feature_membership.config_sync >/dev/null
  note "restored"
}

# Act 4. Two admission controllers with the same opinion, and which one gets
# there first.
#
# This act originally asserted that the denial would name
# deny-privileged-containers. It does not, and the reason is worth more than the
# assertion was.
#
# Pod Security Admission is built into the API server and runs in the admission
# chain BEFORE any validating webhook. The namespaces in config/namespaces carry
# pod-security.kubernetes.io/enforce: baseline, and baseline's definition of
# forbidden starts with privileged containers. So PSA refuses the pod and
# Gatekeeper is never consulted.
#
# The two controls are genuinely redundant here, which is the intent: PSA cannot
# be disabled by deleting a CRD, and Policy Controller covers rules PSA has no
# vocabulary for. But redundancy means the outer layer answers, and a demo that
# insists on hearing from the inner one is asserting something about ordering
# that is not true.
#
# So the act asserts the pod is refused and reports which layer refused it.
# Act 5 is where Gatekeeper speaks, because approving image registries is
# something PSA has no opinion about at all.
cmd_act4() {
  load_env
  rule "Act 4. A privileged container, and which controller catches it"

  note "two controls apply to this namespace, in this order:"
  note "  1. Pod Security Admission, built into the API server, enforce=baseline"
  note "  2. Policy Controller, a validating webhook, deny-privileged-containers"
  kubectl get k8spsprivilegedcontainer deny-privileged-containers \
    -o jsonpath='{"      constraint enforcementAction: "}{.spec.enforcementAction}{"\n"}' 2>/dev/null || true

  local out rc=0
  out="$(kubectl apply -n team-a -f - <<'EOF' 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: privileged-probe
spec:
  containers:
    - name: probe
      image: registry.k8s.io/pause:3.10
      securityContext:
        privileged: true
EOF
  )" || rc=$?

  if [ "${rc}" -eq 0 ]; then
    fail "the pod was ADMITTED. Neither control is enforcing."
    kubectl delete pod privileged-probe -n team-a --ignore-not-found >/dev/null 2>&1
    note "check both:"
    note "  kubectl get ns team-a -o jsonpath='{.metadata.labels}'"
    note "  kubectl get k8spsprivilegedcontainer"
    return 1
  fi

  printf '%s\n' "${out}" | fold -w 100 | sed 's/^/      /' | head -6

  if printf '%s' "${out}" | grep -qi "PodSecurity"; then
    pass "refused by Pod Security Admission, the outer layer"
    note ""
    note "Gatekeeper never saw this request. PSA runs inside the API server,"
    note "ahead of every validating webhook, so the outer control answers and"
    note "the inner one is not consulted. deny-privileged-containers is loaded"
    note "and enforcing; it simply never gets asked about a pod that PSA has"
    note "already rejected."
    note ""
    note "That ordering is the useful thing to know. Removing the constraint"
    note "would not change this output, which means this test cannot tell you"
    note "whether Policy Controller is working. Act 5 can, because approving"
    note "image registries is something PSA has no vocabulary for."
  elif printf '%s' "${out}" | grep -qi "deny-privileged-containers"; then
    pass "refused by the Policy Controller constraint"
    note ""
    note "PSA did not catch this one, so the webhook was consulted and refused."
    note "Check whether the namespace still carries its pod-security labels."
  else
    fail "refused, but by neither expected control. Read it before moving on."
    return 1
  fi
}

# Act 5. Where images may come from.
cmd_act5() {
  load_env
  rule "Act 5. An image from an unapproved registry"

  note "constraint: approved-image-sources (K8sAllowedRepos)"
  kubectl get k8sallowedrepos approved-image-sources \
    -o jsonpath='{"      allowed: "}{.spec.parameters.repos}{"\n"}' 2>/dev/null || true
  note "approved Artifact Registry for this build: ${ARTIFACT_REGISTRY}"

  local out rc=0
  out="$(kubectl apply -n team-a -f - <<'EOF' 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: dockerhub-probe
spec:
  containers:
    - name: probe
      image: docker.io/library/nginx:1.27
EOF
  )" || rc=$?

  if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qi "approved-image-sources"; then
    pass "rejected by the named constraint"
    printf '%s\n' "${out}" | fold -w 100 | sed 's/^/      /' | head -8
    note ""
    note "the image was never pulled. This is not a failed pull that shows up as"
    note "ImagePullBackOff two minutes later, it is a refusal at write time."
  elif [ "${rc}" -eq 0 ]; then
    fail "the pod was ADMITTED from docker.io."
    kubectl delete pod dockerhub-probe -n team-a --ignore-not-found >/dev/null 2>&1
    return 1
  else
    fail "rejected, but not by this constraint:"
    printf '%s\n' "${out}" | sed 's/^/      /' | head -10
    return 1
  fi
}

# Act 6. The constraint that is not enforcing, and why that is the useful one.
cmd_act6() {
  load_env
  rule "Act 6. What enforcing the digest rule would break"

  note "constraint: pin-images-to-digests (K8sRequireImageDigest, custom template)"
  local action total
  action="$(kubectl get k8srequireimagedigest pin-images-to-digests \
    -o jsonpath='{.spec.enforcementAction}' 2>/dev/null || true)"
  note "enforcementAction: ${action}"

  if [ "${action}" != "dryrun" ]; then
    fail "expected dryrun, got '${action}'"
    return 1
  fi

  note ""
  note "the audit controller re-evaluates everything already running every 60s,"
  note "which is how a new constraint reports on objects that predate it."
  note "admission control only ever sees new writes."
  note ""

  local i
  for i in $(seq 1 12); do
    total="$(kubectl get k8srequireimagedigest pin-images-to-digests \
      -o jsonpath='{.status.totalViolations}' 2>/dev/null || true)"
    [ -n "${total}" ] && break
    sleep 10
  done

  if [ -z "${total}" ]; then
    fail "no audit results yet. Give it another minute and re-run."
    return 1
  fi

  note "totalViolations: ${total}"
  kubectl get k8srequireimagedigest pin-images-to-digests \
    -o jsonpath='{range .status.violations[*]}{"      "}{.kind}{" "}{.namespace}{"/"}{.name}{": "}{.message}{"\n"}{end}' 2>/dev/null

  if [ "${total}" -gt 0 ]; then
    pass "the dry run found what enforcing this would reject"
    note ""
    note "that is the sample app in config/workloads, which pulls"
    note "registry.k8s.io/pause by tag. It is running right now and it would"
    note "stop being schedulable the moment this constraint moved to deny."
    note ""
    note "Promoting it is a one-word diff in"
    note "config/constraints/require-image-digest.yaml and a pull request."
    note "Doing that without reading this first is how a policy rollout takes"
    note "down a namespace on a Friday."
  else
    note "no violations, which means nothing is running on a tagged image."
    note "unexpected here: the sample app is meant to be one."
  fi
}

cmd_all() {
  cmd_env
  cmd_act1
  cmd_act2
  cmd_act3
  cmd_act4
  cmd_act5
  cmd_act6
  rule "Done"
  note "tear it down: ./scripts/destroy.sh"
}

case "${1:-}" in
env) cmd_env ;;
act1) cmd_act1 ;;
act2) cmd_act2 ;;
act3) cmd_act3 ;;
act4) cmd_act4 ;;
act5) cmd_act5 ;;
act6) cmd_act6 ;;
all) cmd_all ;;
*)
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
