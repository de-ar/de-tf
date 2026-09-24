variable "oci_region" {
  type        = string
  description = "OCI home region. Must match the region selected at https://signup.cloud.oracle.com and is permanent for the tenancy. Always-Free compute only works in the home region. Default: eu-frankfurt-1."
  default     = "eu-frankfurt-1"
}

variable "oci_tenancy_ocid" {
  type        = string
  description = "OCID of the root tenancy. Found in OCI Console -> Profile -> Tenancy -> OCID. Used as the compartment for all resources and as the API auth principal."
}

variable "oci_user_ocid" {
  type        = string
  description = "OCID of the IAM user whose API key signs Terraform requests. Found in OCI Console -> Profile -> User Settings -> User OCID."
}

variable "oci_fingerprint" {
  type        = string
  description = "Fingerprint of the API key uploaded under the user (colon-separated hex, 32 pairs). Found in OCI Console -> User Settings -> API Keys after uploading the public half of the PEM pair."
}

variable "oci_private_key_path" {
  type        = string
  description = "Absolute filesystem path to the OCI API private key (PEM). Generate via OCI Console -> User Settings -> API Keys -> Generate API Key Pair. Must be chmod 600 (OCI rejects wider permissions). Tilde (~) is NOT expanded by Terraform; use an absolute path."
}

variable "oci_ssh_public_key_path" {
  type        = string
  description = "Absolute filesystem path to the SSH public key pushed into instance metadata via ssh_authorized_keys. For Canonical Ubuntu 24.04 Minimal the default SSH user is 'ubuntu'."
}
