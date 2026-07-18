packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.6"
      source  = "github.com/hashicorp/googlecompute"
    }
    ansible = {
      version = ">= 2.0.0"
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
  # Recommended Default — Treat family/nomad-client As An Option, Not The
  # Assumed Choice.
  image_name = "nomad-client-image-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
}

source "googlecompute" "nomad_client" {
  project_id   = var.project_id
  zone         = var.zone
  machine_type = "e2-medium" # Build VM Only — Unrelated To The Real Client Machine Type

  source_image_family = "debian-12"
  image_name           = local.image_name
  image_family         = "nomad-client"
  image_description    = "nomad-platform-gcp Nomad client golden image — common, consul, nomad, docker, falco roles baked via Ansible."

  subnetwork             = var.subnetwork
  service_account_email  = var.service_account_email
  use_iap                = true
  use_internal_ip        = true
  omit_external_ip       = true
  disable_default_service_account = true

  # REQUIRED — terraform/bootstrap Enforces OS Login Project-Wide
  # (enable-oslogin = TRUE). Without This Explicit Flag, Packer Falls
  # Back To Its Default Instance-Metadata SSH Key Injection, Which
  # OS-Login-Enabled Instances Silently Ignore Entirely — Confirmed By
  # Several Real hashicorp/packer-plugin-googlecompute Issues Reporting
  # Exactly This Failure Mode. With It Set, Packer Instead Registers Its
  # Temporary Key Via The OS Login API Against The Authenticating
  # Identity's Google Account Profile.
  use_os_login = true

  ssh_username = var.ssh_username

  disk_size = 20
  disk_type = "pd-balanced"

  # CMEK — Matches The Boot Disk Encryption Policy Used Everywhere Else In
  # This Project. Pass The Same disk_cmek_key_id compute/ Already Reads
  # From terraform/bootstrap's Outputs.
  disk_encryption_key {
    kms_key_self_link = var.disk_cmek_key_id
  }

  labels = {
    role       = "nomad-client-image"
    managed-by = "packer"
  }
}

build {
  sources = ["source.googlecompute.nomad_client"]

  # Runs ansible-playbook LOCALLY (On Whatever Machine Runs `packer build`
  # — Your Laptop), Connecting Out To The Ephemeral Build VM Over The Same
  # IAP-Tunneled SSH Packer Itself Used To Provision It. playbook_dir Sets
  # The Working Directory Ansible Runs From, So ansible.cfg's
  # inventory/roles_path Settings And group_vars Resolve Exactly As They
  # Would For A Normal Ansible Run — Verify This Against Your Installed
  # packer-plugin-ansible Version's Exact Staging Behavior Before Relying
  # On It; Path Resolution Details Have Shifted Across Plugin Versions.
  #
  # target_hosts=all Overrides nomad-clients.yml's Default hosts:
  # role_nomad_client — Packer's Own Generated Inventory Contains Only
  # The One Build VM, Not That Group, So Without This Override The Play
  # Would Match Zero Hosts And Silently Do Nothing.
  provisioner "ansible" {
    playbook_file = "../../ansible/playbooks/nomad-clients.yml"
    playbook_dir  = "../../ansible"
    user          = var.ssh_username
    use_proxy     = false

    extra_arguments = [
      "-e", "target_hosts=all",
      "-e", "@inventory/group_vars/all.yml",
    ]
  }
}
