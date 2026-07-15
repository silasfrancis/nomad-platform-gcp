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
    Baseline platform secrets with a single uniform consumer (management-vm-sa),
    always created regardless of tfvars. Kept deliberately small — anything
    needing per-secret IAM precision (e.g. PKI material scoped to specific
    nomad SAs, or human-only CA private keys) can't live here, since variable
    defaults can't reference module.service_account outputs. Those live in
    var.secrets instead, defined at the calling main.tf where those
    references resolve. Do not repeat these keys via var.secrets.
  EOT
  type = map(object({
    labels = optional(map(string), {})
    iam = optional(map(object({
      members = list(string)
    })), {})
  }))
  default = {
    "vault-root-token"     = { labels = { purpose = "vault", tier = "root" } }
    "vault-recovery-keys"  = { labels = { purpose = "vault", tier = "root" } }
    "nomad-acl-root-token" = { labels = { purpose = "nomad", tier = "root" } }
    "consul-acl-root-token" = { labels = { purpose = "consul", tier = "root" } }

    "vault-admin-token"      = { labels = { purpose = "vault", tier = "platform" } }
    "nomad-acl-admin-token"  = { labels = { purpose = "nomad", tier = "platform" } }
    "consul-acl-admin-token" = { labels = { purpose = "consul", tier = "platform" } }
    "vault-key"              = { labels = { purpose = "vault", tier = "platform" } }

    "octopus-admin-api-key"        = { labels = { purpose = "octopus", tier = "platform" } }
    "octopus-master-key"           = { labels = { purpose = "octopus", tier = "platform" } }
    "octopus-mssql-admin-password" = { labels = { purpose = "octopus", tier = "platform" } }

    "github-nomad-repo-pat" = { labels = { purpose = "cicd", tier = "platform" } }
    "cloudflare-api-token"  = { labels = { purpose = "traefik", tier = "platform" } }
  }
}

variable "secrets" {
  description = "Net-new secrets to add on top of default_secrets — this is also where every secret needing precise, non-tier-uniform IAM (PKI material, CA private keys) is defined, since only the calling main.tf has module.service_account references available. Do NOT reuse a key already present in default_secrets — it will be replaced wholesale (shallow merge), not merged field-by-field."
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

variable "platform_tier_accessor_members" {
  description = "Members granted secretAccessor on platform-tier secrets (ongoing infra-service credentials consumed by management-vm-sa — Octopus, the GitHub runner, Traefik's Cloudflare token, etc — anything NOT part of the Consul/Nomad cluster's own trust material)."
  type        = list(string)
  default     = []
}

variable "cluster_tier_accessor_members" {
  description = "Reserved for a future secret genuinely uniform across every cluster SA. Currently left empty at the call site — PKI material's consumer sets vary too much per secret (server-only, client-only, per-environment, or all five) to safely bulk-grant, so each cluster secret carries its own explicit iam block in var.secrets instead."
  type        = list(string)
  default     = []
}