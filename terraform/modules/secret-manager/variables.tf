variable "project_id" {
  type        = string
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
  description = "Baseline platform secrets, always created regardless of tfvars. Do not pass these keys again via var.secrets — use var.secrets only for net-new secrets."
  type = map(object({
    labels = optional(map(string), {})
    iam = optional(map(object({
      members = list(string)
    })), {})
  }))
  default = {
    "vault-root-token"      = { labels = { purpose = "vault", tier = "root" } }
    "vault-recovery-keys"   = { labels = { purpose = "vault", tier = "root" } }
    "vault-admin-token"     = { labels = { purpose = "vault", tier = "admin" } }

    "nomad-acl-root-token"  = { labels = { purpose = "nomad", tier = "root" } }
    "nomad-acl-admin-token" = { labels = { purpose = "nomad", tier = "admin" } }

    "consul-acl-root-token"  = { labels = { purpose = "consul", tier = "root" } }
    "consul-acl-admin-token" = { labels = { purpose = "consul", tier = "admin" } }

    "octopus-api-key"            = { labels = { purpose = "octopus", tier = "admin" } }
    "octopus-sql-admin-password" = { labels = { purpose = "octopus", tier = "admin" } }

    "postgres-admin-password" = { labels = { purpose = "database", tier = "admin" } }

    "github-bot-pat" = { labels = { purpose = "cicd", tier = "admin" } }
  }
}

variable "secrets" {
  description = "Net-new secrets to add on top of default_secrets. Do NOT reuse a key already present in default_secrets — it will be replaced wholesale (shallow merge), not merged field-by-field."
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
  description = "Members granted secretAccessor on root-tier secrets (one-time bootstrap tokens). Keep this list minimal — ideally just the SA/user running initial Ansible setup."
  type        = list(string)
  default     = []
}

variable "admin_tier_accessor_members" {
  description = "Members granted secretAccessor on admin-tier secrets (used by platform-config Terraform providers, CI/CD, Ansible ongoing config — anything NOT a Nomad-scheduled job)."
  type        = list(string)
  default     = []
}

variable "app_tier_accessor_members" {
  description = "Members granted secretAccessor on app-tier secrets (consumed exclusively by services running as Nomad jobs under nomad-client-sa)."
  type        = list(string)
  default     = []
}
