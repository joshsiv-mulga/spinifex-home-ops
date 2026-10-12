# The database the cluster's apps use, in place of an in-cluster Postgres.
#
# Nothing in Kubernetes runs it, so it survives a cluster rebuild untouched and
# a node failure cannot take it with them. That is the whole point of the
# substitution: the app's connection string names a managed endpoint rather than
# a service in its own namespace.

resource "random_password" "db_master" {
  length = 32
  # The password reaches psql through a connection URI, where a reserved
  # character would have to be percent-encoded to survive parsing.
  special = false
}

# Reachable from the cluster nodes and from nowhere else. Pod traffic leaves a
# node masqueraded to that node's address, so a rule naming the node group
# covers every pod without naming a pod CIDR that Cilium is free to change.
resource "aws_security_group" "db" {
  name        = "${var.cluster_name}-db"
  description = "Database: Postgres from the cluster nodes only"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-db" })

  ingress {
    description     = "Postgres from the cluster nodes, by group reference"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# No `db_name`: each application's init container creates its own database
# owned by its own role, so a database created here would be owned by the
# master user and the app would land without rights on it.
resource "aws_db_instance" "postgres" {
  identifier     = "${var.cluster_name}-postgres"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage

  # "postgres" is reserved as a master username, exactly as it is on AWS, so
  # the superuser this cluster's init containers authenticate as is named here
  # and passed to them as INIT_POSTGRES_SUPER_USER.
  username = var.db_master_username
  password = random_password.db_master.result

  vpc_security_group_ids = [aws_security_group.db.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  publicly_accessible    = false

  # Storage is always encrypted here, and an explicit false is rejected rather
  # than silently downgraded.
  storage_encrypted = true

  # A lab rebuilds often and restores from the application's own backups.
  skip_final_snapshot = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-postgres" })
}
