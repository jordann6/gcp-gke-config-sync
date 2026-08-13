# Node identity.
#
# The default Compute Engine service account holds roles/editor on the whole
# project, and every node and every pod that reaches the metadata server
# inherits it. That is the single most common way a GKE cluster ends up with a
# workload holding project-wide write access nobody granted on purpose.
resource "google_service_account" "nodes" {
  account_id   = "${var.name_prefix}-nodes"
  display_name = "GKE node pool"
  project      = google_project.workload.project_id

  depends_on = [google_project_service.workload]
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "main" {
  # checkov:skip=CKV_GCP_65: Google Groups for RBAC needs a real
  # gke-security-groups@DOMAIN group that already exists in the org. The
  # RoleBinding in config/rbac binds to a Group subject for exactly this
  # reason, so the model is right; wiring authenticator_groups_config would
  # make the apply depend on a Workspace object this repo does not create.
  # checkov:skip=CKV_GCP_66: Binary Authorization is deliberately out of scope.
  # This repo's argument is about configuration; signing and attestation are
  # gcp-supply-chain-security's, and duplicating them here would be a worse
  # version of that build. approved-image-sources constrains where images come
  # from, which is the configuration-shaped half of the same concern.
  # checkov:skip=CKV_GCP_69: false positive on a split cluster and node pool.
  # The check reads node_config on the cluster resource, which is empty here
  # because remove_default_node_pool is set. GKE_METADATA is on the real pool,
  # in google_container_node_pool.main, and the conftest rule in policy/gcp.rego
  # asserts it there.
  name     = "${var.name_prefix}-cluster"
  project  = google_project.workload.project_id
  location = var.zone

  resource_labels = var.labels

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  # false on purpose, and it is a deliberate choice rather than an oversight.
  #
  # The provider defaults this to true, which makes `terraform destroy` fail
  # with an error telling you to edit the code and apply before you can destroy.
  # On a cluster that is meant to be built, demonstrated, and torn down in an
  # afternoon, that turns every teardown into a two-step dance whose first step
  # is a commit. A production cluster should absolutely leave this true.
  deletion_protection = false

  # The default node pool is created and then replaced, because the cluster
  # resource cannot be created without one and its settings are not fully
  # configurable inline. This is the standard pattern and it is why the cluster
  # takes an extra minute to come up.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.nodes.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.nodes.secondary_ip_range[1].range_name
  }

  private_cluster_config {
    enable_private_nodes = true

    # The control plane endpoint stays public, gated by the authorized network
    # list below. A fully private endpoint needs a bastion or a VPN to reach
    # kubectl at all, and that is a different project. What matters here is that
    # the nodes have no public address, so the only inbound path to the cluster
    # is an authenticated API call from a named range.
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_ip_ranges
      content {
        cidr_block   = cidr_blocks.value
        display_name = "admin"
      }
    }
  }

  # Workload Identity. Pods authenticate to Google APIs as a Google service
  # account through a token exchange, with no key material anywhere.
  #
  # Nothing in the demo depends on it, and it is here because the alternative is
  # a cluster where the way to give a pod access to a bucket is to mount a JSON
  # key. Once that is the pattern, it is the pattern forever. See
  # gcp-workload-identity-federation for the same exchange from outside GCP.
  workload_identity_config {
    workload_pool = "${google_project.workload.project_id}.svc.id.goog"
  }

  enable_shielded_nodes = true

  # Client certificate authentication issues a static credential that is not
  # tied to any IAM identity, cannot be revoked without rotating the cluster CA,
  # and does not appear in audit logs as a person. Off is the modern default and
  # it is stated explicitly, because a default that changes silently is not a
  # control.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Pod-to-pod traffic on the same node normally never touches the VPC, so it is
  # invisible to the flow logs configured on the subnet. Intranode visibility
  # routes it through the dataplane so it gets logged. On a cluster whose
  # tenancy story rests on NetworkPolicy, the traffic most likely to violate a
  # policy is the traffic between two pods that landed on the same node.
  enable_intranode_visibility = true

  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }

  # NetworkPolicy enforcement, so the default-deny policy in config/network is
  # something the dataplane actually applies rather than an object that exists.
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]

    # Managed Prometheus bills per sample ingested. On a cluster running for an
    # afternoon it is pennies, and it is off because nothing here reads it.
    managed_prometheus {
      enabled = false
    }
  }

  depends_on = [time_sleep.service_agent_propagation]
}

resource "google_container_node_pool" "main" {
  name     = "${var.name_prefix}-pool"
  project  = google_project.workload.project_id
  location = var.zone
  cluster  = google_container_cluster.main.name

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-balanced"

    service_account = google_service_account.nodes.email

    # cloud-platform plus IAM roles on the service account, rather than a
    # narrow scope list. Scopes are a legacy second authorization layer that
    # intersects with IAM, and tuning both means every permission problem has
    # two possible causes. One mechanism, checked in one place.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # GKE_METADATA is what makes Workload Identity real. Without it, pods can
    # read the node's metadata server and impersonate the node service account
    # directly, which makes the whole exchange decorative.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = var.labels

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  lifecycle {
    ignore_changes = [
      # The REGULAR release channel upgrades nodes on Google's schedule. Without
      # this, every plan after the first auto-upgrade shows a version diff and
      # proposes to roll the pool back.
      node_config[0].kubelet_config,
      version,
    ]
  }
}
