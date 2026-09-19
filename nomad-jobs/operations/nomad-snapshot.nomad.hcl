job "nomad-snapshot" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  node_pool   = "on-demand"
  type        = "batch"

  periodic {
    cron             = "0 2 * * *"
    prohibit_overlap = true
    time_zone        = "UTC"
  }

  group "nomad-snapshot" {
    count = 1

    affinity {
      attribute = "${node.class}"
      operator  = "="
      value     = "preemptible"
      weight    = 50
    }

    vault {
      role = "nomad-snapshot"
    }

    task "nomad-snapshot" {
      driver = "docker"

      config {
        image        = "google/cloud-sdk:slim"
        command      = "/bin/sh"
        args         = ["-c", "/local/backup.sh"]
        network_mode = "host"
      }

      identity {
        env = true
      }

      # google/cloud-sdk:slim has gcloud but not the nomad CLI
      artifact {
        source      = "https://releases.hashicorp.com/nomad/2.0.4/nomad_2.0.4_linux_amd64.zip"
        destination = "local/"
      }

      template {
        data = <<EOF
#!/bin/sh
set -eu
chmod +x /local/nomad
STAMP=$(date +%Y%m%dT%H%M%SZ)
/local/nomad operator snapshot save "/local/nomad-#{Environment}-${STAMP}.snap"
gsutil cp /local/nomad-*.snap gs://#{PlatformGcsBucket}/nomad-snapshots/#{Environment}/
EOF
        destination = "local/backup.sh"
        perms       = "0755"
      }

      template {
        data = <<EOF
{{ with secret "kv/data/pki/#{Environment}/nomad-ca" }}
{{ .Data.data.ca_cert }}
{{ end }}
EOF
        destination = "secrets/tls/ca.pem"
      }

      template {
        data = <<EOF
NOMAD_ADDR=https://{{ with service "http.nomad" }}{{ with index . 0 }}{{ .Address }}:{{ .Port }}{{ end }}{{ end }}
NOMAD_CACERT=/secrets/tls/ca.pem
NOMAD_TLS_SERVER_NAME=server.#{Datacenter}.nomad
EOF
        destination = "secrets/nomad-snapshot.env"
        env         = true
      }

      resources {
        cpu    = 200
        memory = 512
      }
    }
  }
}