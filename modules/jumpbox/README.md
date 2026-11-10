# jumpbox module

A minimal, reusable SSM bastion: one small private EC2 instance reachable only through AWS Systems
Manager Session Manager. No SSH, no public IP, no inbound security-group rules. Use it to port-forward
from a laptop to in-VPC endpoints (internal ALBs, RDS, ElastiCache, in-cluster services).

It is intentionally deployed from its **own root module and state** (see `environments/jumpbox`) so you
can create and destroy it independently of the main regional stack.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `name_prefix` | Prefix for names/tags | (required) |
| `vpc_id` | VPC to launch into | (required) |
| `subnet_id` | PRIVATE subnet; needs SSM reachability (NAT or SSM VPC endpoints) | (required) |
| `instance_type` | Instance type | `t3.micro` |
| `ami_ssm_parameter` | SSM param for the AMI | latest Amazon Linux 2023 x86_64 |
| `tags` | Tags | `{}` |

## Outputs

`instance_id`, `security_group_id`, `private_ip`, `availability_zone`.

## Prerequisites

- The private subnet must reach the SSM service: either a NAT gateway (default route to internet) or
  the three interface VPC endpoints `com.amazonaws.<region>.ssm`, `.ec2messages`, `.ssmmessages`.
- Locally: AWS CLI v2 and the `session-manager-plugin`.

## Usage: open a tunnel to an in-VPC host

```bash
INSTANCE_ID=$(terraform output -raw instance_id)   # from environments/jumpbox

aws ssm start-session \
  --region <region> \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<internal-alb-or-host-dns>"],"portNumber":["80"],"localPortNumber":["4000"]}'
```

Then reach the target at `http://localhost:4000`. Stop the tunnel with Ctrl-C.

## Teardown

From `environments/jumpbox`: `terraform destroy`. Costs are a single small instance + an 8 GiB gp3
volume, so destroy it when you are not actively tunneling.
