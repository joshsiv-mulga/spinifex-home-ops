# Everything this workspace needs that cluster.toml already answers is
# rendered into terraform.tfvars, so a plain `tofu apply` is the whole step.
# These are the knobs, not a second copy of the config.

variable "region" {
  description = "Region the gateway serves. Must match it exactly or SigV4 fails with 403 SignatureDoesNotMatch."
  type        = string
}

variable "gateway_endpoint" {
  description = "Gateway URL this host reaches the API on, e.g. https://<host>:9999. Not necessarily the one a guest uses."
  type        = string
}

variable "volsync_name" {
  # Names an existing bucket and identity so a cluster that already has backup
  # history keeps it. Left unset, both are named after the cluster.
  description = "Name for the volsync bucket and IAM user. Defaults to <cluster_name>-volsync."
  type        = string
  default     = null
}

variable "s3_endpoint" {
  description = "Predastore URL, e.g. https://<host>:8443. Object storage answers separately from the gateway."
  type        = string
}

variable "aws_profile" {
  description = "Shared-credentials profile carrying the access keys for the environment."
  type        = string
  default     = "spinifex"
}

variable "ca_bundle_file" {
  # The platform CA, not the ACM tenant CA — this is what the gateway's own
  # server certificate chains to, and the two are different files on a node.
  # Copy /etc/spinifex/ca.pem from any node to spinifex-ca.pem in the repo root.
  description = "Path to the platform CA PEM the gateway's certificate chains to."
  type        = string
  default     = "../spinifex-ca.pem"
}

variable "cluster_name" {
  description = "Prefix for every resource this workspace creates, so one environment can carry more than one cluster."
  type        = string
}

variable "domain" {
  description = "Base domain. The listener holds one wildcard certificate for *.domain and every application is a host-header under it."
  type        = string
}

# The platform has no public exposure of its own, so this rule is the entire
# network boundary. Never widen it to 0.0.0.0/0.
variable "admin_cidr" {
  description = "CIDR allowed to reach the load balancer and the Talos and Kubernetes APIs. Your own host or LAN, never 0.0.0.0/0."
  type        = string

  validation {
    condition     = var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must not be 0.0.0.0/0: it is the only network boundary this cluster has."
  }
}

variable "instance_type" {
  description = "Instance type for every node."
  type        = string
}

variable "node_disk_size" {
  description = "Root disk for every node, in GiB. Sized for container images, not for data: a claim lands on an EBS volume of its own, but an image is unpacked onto the root disk, and the AMI's own size leaves nowhere near enough."
  type        = number
  default     = 40
}

variable "controllers" {
  description = "How many control-plane nodes to launch. Must match the count the machine configs were rendered for."
  type        = number
}

variable "workers" {
  description = "How many workers to launch."
  type        = number
  default     = 0
}

variable "controller_addresses" {
  description = "Fixed private addresses for the control-plane nodes, in order. The machine configs resolve the API's name to these, so they are assigned rather than allocated."
  type        = list(string)

  validation {
    condition     = length(var.controller_addresses) >= var.controllers
    error_message = "controller_addresses must carry at least one address per controller. Re-run `just configure` after changing the node count."
  }
}

variable "external_node_port" {
  description = "Node port the external gateway's Envoy service is pinned to. The target group forwards here."
  type        = number
}

variable "ami_id" {
  description = "Talos AMI to boot. Empty resolves the most recent image matching ami_name_prefix."
  type        = string
  default     = ""
}

variable "ami_name_prefix" {
  description = "Substring used to resolve the Talos AMI, matched as *<value>*. Matched loosely because a hand-imported image keeps its own name while `spx admin images import` generates ami-<distro>-<version>-<arch>. Must be the aws platform image: a nocloud image boots and sits in maintenance mode forever."
  type        = string
  default     = "talos-"
}

variable "ami_owners" {
  description = "Accounts searched for the Talos AMI. An imported image belongs to the platform account rather than the account that imported it, so \"self\" alone never matches one."
  type        = list(string)
  default     = ["self", "000000000000"]
}

variable "key_name" {
  description = "Key pair attached to every node. Talos has no SSH, so this is inert and exists only for environments that require one."
  type        = string
  default     = ""
}

variable "node_cidr" {
  description = "CIDR for the cluster's own VPC and its one subnet. Must not overlap any other VPC it needs to route to, or the LAN. Matches cluster.toml's network.node_cidr, which also pins the controller and NFS addresses inside it."
  type        = string

  validation {
    condition     = can(cidrhost(var.node_cidr, 0))
    error_message = "node_cidr must be a valid IPv4 CIDR, e.g. \"172.31.0.0/20\"."
  }
}

variable "tags" {
  description = "Tags applied to taggable resources."
  type        = map(string)
  default     = {}
}

variable "db_engine_version" {
  description = "Postgres major version. Must match the engine-version tag on the registered spinifex-rds-postgres image or CreateDBInstance cannot resolve an AMI."
  type        = string
  default     = "18"
}

variable "db_instance_class" {
  description = "Instance class for the database."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Database storage in GiB."
  type        = number
  default     = 20
}

variable "db_master_username" {
  description = "Master user. Never \"postgres\", which the engine reserves; the applications' init containers take this as INIT_POSTGRES_SUPER_USER."
  type        = string
  default     = "dbadmin"
}

variable "nfs_instance_type" {
  description = "Instance class for the NFS server. It serves files and nothing else."
  type        = string
  default     = "t3.small"
}

variable "nfs_address" {
  description = "Pinned private address of the NFS server. Applications name it in their mounts, so it must not move across a rebuild."
  type        = string
  default     = "172.31.0.20"
}

variable "nfs_media_size" {
  description = "Media library size in GiB, on its own volume so the server can be rebuilt without it."
  type        = number
  default     = 20
}

variable "nfs_root_disk_size" {
  description = "Root disk of the NFS server, in GiB. Holds the OS and the packages first boot installs, not the library, which is its own volume."
  type        = number
  default     = 16
}

variable "nfs_media_uid" {
  description = "Owner of the export. Matches the user jellyfin runs as, so nothing has to be squashed at the server."
  type        = number
  default     = 3000
}
