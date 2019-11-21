# Previously, we didn't need this. Now, we do. How exciting.
provider "aws" {
  region = var.aws_region
}

terraform {
  # The configuration for this backend will be filled in by Terragrunt
  backend "s3" {}

  # The latest version of Terragrunt (v0.19.0 and above) requires Terraform 0.12.0 or above.
  required_version = ">= 0.12.0"
}

resource "aws_security_group" "default" {
  count       = var.enabled == "true" ? 1 : 0
  name        = "${var.name}-sg"
  description = "Security Group for DocumentDB cluster"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_security_group_rule" "egress" {
  count             = var.enabled == "true" ? 1 : 0
  type              = "egress"
  description       = "Allow all egress traffic"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = join("", aws_security_group.default.*.id)
}

locals {
  allowed_security_groups = [split(",", join(",", var.allowed_security_groups))]
}

resource "aws_security_group_rule" "ingress_security_groups" {
  count                    = var.allowed_security_groups_length
  type                     = "ingress"
  description              = "Allow inbound traffic from existing Security Groups"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  source_security_group_id = element(local.allowed_security_groups, count.index)
  security_group_id        = join("", aws_security_group.default.*.id)
}

resource "aws_security_group_rule" "ingress_cidr_blocks" {
  type              = "ingress"
  count             = var.enabled == "true" && length(var.allowed_cidr_blocks) > 0 ? 1 : 0
  description       = "Allow inbound traffic from CIDR blocks"
  from_port         = var.db_port
  to_port           = var.db_port
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = join("", aws_security_group.default.*.id)
}

resource "aws_docdb_cluster" "default" {
  count                           = var.enabled == "true" ? 1 : 0
  cluster_identifier              = var.name
  master_username                 = var.master_username
  master_password                 = var.master_password
  backup_retention_period         = var.retention_period
  preferred_backup_window         = var.preferred_backup_window
  final_snapshot_identifier       = "${var.name}-final-snapshot"
  skip_final_snapshot             = var.skip_final_snapshot
  apply_immediately               = var.apply_immediately
  storage_encrypted               = var.storage_encrypted
  kms_key_id                      = var.kms_key_id
  snapshot_identifier             = var.snapshot_identifier
  vpc_security_group_ids          = [aws_security_group.default[0].id]
  db_subnet_group_name            = aws_docdb_subnet_group.default[0].name
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.default[0].name
  engine                          = var.engine
  engine_version                  = var.engine_version
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  tags                            = var.tags
}

resource "aws_docdb_cluster_instance" "default" {
  count              = var.enabled == "true" ? var.cluster_size : 0
  identifier         = "${var.name}${count.index > 0 ? "-${count.index}" : ""}"
  cluster_identifier = join("", aws_docdb_cluster.default.*.id)
  apply_immediately  = var.apply_immediately
  instance_class     = var.instance_class
  tags               = var.tags
  engine             = var.engine
}

resource "aws_docdb_subnet_group" "default" {
  count       = var.enabled == "true" ? 1 : 0
  name        = "${var.name}-subnet-group"
  description = "Allowed subnets for DB cluster instances"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

# https://docs.aws.amazon.com/documentdb/latest/developerguide/db-cluster-parameter-group-create.html
resource "aws_docdb_cluster_parameter_group" "default" {
  count       = var.enabled == "true" ? 1 : 0
  name        = "${var.name}-parameter-group"
  description = "DB cluster parameter group"
  family      = var.cluster_family
  dynamic "parameter" {
    for_each = [var.cluster_parameters]
    content {
      # TF-UPGRADE-TODO: The automatic upgrade tool can't predict
      # which keys might be set in maps assigned here, so it has
      # produced a comprehensive set here. Consider simplifying
      # this after confirming which keys can be set in practice.

      apply_method = lookup(parameter.value, "apply_method", null)
      name         = parameter.value.name
      value        = parameter.value.value
    }
  }
  tags = var.tags
}

locals {
  cluster_dns_name_default = "master.${var.name}"
  cluster_dns_name         = var.cluster_dns_name != "" ? var.cluster_dns_name : local.cluster_dns_name_default
  reader_dns_name_default  = "replicas.${var.name}"
  reader_dns_name          = var.reader_dns_name != "" ? var.reader_dns_name : local.reader_dns_name_default
}

module "dns_master" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.6"
  enabled   = var.enabled == "true" && length(var.zone_id) > 0 ? "true" : "false"
  namespace = var.namespace
  name      = local.cluster_dns_name
  stage     = var.stage
  zone_id   = var.zone_id
  records   = [coalescelist(aws_docdb_cluster.default.*.endpoint, [""])]
}

module "dns_replicas" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.6"
  enabled   = var.enabled == "true" && length(var.zone_id) > 0 ? "true" : "false"
  namespace = var.namespace
  name      = local.reader_dns_name
  stage     = var.stage
  zone_id   = var.zone_id
  records   = [coalescelist(aws_docdb_cluster.default.*.reader_endpoint, [""])]
}

