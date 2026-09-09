# kpm-mon-tmt blueprint

Reusable Nephio KRM blueprint for the laboratory E2SM-KPM monitoring xApp.
The blueprint is specialized from an injected `WorkloadCluster` object. Site,
target node, container image, E2 node and KPM metric are copied into the
Kubernetes Deployment by the package pipeline.

The package does not deploy the Near-RT RIC or the RAN. It assumes that the
target site provides compatible RIC endpoints and that the selected image
supports the site's CPU architecture.
