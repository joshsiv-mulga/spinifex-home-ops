# A VPC of the cluster's own, rather than whichever one DescribeVpcs lists
# first. Spinifex has no server-side default VPC, and a tenant can hold more
# than one, so picking "the first" is only correct for a single-VPC install —
# on anything else it lands the nodes in a network their pinned addresses
# don't belong to, or lands the database in a security group's VPC rather
# than its own.
#
# The subnet's CIDR is node_cidr itself. The machine configs derive the
# nodes' default gateway as node_cidr's network address plus one, which is
# exactly the VPC router address in AWS's addressing scheme, and the
# controller and NFS addresses are pinned inside node_cidr starting at +10 and
# +30 respectively — clear of the first four addresses and the broadcast
# address a /20 (or anything smaller) reserves at either end. Giving the
# subnet any wider or narrower CIDR than node_cidr would only make those two
# ranges diverge for no benefit.
resource "aws_vpc" "main" {
  cidr_block           = var.node_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.cluster_name })
}

# map_public_ip_on_launch mirrors an AWS default subnet: the nodes have no NAT
# instance in front of them, so this is how they reach the internet to pull
# container images. The address they get is still only reachable from inside
# the tenant network — the LAN-facing addresses the README has you reserve
# are what makes the API and the edge load balancer reachable from outside it.
resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.node_cidr
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = var.cluster_name })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = var.cluster_name })
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = var.cluster_name })

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# RDS resolves its own subnets from this group rather than from the instance's
# security group, so without it the database can land in a different VPC than
# the one its security group belongs to — which is the other half of the bug
# this file fixes.
resource "aws_db_subnet_group" "main" {
  name       = var.cluster_name
  subnet_ids = [aws_subnet.main.id]
  tags       = merge(var.tags, { Name = var.cluster_name })
}
