# nomad-jobs/boutique/loadgenerator.nomad.hcl
#
# Headless Locust, generating continuous traffic against frontend.
#
# UNVERIFIED EDGE CASE: this is the one service in this whole retrofit
# with no real inbound port at all — purely outbound. I've declared a
# minimal network port (8089, Locust's own default, unused in headless
# mode) just to give the group/service stanza something to attach the
# sidecar to, but I'm not fully certain this is the cleanest way Nomad
# expects a connect-enabled, upstream-only, no-real-listener service
# to be declared — worth checking against current Nomad Connect docs
# before trusting this one, unlike everything else in this retrofit.
#
# Hard spot-only: test traffic, zero production impact if preempted.

job "loadgenerator" {
  datacenters = ["#{Datacenter}"]
  namespace   = "#{DeploymentNamespace}"
  type        = "service"

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
  }

  group "loadgenerator" {
    count = #{ReplicaCount}

    constraint {
      attribute = "${meta.node_pool_type}"
      operator  = "="
      value     = "spot"
    }

    network {
      mode = "bridge"

      port "ui" {
        to = 8089
      }
    }

    service {
      name = "loadgenerator"
      port = "ui"

      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "frontend"
              local_bind_port  = 8080
            }
          }
        }
      }
    }

    task "loadgenerator" {
      driver = "docker"

      config {
        image = "#{ArtifactRegistry}/loadgenerator:#{ImageTag}"
        ports = ["ui"]
      }

      env {
        FRONTEND_ADDR   = "localhost:8080"
        USERS           = "10"
        SPAWN_RATE      = "1"
        LOCUST_HEADLESS = "true"
      }

      resources {
        cpu    = #{Cpu}
        memory = #{Memory}
      }
    }
  }
}
