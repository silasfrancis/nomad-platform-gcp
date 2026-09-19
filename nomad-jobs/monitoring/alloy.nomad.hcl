job "alloy" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "all"
  type        = "system"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
  }

  group "alloy" {
    network {
      port "http" {
        to = 12345
      }
    }

    task "alloy" {
      driver = "docker"

      config {
        image   = "#{ArtifactRegistry}/alloy:#{ImageTag}"
        ports   = ["http"]
        args = [
          "run",
          "--server.http.listen-addr=0.0.0.0:12345",
          "/etc/alloy/config.alloy",
        ]
        volumes = [
          # nomad's data_dir is /opt/nomad/data (see /etc/nomad.d/nomad.hcl);
          # mount must match host path so config.alloy's file_match glob resolves inside the container.
          "/opt/nomad/data/alloc:/opt/nomad/data/alloc:ro",
        ]
      }

      template {
        data = <<EOF
{{ range service "loki" }}
LOKI_URL=http://{{ .Address }}:{{ .Port }}/loki/api/v1/push
{{ end }}
EOF
        destination = "secrets/runtime-addr.env"
        env         = true
        change_mode = "restart" 
      }


      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }

      service {
        name = "alloy"
        port = "http"

        check {
          type     = "http"
          path     = "/-/ready"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}
