packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.6"
      source  = "github.com/hashicorp/googlecompute"
    }
    ansible = {
      version = ">= 1.1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  # Version-Controlled Naming — Distinct Image Per Build, All Sharing One
  # image_family So Terraform Can Reference Either A Specific Pinned Name
  # (Reproducible, Explicit Bump Required) Or "family/nomad-client"
  # (Always-Latest, No Terraform Change Needed Per Rebuild). Given This
  # Project's Trunk-Based, Single-Source-Of-Truth Philosophy Elsewhere,
  # Pinning The Specific Name In compute/main.tf's tfvars Is The
  # Recommended Default
  image_name = "nomad-client-image-${formatdate("YYYYMMDD-hhmmss", timestamp())}"

  # Paths Assume `packer build` Is Invoked From Inside This Directory
  # (packer/nomad-client/), Adjust it If You Invoke It From
  # Elsewhere.
  ansible_dir = "../../ansible"
}

source "googlecompute" "nomad_client" {
  project_id   = var.project_id
  zone         = var.zone
  machine_type = "e2-medium" # Build VM Only

  source_image_family = "debian-12"
  image_name           = local.image_name
  image_family         = "nomad-client"
  image_description    = "nomad-platform-gcp Nomad client golden image — common, consul, nomad, docker, falco roles baked via Ansible."

  subnetwork             = var.subnetwork
  service_account_email  = var.service_account_email

  # cloud-platform Scope Is Required — GCE Scopes Are A Separate Access
  # Control Layer On Top Of IAM, And The Default Scope Set
  # (userinfo.email, compute, devstorage.full_control) Does NOT Include
  # Secret Manager. Without This, Every `gcloud secrets versions access`
  # Call The Ansible Roles Run ON This Build VM Would Fail With A
  # Scope-Related Permission Error
  scopes = ["https://www.googleapis.com/auth/cloud-platform"]

  use_iap          = true
  use_internal_ip  = true
  omit_external_ip = true

  # REQUIRED — terraform/bootstrap Enforces OS Login Project-Wide
  # (enable-oslogin = TRUE). Without This Explicit Flag, Packer Falls
  # Back To Its Default Instance-Metadata SSH Key Injection, Which
  # OS-Login-Enabled Instances Silently Ignore Entirely
  use_os_login = true

  ssh_username = var.ssh_username

  disk_size = 20
  disk_type = "pd-balanced"

  # CMEK — Matches The Boot Disk Encryption Policy Used Everywhere Else In
  # This Project.
  disk_encryption_key {
    kmsKeyName = var.disk_cmek_key_id
  }

  labels = {
    role       = "nomad-client-image"
    managed-by = "packer"
  }
}

build {
  sources = ["source.googlecompute.nomad_client"]

  # Runs ansible-playbook locally Connecting Out To The Ephemeral Build VM Over The Same
  # IAP-Tunneled SSH Packer Itself Used To Provision It.
  #
  # target_hosts=all Overrides nomad-clients.yaml's Default hosts:
  # role_nomad_client — Packer's Own Generated Inventory Contains Only
  # The One Build VM, Not That Group, So Without This Override The Play
  # Would Match Zero Hosts And Silently Do Nothing.
  provisioner "ansible" {
    playbook_file = "${local.ansible_dir}/playbooks/nomad-clients.yaml"
    user          = var.ssh_username
    use_proxy     = false

    ansible_env_vars = [
      "ANSIBLE_CONFIG=${local.ansible_dir}/ansible.cfg",
      "ANSIBLE_ROLES_PATH=${local.ansible_dir}/roles",
    ]

    extra_arguments = [
      "-e", "target_hosts=all",
      "-e", "@${local.ansible_dir}/inventory/group_vars/all.yaml",
    ]
  }
}
