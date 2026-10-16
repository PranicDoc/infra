variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  description = "Only used on first create; afterwards CI owns the image (see ignore_changes)."
  type        = string
}

variable "service_account_email" {
  type = string
}

variable "port" {
  type = number
}

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "1Gi"
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 3
}

variable "concurrency" {
  type    = number
  default = 80
}

variable "env" {
  type      = map(string)
  default   = {}
  sensitive = true
}

variable "secret_env" {
  description = "ENV_VAR => Secret Manager secret name (always :latest)."
  type        = map(string)
  default     = {}
}

variable "ingress" {
  type    = string
  default = "INGRESS_TRAFFIC_ALL"
}

resource "google_cloud_run_v2_service" "this" {
  name                = var.name
  location            = var.region
  ingress             = var.ingress
  deletion_protection = true

  template {
    service_account                  = var.service_account_email
    max_instance_request_concurrency = var.concurrency

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true # request-based billing: no CPU charge between requests
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = nonsensitive(keys(var.env))
        content {
          name  = env.value
          value = var.env[env.value]
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # CI rolls out new images with `gcloud run deploy --image`; tofu owns everything else.
      template[0].containers[0].image,
      client,
      client_version,
      scaling, # service-level scaling; per-revision scaling in template is what we manage
      template[0].annotations,
      template[0].labels,
    ]
  }
}

output "name" {
  value = google_cloud_run_v2_service.this.name
}

output "uri" {
  value = google_cloud_run_v2_service.this.uri
}
