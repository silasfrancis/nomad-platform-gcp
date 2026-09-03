# Grant Vault's VM the permission it needs to mint/rotate service account
# keys for static accounts.
resource "google_project_iam_member" "vault_gcp_backend_roles" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountKeyAdmin"
  member  = var.vault_vm_member
}

resource "google_service_account" "nomad_autoscaler" {
  for_each     = toset(["dev", "prod"])
  account_id   = "nomad-autoscaler-${each.key}"
  display_name = "Nomad Autoscaler ${each.key}"
  project      = var.gcp_project_id
}

resource "google_project_iam_member" "nomad_autoscaler_roles" {
  for_each = {
    for pair in setproduct(["dev", "prod"],
      ["roles/compute.instanceAdmin.v1",
      "roles/compute.networkViewer"]) :
    "${pair[0]}-${pair[1]}" => pair
  }

  project = var.gcp_project_id
  role    = each.value[1]
  member  = google_service_account.nomad_autoscaler[each.value[0]].member
}

# --- Per-SA exception to the project-wide iam.disableServiceAccountKeyCreation
# constraint, so ONLY the two nomad-autoscaler service accounts above can
# ever have keys created — everything else in the project stays blocked. ---

# Tag key + value that mark a service account as exempted. Defined at
# project level so this doesn't require org-level tag admin permissions;
# narrow it to org level instead if you want the same exception reusable
# across other projects later.
resource "google_tags_tag_key" "key_exception" {
  parent      = "projects/${var.gcp_project_id}"
  short_name  = "env"
  description = "Marks resources exempted from iam.disableServiceAccountKeyCreation"
}

resource "google_tags_tag_value" "key_exception" {
  parent      = google_tags_tag_key.key_exception.id
  short_name  = "key-exception"
  description = "Service account is allowed to have keys created despite the org-wide policy"
}

# Workaround for Terraform Google Provider limitation: 
# Native `google_tags_tag_binding` triggers a 400 Bad Request error 
# ("Resource type not supported in location global") when bound to IAM service accounts. 
# This null_resource invokes the gcloud CLI directly, which successfully handles 
# the underlying regional API routing for service account tag bindings.
resource "null_resource" "nomad_autoscaler_key_exception" {
  for_each = toset(["dev", "prod"])

  triggers = {
    tag_value = google_tags_tag_value.key_exception.id
    parent    = "//iam.googleapis.com/${google_service_account.nomad_autoscaler[each.key].name}"
  }

  provisioner "local-exec" {
    command = <<EOT
      set -e

      if gcloud resource-manager tags bindings list \
        --parent="${self.triggers.parent}" \
        --format="value(tagValue)" | grep -Fxq "${self.triggers.tag_value}"; then
        echo "Tag binding already exists."
      else
        echo "Creating tag binding..."
        gcloud resource-manager tags bindings create \
          --tag-value="${self.triggers.tag_value}" \
          --parent="${self.triggers.parent}"
      fi
    EOT
  }

  provisioner "local-exec" {
    when = destroy

    command = <<EOT
      gcloud resource-manager tags bindings delete \
        --tag-value="${self.triggers.tag_value}" \
        --parent="${self.triggers.parent}" \
        --quiet || true
    EOT
  }

  depends_on = [
    google_tags_tag_value.key_exception,
    google_service_account.nomad_autoscaler
  ]
}

# Project-level policy: enforced everywhere by default, except on
# resources carrying the key-exception tag (i.e. only the two SAs above).
resource "google_org_policy_policy" "sa_key_creation_exception" {
  name   = "projects/${var.gcp_project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${var.gcp_project_id}"

  spec {
    rules {
      enforce = "FALSE"
      condition {
        expression = "resource.matchTag('${var.gcp_project_id}/env', 'key-exception')"
      }
    }

    rules {
      enforce = "TRUE"
    }
  }
  depends_on = [null_resource.nomad_autoscaler_key_exception]

}

# Static accounts bind Vault to a real, pre-existing GCP service account
# and have Vault mint/rotate short-lived keys for it.
resource "vault_gcp_secret_static_account" "nomad_autoscaler" {
  for_each              = toset(["dev", "prod"])
  backend               = vault_gcp_secret_backend.gcp.path
  static_account        = "nomad-autoscaler-${each.key}"
  service_account_email = google_service_account.nomad_autoscaler[each.key].email
  secret_type           = "service_account_key"

  depends_on = [
    google_org_policy_policy.sa_key_creation_exception,
    null_resource.nomad_autoscaler_key_exception,
  ]
}