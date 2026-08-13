# A Terraform file that must fail every applicable rule in ../gcp.rego.
#
# This is not a template, an example, or a starting point. Nothing here is ever
# applied, and `terraform validate` never sees it: the guardrails workflow runs
# conftest against it and fails the build if it PASSES.
#
# It exists because the way a Rego policy suite dies is not by breaking. It goes
# vacuous. A rule whose first line stops matching the input shape returns no
# violations, which is indistinguishable from a clean run, and conftest reports
# a confident green. That happened in this repo: without --combine, conftest
# sets input to a single parsed document rather than a list of {path, contents},
# so `some file in input` matched nothing and all fourteen deny rules passed on
# a config none of them had looked at.
#
# A policy suite needs a test that proves it can still say no. This is it.
#
# When adding a rule to gcp.rego, add its violation here.

resource "google_container_cluster" "bad" {
  name    = "bad"
  project = "p"

  # Public nodes, public endpoint, and the whole internet authorized to reach
  # the API server.
  private_cluster_config {
    enable_private_nodes    = false
    enable_private_endpoint = false
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block = "0.0.0.0/0"
    }
  }

  enable_shielded_nodes = false

  # No workload_identity_config, so pods fall back to node credentials.
}

resource "google_container_node_pool" "bad" {
  name    = "bad"
  cluster = "bad"

  node_config {
    machine_type = "e2-medium"

    # No service_account, so this runs as the default Compute SA with
    # roles/editor on the project.

    # GCE_METADATA lets any pod read the node's metadata server and impersonate
    # that identity directly.
    workload_metadata_config {
      mode = "GCE_METADATA"
    }
  }
}

resource "google_compute_subnetwork" "bad" {
  name          = "bad"
  ip_cidr_range = "10.0.0.0/24"
  region        = "us-central1"
  network       = "bad"

  # private_ip_google_access omitted.
}

resource "google_compute_firewall" "bad" {
  name    = "bad"
  network = "bad"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_project" "bad" {
  name       = "bad"
  project_id = "bad"

  auto_create_network = true
}

resource "google_project_iam_member" "bad" {
  project = "p"
  role    = "roles/editor"
  member  = "user:x@example.com"
}

resource "google_service_account_key" "bad" {
  service_account_id = "x"
}

# The silent downgrades. Every one of these is a resource that exists, reports
# healthy in the console, and enforces nothing.
resource "google_gke_hub_feature_membership" "bad" {
  feature    = "configmanagement"
  location   = "global"
  membership = "m"

  configmanagement {
    config_sync {
      # On, and reconciling nothing.
      enabled = false

      git {
        # Cluster configuration chosen by anyone on the path.
        sync_repo = "http://example.com/repo"
      }
    }
  }

  policycontroller {
    policy_controller_hub_config {
      # Constraints stay visible in kubectl and stop being evaluated.
      install_spec = "INSTALL_SPEC_SUSPENDED"

      # A webhook that rewrites what you applied, so Git stops describing what
      # is running.
      mutation_enabled = true

      # Nothing exempt, so a constraint can lock out the controller enforcing it.
      exemptable_namespaces = []
    }
  }
}
