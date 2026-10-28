# Gatehouse VMS on AWS, sized for the Free Tier:
#
#   your IP ──HTTP:80──► EC2 t3.micro (Docker: API + dashboard + camera workers)
#                           ├──► RDS PostgreSQL db.t4g.micro (private, 20 GB)
#                           ├──► S3 bucket (evidence clips + snapshots only)
#                           ├──► CloudWatch Logs (7-day retention)
#                           └──► SSM Parameter Store (DB password, app secret, admin password)
#   AWS Budgets emails you after about $1 of usage (credits included) and if the month heads past $5.
#
# Deliberately left out because they are never free: NAT gateway, load balancer, Elastic IP,
# ElastiCache, Secrets Manager, KMS customer keys, Multi-AZ, Performance Insights.

data "aws_caller_identity" "me" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  bucket      = "${var.name}-${data.aws_caller_identity.me.account_id}-${var.region}"
  param_path  = "/${var.name}"
  log_group   = "/${var.name}/app"
  subnet_ids  = sort(data.aws_subnets.default.ids)
  db_name     = "vms"
  db_username = "vms"
}

# ------------------------------------------------------------------ secrets (SSM, standard tier = free)
resource "random_password" "db" {
  length           = 32
  override_special = "-_" # safe inside a database URL
}

resource "random_password" "app_secret" {
  length  = 64
  special = false
}

resource "random_password" "admin" {
  length           = 20
  override_special = "-_!"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "${local.param_path}/db_password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_ssm_parameter" "app_secret" {
  name  = "${local.param_path}/secret_key"
  type  = "SecureString"
  value = random_password.app_secret.result
}

resource "aws_ssm_parameter" "admin_password" {
  name  = "${local.param_path}/admin_password"
  type  = "SecureString"
  value = random_password.admin.result
}

# ------------------------------------------------------------------ S3 (5 GB / 2,000 PUTs a month free)
resource "aws_s3_bucket" "media" {
  bucket        = local.bucket
  force_destroy = true # `terraform destroy` empties it, so nothing is left behind billing
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    id     = "expire-media" # backstop for the app's own retention, keeps the bucket under 5 GB
    status = "Enabled"
    filter {}
    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# ------------------------------------------------------------------ network (default VPC: no NAT gateway)
resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "Gatehouse dashboard"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Dashboard (HTTP) from the allowed IP only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    description = "GitHub, PyPI, cameras, AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "PostgreSQL from the app server only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}

# ------------------------------------------------------------------ RDS (750 h db.t4g.micro + 20 GB free)
resource "aws_db_subnet_group" "db" {
  name       = "${var.name}-db"
  subnet_ids = local.subnet_ids
}

resource "aws_db_instance" "db" {
  identifier                   = "${var.name}-db"
  engine                       = "postgres"
  engine_version               = "16"
  instance_class               = var.db_instance_class
  allocated_storage            = 20
  storage_type                 = "gp2"
  storage_encrypted            = true
  db_name                      = local.db_name
  username                     = local.db_username
  password                     = random_password.db.result
  db_subnet_group_name         = aws_db_subnet_group.db.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  publicly_accessible          = false # a public endpoint needs a second (billed) public IPv4
  multi_az                     = false
  backup_retention_period      = 1
  performance_insights_enabled = false
  monitoring_interval          = 0
  auto_minor_version_upgrade   = true
  apply_immediately            = true
  skip_final_snapshot          = true # snapshots left after destroy would be billed
  deletion_protection          = false
}

# ------------------------------------------------------------------ IAM role for the server (no access keys)
resource "aws_iam_role" "app" {
  name = "${var.name}-app"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "MediaObjects", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      Resource = "${aws_s3_bucket.media.arn}/*" },
      { Sid = "MediaList", Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.media.arn },
      { Sid = "Secrets", Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"],
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.me.account_id}:parameter${local.param_path}/*" },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"],
      Resource = "${aws_cloudwatch_log_group.app.arn}:*" },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_session" { # shell access via Session Manager, no SSH port
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

# ------------------------------------------------------------------ logs (5 GB ingest free)
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = 7
}

# ------------------------------------------------------------------ EC2 (750 h t3.micro + 30 GB EBS free)
resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true # auto-assigned, not an Elastic IP; it changes after stop/start
  monitoring                  = false

  credit_specification {
    cpu_credits = "standard" # "unlimited" (the t3 default) bills extra when the AI runs the CPU hot
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # lets the Docker container reach the instance role
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region          = var.region
    repo_url        = var.repo_url
    repo_ref        = var.repo_ref
    param_path      = local.param_path
    db_host         = aws_db_instance.db.address
    db_name         = local.db_name
    db_username     = local.db_username
    bucket          = aws_s3_bucket.media.bucket
    s3_key_prefixes = jsonencode(var.s3_key_prefixes)
    log_group       = local.log_group
    timezone        = var.timezone
  })
  user_data_replace_on_change = true

  depends_on = [aws_ssm_parameter.db_password, aws_ssm_parameter.app_secret, aws_ssm_parameter.admin_password,
  aws_iam_role_policy.app]

  lifecycle {
    ignore_changes = [ami] # a newer Amazon Linux image must not recreate the server
  }

  tags = { Name = "${var.name}-app" }
}

# ------------------------------------------------------------------ cost guard (first 2 budgets are free)
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false # show usage paid with credits too, instead of netting it to $0
    include_refund = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 20 # $1 of the default $5: about a day of running
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
