# The media library the lab this came from served from a NAS appliance. Here it
# is an EC2 instance exporting an EBS volume over NFS, which is the substitution
# stage 6 exists to prove: the storage is a platform volume, the server is a
# platform instance, and the applications mount it exactly as they did before.

data "aws_ami" "ubuntu" {
  owners      = var.ami_owners
  most_recent = true

  filter {
    name   = "name"
    values = ["ami-ubuntu-*"]
  }
}

# NFS from the cluster nodes by group reference; SMB and SSH from the admin
# CIDR, so media can be loaded and the export inspected without widening
# anything to the world.
resource "aws_security_group" "nfs" {
  name        = "${var.cluster_name}-nfs"
  description = "NFS: port 2049 from the cluster nodes only"
  vpc_id      = aws_vpc.main.id
  tags        = merge(var.tags, { Name = "${var.cluster_name}-nfs" })

  ingress {
    description     = "NFS from the cluster nodes, by group reference"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.node.id]
  }

  ingress {
    description = "SMB from the admin CIDR, for loading media from a desktop"
    from_port   = 445
    to_port     = 445
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "SSH from the admin CIDR only - never widen this"
    from_port   = 22
    to_port     = 22
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

# The library itself, separate from the instance's root disk so the server can
# be rebuilt without it. Detaching and reattaching is the whole recovery story.
resource "aws_ebs_volume" "media" {
  # The subnet's zone, not the instance's: a replaced instance's zone is
  # unknown until apply, and naming it here made every NFS rebuild plan to
  # destroy the library along with the server.
  availability_zone = aws_subnet.main.availability_zone
  size              = var.nfs_media_size
  type              = "gp3"
  encrypted         = true
  tags              = merge(var.tags, { Name = "${var.cluster_name}-media" })
}

resource "aws_volume_attachment" "media" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.media.id
  instance_id = aws_instance.nfs.id
}

# The SMB login for the library. Alphanumeric because it is written into the
# instance's user-data inside shell quotes.
resource "random_password" "smb" {
  length  = 24
  special = false
}

resource "aws_instance" "nfs" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nfs_instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.nfs.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # Pinned for the same reason the controllers are: the applications name this
  # address in their mounts, and a rebuild that moved it would break every one.
  private_ip = var.nfs_address

  # The image's own root disk has no room for the packages first boot installs
  # (nfs-kernel-server, samba, ffmpeg and their dependencies): dpkg ran out of
  # space unpacking samba, NFS was left half-installed and never exported.
  root_block_device {
    volume_size = var.nfs_root_disk_size
  }

  user_data = templatefile("${path.module}/nfs-cloud-init.yaml.tftpl", {
    export_cidr  = aws_subnet.main.cidr_block
    media_uid    = var.nfs_media_uid
    smb_password = random_password.smb.result
  })
  user_data_replace_on_change = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-nfs" })

  lifecycle {
    ignore_changes = [source_dest_check]
  }
}
