# Model weight ingestion for the HyperPod global inference sample.
#
# This module produces the artifacts needed to get model weights INTO the primary S3 bucket,
# driven by model_source_type:
#   - jumpstart   : SageMaker JumpStart manages the weights; no ingestion is needed (empty manifest).
#   - huggingface : run huggingface-cli download, then aws s3 sync into the target bucket/prefix.
#   - s3          : aws s3 sync from a user-supplied source URI into the target bucket/prefix.
#
# The module does NOT touch Kubernetes. It exposes the batch/v1 Job spec as a YAML string
# (job_manifest_yaml) for the caller to apply via the kubectl provider, plus the least-privilege
# IAM policy JSON (irsa_policy_json) the Job's IRSA role needs to write to the bucket (and read the
# Hugging Face token secret when set). Secret material is referenced by ARN and never read here.

data "aws_partition" "current" {}

locals {
  needs_ingestion = var.model_source_type != "jumpstart"

  bucket_arn  = "arn:${data.aws_partition.current.partition}:s3:::${var.target_bucket}"
  destination = "s3://${var.target_bucket}/${var.target_prefix}"

  # Per-source ingestion command run inside the container. Both locals are evaluated eagerly, so the
  # possibly-null inputs are coalesced; the placeholder is never executed because ingestion_command
  # selects the command matching the source type (where the relevant input is always set).
  hf_model_id = coalesce(var.model_id, "UNSET_MODEL_ID")
  # huggingface_hub >= 1.0 renamed the CLI from `huggingface-cli` to `hf`.
  hf_command = join(" && ", [
    "pip install --no-cache-dir huggingface_hub awscli",
    "hf download ${local.hf_model_id} --local-dir /tmp/model",
    "aws s3 sync /tmp/model ${local.destination}${local.hf_model_id}"
  ])

  s3_command = join(" && ", [
    "pip install --no-cache-dir awscli",
    "aws s3 sync ${coalesce(var.model_s3_uri, "s3://UNSET_SOURCE")} ${local.destination}"
  ])

  ingestion_command = var.model_source_type == "huggingface" ? local.hf_command : local.s3_command

  # HF token is injected as an env var from a Kubernetes secret, only for huggingface with a token.
  container_env = var.model_source_type == "huggingface" && var.hf_token_secret_arn != null ? [
    {
      name = "HF_TOKEN"
      valueFrom = {
        secretKeyRef = {
          name = "${var.name_prefix}-hf-token"
          key  = "HF_TOKEN"
        }
      }
    }
  ] : []

  job_object = {
    apiVersion = "batch/v1"
    kind       = "Job"
    metadata = {
      name      = "${var.name_prefix}-model-ingestion"
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/name"       = "model-ingestion"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      backoffLimit = 4
      template = {
        metadata = {
          labels = {
            "app.kubernetes.io/name" = "model-ingestion"
          }
        }
        spec = {
          serviceAccountName = var.service_account_name
          restartPolicy      = "Never"
          containers = [
            {
              name    = "model-ingestion"
              image   = var.image
              command = ["/bin/sh", "-c"]
              args    = [local.ingestion_command]
              env     = local.container_env
            }
          ]
        }
      }
    }
  }

  # Least-privilege policy for the ingestion Job's IRSA role.
  s3_statement = {
    Sid    = "WriteModelWeights"
    Effect = "Allow"
    Action = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket"
    ]
    Resource = [
      local.bucket_arn,
      "${local.bucket_arn}/*"
    ]
  }

  secret_statements = var.hf_token_secret_arn != null ? [
    {
      Sid      = "ReadHuggingFaceToken"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.hf_token_secret_arn]
    }
  ] : []

  irsa_policy = {
    Version   = "2012-10-17"
    Statement = concat([local.s3_statement], local.secret_statements)
  }
}
