# BigQuery Dataset
resource "google_bigquery_dataset" "chameleon" {
  dataset_id    = var.bigquery_dataset_id
  friendly_name = "Chameleon Data Warehouse"
  description   = "Data warehouse for Project Chameleon cryptographic shredding pipeline"
  location      = var.bigquery_location

  default_table_expiration_ms     = null
  default_partition_expiration_ms = null

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "data-warehouse"
  })

  depends_on = [
    google_project_service.bigquery,
    google_kms_crypto_key_iam_member.bigquery_service_agent_kms
  ]
}

# BigQuery Dataset - Lineage Engine
resource "google_bigquery_dataset" "lineage" {
  dataset_id    = var.lineage_dataset_id
  friendly_name = "Chameleon Lineage Database"
  description   = "Database for tracking user data movement and lineage"
  location      = var.bigquery_location

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "lineage-engine"
  })

  depends_on = [
    google_project_service.bigquery,
    google_kms_crypto_key_iam_member.bigquery_service_agent_kms
  ]
}

# BigQuery Dataset - Compliance Operational State
resource "google_bigquery_dataset" "compliance" {
  dataset_id    = "compliance"
  friendly_name = "Chameleon Compliance Registry"
  description   = "Operational compliance tables for PII metadata and ghost data discovery"
  location      = var.bigquery_location

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  labels = merge(var.labels, {
    environment = var.environment
    component   = "compliance-registry"
  })

  depends_on = [
    google_project_service.bigquery,
    google_kms_crypto_key_iam_member.bigquery_service_agent_kms
  ]
}

# BigQuery Table - Lineage Events
resource "google_bigquery_table" "lineage_events" {
  dataset_id  = google_bigquery_dataset.lineage.dataset_id
  table_id    = var.lineage_table_id
  description = "Table for recording data movement events"

  # SET TO FALSE FOR SCHEMA TRANSITION
  # This allows recreation of tables during the Required -> Nullable transition.
  deletion_protection = false

  clustering = ["tenant_id", "user_id"]

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The unique identifier for the SaaS tenant"
    },
    {
      name        = "jsonPayload"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "The structured log payload containing the event data"
    },
    {
      name        = "logName"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The name of the log source"
    },
    {
      name        = "severity"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Log severity level"
    },
    {
      name        = "receiveTimestamp"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When the log was received by Cloud Logging"
    },
    {
      name        = "event_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Unique ULID for the event"
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The subject user ID"
    },
    {
      name        = "source"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "System that sent the data"
    },
    {
      name        = "destination"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "System that received the data"
    },
    {
      name        = "context"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Metadata (job IDs, table names)"
    },
    {
      name        = "data_classification"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Classification level of the data (e.g., PII, SENSITIVE, PUBLIC)"
    },
    {
      name        = "retention_policy"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Retention rules applicable to the data movement"
    },
    {
      name        = "operation_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Unique ID for the specific lineage operation"
    },
    {
      name        = "deletion_request_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Reference to the associated deletion request"
    },
    {
      name        = "event_type"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Type of event (e.g., INGESTION, SHREDDING, WIPE_REQUEST)"
    },
    {
      name        = "metadata"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Additional structured metadata for the event"
    },
    {
      name        = "timestamp"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When the movement occurred"
    },
    {
      name        = "data"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Required Pub/Sub payload field for JSON mapping"
    },
    {
      name        = "subscription_name"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub subscription name (if via ingestion stream)"
    },
    {
      name        = "message_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub message ID (if via ingestion stream)"
    },
    {
      name        = "publish_time"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "Pub/Sub message publish time (if via ingestion stream)"
    }
  ])

  labels = {
    component = "lineage-engine"
  }
}

# BigQuery Table - Tenant Access Control Mapping
resource "google_bigquery_table" "tenant_access_map" {
  dataset_id  = google_bigquery_dataset.lineage.dataset_id
  table_id    = "tenant_access_map"
  description = "Maps service accounts or users to specific tenant IDs for RLS enforcement"

  deletion_protection = false

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "The unique identifier for the SaaS tenant"
    },
    {
      name        = "authorized_member"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "The bare principal email (e.g. user@example.com). Must match BigQuery SESSION_USER(). IMPORTANT: Do not use IAM prefixes. Note: RLS tables do not support the 'Preview' tab."
    }
  ])

  labels = {
    component = "security"
    purpose   = "multi-tenant-isolation"
  }
}

