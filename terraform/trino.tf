locals {
  # Build the htpasswd-format string: "user:hash\nuser2:hash2\n..."
  # The leading "admin:" entry is always present; extra_users appends more.
  password_auth = join("\n", concat(
    ["admin:${var.admin_password}"],
    var.extra_users,
  ))
}

resource "helm_release" "trino" {
  name       = "trino"
  repository = "https://trinodb.github.io/charts"
  chart      = "trino"
  version    = var.trino_chart_version
  namespace  = local.trino_namespace

  # Wait until all pods pass their readiness probes.
  wait    = true
  timeout = 600

  # Force a Helm upgrade even if the chart version hasn't changed
  # (useful when only values change).
  force_update = true

  # OPA must be running before Trino starts so the access-control plugin
  # can reach it on the first request.
  depends_on = [
    kubernetes_namespace_v1.trino,
    kubernetes_service_v1.opa,
  ]

  values = [
    templatefile("${path.module}/helm-values.yml", {
      internal_communication_shared_secret = var.internal_communication_shared_secret
      trino_image_tag                      = var.trino_image_tag
      workers                              = var.coordinator_workers
      coordinator_heap                     = var.coordinator_heap
      coordinator_memory                   = var.coordinator_memory
      coordinator_cpu                      = var.coordinator_cpu
      coordinator_max_memory               = var.coordinator_max_memory
      coordinator_max_memory_per_node      = var.coordinator_max_memory_per_node
      coordinator_heap_headroom            = var.coordinator_heap_headroom
      worker_heap                          = var.worker_heap
      worker_memory                        = var.worker_memory
      worker_cpu                           = var.worker_cpu
      worker_max_memory_per_node           = var.worker_max_memory_per_node
      worker_heap_headroom                 = var.worker_heap_headroom
      password_auth                        = local.password_auth
      ingress_enabled                      = var.ingress_enabled
      trino_hostname                       = var.trino_hostname
      tls_secret_name                      = var.tls_secret_name
    })
  ]
}
