# ── Policy ConfigMap ──────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "opa_policies" {
  metadata {
    name      = "trino-opa-policies"
    namespace = local.trino_namespace
  }

  data = {
    "trino.rego" = file("${path.module}/../opa/trino.rego")
  }
}

# ── OPA Deployment ────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "opa" {
  metadata {
    name      = "trino-opa"
    namespace = local.trino_namespace
    labels    = { app = "trino-opa" }
  }

  wait_for_rollout = false

  spec {
    replicas = 1

    selector {
      match_labels = { app = "trino-opa" }
    }

    template {
      metadata {
        labels = { app = "trino-opa" }
        annotations = {
          # Whenever the policy file changes, the hash changes → Kubernetes
          # performs a rolling restart of the OPA pod automatically.
          # No manual kubectl rollout restart needed.
          "configmap-hash" = sha256(jsonencode(kubernetes_config_map_v1.opa_policies.data))
        }
      }

      spec {
        container {
          name  = "opa"
          image = "openpolicyagent/opa:latest"

          args = [
            "run",
            "--server",
            "--addr=0.0.0.0:8181",
            "--log-format=json",
            "--log-level=info",
            "/policies/trino.rego",
          ]

          port {
            container_port = 8181
          }

          # subPath mounts the file directly — avoids the symlink indirection
          # introduced by Kubernetes' ..data/ directory that caused OPA to load
          # duplicate package definitions.
          volume_mount {
            name       = "policies"
            mount_path = "/policies/trino.rego"
            sub_path   = "trino.rego"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8181
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health?plugins"
              port = 8181
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }

        volume {
          name = "policies"
          config_map {
            name = kubernetes_config_map_v1.opa_policies.metadata[0].name
          }
        }
      }
    }
  }
}

# ── OPA Service (ClusterIP — only reachable inside the cluster) ───────────────

resource "kubernetes_service_v1" "opa" {
  metadata {
    name      = "trino-opa"
    namespace = local.trino_namespace
  }

  spec {
    selector = { app = "trino-opa" }

    port {
      port        = 8181
      target_port = 8181
    }

    type = "ClusterIP"
  }
}
