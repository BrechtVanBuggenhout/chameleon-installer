# Project Audit Logging - Data Access and Admin Read Events
resource "google_project_iam_audit_config" "compliance_services" {
  for_each = local.audit_log_services

  project = var.gcp_project_id
  service = each.value

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# Ensure the Cloud Logging service identity exists before granting bucket IAM.
resource "google_project_service_identity" "logging" {
  provider = google-beta

  project = var.gcp_project_id
  service = "logging.googleapis.com"

  depends_on = [google_project_service.logging]
}

resource "google_project_service_identity" "run" {
  provider = google-beta

  project = var.gcp_project_id
  service = "run.googleapis.com"

  depends_on = [google_project_service.run]
}

# Cloud Logging Sink - Export Compliance Evidence to GCS
resource "google_logging_project_sink" "compliance_audit_logs" {
  name                   = "${var.app_name}-compliance-audit-${local.instance_name}"
  project                = var.gcp_project_id
  destination            = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"
  unique_writer_identity = true
  filter                 = <<-EOT
    (
      logName:"cloudaudit.googleapis.com" AND (
        protoPayload.serviceName="bigquery.googleapis.com" OR
        protoPayload.serviceName="cloudkms.googleapis.com" OR
        protoPayload.serviceName="run.googleapis.com" OR
        protoPayload.serviceName="datastore.googleapis.com" OR
        protoPayload.serviceName="iam.googleapis.com" OR
        protoPayload.serviceName="secretmanager.googleapis.com" OR
        protoPayload.serviceName="storage.googleapis.com"
      )
    ) OR (
      resource.type="cloud_run_revision" AND
      resource.labels.service_name="${local.key_vault_service_name}" AND
      jsonPayload.certificateChainAnchor=true
    )
  EOT

  depends_on = [
    google_project_service.logging,
    google_project_iam_audit_config.compliance_services
  ]
}

resource "google_storage_bucket_iam_member" "audit_logs_sink_writer" {
  bucket = google_storage_bucket.audit_logs.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.compliance_audit_logs.writer_identity

  depends_on = [google_project_service_identity.logging]
}
