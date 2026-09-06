locals {
  catalog_templates = {
    # Each .tmpl file is rendered by the init container at pod startup.
    # {placeholder} variables are replaced with values from the trino-credentials secret.
    # Add one entry per catalog — the key becomes the catalog name in Trino.

    "powerschool.properties.tmpl" = <<-EOT
      connector.name=postgresql
      connection-url={powerschool_url}
      connection-user={powerschool_user}
      connection-password={powerschool_password}
      postgresql.fetch-size=10000
    EOT

    "illuminate.properties.tmpl" = <<-EOT
      connector.name=postgresql
      connection-url={illuminate_url}
      connection-user={illuminate_user}
      connection-password={illuminate_password}
      postgresql.fetch-size=10000
    EOT

    "bi_prod.properties.tmpl" = <<-EOT
      connector.name=postgresql
      connection-url={bi_prod_url}
      connection-user={bi_prod_user}
      connection-password={bi_prod_password}
      postgresql.fetch-size=10000
    EOT

    # Memory connector needs no credentials — the template is still processed
    # but render_template finds no placeholders and writes it as-is.
    "sandbox.properties.tmpl" = <<-EOT
      connector.name=memory
    EOT
  }
}

# ── Catalog template ConfigMap ────────────────────────────────────────────────
# Holds the .properties.tmpl files. Mounted read-only into both the init
# container (which renders them) and the sidecar (which watches for changes).

resource "kubernetes_config_map_v1" "catalog_templates" {
  metadata {
    name      = "trino-catalog-templates"
    namespace = local.trino_namespace
  }
  data = local.catalog_templates
}

# ── Refresher script ConfigMap ────────────────────────────────────────────────
# Holds catalog_refresher.py so the pod can run it without baking it into the
# image. Mounted with defaultMode 0755 so the container can execute it.

resource "kubernetes_config_map_v1" "catalog_refresher" {
  metadata {
    name      = "trino-catalog-refresher"
    namespace = local.trino_namespace
  }
  data = {
    "catalog_refresher.py" = file("${path.module}/catalog_refresher.py")
  }
}

# ── External Secrets Operator: SecretStore ────────────────────────────────────
# Tells ESO how to reach AWS Secrets Manager.

resource "kubectl_manifest" "secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "SecretStore"
    metadata = {
      name      = "trino-aws-sm"
      namespace = local.trino_namespace
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  })

  depends_on = [helm_release.external_secrets_operator]
}

# ── External Secrets Operator: ExternalSecret ─────────────────────────────────
# ESO syncs all keys from the Secrets Manager secret into the
# trino-credentials Kubernetes Secret every minute.
# The init container and sidecar read files from this secret.

resource "kubectl_manifest" "external_secret" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "trino-credentials"
      namespace = local.trino_namespace
    }
    spec = {
      refreshInterval = "1m"
      secretStoreRef = {
        name = "trino-aws-sm"
        kind = "SecretStore"
      }
      target = {
        name           = "trino-credentials"
        creationPolicy = "Owner"
      }
      dataFrom = [{
        extract = {
          key = var.secret_name
        }
      }]
    }
  })

  depends_on = [kubectl_manifest.secret_store]
}
