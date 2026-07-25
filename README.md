# chameleon-installer

Terraform module + bootstrap script that deploys a self-contained Chameleon
instance (Key Vault, PII ingestor worker, console) into your own GCP
project — bring-your-own-cloud (BYOC). Nothing runs outside the project you
deploy into, and nothing here has any runtime dependency on Chameleon's own
infrastructure after your images are pulled.

Chameleon is a compliance control plane that encrypts customer PII at
ingestion with a per-user key. Deleting that key (crypto-shredding) makes
every copy of that user's data — warehouse tables, dbt models, backups,
exports — unreadable everywhere at once, and produces a signed certificate
as proof.

## Get started

See **[INSTALL.md](./INSTALL.md)** for the full walkthrough: prerequisites,
running `bootstrap.sh`, BigQuery vs. Snowflake setup, and the end-to-end
verification loop.

Quick version:

```bash
cp terraform.tfvars.byoc.example terraform.tfvars
# edit terraform.tfvars — at minimum, set bigquery_rls_admin_email

./scripts/bootstrap.sh <instance_name> <environment> <gcp_project_id>
```

## Questions

Contact Chameleon — see [chameleon-data.com](https://www.chameleon-data.com).
