variable "environment" {
  type    = string
  default = "dev"
}

variable "gcp_project" {
  type = string
}

variable "gcp_region" {
  type = string
}

variable "min_ondemand_instances" {
  type    = number
  default = 1
}

variable "max_ondemand_instances" {
  type    = number
  default = 10
}

variable "min_spot_instances" {
  type    = number
  default = 1
}

variable "max_spot_instances" {
  type    = number
  default = 10
}

locals {
  datacenter = "dc-${var.environment}"
}

job "nomad-autoscaler" {
  datacenters = [local.datacenter]
  namespace   = "plugins"

  node_pool = "on-demand"
  type      = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "nomad-autoscaler" {
    count = 1

    constraint {
      attribute = "${node.class}"
      operator  = "="
      value     = "critical"
    }

    network {
      port "http" {
        static = 8080
      }
    }

    task "nomad-autoscaler" {
      driver = "docker"

      config {
        image        = "hashicorp/nomad-autoscaler:0.5.0"
        network_mode = "host"
        args = [
          "agent",
          "-config", "/local/config.hcl",
          "-policy-dir", "local/policies",
        ]
      }

      identity {
        env = true
      }

      vault {
        role = "nomad-autoscaler"
      }

      template {
        data = <<EOF
{{ with secret "gcp/static-account/nomad-autoscaler-${var.environment}/key" }}
{{ .Data.private_key_data | base64Decode }}
{{ end }}
EOF
        destination = "local/creds.json"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/pki/${var.environment}/nomad-ca" }}
{{ .Data.data.ca_cert }}
{{ end }}
EOF
        destination = "local/tls/ca.pem"
      }

      template {
        data = <<EOF
http {
  bind_address = "0.0.0.0"
  bind_port    = 8080
}

nomad {
  address          = "https://nomad.service.consul:4646"
  ca_cert          = "/local/tls/ca.pem"
  tls_server_name  = "server.${local.datacenter}.nomad"
}

apm "prometheus" {
  driver = "prometheus"
  config = {
    address = "http://prometheus.service.consul:9090"
  }
}

target "gce-mig" {
  driver = "gce-mig"
  config = {
    credentials = "local/creds.json"
  }
}

strategy "target-value" {
  driver = "target-value"
}

policy {
  default_cooldown            = "10m"
  default_evaluation_interval = "1m"
  dir                          = "/local/policies"
}
EOF
        destination = "local/config.hcl"
      }

      # Cluster-scaling policies.
      template {
        data = <<EOF
scaling "cluster_policy_ondemand" {
  enabled = true
  min     = ${var.min_ondemand_instances}
  max     = ${var.max_ondemand_instances}

  policy {
    cooldown             = "10m"
    evaluation_interval  = "1m"

    check "cpu_allocated_percentage" {
      source = "prometheus"
      query  = <<-EOQ
        sum(
          nomad_client_allocated_cpu{node_pool="on-demand"} * 100
          /
          (
            nomad_client_unallocated_cpu{node_pool="on-demand"}
            + nomad_client_allocated_cpu{node_pool="on-demand"}
          )
        )
        / count(nomad_client_allocated_cpu{node_pool="on-demand"})
        or vector(0)
      EOQ

      strategy "target-value" {
        target = 70
      }
    }

    check "mem_allocated_percentage" {
      source = "prometheus"
      query  = <<-EOQ
        sum(
          nomad_client_allocated_memory{node_pool="on-demand"} * 100
          /
          (
            nomad_client_unallocated_memory{node_pool="on-demand"}
            + nomad_client_allocated_memory{node_pool="on-demand"}
          )
        )
        / count(nomad_client_allocated_memory{node_pool="on-demand"})
        or vector(0)
      EOQ

      strategy "target-value" {
        target = 70
      }
    }

    target "gce-mig" {
      project    = "${var.gcp_project}"
      region     = "${var.gcp_region}"
      mig_name   = "nomad-${var.environment}-ondemand"
      datacenter = "dc-${var.environment}"
      node_pool  = "on-demand"

      node_drain_deadline    = "10m"
      node_purge             = true
      node_selector_strategy = "empty_ignore_system"
    }
  }
}

scaling "cluster_policy_spot" {
  enabled = true
  min     = ${var.min_spot_instances}
  max     = ${var.max_spot_instances}

  policy {
    cooldown             = "10m"
    evaluation_interval  = "1m"

    check "cpu_allocated_percentage" {
      source = "prometheus"
      query  = <<-EOQ
        sum(
          nomad_client_allocated_cpu{node_pool="spot"} * 100
          /
          (
            nomad_client_unallocated_cpu{node_pool="spot"}
            + nomad_client_allocated_cpu{node_pool="spot"}
          )
        )
        / count(nomad_client_allocated_cpu{node_pool="spot"})
        or vector(0)
      EOQ

      strategy "target-value" {
        target = 70
      }
    }

    check "mem_allocated_percentage" {
      source = "prometheus"
      query  = <<-EOQ
        sum(
          nomad_client_allocated_memory{node_pool="spot"} * 100
          /
          (
            nomad_client_unallocated_memory{node_pool="spot"}
            + nomad_client_allocated_memory{node_pool="spot"}
          )
        )
        / count(nomad_client_allocated_memory{node_pool="spot"})
        or vector(0)
      EOQ

      strategy "target-value" {
        target = 70
      }
    }

    target "gce-mig" {
      project    = "${var.gcp_project}"
      region     = "${var.gcp_region}"
      mig_name   = "nomad-${var.environment}-spot"
      datacenter = "dc-${var.environment}"
      node_pool  = "spot"

      node_drain_deadline    = "10m"
      node_purge             = true
      node_selector_strategy = "empty_ignore_system"
    }
  }
}
EOF
        destination = "local/policies/policies.hcl"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}