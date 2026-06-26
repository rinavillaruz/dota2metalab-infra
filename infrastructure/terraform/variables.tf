variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "dota2metalab"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type = string
}