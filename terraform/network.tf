# The network exists to make one thing true: nodes have no public address, and
# the only way out is a NAT that logs.

resource "google_compute_network" "vpc" {
  # checkov:skip=CKV2_GCP_18: the check wants an explicit google_compute_firewall
  # attached to this network. GKE creates and manages its own rules for the
  # control plane, node-to-node traffic, and health checks, and a hand-written
  # rule alongside them is how someone later widens one by accident. There is no
  # inbound path this repo needs that GKE does not already create, and the
  # conftest rule in policy/gcp.rego fails any 0.0.0.0/0 rule that appears here.
  name                    = "${var.name_prefix}-vpc"
  project                 = google_project.workload.project_id
  auto_create_subnetworks = false

  depends_on = [google_project_service.workload]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.name_prefix}-nodes"
  project       = google_project.workload.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/20"

  # Lets a node with no external IP reach a Google API directly rather than
  # hairpinning through the NAT. Artifact Registry, Cloud Logging, and the GKE
  # control plane all take this path.
  private_ip_google_access = true

  # VPC-native. Pods and Services get real routable ranges out of the subnet
  # rather than a route-based overlay. Required for private nodes, and required
  # by everything modern in GKE.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud NAT.
#
# This is the one resource here that exists purely because of Config Sync, and
# it is the largest line item after the nodes at roughly $0.044 an hour.
#
# Private nodes can reach Google APIs through Private Google Access without it.
# They cannot reach github.com, and the whole build is a reconciler polling
# github.com every fifteen seconds. Removing the NAT does not degrade the sync,
# it stops it, and the symptom is a RootSync stuck reporting a Git error that
# reads like an auth problem.
#
# A private repo mirrored into Artifact Registry as OCI would remove this
# dependency and the cost with it. That is the right answer for a real
# deployment and the wrong one for a demo, because then nobody can read the
# config the cluster is running by clicking a link.
resource "google_compute_router" "nat" {
  name    = "${var.name_prefix}-router"
  project = google_project.workload.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name    = "${var.name_prefix}-nat"
  project = google_project.workload.project_id
  region  = var.region
  router  = google_compute_router.nat.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Egress only is logged. Ingress is not logged because there is none: a NAT
  # gateway does not accept unsolicited inbound connections, so ALL would just
  # be a more expensive way to log the same records.
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# GKE creates its own ingress rules for the control plane and for node to node
# traffic. Nothing here opens anything else, and there is deliberately no SSH
# rule: there is no reason to reach a node shell on a cluster whose entire
# configuration is declared in Git.
