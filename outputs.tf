output "instance_public_ips" {
  description = "Map of instance display name -> reserved public IPv4 address. Stable across re-launches. SSH: ssh -i <key> ubuntu@<ip>."
  value = {
    for i, pip in oci_core_public_ip.micro : "micro-${i + 1}" => pip.ip_address
  }
}
