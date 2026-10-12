# Where volsync sends its backups: a bucket in Predastore, and an identity that
# can only reach that bucket. Both were created by hand once, which is how they
# end up being the step nobody remembers on a rebuild.

locals {
  volsync_name = coalesce(var.volsync_name, "${var.cluster_name}-volsync")
}

resource "aws_s3_bucket" "volsync" {
  bucket = local.volsync_name

  tags = merge(var.tags, { Name = local.volsync_name })
}

resource "aws_iam_user" "volsync" {
  name = local.volsync_name
  tags = var.tags
}

# The movers run in the cluster and hold this key, so it is scoped to the one
# bucket rather than to S3 as a whole.
resource "aws_iam_user_policy" "volsync" {
  name = local.volsync_name
  user = aws_iam_user.volsync.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.volsync.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.volsync.arn}/*"
      },
    ]
  })
}

resource "aws_iam_access_key" "volsync" {
  user = aws_iam_user.volsync.name
}
