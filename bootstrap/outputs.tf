output "seed_project_id" {
  description = "Project holding Terraform state and acting as the API quota project."
  value       = google_project.seed.project_id
}

output "state_bucket" {
  description = "Terraform state bucket."
  value       = google_storage_bucket.state.name
}

output "backend_hcl" {
  description = "Paste into terraform/backend.hcl, then: terraform init -backend-config=backend.hcl"
  value       = <<-EOT
    bucket = "${google_storage_bucket.state.name}"
    prefix = "gke-config-sync/dev"
  EOT
}

output "tfvars_snippet" {
  description = "Values the root module needs."
  value       = <<-EOT
    seed_project_id = "${google_project.seed.project_id}"
  EOT
}
