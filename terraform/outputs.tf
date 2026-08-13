output "workload_project_id" {
  description = "Project holding the cluster."
  value       = google_project.workload.project_id
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.main.name
}

output "get_credentials" {
  description = "Command to point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${var.zone} --project ${google_project.workload.project_id}"
}

output "sync_source" {
  description = "What the cluster reconciles from."
  value       = "${var.sync_repo} (branch ${var.sync_branch}, dir ${var.sync_dir})"
}

output "prevent_drift" {
  description = "Whether the Config Sync admission webhook is refusing drift, or only correcting it after the fact."
  value       = var.prevent_drift
}

output "artifact_registry" {
  description = "The one image source the allowed-repos constraint approves."
  value       = "${var.region}-docker.pkg.dev/${google_project.workload.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

# Rendered to .demo.env by scripts/demo.sh, so the acts do not have to shell out
# to terraform between every step. Gitignored: no secrets in it, but it is
# generated state and it names project IDs.
output "demo_env" {
  description = "Shell variables for scripts/demo.sh."
  value       = <<-EOT
    WORKLOAD_PROJECT="${google_project.workload.project_id}"
    CLUSTER="${google_container_cluster.main.name}"
    ZONE="${var.zone}"
    REGION="${var.region}"
    MEMBERSHIP="${google_gke_hub_membership.cluster.membership_id}"
    SYNC_REPO="${var.sync_repo}"
    SYNC_BRANCH="${var.sync_branch}"
    SYNC_DIR="${var.sync_dir}"
    SYNC_WAIT_SECS="${var.sync_wait_secs}"
    PREVENT_DRIFT="${var.prevent_drift}"
    ARTIFACT_REGISTRY="${var.region}-docker.pkg.dev/${google_project.workload.project_id}/${google_artifact_registry_repository.apps.repository_id}"
  EOT
}
