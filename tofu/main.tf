# The cluster's infrastructure: the nodes, the edge load balancer that holds
# the certificate, and the one security boundary in front of both. The machine
# configuration the nodes boot from is rendered by `just bootstrap talos` and
# read here as user-data — this workspace never generates it.

locals {
  controlplane_config = "${path.module}/../talos/rendered/controlplane.yaml"
  worker_config       = "${path.module}/../talos/rendered/worker.yaml"
}

# Listed without failing when nothing matches, so the instance precondition
# below can say what to fix instead of the provider's "no results".
#
# An imported image is owned by the platform account rather than the account
# that imported it, so `self` alone finds nothing however the image got there.
data "aws_ami_ids" "talos" {
  count  = var.ami_id == "" ? 1 : 0
  owners = var.ami_owners

  filter {
    name   = "name"
    values = ["*${var.ami_name_prefix}*"]
  }
}

data "aws_ami" "talos" {
  count       = var.ami_id == "" && length(try(one(data.aws_ami_ids.talos[*].ids), [])) > 0 ? 1 : 0
  owners      = var.ami_owners
  most_recent = true

  filter {
    name   = "name"
    values = ["*${var.ami_name_prefix}*"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : one(data.aws_ami.talos[*].id)
}

# --- security ---

# The edge LB's own group. 80 and 443 reach it from the admin CIDR and nowhere
# else; the nodes open their node port to this group by reference, so widening
# the cluster never widens the boundary.
resource "aws_security_group" "edge" {
  name        = "${var.cluster_name}-edge"
  description = "Edge LB: HTTP and HTTPS from the admin CIDR only"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-edge" })

  ingress {
    description = "HTTPS from the admin CIDR only - never widen this"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "HTTP from the admin CIDR only, redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The nodes. The Kubernetes and Talos APIs are answered to the admin CIDR
# because both are client-authenticated with certificates the cluster issued;
# application traffic arrives on the node port from the edge LB alone.
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node"
  description = "Cluster nodes: APIs from the admin CIDR, ingress from the edge LB"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-node" })

  ingress {
    description = "Kubernetes API from the admin CIDR"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Talos API from the admin CIDR"
    from_port   = 50000
    to_port     = 50001
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description     = "Application traffic on the gateway node port, edge LB only"
    from_port       = var.external_node_port
    to_port         = var.external_node_port
    protocol        = "tcp"
    security_groups = [aws_security_group.edge.id]
  }

  # etcd, kubelet, the CNI's tunnel and every other port the nodes use between
  # themselves. Inline like the rest: a separate rule resource reads back as a
  # fourth rule this group does not know about, so the two delete each other's
  # work on every apply.
  ingress {
    description = "Everything between nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- the edge ---

# One wildcard certificate for the whole cluster. It only reaches ISSUED inside
# this apply if the platform holds a tenant CA permitted to sign for this
# domain, which is the one issuance mode with no domain-control step. Without
# one it stays PENDING_VALIDATION forever, and a listener holding an unissued
# certificate stops the load balancer serving at all — port 80 included.
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.domain}"
  validation_method = "DNS"
  tags              = var.tags

  lifecycle {
    create_before_destroy = true

    # A privately issued certificate reads back with validation_method "NONE",
    # which the ACM API cannot be asked for. Left unignored that is a
    # permanent diff, and the certificate is replaced on every plan.
    ignore_changes = [validation_method]
  }
}

resource "aws_lb" "edge" {
  name               = "${var.cluster_name}-edge"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.edge.id]
  subnets            = [aws_subnet.main.id]
  tags               = var.tags
}

# Every application is one target: the gateway's node port, which Envoy then
# routes by host header inside the cluster. Adding an application is an
# HTTPRoute in git, not a change here.
resource "aws_lb_target_group" "gateway" {
  name        = "${var.cluster_name}-gateway"
  port        = var.external_node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id
  tags        = var.tags

  # Envoy answers 404 for a host it has no route for, which is the healthy
  # answer for a gateway with no application bound to /. It answers 426 to the
  # HTTP/1.0 probe the platform sends, which is why the range reaches that far:
  # a narrower matcher leaves every target permanently unhealthy.
  health_check {
    path    = "/"
    matcher = "200-499"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.edge.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate.wildcard.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }

  # Asserted here rather than on the certificate, because here is where an
  # unissued certificate does its damage: a listener holding one takes the
  # whole load balancer down, port 80 with it. Written as a postcondition on
  # the certificate instead, OpenTofu 1.12.6 reports the same check twice in
  # one walk and panics with "duplicate status report".
  lifecycle {
    precondition {
      condition     = aws_acm_certificate.wildcard.status == "ISSUED"
      error_message = "The certificate for *.${var.domain} is ${aws_acm_certificate.wildcard.status}, not ISSUED. Create a tenant CA that covers this domain — `spx admin cert create-tenant-ca --domain ${var.domain}` — on every node of the cluster, restart spinifex-daemon and spinifex-awsgw there, then apply again."
    }
  }
}

# The redirect the cluster used to serve itself. It belongs here now: TLS ends
# at this listener, so the cluster never sees a plaintext request to redirect.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.edge.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }
}

# --- node identity ---

# The EBS CSI driver has no credentials of its own. It reads them from IMDS,
# which serves them only for an instance that carries a profile with a role
# attached — without one the role listing is an empty 200 and the driver stops
# at "unexpected empty EC2 IMDS role list".
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"
  tags = var.tags

  # The instance path mints a session through this role, so the trust policy
  # has to name the EC2 service or nothing is issued.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Credentials minted for a role carry only what the role grants, so this is the
# whole list of what the driver does: find volumes and attachments, then create,
# attach, grow and delete them.
resource "aws_iam_role_policy" "node_ebs" {
  name = "${var.cluster_name}-node-ebs"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Resource = "*"
      Action = [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumesModifications",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
  tags = var.tags
}

# --- nodes ---

# One controller per physical host, so losing a host costs one etcd member
# rather than quorum. Spinifex spreads at host level only, and refuses a launch
# with InsufficientInstanceCapacity rather than doubling up once every host
# holds one, so `controllers` can't exceed the platform's host count. Workers
# stay outside it: they carry no quorum, and would only use up those slots.
resource "aws_placement_group" "controllers" {
  name         = "${var.cluster_name}-controllers"
  strategy     = "spread"
  spread_level = "host"
  tags         = merge(var.tags, { Name = "${var.cluster_name}-controllers" })
}

resource "aws_instance" "controller" {
  count                  = var.controllers
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = aws_iam_instance_profile.node.name
  placement_group        = aws_placement_group.controllers.name

  # Pinned, not assigned: the machine configuration resolves the API's name to
  # these addresses, and it is written before anything is launched.
  private_ip = var.controller_addresses[count.index]

  # Without this the node inherits the AMI's disk, which leaves about 6 GiB of
  # allocatable ephemeral storage — less than this cluster's container images.
  # Every node then reports DiskPressure before Flux finishes its first
  # reconcile, and the pulls fail with "no space left on device" rather than
  # with anything that names a disk.
  root_block_device {
    volume_size = var.node_disk_size
  }

  # The whole machine configuration, read at first boot from IMDS. Replace on
  # change: a running node never reads it again. `try` because the file is
  # written by `just bootstrap talos`, after this workspace is validated; the
  # precondition below is what actually requires it.
  user_data                   = try(file(local.controlplane_config), null)
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-${count.index}" })

  lifecycle {
    precondition {
      condition     = fileexists(local.controlplane_config)
      error_message = "No machine configuration at ${local.controlplane_config}. Run `just bootstrap talos` first: a node that boots without one sits in maintenance mode forever."
    }

    precondition {
      condition     = local.ami_id != null
      error_message = "No AMI matches \"*${var.ami_name_prefix}*\". Import the Talos aws platform image, or set ami_id."
    }

    # DescribeInstances reports this back as false whatever was set, so any
    # explicit value is a permanent diff. A node is never a NAT instance.
    ignore_changes = [source_dest_check]
  }
}

resource "aws_instance" "worker" {
  count                  = var.workers
  ami                    = local.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = aws_iam_instance_profile.node.name

  root_block_device {
    volume_size = var.node_disk_size
  }

  user_data                   = try(file(local.worker_config), null)
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-${var.controllers + count.index}" })

  lifecycle {
    precondition {
      condition     = fileexists(local.worker_config)
      error_message = "No machine configuration at ${local.worker_config}. Run `just bootstrap talos` first: a node that boots without one sits in maintenance mode forever."
    }

    ignore_changes = [source_dest_check]
  }
}

# The cluster's own APIs are answered inside the tenant network, and the
# operator is not in it. This is the one address that crosses that line: the
# Talos and Kubernetes APIs on the first controller, which is what
# `just bootstrap cluster` and every kubectl afterwards talk to. The node
# group opens both to the admin CIDR alone.
resource "aws_eip" "controller" {
  domain   = "vpc"
  instance = aws_instance.controller[0].id
  tags     = merge(var.tags, { Name = "${var.cluster_name}-0" })
}

# Every node carries the gateway, so every node is a target: Envoy runs on the
# nodes the Service selects, and the node port answers on all of them.
resource "aws_lb_target_group_attachment" "gateway" {
  count            = var.controllers + var.workers
  target_group_arn = aws_lb_target_group.gateway.arn
  target_id        = concat(aws_instance.controller[*].id, aws_instance.worker[*].id)[count.index]
  port             = var.external_node_port
}
