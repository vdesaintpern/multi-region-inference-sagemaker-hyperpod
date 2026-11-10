# Karpenter NodePool + HyperpodNodeClass for HyperPod-managed Karpenter (GPU tier).
#
# The GPU NodePool lets Karpenter scale the g5 HyperPod instance group beyond its warm baseline.
# The system/CPU tier is the EKS managed node group (static) — it is NOT a HyperPod instance group,
# so it is not represented here.
#
# CRD facts (verified against the installed operator):
#   - HyperpodNodeClass: karpenter.sagemaker.amazonaws.com/v1, spec.instanceGroups = [<ig name>, ...]
#   - NodePool:          karpenter.sh/v1 (standard Karpenter)

resource "kubectl_manifest" "gpu_nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sagemaker.amazonaws.com/v1"
    kind       = "HyperpodNodeClass"
    metadata = {
      name = "${var.name_prefix}-gpu"
    }
    spec = {
      instanceGroups = [var.gpu_instance_group_name]
    }
  })
}

resource "kubectl_manifest" "gpu_nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "${var.name_prefix}-gpu"
    }
    spec = {
      template = {
        metadata = {
          labels = { "workload" = "gpu" }
        }
        spec = {
          # The HyperpodNodeClass already scopes provisioning to the "gpu" instance group.
          # Taint the GPU nodes with nvidia.com/gpu:NoSchedule so ONLY GPU-requesting pods land here.
          # This keeps CPU-only pods (notably the HyperPod Intelligent Router, a ~1-vCPU proxy) OFF the
          # expensive g5 nodes and on the system tier - otherwise a CPU pod parks on a g5 (via image
          # locality) and keeps a second g5 alive, so one model would occupy TWO cluster-usage slots.
          # VERIFIED: the operator-generated vLLM serving pod already carries a matching toleration
          # (`nvidia.com/gpu` Exists, NoSchedule) and requests nvidia.com/gpu=1, so it still schedules
          # here; the router does not tolerate it, so it moves to the system tier. Result: 1 g5 per model.
          taints = [{
            key    = "nvidia.com/gpu"
            value  = "true"
            effect = "NoSchedule"
          }]
          nodeClassRef = {
            group = "karpenter.sagemaker.amazonaws.com"
            kind  = "HyperpodNodeClass"
            name  = "${var.name_prefix}-gpu"
          }
          requirements = []
          expireAfter  = "720h"
        }
      }
      limits = {
        "nvidia.com/gpu" = var.gpu_node_limit
      }
      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "300s"
      }
    }
  })
  depends_on = [kubectl_manifest.gpu_nodeclass]
}
