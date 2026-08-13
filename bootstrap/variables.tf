variable "org_id" {
  description = "Numeric GCP organization ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{10,14}$", var.org_id))
    error_message = "org_id must be the numeric organization ID, not the domain name."
  }
}

variable "billing_account" {
  description = "Billing account ID in XXXXXX-XXXXXX-XXXXXX form."
  type        = string

  validation {
    condition     = can(regex("^[A-F0-9]{6}-[A-F0-9]{6}-[A-F0-9]{6}$", var.billing_account))
    error_message = "billing_account must look like 0X0X0X-0X0X0X-0X0X0X."
  }
}

variable "name_prefix" {
  description = "Prefix for generated project IDs."
  type        = string
  default     = "jn-gitops"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, and hyphens, 3 to 11 characters."
  }
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
  default     = "us-central1"
}

variable "state_bucket_location" {
  description = "Location for the Terraform state bucket."
  type        = string
  default     = "US"
}

variable "force_destroy_state" {
  description = "Allow destroy to delete the state bucket with objects in it. Set true only for final teardown."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels applied to the seed project."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "gcp-gke-config-sync"
  }
}
