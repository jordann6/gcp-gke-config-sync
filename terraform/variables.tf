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

variable "seed_project_id" {
  description = "Seed project from the bootstrap layer. Holds state and acts as the API quota project."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for generated project IDs and resource names."
  type        = string
  default     = "jn-gitops"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,10}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, and hyphens, 3 to 11 characters."
  }
}

variable "workload_name_suffix" {
  description = <<-EOT
    Short suffix making the workload project ID globally unique, for example the
    output of: openssl rand -hex 3

    Once set, keep it. Changing it renames the project, which destroys and
    recreates the cluster and everything in it.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{4,8}$", var.workload_name_suffix))
    error_message = "workload_name_suffix must be 4 to 8 lowercase alphanumeric characters."
  }
}

variable "region" {
  description = "Region for the subnet, Cloud NAT, and Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = <<-EOT
    Zone for the cluster. Zonal rather than regional on purpose.

    A regional cluster replicates the control plane across three zones and
    spreads the node pool across them, which triples the node count for a demo
    that proves nothing about availability. The control plane fee is the same
    either way, the nodes are not.
  EOT
  type        = string
  default     = "us-central1-a"
}

variable "admin_principal" {
  description = <<-EOT
    The human who administers this build, in IAM member form, for example
    "user:someone@example.com". Granted container.clusterAdmin on the workload
    project so kubectl works without the cluster ever issuing a static
    credential.
  EOT
  type        = string

  validation {
    condition     = can(regex("^(user|group|serviceAccount):", var.admin_principal))
    error_message = "admin_principal must be prefixed with user:, group:, or serviceAccount:."
  }
}

variable "authorized_ip_ranges" {
  description = <<-EOT
    CIDR ranges allowed to reach the Kubernetes API server, normally your
    current public IP as a /32. Get it with: curl -s https://api.ipify.org

    The nodes are private and the control plane endpoint is public but gated by
    this list. A public endpoint with no authorized network is the default
    people leave in place, and it puts the API server on the internet behind
    nothing but authentication.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.authorized_ip_ranges) > 0
    error_message = "authorized_ip_ranges cannot be empty, or kubectl cannot reach the cluster."
  }
}

variable "sync_repo" {
  description = <<-EOT
    Git repository Config Sync reconciles from. This repo, by default.

    Public over HTTPS with secret_type = "none", which is why there is no
    credential anywhere in this build. A private repo needs either a Kubernetes
    Secret holding a token or a Google service account with Secret Manager
    access, and both of those are a standing credential that the cluster reads
    on every sync. Public config with no secrets in it is the better default,
    and it forces the discipline that config carries no secrets.
  EOT
  type        = string
  default     = "https://github.com/jordann6/gcp-gke-config-sync"
}

variable "sync_branch" {
  description = "Branch Config Sync tracks."
  type        = string
  default     = "main"
}

variable "sync_dir" {
  description = <<-EOT
    Directory inside sync_repo that Config Sync owns.

    Everything under here is reconciled. Everything outside it, including all
    the Terraform, is invisible to the cluster. That split is the point: the
    infrastructure that creates the cluster and the configuration that lives
    inside it are different lifecycles with different blast radii.
  EOT
  type        = string
  default     = "config"
}

variable "sync_wait_secs" {
  description = "Seconds between Config Sync polls of the Git repo."
  type        = string
  default     = "15"
}

variable "prevent_drift" {
  description = <<-EOT
    false: Config Sync reconciles drift after the fact. Someone deletes a
    managed object, and it comes back on the next sync. There is a window,
    bounded by sync_wait_secs, where the cluster does not match Git.

    true: Config Sync installs a validating admission webhook that refuses the
    change outright. There is no window, because the write never lands.

    Default false so the reconciliation loop is observable. Acts 2 and 3 of the
    demo flip it, because the difference between "corrected in fifteen seconds"
    and "refused" is the difference between a config management tool and a
    control, and it is worth seeing both.
  EOT
  type        = bool
  default     = false
}

variable "config_sync_version" {
  description = <<-EOT
    Config Sync version, or null to take whatever the fleet feature defaults to.

    Pinning is the right instinct and it has a cost here: a version the fleet
    feature has stopped offering fails the apply with an error that names the
    version and not the reason. Leave null unless a specific version is needed,
    and check what is current before pinning:
      gcloud beta container fleet config-management version
  EOT
  type        = string
  default     = null
}

variable "node_machine_type" {
  description = <<-EOT
    Machine type for the node pool.

    e2-standard-2 rather than e2-medium because of what has to fit. Config Sync
    runs a reconciler-manager plus a root-reconciler with five containers, and
    Policy Controller runs a controller-manager and an audit pod. On e2-medium,
    with roughly 940m allocatable per node after GKE's system pods, those land
    in Pending and the failure looks like Config Sync being broken rather than
    the cluster being too small.
  EOT
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Nodes in the pool. Two gives Policy Controller's soft anti-affinity somewhere to spread."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 5
    error_message = "node_count must be between 1 and 5. This is a demo cluster."
  }
}

variable "labels" {
  description = "Labels applied to the workload project and its resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "gcp-gke-config-sync"
  }
}
