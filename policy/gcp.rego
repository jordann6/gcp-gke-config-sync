# Repo-local conftest rules, layered on top of the shared suite in
# platform-guardrails.
#
# The shared policies are AWS-shaped by history: access keys, security groups,
# NAT gateways. On a GCP repo they pass by being vacuously true. These are the
# GKE equivalents.
#
# Most of them exist to catch a silent downgrade rather than an obvious mistake.
# The failure this repo has to defend against is not a cluster that is visibly
# insecure, it is a fleet feature that is enabled, appears in the console, shows
# a green status, and enforces nothing. Those read as configured at a glance,
# which is exactly why they need a machine check.
#
# Everything here is checkable in the HCL itself. Anything needing a resolved
# value or visibility inside a module belongs in plan-based policy.

package main

import rego.v1

blocks_of(v) := v if {
	is_array(v)
}

blocks_of(v) := [v] if {
	is_object(v)
}

resources contains r if {
	some file in input
	some type, named in file.contents.resource
	some name, block in named
	some body in blocks_of(block)
	r := {"type": type, "name": name, "body": body, "path": file.path}
}

# The default VPC arrives with permissive firewall rules nobody chose, in every
# region, including SSH from anywhere. Nothing in this build wants a node shell.
deny contains msg if {
	some r in resources
	r.type == "google_project"
	r.body.auto_create_network == true
	msg := sprintf(
		"%s: google_project.%s sets auto_create_network = true. The default VPC ships an SSH-from-anywhere rule.",
		[r.path, r.name],
	)
}

# A node pool with no service_account runs as the default Compute Engine
# service account, which holds roles/editor on the entire project. Every pod
# that reaches the metadata server inherits it. This is the single most common
# way a GKE cluster ends up with project-wide write access nobody granted.
deny contains msg if {
	some r in resources
	r.type == "google_container_node_pool"
	some nc in blocks_of(r.body.node_config)
	not nc.service_account
	msg := sprintf(
		"%s: google_container_node_pool.%s sets no service_account, so nodes run as the default Compute SA (roles/editor).",
		[r.path, r.name],
	)
}

# GKE_METADATA is what makes Workload Identity real. Without it a pod reads the
# node's metadata server directly and impersonates the node service account,
# which makes the whole token exchange decorative.
deny contains msg if {
	some r in resources
	r.type == "google_container_node_pool"
	some nc in blocks_of(r.body.node_config)
	some wmc in blocks_of(nc.workload_metadata_config)
	wmc.mode != "GKE_METADATA"
	msg := sprintf(
		"%s: google_container_node_pool.%s sets workload_metadata_config mode = %v. Only GKE_METADATA isolates pods from the node identity.",
		[r.path, r.name, wmc.mode],
	)
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	not r.body.workload_identity_config
	msg := sprintf(
		"%s: google_container_cluster.%s has no workload_identity_config. Pods would authenticate with node credentials or mounted keys.",
		[r.path, r.name],
	)
}

# A public control plane endpoint with no authorized network list is the API
# server on the internet behind nothing but authentication.
deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	some pcc in blocks_of(r.body.private_cluster_config)
	pcc.enable_private_endpoint != true
	not r.body.master_authorized_networks_config
	msg := sprintf(
		"%s: google_container_cluster.%s has a public endpoint and no master_authorized_networks_config.",
		[r.path, r.name],
	)
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	some manc in blocks_of(r.body.master_authorized_networks_config)
	some cb in blocks_of(manc.cidr_blocks)
	cb.cidr_block == "0.0.0.0/0"
	msg := sprintf(
		"%s: google_container_cluster.%s authorizes 0.0.0.0/0 to the API server, which is the same as no list at all.",
		[r.path, r.name],
	)
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	some pcc in blocks_of(r.body.private_cluster_config)
	pcc.enable_private_nodes != true
	msg := sprintf(
		"%s: google_container_cluster.%s does not set enable_private_nodes. Nodes would get public addresses.",
		[r.path, r.name],
	)
}

deny contains msg if {
	some r in resources
	r.type == "google_container_cluster"
	r.body.enable_shielded_nodes == false
	msg := sprintf(
		"%s: google_container_cluster.%s disables shielded nodes, giving up secure boot and integrity monitoring.",
		[r.path, r.name],
	)
}

