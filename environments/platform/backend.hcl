# Remote state backend for the platform root (primary region). Apply AFTER every region root.
#   terraform init -reconfigure -backend-config=backend.hcl -backend-config="key=platform/terraform.tfstate"
#   terraform apply
# bucket / region / dynamodb_table (or use_lockfile) come from the 00-bootstrap outputs.
bucket = "REPLACE_WITH_BOOTSTRAP_STATE_BUCKET"
region = "REPLACE_WITH_BOOTSTRAP_STATE_REGION"
# use_lockfile = true   # or: dynamodb_table = "REPLACE_WITH_LOCK_TABLE"
