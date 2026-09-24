# Always-Free E2.1.Micro instances (count = 2): 1 OCPU, 1 GB RAM, 50 GB boot
# each, Canonical Ubuntu 24.04 Minimal (x86). Both land in local.micro_ad,
# which is the first AD in the home region with available E2.1.Micro quota
# (Frankfurt: AD-2, which has both micro slots). Default SSH user 'ubuntu'.
#
# availability_domain is ignored for diff purposes so the existing placement
# survives refreshes where the picker reports zero (post-deploy, all quotas
# consumed) and the fallback would otherwise pick a different AD. Destroy +
# re-apply honors the picker fresh — new instances land wherever quota exists.
resource "oci_core_instance" "micro" {
  count               = 2
  compartment_id      = local.compartment_id
  availability_domain = local.micro_ad
  display_name        = "micro-${count.index + 1}"
  shape               = "VM.Standard.E2.1.Micro"

  metadata = {
    ssh_authorized_keys = file(var.oci_ssh_public_key_path)
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false
    display_name     = "micro-${count.index + 1}"
  }

  shape_config {
    ocpus         = 1
    memory_in_gbs = 1
  }

  source_details {
    source_type             = "image"
    source_id               = local.micro_image_id
    boot_volume_size_in_gbs = 50
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [availability_domain]
  }
}

# Always-Free A1.Flex instance — TEMPORARILY COMMENTED OUT 2026-09-22.
# Per user decision. To re-enable: uncomment the resource block below AND
# uncomment `data "oci_core_images" "a1_image"`, `local.a1_image_id`, and
# `local.a1_ad` in locals.tf.
#
# resource "oci_core_instance" "flex" {
#   count               = 1
#   compartment_id      = local.compartment_id
#   availability_domain = local.a1_ad
#   display_name        = "flex-${count.index + 1}"
#   shape               = "VM.Standard.A1.Flex"
#   metadata = {
#     ssh_authorized_keys = file(var.oci_ssh_public_key_path)
#   }
#   create_vnic_details {
#     subnet_id        = oci_core_subnet.public.id
#     assign_public_ip = true
#     display_name     = "flex-${count.index + 1}"
#   }
#   shape_config {
#     ocpus         = 2
#     memory_in_gbs = 12
#   }
#   source_details {
#     source_type             = "image"
#     source_id               = local.a1_image_id
#     boot_volume_size_in_gbs = 50
#   }
#   freeform_tags = local.common_tags
# }

# Reserved public IPv4 — one per micro instance. Free on OCI (public IPv4 is
# $0.00 for both ephemeral and reserved; only outbound data transfer past
# 10 TB/mo on Always-Free incurs cost). Region-scoped by default for RESERVED
# lifetime, so the IP can be reassigned to another VNIC/instance/VCN later
# without re-creating it. Assigned inline via `private_ip_id` — the
# oracle/oci provider v6 has no separate assignment resource (CreatePublicIp
# API accepts privateIpId at creation time). Three lookups are needed to get
# the private IP's OCID: instance → vnic_attachments → vnic (IP address) →
# private_ips (OCID), because oci_core_vnic only exposes `private_ip_address`
# (string), not `private_ip_id` (OCID).
data "oci_core_vnic_attachments" "micro" {
  count          = length(oci_core_instance.micro)
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.micro[count.index].id
}

data "oci_core_vnic" "micro" {
  count   = length(oci_core_instance.micro)
  vnic_id = data.oci_core_vnic_attachments.micro[count.index].vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "micro" {
  count   = length(oci_core_instance.micro)
  vnic_id = data.oci_core_vnic.micro[count.index].vnic_id
}

resource "oci_core_public_ip" "micro" {
  count          = length(oci_core_instance.micro)
  compartment_id = local.compartment_id
  lifetime       = "RESERVED"
  display_name   = "micro-${count.index + 1}-public-ip"
  private_ip_id  = data.oci_core_private_ips.micro[count.index].private_ips[0].id
  freeform_tags  = local.common_tags
}
