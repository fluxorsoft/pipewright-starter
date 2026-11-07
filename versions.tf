terraform {
  required_version = ">= 1.9"
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 8.5" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 8.5" }
    time        = { source = "hashicorp/time", version = "~> 0.13" } # IAM propagation waits (1.4.1)
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