# Private Google Access is what lets a node with no external IP reach Artifact
# Registry and the logging API without hairpinning through the NAT. Its absence
# is a debugging trap more than a security one, and the fix people reach for is
# a wider NAT.
deny contains msg if {
	some r in resources
	r.type == "google_compute_subnetwork"
	not r.body.private_ip_google_access
	msg := sprintf(
		"%s: google_compute_subnetwork.%s does not enable private_ip_google_access.",
		[r.path, r.name],
	)
}

# The silent downgrades. A configmanagement feature membership with config_sync
# disabled is a feature that exists, reports healthy, and reconciles nothing.
deny contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some cm in blocks_of(r.body.configmanagement)
	some cs in blocks_of(cm.config_sync)
	cs.enabled == false
	msg := sprintf(
		"%s: %s has config_sync.enabled = false. The feature is on and nothing is being reconciled.",
		[r.path, r.name],
	)
}

# Likewise for Policy Controller. INSTALL_SPEC_SUSPENDED leaves the CRDs and the
# constraints in place while the webhook stops evaluating them, so every
# constraint still shows up in kubectl and none of them refuse anything.
deny contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some pc in blocks_of(r.body.policycontroller)
	some hub in blocks_of(pc.policy_controller_hub_config)
	hub.install_spec != "INSTALL_SPEC_ENABLED"
	msg := sprintf(
		"%s: %s sets policy controller install_spec = %v. Constraints remain visible and stop being enforced.",
		[r.path, r.name, hub.install_spec],
	)
}

# A mutating webhook that silently rewrites what you applied breaks the property
# the whole build rests on: that what is in Git is what is running.
deny contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some pc in blocks_of(r.body.policycontroller)
	some hub in blocks_of(pc.policy_controller_hub_config)
	hub.mutation_enabled == true
	msg := sprintf(
		"%s: %s enables Policy Controller mutation. Cluster state would stop matching Git by design.",
		[r.path, r.name],
	)
}

# Syncing over plain HTTP means an on-path attacker chooses the cluster's
# configuration. secret_type = "none" is fine; the transport is not.
deny contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some cm in blocks_of(r.body.configmanagement)
	some cs in blocks_of(cm.config_sync)
	some git in blocks_of(cs.git)
	startswith(git.sync_repo, "http://")
	msg := sprintf(
		"%s: %s syncs from an http:// repo. Config would be attacker-controlled on any shared network.",
		[r.path, r.name],
	)
}

# Basic roles carry enough permission to edit the fleet features and the
# constraints that constrain them, which collapses the model.
basic_roles := {"roles/owner", "roles/editor"}

deny contains msg if {
	some r in resources
	r.type in {"google_project_iam_member", "google_project_iam_binding"}
	r.body.role in basic_roles
	msg := sprintf(
		"%s: %s.%s grants %s. Basic roles are not granted anywhere in this repo.",
		[r.path, r.type, r.name, r.body.role],
	)
}

# A service account key is a credential that authenticates forever, from
# anywhere, and outlives the machine it was made on. Workload Identity exists so
# that this file never needs to.
deny contains msg if {
	some r in resources
	r.type == "google_service_account_key"
	msg := sprintf(
		"%s: google_service_account_key.%s creates a long-lived JSON key. Use Workload Identity.",
		[r.path, r.name],
	)
}

deny contains msg if {
	some r in resources
	r.type == "google_compute_firewall"
	r.body.allow
	some src in r.body.source_ranges
	src == "0.0.0.0/0"
	msg := sprintf(
		"%s: google_compute_firewall.%s allows traffic from 0.0.0.0/0.",
		[r.path, r.name],
	)
}

# Not a failure, a note. An empty exemption list means a constraint can be
# written that blocks the controllers doing the enforcing, and recovering from
# that needs a change to Git plus a sync that the webhook may be preventing.
warn contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some pc in blocks_of(r.body.policycontroller)
	some hub in blocks_of(pc.policy_controller_hub_config)
	count(hub.exemptable_namespaces) == 0
	msg := sprintf(
		"%s: %s exempts no namespaces from Policy Controller. A constraint could lock out its own control plane.",
		[r.path, r.name],
	)
}

# Also not a failure. prevent_drift being wired to a variable is the point of
# the demo, and a default of false is a real gap in a real cluster.
warn contains msg if {
	some r in resources
	r.type == "google_gke_hub_feature_membership"
	some cm in blocks_of(r.body.configmanagement)
	some cs in blocks_of(cm.config_sync)
	cs.prevent_drift
	msg := sprintf(
		"%s: %s takes prevent_drift from a variable. Confirm it is true in any environment that is not a demo.",
		[r.path, r.name],
	)
}
