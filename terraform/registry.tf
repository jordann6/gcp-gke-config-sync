# Artifact Registry.
#
# Empty, and deliberately so. It exists because the allowed-repos constraint in
# config/constraints has to name a registry, and naming a real one belonging to
# this project is the difference between a policy that encodes where images are
# supposed to come from and one that lists a public mirror.
#
# Standard tier storage is free below 0.5 GB, so an empty repository costs
# nothing. Pushing an image here and referencing it by digest is the natural
# next step, and it is the seam where this repo meets
# gcp-supply-chain-security: signing and attestation are that project's
# argument, not this one's. This build is about configuration, not artifacts.
resource "google_artifact_registry_repository" "apps" {
  # checkov:skip=CKV_GCP_84: CMEK on an empty registry that exists to be named
  # by a constraint would add a KMS key ring, a key, and a service agent
  # binding, none of which protect anything: there are no images in it. Google
  # encrypts it at rest either way. A registry holding real artifacts is a
  # different answer.
  repository_id = "${var.name_prefix}-apps"
  project       = google_project.workload.project_id
  location      = var.region
  format        = "DOCKER"
  description   = "Approved image source for workloads on this cluster."
  labels        = var.labels

  docker_config {
    # Tags cannot be moved once pushed. A mutable tag means the image a
    # constraint approved and the image that runs can be different bytes, which
    # quietly undoes the point of approving anything.
    immutable_tags = true
  }

  depends_on = [google_project_service.workload]
}
