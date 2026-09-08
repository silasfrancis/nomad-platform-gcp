job "consul-snapshot" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "batch"

  periodic {
    cron             = "30 2 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "consul-snapshot" {
    count = #{ReplicaCount}

    # Short-lived, idempotent, retry-safe — soft Spot preference is
    # fine, unlike the always-on services above.
    affinity {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
      weight    = 50
    }

    vault {
      role = "consul-snapshot"
    }

    task "consul-snapshot" {
      driver = "docker"

      config {
        image   = "google/cloud-sdk:alpine"
        command = "/bin/sh"
        args    = ["-c", "/local/backup.sh"]
      }

      # google/cloud-sdk:alpine has gcloud but not the consul CLI —
      # fetched directly rather than assuming any base image happens
      # to ship both tools this job needs.
      artifact {
        source      = "https://releases.hashicorp.com/consul/1.20.1/consul_1.20.1_linux_amd64.zip"
        destination = "local/"
      }

      template {
        data = <<EOF
#!/bin/sh
set -eu
chmod +x /local/consul
STAMP=$(date +%Y%m%dT%H%M%SZ)
/local/consul snapshot save "/local/consul-#{Environment}-${STAMP}.snap"
gcloud storage cp /local/consul-*.snap gs://nomad-platform-gcp-europe-west1-platform-artifacts/consul-snapshots/#{Environment}/
EOF
        destination = "local/backup.sh"
        perms       = "0755"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/#{Environment}/backup/consul-token" }}
CONSUL_HTTP_TOKEN={{ .Data.data.token }}
{{ end }}
CONSUL_HTTP_ADDR=http://localhost:8500
EOF
        destination = "secrets/consul-snapshot.env"
        env         = true
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