resource "google_bigquery_job" "seed_tenant_access_map" {
  count = length(local.tenant_access_map_rows) > 0 ? 1 : 0

  # Incrementing job_id to v7 to bypass previous conflicts (v4, v5, v6 are likely burnt in history)
  job_id   = "seed_tenant_access_map_v8_${local.instance_name}_${substr(sha256(jsonencode(local.tenant_access_map_rows)), 0, 12)}"
  location = var.bigquery_location

  query {
    use_legacy_sql = false
    query          = <<-EOT
      MERGE `${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.${google_bigquery_table.tenant_access_map.table_id}` AS target
      USING (
        SELECT tenant_id, authorized_member
        FROM UNNEST([
          ${local.tenant_access_map_seed_structs}
        ])
      ) AS source
      ON target.tenant_id = source.tenant_id
        AND target.authorized_member = source.authorized_member
      WHEN NOT MATCHED THEN
        INSERT (tenant_id, authorized_member)
        VALUES (source.tenant_id, source.authorized_member)
    EOT

    # Explicitly clear dispositions to allow DML statements (MERGE)
    create_disposition = ""
    write_disposition  = ""
  }

  depends_on = [
    google_bigquery_table.tenant_access_map,
    google_project_iam_member.bigquery_access_job
  ]

  lifecycle {
    ignore_changes = [
      labels,
      query[0].allow_large_results,
      query[0].destination_encryption_configuration,
      query[0].destination_table,
      query[0].flatten_results,
      query[0].maximum_billing_tier,
      query[0].schema_update_options
    ]
  }
}

# BigQuery Table - PII Metadata Registry
resource "google_bigquery_table" "pii_metadata_registry" {
  dataset_id  = google_bigquery_dataset.compliance.dataset_id
  table_id    = "pii_metadata_registry"
  description = "Tenant-scoped registry of approved systems and resources that contain PII"

  deletion_protection = var.environment == "prod"
  clustering          = ["tenant_id", "system", "classification", "status"]

  time_partitioning {
    type  = "DAY"
    field = "updated_at"
  }

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "The SaaS tenant that owns the resource"
    },
    {
      name        = "resource_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Stable identifier for the table, bucket, object prefix, SaaS object, or other PII resource"
    },
    {
      name        = "system"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Source system or platform that contains the resource"
    },
    {
      name        = "classification"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "PII classification such as PII, SENSITIVE, or PUBLIC"
    },
    {
      name        = "handling"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Required handling policy for the resource"
    },
    {
      name        = "deletion_strategy"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Deletion or cryptographic shredding strategy for this resource"
    },
    {
      name        = "status"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Registry status such as approved, pending_review, deprecated, or disabled"
    },
    {
      name        = "confidence"
      type        = "FLOAT"
      mode        = "NULLABLE"
      description = "Confidence score from discovery or review, from 0.0 to 1.0"
    },
    {
      name        = "owner"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Owning service, team, or operator"
    },
    {
      name        = "notes"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Human-readable review notes"
    },
    {
      name        = "metadata"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Additional structured metadata for scanner and registry integrations"
    },
    {
      name        = "created_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the registry row was created"
    },
    {
      name        = "updated_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the registry row was last updated"
    },
    {
      name        = "last_seen_at"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When a scanner or pipeline last observed the resource"
    }
  ])

  labels = merge(var.labels, {
    component = "compliance-registry"
    purpose   = "pii-metadata"
  })
}

