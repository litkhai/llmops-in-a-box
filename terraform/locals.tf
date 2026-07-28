locals {
  common_tags = {
    Project     = var.project_slug
    Environment = "demo"
    ManagedBy   = "terraform"
    Owner       = "llmops-in-a-box"
    Region      = var.region
  }
}
