# Config Sync and Policy Controller, installed as fleet features.
#
# The licensing note first, because it is the thing that was true and stopped
# being true. Both of these used to require a GKE Enterprise subscription,
# billed per vCPU per hour, which put them out of reach of a demo cluster and
# sent people to the open source installs instead. In September 2025 Google
# dissolved the Enterprise tier and moved Fleets, Config Sync, Policy
# Controller, and Connect Gateway into base GKE at no additional cost. The only
# cluster charge left is the flat $0.10 an hour control plane fee, and one
# zonal cluster per billing account is covered by the $74.40 monthly credit.
#
# The open source paths still exist and are worse for this. kpt-config-sync
# publishes no GitHub release assets and its manifest bucket
# (gs://config-management-release) no longer serves anonymous or ordinary
# authenticated callers, so the documented OSS install is a dead link. Running
# upstream Gatekeeper instead of Policy Controller means giving up the template
# library and wiring the constraint templates by hand. Neither is worth doing
# now that the managed path is free.

resource "google_gke_hub_membership" "cluster" {
  membership_id = "${var.name_prefix}-cluster"
  project       = google_project.workload.project_id

  # Global rather than regional. A regional membership has to be addressed with
  # membership_location on every feature membership that references it, and
  # getting that wrong produces a not-found error that names a membership you
  # can see in the console.
  location = "global"

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.main.id}"
    }
  }

  labels = var.labels

  depends_on = [
    google_project_service.workload,
    google_container_node_pool.main,
  ]
}

# The features are project-level switches. Enabling one installs nothing on its
# own: it makes the feature available to memberships, and the feature_membership
# resources below are what put the controllers on the cluster.
resource "google_gke_hub_feature" "configmanagement" {
  name     = "configmanagement"
  project  = google_project.workload.project_id
  location = "global"

  depends_on = [google_project_service.workload]
}

resource "google_gke_hub_feature" "policycontroller" {
  name     = "policycontroller"
  project  = google_project.workload.project_id
  location = "global"

  depends_on = [google_project_service.workload]
}

resource "google_gke_hub_feature_membership" "config_sync" {
  project             = google_project.workload.project_id
  location            = "global"
  feature             = google_gke_hub_feature.configmanagement.name
  membership          = google_gke_hub_membership.cluster.membership_id
  membership_location = google_gke_hub_membership.cluster.location

  configmanagement {
    version = var.config_sync_version

    config_sync {
      enabled = true

      # Unstructured, not hierarchical.
      #
      # The hierarchical format expects a namespaces/ tree with inherited
      # abstract namespaces and a system/ directory, and it is a real answer to
      # multi-tenancy at scale. It is also a directory layout nobody can read
      # without learning it first. Unstructured syncs plain manifests from any
      # directory shape, which means config/ is a normal Kubernetes repo that a
      # reviewer can understand from the file names.
      source_format = "unstructured"

      # See the prevent_drift variable. false reconciles after the fact, true
      # installs an admission webhook that refuses the write. The demo shows
      # both, which is the only reason this is not simply pinned to true.
      prevent_drift = var.prevent_drift

      git {
        sync_repo   = var.sync_repo
        sync_branch = var.sync_branch
        policy_dir  = var.sync_dir

        # No credential. The repo is public over HTTPS, so there is nothing for
        # the reconciler to hold and nothing to rotate. This is why the NAT in
        # network.tf is load bearing: the reconciler reaches github.com over the
        # internet, not over a Google API path.
        secret_type = "none"

        sync_wait_secs = var.sync_wait_secs
      }
    }
  }
}

resource "google_gke_hub_feature_membership" "policy_controller" {
  project             = google_project.workload.project_id
  location            = "global"
  feature             = google_gke_hub_feature.policycontroller.name
  membership          = google_gke_hub_membership.cluster.membership_id
  membership_location = google_gke_hub_membership.cluster.location

  policycontroller {
    policy_controller_hub_config {
      install_spec = "INSTALL_SPEC_ENABLED"

      # Every sixty seconds the audit controller re-evaluates everything already
      # running against every constraint, which is what surfaces violations in
      # objects that were admitted before the constraint existed. Admission
      # control only ever sees new writes.
      audit_interval_seconds = 60

      # Denials go to the container log, so a refusal is recoverable after the
      # fact rather than only visible to whoever ran the kubectl command.
      log_denies_enabled = true

      # Lets a constraint reason about objects other than the one being
      # admitted. Nothing in config/constraints uses it yet. It is on because
      # turning it on later restarts the controller, and the first constraint
      # anyone writes about uniqueness across a namespace needs it.
      referential_rules_enabled = true

      # Mutation is off. A webhook that silently rewrites what you applied is a
      # legitimate tool and a bad default, because it breaks the property this
      # whole build rests on: what is in Git is what is running.
      mutation_enabled = false

      # Namespaces a constraint can never apply to. These hold the controllers
      # doing the enforcing, and a constraint that blocks Policy Controller from
      # scheduling its own audit pod is a cluster that cannot be un-broken
      # without deleting the constraint from Git and waiting for a sync that the
      # webhook may itself be preventing.
      exemptable_namespaces = [
        "kube-system",
        "gatekeeper-system",
        "config-management-system",
        "config-management-monitoring",
        "resource-group-system",
        "gke-managed-system",
      ]

      policy_content {
        # The template library: roughly seventy maintained ConstraintTemplates
        # covering the PodSecurityPolicy replacements, image and repo controls,
        # required labels, resource limits, and more.
        #
        # Installing the templates creates no constraints. A ConstraintTemplate
        # is a CRD definition plus Rego; nothing is enforced until a Constraint
        # in config/constraints instantiates it. That separation is why this can
        # be "ALL" without turning seventy policies on at once.
        template_library {
          installation = "ALL"
        }
      }
    }
  }
}