# BigQuery Table - Ghost Data Findings
resource "google_bigquery_table" "ghost_data_findings" {
  dataset_id  = google_bigquery_dataset.compliance.dataset_id
  table_id    = "ghost_data_findings"
  description = "Tenant-scoped scanner findings for residual or unmanaged PII resources"

  deletion_protection = var.environment == "prod"
  clustering          = ["tenant_id", "system", "status", "classification"]

  time_partitioning {
    type  = "DAY"
    field = "detected_at"
  }

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "finding_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Stable unique identifier for the finding"
    },
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "The SaaS tenant associated with the finding"
    },
    {
      name        = "resource_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Resource where ghost or unmanaged PII was found"
    },
    {
      name        = "system"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "System or platform where the finding was detected"
    },
    {
      name        = "classification"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "PII classification for the finding"
    },
    {
      name        = "handling"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Expected handling policy for the resource"
    },
    {
      name        = "deletion_strategy"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Recommended deletion or remediation strategy"
    },
    {
      name        = "status"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Finding status such as open, triaged, remediating, resolved, or false_positive"
    },
    {
      name        = "confidence"
      type        = "FLOAT"
      mode        = "REQUIRED"
      description = "Scanner confidence score from 0.0 to 1.0"
    },
    {
      name        = "evidence_uri"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pointer to supporting evidence, sample metadata, or certificate artifacts"
    },
    {
      name        = "details"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Structured scanner details for the finding"
    },
    {
      name        = "detected_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the finding was detected"
    },
    {
      name        = "updated_at"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "When the finding status was last updated"
    },
    {
      name        = "resolved_at"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When the finding was resolved, if applicable"
    }
  ])

  labels = merge(var.labels, {
    component = "compliance-registry"
    purpose   = "ghost-data-findings"
  })
}

# BigQuery Table - Raw Ingestion Layer
resource "google_bigquery_table" "raw_users" {
  dataset_id  = google_bigquery_dataset.chameleon.dataset_id
  table_id    = "raw_users"
  description = "Raw encrypted user ingestion table. dbt materializes stg_users from this table."

  # SET TO FALSE FOR SCHEMA TRANSITION
  # This allows recreation of tables during the Required -> Nullable transition.
  deletion_protection = false

  clustering = ["tenant_id", "user_id"]

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "tenant_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The unique identifier for the SaaS tenant"
    },
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Unique user identifier"
    },
    {
      name        = "email_token"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "HMAC-SHA256 token of email for deterministic joins"
    },
    {
      name        = "encryption_version"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Version of the encryption scheme (e.g., v2)"
    },
    {
      name        = "key_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "UUID of the specific key version used"
    },
    {
      name        = "encrypted_pii"
      type        = "BYTES"
      mode        = "NULLABLE"
      description = "Encrypted PII blob (CMEK encrypted)"
    },
    {
      name        = "data_hash"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Hash of data for lineage tracking"
    },
    {
      name        = "operation_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "ULID/UUID for ingestion idempotency"
    },
    {
      name        = "ingested_at"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "Data ingestion timestamp"
    },
    {
      name        = "source_system"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Originating data source"
    },
    {
      name        = "pii_fields"
      type        = "RECORD"
      mode        = "REPEATED"
      description = "One entry per PII field declared for this resource in the PII registry (email, phone, etc). email_token/encrypted_pii above are kept in sync for whichever field is classified as email, for backward compatibility with existing readers -- this column is the general, N-field home."
      fields = [
        {
          name        = "field_name"
          type        = "STRING"
          mode        = "NULLABLE"
          description = "Declared PII field name, e.g. 'email' or 'phone'"
        },
        {
          name        = "token"
          type        = "STRING"
          mode        = "NULLABLE"
          description = "HMAC-SHA256 token of this field's value for deterministic joins"
        },
        {
          name        = "encrypted_value"
          type        = "BYTES"
          mode        = "NULLABLE"
          description = "Encrypted value for this field (CMEK encrypted)"
        }
      ]
    },
    {
      name        = "data"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Required Pub/Sub payload field for JSON mapping"
    },
    {
      name        = "subscription_name"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub subscription name"
    },
    {
      name        = "message_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub message ID"
    },
    {
      name        = "publish_time"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "Pub/Sub message publish time"
    },
    {
      name        = "attributes"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Pub/Sub message attributes"
    }
  ])

  labels = {
    layer = "raw"
  }
}

# BigQuery Table - Analytics/Mart Layer
resource "google_bigquery_table" "analytics_users" {
  dataset_id  = google_bigquery_dataset.chameleon.dataset_id
  table_id    = "analytics_users"
  description = "Analytics table: aggregated user reporting mart"

  # SET TO FALSE FOR SCHEMA TRANSITION
  # Re-enable after successful apply.
  deletion_protection = false

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "user_id"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Unique user identifier"
    },
    {
      name        = "is_encrypted"
      type        = "BOOLEAN"
      mode        = "REQUIRED"
      description = "Whether user PII is encrypted"
    },
    {
      name        = "aggregated_metrics"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "JSON blob of aggregated user metrics"
    },
    {
      name        = "last_updated"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Last update timestamp"
    }
  ])

  labels = {
    layer = "analytics"
  }
}

