# Bootstrap layer.
#
# Creates the seed project and the Terraform state bucket. The seed holds state
# and acts as the API quota project for calls made with user credentials. It
# holds nothing else.
#
# Two layers rather than one because of what the root module does on destroy. It
# deletes the workload project, and the workload project is where a
# single-layer build would have put the state bucket. A destroy that removes the
# bucket holding its own state finishes by failing to write the state that says
# it finished, and the recovery is manual.
#
# The seed is cheap to keep between runs. Deleting the workload project and
# rebuilding it against the same seed is the normal cycle here.

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  seed_project_id = "${var.name_prefix}-seed-${random_id.suffix.hex}"

  # Every API the root module *calls*, which is not the same as every API the
  # built system uses.
  #
  # The root module sets user_project_override with billing_project pointed
  # here, so the seed is the quota project for every call Terraform makes.
  # Google requires an API to be enabled on the quota project as well as on the
  # project the resource lands in. Creating a cluster in the workload project
  # with container.googleapis.com missing here fails with SERVICE_DISABLED
  # naming the seed, which is a project you are not building anything in. That
  # mismatch between the error and the intent is what makes it cost an hour.
  seed_apis = [
    "artifactregistry.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "gkehub.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

resource "google_project" "seed" {
  name            = local.seed_project_id
  project_id      = local.seed_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "seed" })

  deletion_policy = "DELETE"

  # The default VPC arrives with firewall rules nobody chose, in every region,
  # including SSH from anywhere. Nothing in the seed needs a network at all.
  auto_create_network = false
}

resource "google_project_service" "seed" {
  for_each = toset(local.seed_apis)

  project = google_project.seed.project_id
  service = each.value

  # Disabling an API on destroy sounds tidy and is not. It fails whenever any
  # other resource in any project still depends on it, and the failure lands in
  # the middle of a teardown.
  disable_on_destroy = false
}

resource "google_project_iam_audit_config" "seed" {
  project = google_project.seed.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

resource "google_storage_bucket" "state_logs" {
  # checkov:skip=CKV_GCP_62: log bucket, so access logging terminates here.
  name     = "${local.seed_project_id}-tfstate-logs"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}

resource "google_storage_bucket" "state" {
  name     = "${local.seed_project_id}-tfstate"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Defaults to false so a stray destroy of the bootstrap layer cannot take the
  # state history with it. Set true only for a genuine final teardown.
  force_destroy = var.force_destroy_state

  versioning {
    enabled = true
  }

  logging {
    log_bucket        = google_storage_bucket.state_logs.name
    log_object_prefix = "tfstate/"
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}
