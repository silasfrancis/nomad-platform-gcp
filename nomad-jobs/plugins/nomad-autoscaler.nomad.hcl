variable "environment" {
  type    = string
  default = "dev"
}

variable "gcp_project"{
  type = string
}

variable "gcp_region"{
  type = string
}

variable "min_ondemand_instances"{
  type = number
  default = 1
}

variable "max_ondemand_instances"{
  type = number
  default = 10
}

variable "min_spot_instances"{
  type = number
  default = 0
}

variable "max_spot_instances"{
  type = number
  default = 10
}

locals {
  datacenter = "dc-${var.environment}"
}

job "nomad-autoscaler" {
  datacenters = [local.datacenter]
  namespace   = "plugins"
  type        = "service"

  update {
    max_parallel      = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "nomad-autoscaler" {
    count = 1

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "on-demand"
    }

    network {
      port "http" {
        to = 8080
      }
      dns {
        servers = ["${attr.driver.docker.bridge_ip}"]
      }
    }

    task "nomad-autoscaler" {
      driver = "docker"

      config {
        image = "hashicorp/nomad-autoscaler:0.5.0"
        ports = ["http"]
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
http {
  bind_address = "0.0.0.0"
  bind_port    = 8080
}

nomad {
  address = "http://nomad.service.consul:4646"
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
  dir = "/local/policies"
}
EOF
        destination = "local/config.hcl"
      }

      # Cluster-scaling policies
      template {
        data = <<EOF
scaling "cluster_policy_ondemand" {
  enabled = true
  min     = ${var.min_ondemand_instances}
  max     = ${var.max_ondemand_instances}

  policy {
    cooldown             = "10m"
    evaluation_interval  = "1m"

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "${var.gcp_project}"
      region     = "${var.gcp_region}"
      mig_name = "nomad-${var.environment}-ondemand" 
      datacenter = "dc-${var.environment}"
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

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "${var.gcp_project}"
      region     = "${var.gcp_region}"
      mig_name = "nomad-${var.environment}-spot"
      datacenter = "dc-${var.environment}"
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