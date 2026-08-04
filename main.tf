provider "aws" {
  region = "us-east-1"
}

# Cross-region replication ke liye doosra provider (alias) chahiye
provider "aws" {
  alias  = "west"
  region = "us-west-2"
}

# ============================================
# PRIMARY BUCKET (secure_bucket)
# ============================================
resource "aws_s3_bucket" "secure_bucket" {
  bucket = "ahmad-security-lab-demo-bucket-2026"
}

resource "aws_s3_bucket_public_access_block" "secure_bucket_block" {
  bucket = aws_s3_bucket.secure_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "secure_bucket_encryption" {
  bucket = aws_s3_bucket.secure_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "secure_bucket_versioning" {
  bucket = aws_s3_bucket.secure_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "secure_bucket_lifecycle" {
  bucket = aws_s3_bucket.secure_bucket.id

  rule {
    id     = "archive-old-versions"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ============================================
# LOG BUCKET (access logs store honge yahan)
# ============================================
resource "aws_s3_bucket" "log_bucket" {
  bucket = "ahmad-security-lab-logs-2026"
}

resource "aws_s3_bucket_public_access_block" "log_bucket_block" {
  bucket = aws_s3_bucket.log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log_bucket_encryption" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "log_bucket_versioning" {
  bucket = aws_s3_bucket.log_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "log_bucket_lifecycle" {
  bucket = aws_s3_bucket.log_bucket.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "secure_bucket_logging" {
  bucket        = aws_s3_bucket.secure_bucket.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}

# ============================================
# REPLICA BUCKET (us-west-2 mein — disaster recovery)
# ============================================
resource "aws_s3_bucket" "replica_bucket" {
  provider = aws.west
  bucket   = "ahmad-security-lab-replica-2026"
}

resource "aws_s3_bucket_versioning" "replica_bucket_versioning" {
  provider = aws.west
  bucket   = aws_s3_bucket.replica_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "replica_bucket_block" {
  provider = aws.west
  bucket   = aws_s3_bucket.replica_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "replica_bucket_encryption" {
  provider = aws.west
  bucket   = aws_s3_bucket.replica_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# ============================================
# IAM ROLE — S3 ko permission dena replicate karne ki
# ============================================
resource "aws_iam_role" "replication_role" {
  name = "ahmad-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "s3.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "replication_policy" {
  name = "ahmad-s3-replication-policy"
  role = aws_iam_role.replication_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [aws_s3_bucket.secure_bucket.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl"]
        Resource = ["${aws_s3_bucket.secure_bucket.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete"]
        Resource = ["${aws_s3_bucket.replica_bucket.arn}/*"]
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "replication" {
  depends_on = [aws_s3_bucket_versioning.secure_bucket_versioning]

  role   = aws_iam_role.replication_role.arn
  bucket = aws_s3_bucket.secure_bucket.id

  rule {
    id     = "replicate-to-west"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.replica_bucket.arn
      storage_class = "STANDARD"
    }
  }
}

# ============================================
# EVENT NOTIFICATIONS — SNS Topic
# ============================================
resource "aws_sns_topic" "s3_events" {
  name   = "ahmad-s3-bucket-events"

  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_policy" "s3_events_policy" {
  arn = aws_sns_topic.s3_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.s3_events.arn
      Condition = {
        ArnLike = {
          "aws:SourceArn" = aws_s3_bucket.secure_bucket.arn
        }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "secure_bucket_notification" {
  bucket = aws_s3_bucket.secure_bucket.id

  topic {
    topic_arn = aws_sns_topic.s3_events.arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.s3_events_policy]
}
