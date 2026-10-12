# One provider for the whole gateway: EC2, ACM, ELBv2 and IAM all answer
# behind it. The account-id and metadata probes are skipped because an
# AWS-shaped endpoint that is not AWS fails them, and the CA is the tenant's
# own — the same file the EBS CSI driver trusts inside the cluster.

provider "aws" {
  region                      = var.region
  profile                     = var.aws_profile
  custom_ca_bundle            = var.ca_bundle_file
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  # Named one by one rather than left to the profile: a profile may carry a
  # global endpoint_url, but relying on it makes this workspace depend on how
  # the operator's profile happens to be written. Both load balancer keys are
  # named because `elasticloadbalancing` is the classic service and does not
  # cover `aws_lb` — naming only that one is how every v2 call ends up at the
  # profile's endpoint, which is the failure this block exists to prevent.
  endpoints {
    ec2                    = var.gateway_endpoint
    acm                    = var.gateway_endpoint
    elasticloadbalancing   = var.gateway_endpoint
    elasticloadbalancingv2 = var.gateway_endpoint
    iam                    = var.gateway_endpoint
    rds                    = var.gateway_endpoint
    sts                    = var.gateway_endpoint

    # Object storage is Predastore, on its own port.
    s3 = var.s3_endpoint
  }

  # Predastore addresses buckets by path, not as a subdomain of the endpoint.
  s3_use_path_style = true
}
