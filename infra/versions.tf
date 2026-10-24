terraform {
  required_version = ">= 1.10"

  required_providers {
    mgc = {
      source  = "magalucloud/mgc"
      version = "~> 0.55"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
  }

  # State remoto no Object Storage da Magalu (API S3), bucket privado e versionado
  # criado por `make bootstrap`. Credenciais via AWS_ACCESS_KEY_ID/SECRET do .env.
  backend "s3" {
    bucket = "mgdn-platform-tfstate-b29a4ccd"
    key    = "mgdn-platform/terraform.tfstate"
    region = "br-ne1"

    endpoints = {
      s3 = "https://br-ne1.magaluobjects.com"
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# Região principal.
provider "mgc" {
  alias   = "ne1"
  region  = "br-ne1"
  api_key = var.mgc_api_key
}

# Região da VM secundária (ADR 0005).
provider "mgc" {
  alias   = "se1"
  region  = "br-se1"
  api_key = var.mgc_api_key
}

# DNS do domínio mgdn.com.br (ADR 0010). O token só edita o DNS desta zona.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
