terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0, < 6.0"
    }
  }

  # Remote state backend (recommended for team use).
  # Uncomment and configure after the GCS bucket is created.
  # See TODO.md for instructions.
  #
  # backend "gcs" {
  #   bucket = "oran-lab-tfstate"
  #   prefix = "terraform/state"
  # }
}
