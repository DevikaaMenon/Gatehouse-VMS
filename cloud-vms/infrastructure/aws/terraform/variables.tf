# Every default is chosen to stay inside the AWS Free Tier. Read the README before changing
# instance_type, db_instance_class, disk sizes or s3_key_prefixes.

variable "name" {
  description = "Prefix for every resource name"
  type        = string
  default     = "gatehouse"
}

variable "region" {
  description = "Our AWS account's organization only allows EC2 in Sydney; use ap-south-1 (Mumbai) elsewhere"
  type        = string
  default     = "ap-southeast-2"
}

variable "alert_email" {
  description = "Email that AWS Budgets notifies when anything is charged"
  type        = string
}

variable "allowed_cidr" {
  description = "Who may open the dashboard, e.g. \"203.0.113.7/32\" (vms-aws.ps1 fills in your current IP)"
  type        = string
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "Use your own IP range (x.x.x.x/32), not the whole internet."
  }
}

variable "repo_url" {
  description = "Git repository the server clones and builds"
  type        = string
  default     = "https://github.com/DevikaaMenon/Gatehouse-VMS.git"
}

variable "repo_ref" {
  description = "Branch or tag to deploy"
  type        = string
  default     = "main"
}

variable "instance_type" {
  description = "Free tier: t3.micro (or t2.micro in regions without t3). Anything else is billed."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_gb" {
  description = "Free tier: 30 GB of EBS in total"
  type        = number
  default     = 30
  validation {
    condition     = var.root_volume_gb >= 20 && var.root_volume_gb <= 30
    error_message = "Keep the disk between 20 and 30 GB (the free tier covers 30 GB)."
  }
}

variable "db_instance_class" {
  description = "Free tier: db.t4g.micro / db.t3.micro, single-AZ"
  type        = string
  default     = "db.t4g.micro"
}

variable "s3_key_prefixes" {
  description = "Storage folders sent to S3; the rest stay on the server disk. Adding recordings/thumbnails exceeds the 2,000 free PUTs a month within days."
  type        = list(string)
  default     = ["evidence", "snapshots"]
}

variable "monthly_budget_usd" {
  description = "Monthly budget (USD, credits included): email at 20 % actual and 100 % forecast"
  type        = number
  default     = 5
}

variable "timezone" {
  type    = string
  default = "Asia/Kolkata"
}
