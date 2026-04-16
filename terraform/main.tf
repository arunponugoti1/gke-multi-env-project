resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "clouddeploy.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}



resource "google_artifact_registry_repository" "docker_repo" {
  location      = var.region
  repository_id = "${var.app_name}-images"
  format        = "DOCKER"
  depends_on    = [google_project_service.enabled_apis]
}

resource "google_container_cluster" "primary" {
  name             = "${var.app_name}-cluster"
  location         = var.region
  enable_autopilot = true

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.enabled_apis]
}



resource "google_service_account" "cicd_sa" {
  account_id   = "cicd-pipeline-sa"
  display_name = "CI/CD Pipeline Service Account"
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset([
    "roles/source.reader",
    "roles/artifactregistry.writer",
    "roles/container.developer",
    "roles/clouddeploy.operator",
    "roles/iam.serviceAccountUser"
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.cicd_sa.email}"
}
