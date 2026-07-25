terraform {
  backend "gcs" {
    # Configure backend via command line or backend config file:
    # terraform init -backend-config="bucket=YOUR_STATE_BUCKET" -backend-config="prefix=chameleon/terraform"
    prefix = "chameleon/terraform"
  }
}
