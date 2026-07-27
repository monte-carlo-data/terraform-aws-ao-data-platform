# IAM — EBS CSI Controller IRSA. The EKS-managed aws-ebs-csi-driver addon
# creates a Deployment (controller) and a DaemonSet (node plugin). Only the
# controller calls AWS APIs (CreateVolume/AttachVolume); EKS annotates the
# ebs-csi-controller-sa ServiceAccount with this role's ARN when the addon's
# service_account_role_arn is set. The node DaemonSet runs hostNetwork=true
# and doesn't need IAM creds in the steady-state path.

resource "aws_iam_role" "ebs_csi_controller" {
  count = var.cluster.create ? 1 : 0
  name  = "${local.region_qualified_name}-ebs-csi-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_controller" {
  count      = var.cluster.create ? 1 : 0
  role       = aws_iam_role.ebs_csi_controller[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# IAM — OTel Collector IRSA. Inline policies are attached conditionally below
# based on which optional receivers/exporters the caller has enabled.

resource "aws_iam_role" "otel_collector" {
  name = "${local.region_qualified_name}-otel-collector"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:${kubernetes_namespace_v1.montecarlo.metadata[0].name}:opentelemetry-collector"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# One inline policy spans every enabled awss3 receiver (from
# local.otel_awss3_receivers): resource lists are sorted for plan stability
# and deduplicated (two receivers may share a bucket — never a queue, which
# the helm variable validation rejects). With a single enabled receiver the
# rendered JSON is identical to the policy this module has always attached.
# When the trace-export ingest bucket uses a caller-supplied CMK, a fourth
# statement grants the collector kms:Decrypt on that key so GetObject on the
# SSE-KMS objects succeeds; without a CMK the statement list is unchanged.
resource "aws_iam_role_policy" "otel_collector_awss3_receiver" {
  count = length(local.otel_awss3_receivers) > 0 ? 1 : 0
  name  = "awss3-receiver"
  role  = aws_iam_role.otel_collector.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
          ]
          Resource = sort([for r in values(local.otel_awss3_receivers) : r.sqs_queue_arn])
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = sort(distinct([for r in values(local.otel_awss3_receivers) : "arn:aws:s3:::${r.s3_bucket}/${r.s3_prefix}*"]))
        },
        {
          # Some collector versions probe the bucket region.
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation"]
          Resource = sort(distinct([for r in values(local.otel_awss3_receivers) : "arn:aws:s3:::${r.s3_bucket}"]))
        },
      ],
      local.trace_export_ingest_enabled && var.trace_export_ingest.kms_key_arn != null ? [
        {
          Effect   = "Allow"
          Action   = ["kms:Decrypt"]
          Resource = [var.trace_export_ingest.kms_key_arn]
        },
      ] : [],
    )
  })
}

# IAM — Trace-export writer (var.trace_export_ingest). The module's only
# non-IRSA role: an external execution role assumes it — typically
# cross-account — to PUT OTLP trace files under the ingest prefix. The trust
# principal is the external account's root (parsed from the validated
# execution-role ARN), narrowed by two conditions: sts:ExternalId as the
# confused-deputy guard, and aws:PrincipalArn StringLike on the configured
# ARN. That pattern is the effective principal boundary — and because it may
# carry a role-name wildcard, the external role can be re-provisioned (new
# unique suffix, new ARN) without this trust policy going stale.
resource "aws_iam_role" "trace_export_writer" {
  count = local.trace_export_ingest_enabled ? 1 : 0
  name  = "${local.region_qualified_name}-trace-export-writer"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.trace_export_producer_partition}:iam::${local.trace_export_producer_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = var.trace_export_ingest.external_id }
        StringLike   = { "aws:PrincipalArn" = var.trace_export_ingest.producer_execution_role_arn }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# Write-only and prefix-scoped: the writer can PUT under the ingest prefix
# and nothing else — no reads, no lists, no deletes. With a caller-supplied
# CMK on the bucket, SSE-KMS PUTs additionally need GenerateDataKey (Encrypt
# covers non-Bucket-Keys key usage).
resource "aws_iam_role_policy" "trace_export_writer" {
  count = local.trace_export_ingest_enabled ? 1 : 0
  name  = "trace-export-writer"
  role  = aws_iam_role.trace_export_writer[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["${local.trace_export_ingest_bucket_arn}/${local.trace_export_ingest_prefix}*"]
        },
      ],
      var.trace_export_ingest.kms_key_arn != null ? [
        {
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey", "kms:Encrypt"]
          Resource = [var.trace_export_ingest.kms_key_arn]
        },
      ] : [],
    )
  })
}

# IAM — LLM Worker IRSA. Grants Bedrock InvokeModel for the llm-worker pods.

resource "aws_iam_role" "llm_worker" {
  name = "${local.region_qualified_name}-llm-worker"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:${kubernetes_namespace_v1.montecarlo.metadata[0].name}:llm-worker"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "llm_worker_bedrock" {
  name = "bedrock-invoke"
  role = aws_iam_role.llm_worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      "Resource" : [
        "arn:aws:bedrock:*::foundation-model/*",
        "arn:aws:bedrock:*:*:inference-profile/*"
      ]
    }]
  })
}

# IAM — AWS Load Balancer Controller IRSA Role (conditional).

