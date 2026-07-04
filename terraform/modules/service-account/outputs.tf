output "service_accounts" {
  description = "A map of Service Account names to their email addresses and member strings."
  value = {
    for name, sa in google_service_account.this : name => {
      email  = sa.email
      member = sa.member
    }
  }
}

output "service_account_iam_bindings" {
  description = "A map showing which roles were assigned to which service accounts."
  value = {
    for key, binding in google_project_iam_member.roles : key => {
      role   = binding.role
      member = binding.member
    }
  }
}