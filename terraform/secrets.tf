# ── AWS Secrets Manager ───────────────────────────────────────────────────────
#
# All sensitive values are stored as a single JSON object in one secret.
# This keeps secrets out of terraform.tfvars and CI environment variables.
#
# Create the secret once:
#   aws secretsmanager create-secret \
#     --name terraform-trino \
#     --secret-string '{
#       "admin_password":                      "$2y$10$...",
#       "internal_communication_shared_secret": "openssl rand -hex 32 output",
#       "extra_users": [
#         "alice:$2y$10$...",
#         "charlie:$2y$10$..."
#       ]
#     }'
#
# Update the secret after rotating credentials:
#   aws secretsmanager put-secret-value \
#     --secret-id terraform-trino \
#     --secret-string file://secrets.json

data "aws_secretsmanager_secret_version" "trino" {
  secret_id = var.secret_name
}

locals {
  secrets = jsondecode(data.aws_secretsmanager_secret_version.trino.secret_string)

  # htpasswd-format string consumed by Trino's PASSWORD authenticator.
  password_auth = join("\n", concat(
    ["admin:${local.secrets["admin_password"]}"],
    try(local.secrets["extra_users"], []),
  ))

  # SHA-256 of the raw secret string. Injected as a pod annotation on both the
  # coordinator and worker so that Kubernetes performs a rolling restart
  # automatically whenever the secret value changes — same pattern as the
  # configmap-hash annotation on the OPA deployment.
  secrets_hash = sha256(data.aws_secretsmanager_secret_version.trino.secret_string)
}
