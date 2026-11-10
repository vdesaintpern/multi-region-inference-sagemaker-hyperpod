# 00-bootstrap — Terraform remote-state backend

This is a **one-time** stack that creates the remote-state backend shared by every
other stack in this sample:

- An **S3 bucket** for Terraform state — versioned, KMS-encrypted (`aws:kms`),
  all public access blocked, `BucketOwnerEnforced` ownership, a bucket policy that
  denies non-TLS (`aws:SecureTransport = false`) access, and `force_destroy = false`.
- A **KMS key + alias** (`alias/<name_prefix>-tf-state`) used to encrypt the bucket.
- A **DynamoDB table** `<name_prefix>-tf-lock` (`PAY_PER_REQUEST`, hash key `LockID`
  of type `S`, SSE enabled) for teams that prefer DynamoDB-based state locking.

This stack itself uses a **local** backend (see `versions.tf`) because it creates the
remote backend and therefore cannot store its own state in a backend that does not
exist yet.

> **State locking:** S3 native locking (the `use_lockfile = true` backend option) needs
> no extra infrastructure and is the recommended default. The DynamoDB table above is an
> alternative for teams standardised on DynamoDB locking — wire it in with
> `dynamodb_table = "<name_prefix>-tf-lock"`.

## Usage

```bash
terraform init
terraform apply

# Capture the outputs for the backend config used by the other stacks:
terraform output
```

Outputs: `state_bucket_name`, `state_bucket_arn`, `lock_table_name`, `kms_key_arn`.

## Backend config for the OTHER stacks

After this stack applies, configure each downstream stack's backend using the outputs.
Give every stack a **unique `key`** so their states never collide. Example:

```hcl
terraform {
  backend "s3" {
    bucket = "<state_bucket_name>"          # e.g. sample-hpinf-tf-state-a1b2c3d4
    key    = "region-us-east-1/terraform.tfstate"
    region = "us-east-1"                    # region where the bucket was created

    # Option A (recommended) — S3 native locking, no DynamoDB needed:
    use_lockfile = true

    # Option B — DynamoDB-based locking (remove use_lockfile if you use this):
    dynamodb_table = "<lock_table_name>"    # e.g. sample-hpinf-tf-lock

    encrypt = true
  }
}
```

Suggested `key` values per stack:

| Stack                          | `key`                                 |
| ------------------------------ | ------------------------------------- |
| `environments/region` (primary)| `region-us-east-1/terraform.tfstate`  |
| `environments/region` (added)  | `region-<region>/terraform.tfstate`   |
| `environments/platform`        | `platform/terraform.tfstate`          |

The single `environments/region` root is applied once per region; give each region its OWN unique key
(one state file per region). `environments/platform` is applied once, in the primary region.

## Apply order

Stacks must be applied in dependency order (every region root, then the platform root):

```
00-bootstrap  ->  region (primary)  ->  region (each added)...  ->  platform
```

`terraform destroy` runs in the **reverse** order (see `scripts/pre-destroy-cleanup.sh`):

```
platform  ->  region (each added)...  ->  region (primary)  ->  00-bootstrap
```

> Do not destroy `00-bootstrap` unless you are tearing down everything — it holds the
> state for every other stack. The bucket has `force_destroy = false` on purpose.
