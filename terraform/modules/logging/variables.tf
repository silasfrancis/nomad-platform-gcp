variable "project_id" {
  type = string
}

variable "region" {
  description = "Default location for new log buckets, unless a bucket entry overrides it."
  type        = string
}

variable "default_cmek_key" {
  description = "KMS key ID used by every log bucket unless a bucket entry overrides it. Typically module.kms.kms_keys[\"platform/storage-cmek\"].id."
  type        = string
}

variable "log_buckets" {
  description = "Map of log buckets to create. Add a new entry here to add a new bucket — a matching sink and a _Default exclusion are generated automatically for each one. Key is used as both the bucket_id and the sink name prefix."
  type = map(object({
    location       = optional(string)
    retention_days = optional(number, 7)
    filter         = string
    description = string
    cmek_key       = optional(string)
  }))
  default = {
    "vpc-flow-logs" = {
      retention_days = 7
      filter         = "resource.type=\"gce_subnetwork\" AND log_id(\"compute.googleapis.com/vpc_flows\")"
      description = "VPC flow logs"
    }
    # Add more here as new logging needs come up, e.g.:
    # "secret-access" = {
    #   retention_days = 30
    #   filter         = "resource.type=\"audited_resource\" AND protoPayload.serviceName=\"secretmanager.googleapis.com\""
    # }
  }
}
