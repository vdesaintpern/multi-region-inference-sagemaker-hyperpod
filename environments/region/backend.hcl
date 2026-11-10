# Remote state backend for the `region` root. This root is applied ONCE PER REGION, so each region needs
# its OWN state key. Pass this file plus a per-region key at init time, e.g.:
#
#   terraform init -reconfigure \
#     -backend-config=backend.hcl \
#     -backend-config="key=region-us-east-1/terraform.tfstate"
#
# then apply with the matching per-region var file:
#
#   terraform apply -var-file=us-east-1.tfvars
#
# bucket / region / dynamodb_table (or use_lockfile) come from the 00-bootstrap outputs.
bucket = "REPLACE_WITH_BOOTSTRAP_STATE_BUCKET"
region = "REPLACE_WITH_BOOTSTRAP_STATE_REGION"
# use_lockfile = true   # or: dynamodb_table = "REPLACE_WITH_LOCK_TABLE"
