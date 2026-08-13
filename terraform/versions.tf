terraform {
  required_version = ">= 1.9"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# billing_project plus user_project_override is required when applying with user
# credentials. Without it, APIs that demand a quota project bill the call to
# Google's shared OAuth client project and fail with SERVICE_DISABLED on a
# project ID you do not recognize.
#
# gkehub is the one that bites here. Registering a cluster in a fleet and
# enabling the configmanagement feature are both quota-project calls, and both
# fail in that confusing way if the seed does not have gkehub.googleapis.com
# enabled. That is why it is in seed_apis in the bootstrap layer even though no
# fleet resource is ever created in the seed.
provider "google" {
  region                = var.region
  billing_project       = var.seed_project_id
  user_project_override = true
}
