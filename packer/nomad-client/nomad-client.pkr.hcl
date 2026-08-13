packer {
  required_plugins {
    googlecompute = {
      version = "= 1.2.7"
      source  = "github.com/hashicorp/googlecompute"
    }
    ansible = {
      version = "= 1.1.6"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

locals {
  # Version-Controlled Naming
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

  scopes = ["https://www.googleapis.com/auth/cloud-platform"]

  use_iap          = true
  use_internal_ip  = true
  omit_external_ip = true
  use_os_login = false
  ssh_username = var.ssh_username
  
  disk_size = 20
  disk_type = "pd-balanced"

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
  # target_hosts=all Overrides nomad-clients.yaml's Default hosts: role_worker
  provisioner "ansible" {
    playbook_file = "${local.ansible_dir}/playbooks/nomad-clients.yaml"
    user          = build.User
    use_proxy     = false
    keep_inventory_file  = true

    ansible_env_vars = [
      "ANSIBLE_CONFIG=${local.ansible_dir}/ansible.cfg",
      "ANSIBLE_ROLES_PATH=${local.ansible_dir}/roles",
    ]

    extra_arguments = [
      "-e", "target_hosts=all",
      "-e", "@${local.ansible_dir}/inventory/group_vars/all.yaml",
      "-e", "ansible_ssh_common_args=",
      "-e", "ansible_user=${build.User}",
      "-vvvv"
    ]
  }
}
