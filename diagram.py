"""Architecture diagram for gcp-gke-config-sync.

Renders docs/architecture.png using the official GCP and Kubernetes icon sets.

    pip install diagrams   # requires graphviz: brew install graphviz
    python diagram.py

Drawn around the two loops, not around the infrastructure.

An infrastructure diagram of this build would be a VPC, a cluster, a node pool,
and a registry, which is every GKE diagram ever drawn and explains nothing about
what the repo does. What matters is that there are exactly two paths by which
the cluster's state can change, and one of them is a loop that runs forever
while the other is a gate that says no.

So Git sits on the left with an arrow running to the cluster and back, and the
operator sits on the bottom with an arrow that stops at the webhook. The two
edges are drawn in different colors because the difference between them is the
whole argument.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.gcp.compute import GKE
from diagrams.gcp.devtools import ContainerRegistry
from diagrams.gcp.network import NAT
from diagrams.k8s.compute import Deployment
from diagrams.k8s.group import Namespace
from diagrams.onprem.client import User
from diagrams.onprem.vcs import Github

GRAPH_ATTR = {
    "fontsize": "16",
    "labelloc": "t",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.7",
    "ranksep": "1.1",
    "bgcolor": "transparent",
}

NODE_ATTR = {"fontsize": "12"}

# Green: the reconciliation loop, which is allowed and continuous.
SYNC = Edge(color="#1a7f37", style="bold", fontcolor="#1a7f37", fontsize="11")
# Red: a write that is refused. It never reaches the thing it points at.
DENY = Edge(color="#cf222e", style="bold", fontcolor="#cf222e", fontsize="11")
# Grey: plumbing that exists so the green loop can run at all.
PLUMBING = Edge(color="#57606a", style="dashed", fontcolor="#57606a", fontsize="10")

with Diagram(
    "GKE with Config Sync: two paths to cluster state",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=GRAPH_ATTR,
    node_attr=NODE_ATTR,
):
    git = Github("github.com/jordann6/gcp-gke-config-sync\nconfig/ on main")
    operator = User("operator\nwith cluster-admin")

    with Cluster("workload project"):
        registry = ContainerRegistry("Artifact Registry\nthe one approved source")

        with Cluster("VPC: private nodes, no public addresses"):
            nat = NAT("Cloud NAT\negress only")

            with Cluster("GKE zonal cluster"):
                with Cluster("gatekeeper-system"):
                    policy = GKE("Policy Controller\nadmission webhook")

                with Cluster("config-management-system"):
                    reconciler = GKE("Config Sync\nroot-reconciler")

                with Cluster("team-a"):
                    ns = Namespace("quota, RBAC,\nNetworkPolicy")
                    app = Deployment("sample-app")

    # The loop. Poll, compare, apply, repeat. This is the only path that ever
    # writes to the cluster.
    git >> Edge(color="#1a7f37", style="bold", label="polls\nevery 15s") >> reconciler
    reconciler >> Edge(color="#1a7f37", style="bold", label="applies") >> ns
    ns >> Edge(color="#57606a", style="dotted") >> app

    # Why the loop can reach GitHub at all. Private nodes have no route out
    # except this one.
    reconciler >> PLUMBING >> nat
    nat >> Edge(color="#57606a", style="dashed", label="the only\negress path") >> git

    # The gate. The operator's write reaches the webhook and stops there, which
    # is why the second edge has no arrowhead: nothing arrives.
    operator >> Edge(color="#cf222e", style="bold", label="kubectl apply:\nunapproved registry") >> policy
    policy >> Edge(
        color="#cf222e",
        style="dotted",
        dir="none",
        label="refused at admission,\nnever lands",
    ) >> ns

    app >> Edge(color="#57606a", style="dotted", label="pulls from") >> registry
