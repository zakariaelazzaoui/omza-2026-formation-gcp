# GCS bucket for raw data
resource "google_storage_bucket" "bucket" {
  name          = "omza-etl-dsy"
  location      = "EU"
  force_destroy = true
}

# BigQuery dataset
resource "google_bigquery_dataset" "dataset" {
  dataset_id    = "omza_dsy"
  friendly_name = "omza Dataset"
  description   = "omza Dataset"
  location      = "EU"
}

# Raw country reference table
resource "google_bigquery_table" "raw_country" {
  dataset_id = "omza_dsy"
  table_id   = "raw_country"
  schema     = <<EOF
  [
    {"name": "id", "type": "STRING"},
    {"name": "iso", "type": "STRING"},
    {"name": "name", "type": "STRING"},
    {"name": "nicename", "type": "STRING"},
    {"name": "iso3", "type": "STRING"},
    {"name": "numcode", "type": "STRING"},
    {"name": "phonecode", "type": "STRING"}
  ]
  EOF
}

# Raw invoice transactions table
resource "google_bigquery_table" "raw_invoice" {
  dataset_id = "omza_dsy"
  table_id   = "raw_invoice"
  schema     = <<EOF
  [
    {"name": "InvoiceNo", "type": "STRING"},
    {"name": "StockCode", "type": "STRING"},
    {"name": "Description", "type": "STRING"},
    {"name": "Quantity", "type": "STRING"},
    {"name": "InvoiceDate", "type": "STRING"},
    {"name": "UnitPrice", "type": "STRING"},
    {"name": "CustomerID", "type": "STRING"},
    {"name": "Country", "type": "STRING"}
  ]
  EOF
}