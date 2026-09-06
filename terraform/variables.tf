variable "kubeconfig_path" {
  description = "Path to the kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Context name inside the kubeconfig file. Leave empty to use the current context."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Kubernetes namespace to deploy Trino and OPA into."
  type        = string
  default     = "trino"
}

variable "trino_chart_version" {
  description = "Version of the trinodb/trino Helm chart."
  type        = string
  default     = "1.39.0"
}

variable "trino_image_tag" {
  description = "Trino Docker image tag (corresponds to the Trino release version)."
  type        = string
  default     = "481"
}

# ── Authentication ────────────────────────────────────────────────────────────

variable "admin_password" {
  description = "Bcrypt-hashed password for the admin user. Generate with: htpasswd -bnBC 10 '' mypassword | tr -d ':'."
  type        = string
  sensitive   = true
}

variable "extra_users" {
  description = "Additional username:bcrypt-hash pairs for password auth, one per list item."
  type        = list(string)
  default     = []
  sensitive   = true
}

# ── Sizing: coordinator ───────────────────────────────────────────────────────

variable "coordinator_workers" {
  description = "Number of Trino worker pods."
  type        = number
  default     = 1
}

variable "coordinator_heap" {
  description = "JVM max heap for the coordinator (e.g. '8G')."
  type        = string
  default     = "4G"
}

variable "coordinator_memory" {
  description = "Kubernetes memory request/limit for the coordinator pod (e.g. '5Gi')."
  type        = string
  default     = "5Gi"
}

variable "coordinator_cpu" {
  description = "Kubernetes CPU request/limit for the coordinator pod (e.g. '2')."
  type        = string
  default     = "2"
}

variable "coordinator_max_memory" {
  description = "Trino query.max-memory (cluster-wide)."
  type        = string
  default     = "3GB"
}

variable "coordinator_max_memory_per_node" {
  description = "Trino query.max-memory-per-node for the coordinator."
  type        = string
  default     = "2GB"
}

variable "coordinator_heap_headroom" {
  description = "Trino memory.heap-headroom-per-node for the coordinator."
  type        = string
  default     = "512MB"
}

# ── Sizing: workers ───────────────────────────────────────────────────────────

variable "worker_heap" {
  description = "JVM max heap for workers (e.g. '8G')."
  type        = string
  default     = "4G"
}

variable "worker_memory" {
  description = "Kubernetes memory request/limit for worker pods."
  type        = string
  default     = "5Gi"
}

variable "worker_cpu" {
  description = "Kubernetes CPU request/limit for worker pods."
  type        = string
  default     = "2"
}

variable "worker_max_memory_per_node" {
  description = "Trino query.max-memory-per-node for workers."
  type        = string
  default     = "3GB"
}

variable "worker_heap_headroom" {
  description = "Trino memory.heap-headroom-per-node for workers."
  type        = string
  default     = "512MB"
}

# ── Ingress ───────────────────────────────────────────────────────────────────

variable "ingress_enabled" {
  description = "Whether to create a Kubernetes Ingress for the Trino coordinator."
  type        = bool
  default     = false
}

variable "trino_hostname" {
  description = "Hostname for the Trino coordinator Ingress (e.g. 'trino.example.com')."
  type        = string
  default     = "trino.example.com"
}

variable "tls_secret_name" {
  description = "Name of the TLS Secret to use for the Ingress. Leave empty for no TLS."
  type        = string
  default     = ""
}

# ── Internal communication ────────────────────────────────────────────────────

variable "internal_communication_shared_secret" {
  description = "Shared secret for internal Trino coordinator ↔ worker communication. Generate with: openssl rand -hex 32."
  type        = string
  sensitive   = true
}
