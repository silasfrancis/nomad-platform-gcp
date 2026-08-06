variable "environment" {
  type    = string
  default = "dev"
}

variable "project"{
  type = string
}

variable "zone"{
  type = string
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
    }

    task "nomad-autoscaler" {
      driver = "docker"

      config {
        image = "hashicorp/nomad-autoscaler:v0.5.0"
        ports = ["http"]
        args = [
            "agent",
            "-config", "/local/config.hcl",
            "-config", "/local/policies.hcl",
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
{{ with secret "gcp/roleset/nomad-autoscaler-${var.environment}/key" }}
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
  address = "http://localhost:4646"
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
EOF
        destination = "local/config.hcl"
      }

      # Cluster-scaling policies
      template {
        data = <<EOF
scaling "cluster_policy_ondemand" {
  enabled = true
  min     = 1
  max     = 10

  policy {
    default_cooldown             = "10m"
    default_evaluation_interval  = "1m"

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "${var.project}"
      zone     = "${var.zone}"
      mig_name = "nomad-${var.environment}-ondemand" 
    }
  }
}

scaling "cluster_policy_spot" {
  enabled = true
  min     = 0
  max     = 10

  policy {
    default_cooldown             = "10m"
    default_evaluation_interval  = "1m"

    check "blocked_evaluations" {
      source = "prometheus"
      query  = "sum(nomad_nomad_blocked_evals_total_blocked)"

      strategy "target-value" {
        target = 0
      }
    }

    target "gce-mig" {
      project  = "${var.project}"
      zone     = "${var.zone}"
      mig_name = "nomad-${var.environment}-spot"
    }
  }
}
EOF
        destination = "local/policies.hcl"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }
}