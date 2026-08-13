locals {
  workload_project_id = "${var.name_prefix}-${var.workload_name_suffix}"

  workload_apis = [
    # The two anthos* APIs still carry that name even though the GKE Enterprise
    # tier they were named for was dissolved in September 2025 and the features
    # are now included in base GKE. Enabling them costs nothing and grants
    # nothing; they are the API surfaces the fleet features are served from.
    #
    # gkehub.googleapis.com is not enough on its own, and the failure is a
    # 400 "failed precondition" on google_gke_hub_feature that names the missing
    # API but arrives 15 minutes into an apply, after the cluster is already
    # built. Both of these belong in the list from the start.
    "anthosconfigmanagement.googleapis.com",
    "anthospolicycontroller.googleapis.com",
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "gkehub.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_project" "workload" {
  name            = local.workload_project_id
  project_id      = local.workload_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = var.labels

  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project_service" "workload" {
  for_each = toset(local.workload_apis)

  project            = google_project.workload.project_id
  service            = each.value
  disable_on_destroy = false
}

# Enabling container.googleapis.com creates the GKE service agent, and the
# service agent is granted its role asynchronously after the API reports ready.
# Creating a cluster inside that window fails with a permission error against a
# service account you never made and cannot see in the IAM page yet.
#
# Thirty seconds is empirical, not documented. It is the smallest wait that has
# not failed across repeated builds of this repo.
resource "time_sleep" "service_agent_propagation" {
  depends_on      = [google_project_service.workload]
  create_duration = "30s"
}

resource "google_project_iam_audit_config" "workload" {
  project = google_project.workload.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

# Cluster administration for the human running this, granted at the project
# rather than through the cluster's own RBAC.
#
# This is the boundary worth naming. Everything in config/ is reconciled from
# Git and any hand edit to it is either reverted or refused. This grant is not,
# because it is the grant that lets you break glass when the reconciler itself
# is what is broken. GitOps that cannot be escaped is GitOps you cannot recover.
resource "google_project_iam_member" "admin_cluster" {
  project = google_project.workload.project_id
  role    = "roles/container.clusterAdmin"
  member  = var.admin_principal
}

# Reading the cluster endpoint and credentials, which clusterAdmin does not
# include on its own.
resource "google_project_iam_member" "admin_viewer" {
  project = google_project.workload.project_id
  role    = "roles/container.clusterViewer"
  member  = var.admin_principal
}
