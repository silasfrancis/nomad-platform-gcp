variable "project_id" {
  type = string
}

variable "storage_cmek" {
  description = "Full resource name of the KMS key used to encrypt secret replication"
  type        = string
}

variable "labels" {
  description = "Common labels applied to all secrets, merged with per-secret labels."
  type        = map(string)
  default     = {}
}

# Secret definitions

variable "default_secrets" {
  description = <<-EOT
    Baseline platform secrets whose access pattern is uniform across an
    entire tier, always created regardless of tfvars. Kept deliberately
    small — anything needing per-secret IAM precision (PKI material,
    per-environment tokens with a single specific VM consumer) can't live
    here, since variable defaults can't reference module.service_account
    outputs. Those live in var.secrets instead, defined at the calling
    main.tf where those references resolve. Do not repeat these keys via
    var.secrets.
  EOT
  type = map(object({
    labels = optional(map(string), {})
    iam = optional(map(object({
      members = list(string)
    })), {})
  }))
default = {
    # --- root: Write-Once Bootstrap Secrets, Essentially Archival After
    # Initial Setup. Human-Only (platform_admin_email) — No VM, Ever. ---
    "vault-root-token"    = { labels = { purpose = "vault", tier = "root" } }
    "vault-recovery-keys" = { labels = { purpose = "vault", tier = "root" } }

    "nomad-acl-root-token-dev"   = { labels = { purpose = "nomad", tier = "root", environment = "dev" } }
    "nomad-acl-root-token-prod"  = { labels = { purpose = "nomad", tier = "root", environment = "prod" } }
    "consul-acl-root-token-dev"  = { labels = { purpose = "consul", tier = "root", environment = "dev" } }
    "consul-acl-root-token-prod" = { labels = { purpose = "consul", tier = "root", environment = "prod" } }

    # --- operator: Ongoing Tokens Read Only By Whoever Runs
    # terraform/platform-config. Human-Only, Never A VM.
    #
    # vault-admin-token DROPPED — same duplicate-naming issue as the
    # nomad/consul admin tokens below. One human operator, one token
    # per system; vault-operator-token already covers this. ---
    "vault-operator-token"       = { labels = { purpose = "vault", tier = "operator" } }
    "consul-operator-token-dev"  = { labels = { purpose = "consul", tier = "operator", environment = "dev" } }
    "consul-operator-token-prod" = { labels = { purpose = "consul", tier = "operator", environment = "prod" } }
    "nomad-operator-token-dev"   = { labels = { purpose = "nomad", tier = "operator", environment = "dev" } }
    "nomad-operator-token-prod"  = { labels = { purpose = "nomad", tier = "operator", environment = "prod" } }

    # nomad-acl-admin-token-{dev,prod} DROPPED — duplicate of nomad-operator-token-{dev,prod}
    # consul-acl-admin-token-{dev,prod} DROPPED — duplicate of consul-operator-token-{dev,prod}

    # mgmt: Ongoing Secrets Consumed By Ansible Roles Running On
    # mgmt-vm (management-vm-sa).
    "vault-snapshot-token" = { labels = { purpose = "vault", tier = "mgmt" } }
    "grafana-admin-token"  = { labels = { purpose = "grafana", tier = "mgmt" } }
    "github-nomad-repo-pat" = { labels = { purpose = "cicd", tier = "mgmt" } }
    
    "octopus-slack-webhook-url" = { labels = { purpose = "cicd", tier = "mgmt" } }
    "cloudflare-api-token"  = { labels = { purpose = "traefik", tier = "mgmt" } }
  }
}

variable "secrets" {
  description = "Net-new secrets to add on top of default_secrets — this is also where every secret needing precise, non-tier-uniform IAM (PKI material, per-environment tokens with a single specific consumer) is defined, since only the calling main.tf has module.service_account references available. Do NOT reuse a key already present in default_secrets — it will be replaced wholesale (shallow merge), not merged field-by-field."
  type = map(object({
    labels = optional(map(string), {})
    iam = optional(map(object({
      members = list(string)
    })), {})
  }))
  default = {}

  validation {
    condition = length([
      for k in keys(var.secrets) : k if contains(keys(var.default_secrets), k)
    ]) == 0
    error_message = "One or more keys in var.secrets already exist in default_secrets. Edit default_secrets directly instead of overriding via var.secrets, or the existing entry (including its labels) will be silently replaced."
  }
}

# Tier-based IAM

variable "root_tier_accessor_members" {
  description = "Members granted secretAccessor on root-tier secrets (write-once bootstrap tokens, essentially archival afterward). Keep minimal — ideally just platform_admin_email. No VM, ever."
  type        = list(string)
  default     = []
}

variable "operator_tier_accessor_members" {
  description = "Members granted secretAccessor on operator-tier secrets (ongoing admin tokens read only by whoever runs terraform/platform-config, or by a human managing Vault directly — never a VM). Keep minimal — ideally just platform_admin_email."
  type        = list(string)
  default     = []
}

variable "mgmt_tier_accessor_members" {
  description = "Members granted secretAccessor on mgmt-tier secrets (ongoing operational secrets whose sole consumer is management-vm-sa)."
  type        = list(string)
  default     = []
}

variable "scoped_tier_accessor_members" {
  description = "Reserved for a future secret genuinely uniform across every scoped-tier consumer. Currently left empty at the call site — scoped secrets' consumer sets vary too much (server-only, client-only, per-environment, or a specific non-cluster VM like Traefik) to safely bulk-grant, so each one carries its own explicit iam block in var.secrets instead."
  type        = list(string)
  default     = []
}