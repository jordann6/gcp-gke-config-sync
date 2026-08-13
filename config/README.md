# config/

Everything under this directory is owned by the cluster, not by whoever has
kubectl. Config Sync polls it every 15 seconds, applies what it finds, and
removes anything it previously applied that is no longer here.

Nothing outside this directory is visible to the cluster. The Terraform in
`../terraform` builds the cluster and turns Config Sync on; it does not manage a
single object inside it. Those are two lifecycles with two blast radii, and
keeping them apart is why a bad namespace change is a revert rather than a
`terraform apply`.

## Layout

    namespaces/     the tenants
    rbac/           who can do what inside them
    quotas/         how much they can consume
    network/        what can talk to what
    workloads/      a sample app, deliberately imperfect
    constraints/    what the admission controller refuses

Flat and unstructured on purpose. Config Sync also supports a hierarchical
format with abstract namespaces and inheritance, which is a real answer to
multi-tenancy at scale and a directory layout nobody reads correctly the first
time. These are plain manifests in named folders.

## The two enforcement modes

`constraints/` holds Policy Controller constraints. Two of them are set to
`deny`: they refuse the write at admission time. One is set to `dryrun`: it
records violations and admits the object anyway.

That is not a half-finished policy. It is how a policy gets introduced to a
cluster that already has things running in it. Turn it on in `dryrun`, read
`status.violations` on the constraint, fix or exempt what it found, then change
one word. Going straight to `deny` on a live cluster means finding out what it
breaks from the people whose deploys stopped working.

`workloads/sample-app.yaml` exists to be one of those violations. It runs an
image referenced by tag, which is exactly what `require-image-digest` is looking
for, so the dry run has something honest to report.

## Changing anything here

Open a pull request. The merge is the deploy. There is no second step, and
there is no way to make a change to a managed object by hand that survives:
with `prevent_drift = false` it is reverted within 15 seconds, and with
`prevent_drift = true` the API server refuses it outright.
