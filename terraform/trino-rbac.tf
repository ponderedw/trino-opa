# ── Kubernetes RBAC for catalog-refresher sidecar ────────────────────────────
#
# The catalog-refresher sidecar triggers rolling restarts by PATCHing the
# trino-coordinator and trino-worker Deployments via the Kubernetes API.
# The Trino ServiceAccount (created by Helm) needs explicit permission to do so.

resource "kubernetes_role_v1" "trino_restart" {
  metadata {
    name      = "trino-restart"
    namespace = local.trino_namespace
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "patch"]
  }

  depends_on = [helm_release.trino]
}

resource "kubernetes_role_binding_v1" "trino_restart" {
  metadata {
    name      = "trino-restart"
    namespace = local.trino_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.trino_restart.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "trino"
    namespace = local.trino_namespace
  }

  depends_on = [helm_release.trino]
}
