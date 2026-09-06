variable "location" {
  description = "Azure region."
  type        = string
  default     = "westeurope"
}

variable "allowed_cidr_blocks" {
  description = "Who may reach the DSS port, for example your office range."
  type        = list(string)
}

variable "ssh_public_key" {
  description = "SSH public key for the admin user."
  type        = string
}