resource "aws_iam_role" "aws_load_balancer_controller" {
  count = var.helm.install_aws_load_balancer_controller ? 1 : 0
  name  = "${local.region_qualified_name}-aws-load-balancer-controller"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  count = var.helm.install_aws_load_balancer_controller ? 1 : 0
  name  = "aws-load-balancer-controller"
  role  = aws_iam_role.aws_load_balancer_controller[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Allow LBC to create the ELB service-linked role on first use.
        Effect    = "Allow"
        Action    = ["iam:CreateServiceLinkedRole"]
        Resource  = "*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com" } }
      },
      {
        # Read-only discovery: EC2, ELB, ACM, WAF, Shield, Cognito.
        Effect = "Allow"
        Action = [
          "acm:DescribeCertificate",
          "acm:ListCertificates",
          "cognito-idp:DescribeUserPoolClient",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeCoipPools",
          "ec2:DescribeInstances",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroupRules",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeVpcs",
          "ec2:GetCoipPoolUsage",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetHealth",
          "iam:GetServerCertificate",
          "iam:ListServerCertificates",
          "shield:CreateProtection",
          "shield:DeleteProtection",
          "shield:DescribeProtection",
          "shield:GetSubscriptionState",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:ListResourcesForWebACL",
        ]
        Resource = "*"
      },
      # Mutating statements below follow the official AWS Load Balancer
      # Controller reference policy (kubernetes-sigs/aws-load-balancer-controller
      # docs/install/iam_policy.json): resources the controller creates are
      # tagged elbv2.k8s.aws/cluster at creation, and every destructive action
      # is conditioned on that tag — the controller cannot mutate or delete
      # security groups, load balancers, or target groups it does not own.
      # Action set is the subset this module has always granted; only the
      # resource scoping and condition keys are taken from the reference.
      {
        # Ingress rule management on existing security groups (e.g. the
        # cluster's shared node SG, which the controller does not own).
        # Unconditioned in the reference policy for the same reason.
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        # Tag-on-create: the controller must tag SGs it creates with its
        # cluster tag in the same call (ec2:CreateAction).
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" }
          Null         = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        # Subsequent tag updates: only on SGs carrying the cluster tag, and
        # the request may not add/strip the cluster tag itself.
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        # Mutation/deletion of controller-owned SGs only (cluster tag present).
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        # LB/TG creation must carry the cluster tag in the request.
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        # Listeners/rules have no tags of their own; ownership is enforced
        # via the parent LB statements above/below (as in the reference).
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule",
        ]
        Resource = "*"
      },
      {
        # Tag updates on controller-owned LBs/TGs; the cluster tag itself
        # may not be added or stripped after creation.
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
        ]
      },
      {
        # Mutation/deletion of controller-owned LBs/TGs only.
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
        ]
        Resource = "*"
        Condition = {
          Null = { "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        # Tag-on-create for LBs/TGs (mirror of the ec2:CreateAction statement).
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = { "aws:RequestTag/elbv2.k8s.aws/cluster" = "false" }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        # Listener/rule mutation; unconditioned in the reference (listeners
        # carry no tags), bounded by the conditioned parent-LB statements.
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
        ]
        Resource = "*"
      },
    ]
  })
}

# IAM — cert-manager IRSA. Grants cert-manager Route 53 permissions for ACME DNS-01
# challenge record management. Only created when hosted_zone_id is provided.

resource "aws_iam_role" "cert_manager" {
  count = var.hosted_zone_id != null ? 1 : 0
  name  = "${local.region_qualified_name}-cert-manager"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:cert-manager:cert-manager"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "cert_manager" {
  count = var.hosted_zone_id != null ? 1 : 0
  name  = "cert-manager-route53"
  role  = aws_iam_role.cert_manager[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZonesByName"]
        Resource = ["*"]
      },
    ]
  })
}

# IAM — external-dns IRSA. Grants external-dns Route 53 permissions to manage CNAME records
# for the ClickHouse and OTel Collector NLB hostnames. Only created when hosted_zone_id is set.

resource "aws_iam_role" "external_dns" {
  count = var.hosted_zone_id != null ? 1 : 0
  name  = "${local.region_qualified_name}-external-dns"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-dns:external-dns"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.hosted_zone_id != null ? 1 : 0
  name  = "external-dns-route53"
  role  = aws_iam_role.external_dns[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      },
    ]
  })
}

# IAM — External Secrets Operator IRSA. Grants the ESO controller read access to the
# ClickHouse password secrets (and the KMS key used to encrypt them).

resource "aws_iam_role" "external_secrets" {
  count = var.helm.install_external_secrets_operator ? 1 : 0
  name  = "${local.region_qualified_name}-external-secrets"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  count = var.helm.install_external_secrets_operator ? 1 : 0
  name  = "external-secrets"
  role  = aws_iam_role.external_secrets[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = concat(
          [
            aws_secretsmanager_secret.clickhouse_otel_password.arn,
            aws_secretsmanager_secret.clickhouse_monte_carlo_password.arn,
            aws_secretsmanager_secret.clickhouse_schema_owner_password.arn,
            aws_secretsmanager_secret.clickhouse_llm_worker_password.arn,
          ],
          local.clickhouse_admin_enabled ? [aws_secretsmanager_secret.clickhouse_admin_password[0].arn] : [],
          local.clickhouse_readonly_user_enabled ? [aws_secretsmanager_secret.clickhouse_readonly_user_password[0].arn] : [],
        )
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.pipeline_secrets.arn]
      },
    ]
  })
}
