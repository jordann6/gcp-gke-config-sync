#!/usr/bin/env bash
#
# Teardown.
#
# Simpler than the perimeter builds in this portfolio, because nothing here is
# organization-scoped. The fleet membership, both fleet features, the cluster,
# the network, and the registry all live inside the workload project, and
# deleting the project takes them with it.
#
# Three things still go wrong if you skip Terraform and delete the project by
# hand:
#
#   1. The fleet membership is registered against the cluster's resource link.
#      Deleting the cluster out from under it leaves a membership pointing at
#      nothing, which then has to be force-deleted with gcloud before that
#      membership ID can ever be reused.
#   2. State still describes everything. The next apply plans a create for
#      resources whose project no longer exists and fails partway through.
#   3. Project deletion is a 30-day soft delete. The project ID is not free
#      again until it completes, so a rebuild with the same
#      workload_name_suffix fails on a name that is invisible in the console.
#
# So: Terraform destroys, in dependency order, and then this verifies.
#
# The seed project is deliberately left standing. It costs nothing (an empty
# project with one small bucket) and it holds the state history. Removing it is
# a separate, explicit step at the bottom.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
ENV_FILE="${REPO_ROOT}/.demo.env"

rule() { printf '\n\033[1m%s\033[0m\n%s\n' "$1" "$(printf '=%.0s' {1..72})"; }
note() { printf '  %s\n' "$1"; }

if [ ! -f "${ENV_FILE}" ]; then
  echo "No ${ENV_FILE}. Run ./scripts/demo.sh env while the stack is still up." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

read -r -p "Destroy project ${WORKLOAD_PROJECT} and cluster ${CLUSTER}? [yes/NO] " confirm
[ "${confirm}" = "yes" ] || {
  echo "Aborted."
  exit 1
}

rule "1. Turn the admission webhook off first"
note "if prevent_drift was left on, the Config Sync webhook is still intercepting"
note "writes to managed objects. It does not block the destroy, because Terraform"
note "deletes the cluster rather than the objects in it, but leaving a webhook"
note "whose backing service is being deleted is how a hung finalizer happens."
terraform -chdir="${TF_DIR}" apply -auto-approve -no-color \
  -var 'prevent_drift=false' \
  -target=google_gke_hub_feature_membership.config_sync >/dev/null 2>&1 || true
note "done"

rule "2. Destroy the root module"
note "order matters and Terraform derives it: feature memberships, then the"
note "fleet membership, then the node pool, then the cluster, then the network."
note "expect 12 to 15 minutes, nearly all of it the cluster."
terraform -chdir="${TF_DIR}" destroy -auto-approve -no-color

rule "3. Verify nothing survived"

note "fleet memberships still registered in the project:"
gcloud container fleet memberships list --project="${WORKLOAD_PROJECT}" \
  --format='value(name)' 2>/dev/null | sed 's/^/      /' ||
  note "      none (or the project is already gone, which is the same answer)"

note ""
note "project state:"
gcloud projects describe "${WORKLOAD_PROJECT}" \
  --format='value(lifecycleState)' 2>/dev/null | sed 's/^/      /' ||
  note "      not found, fully deleted"

note ""
note "If the project shows DELETE_REQUESTED, that is correct. It stays that way"
note "for 30 days and the ID is not reusable until it clears. To rebuild before"
note "then, change workload_name_suffix in terraform.tfvars."

rule "4. What is deliberately still standing"
note "the seed project and the state bucket. Empty project, one small bucket,"
note "effectively free, and it holds the state history for this build."
note ""
note "To remove them for good:"
note "  terraform -chdir=bootstrap apply -auto-approve -var force_destroy_state=true"
note "  terraform -chdir=bootstrap destroy"
note ""
note "The apply before the destroy is not optional. force_destroy_state defaults"
note "to false, and a bucket with objects in it refuses to be deleted, which"
note "leaves the bootstrap destroy half finished."

rule "5. Confirm the bill"
note "check that nothing is still accruing:"
note "  https://console.cloud.google.com/billing"
note ""
note "the two line items that matter are the GKE control plane fee and the"
note "Cloud NAT gateway. Both stop with the project."