# BigQuery Table - Lineage Failed Events (DLQ Storage)
resource "google_bigquery_table" "lineage_failed_events" {
  dataset_id  = google_bigquery_dataset.lineage.dataset_id
  table_id    = "lineage_failed_events"
  description = "Persistent log of lineage events that failed to be written to the main events table"

  deletion_protection = false

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "publish_time"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When the message was published to the DLQ"
    },
    {
      name        = "subscription_name"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The name of the Pub/Sub subscription that pushed the message"
    },
    {
      name        = "message_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub message ID"
    },
    {
      name        = "data"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Raw event data"
    },
    {
      name        = "attributes"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Pub/Sub message attributes including error codes"
    }
  ])
}

# BigQuery Table - Janitor Failed Wipe Log (DLQ Storage)
resource "google_bigquery_table" "janitor_failed_wipes" {
  dataset_id  = google_bigquery_dataset.lineage.dataset_id
  table_id    = "janitor_failed_wipes"
  description = "Persistent log of permanently failed SaaS wipe requests from the Janitor DLQ"

  # SET TO FALSE FOR SCHEMA TRANSITION
  # Re-enable after successful apply.
  deletion_protection = false

  encryption_configuration {
    kms_key_name = google_kms_crypto_key.bigquery_dataset_key.id
  }

  schema = jsonencode([
    {
      name        = "publish_time"
      type        = "TIMESTAMP"
      mode        = "NULLABLE"
      description = "When the message was published to the DLQ"
    },
    {
      name        = "subscription_name"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "The name of the Pub/Sub subscription that pushed the message"
    },
    {
      name        = "message_id"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Pub/Sub message ID"
    },
    {
      name        = "data"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Required Pub/Sub payload field for JSON mapping"
    },
    {
      name        = "attributes"
      type        = "JSON"
      mode        = "NULLABLE"
      description = "Pub/Sub message attributes (e.g., error codes, retry counts)"
    }
  ])

  labels = {
    component = "key-vault"
    purpose   = "audit-trail"
  }
}

# New: Row-Level Security Policy for Lineage Events (Multi-Tenancy)
resource "google_bigquery_row_access_policy" "tenant_isolation" {
  count = var.enable_bigquery_row_access_policies ? 1 : 0

  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.lineage.dataset_id
  table_id   = google_bigquery_table.lineage_events.table_id
  policy_id  = "tenant_isolation_policy"
  grantees   = local.bigquery_rls_policy_grantees

  # Enforces that the caller can only see rows where their identity is mapped to the tenant_id
  # or if they are an admin with a specific override.
  # SUPER ADMIN BYPASS: Added SESSION_USER() check to allow full visibility for debugging.
  filter_predicate = <<-EOT
    LOWER(SESSION_USER()) = '${local.bigquery_rls_admin_email}'
    OR 
    tenant_id IN (SELECT tenant_id FROM `${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.tenant_access_map` WHERE LOWER(authorized_member) = LOWER(SESSION_USER()))
  EOT
}

resource "google_bigquery_row_access_policy" "raw_users_tenant_isolation" {
  count = var.enable_bigquery_row_access_policies ? 1 : 0

  project    = var.gcp_project_id
  dataset_id = google_bigquery_dataset.chameleon.dataset_id
  table_id   = google_bigquery_table.raw_users.table_id
  policy_id  = "raw_users_tenant_isolation_policy"
  grantees   = local.bigquery_rls_policy_grantees

  filter_predicate = <<-EOT
    LOWER(SESSION_USER()) = '${local.bigquery_rls_admin_email}'
    OR
    tenant_id IN (SELECT tenant_id FROM `${var.gcp_project_id}.${google_bigquery_dataset.lineage.dataset_id}.tenant_access_map` WHERE LOWER(authorized_member) = LOWER(SESSION_USER()))
  EOT
}

# IAM: GCP-managed BigQuery service agent needs KMS access for CMEK
resource "google_kms_crypto_key_iam_member" "bigquery_service_agent_kms" {
  crypto_key_id = google_kms_crypto_key.bigquery_dataset_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = data.google_bigquery_default_service_account.bq.member
}
