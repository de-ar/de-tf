# Primary VCN (10.0.0.0/16) hosting all Always-Free resources in the home region.
resource "oci_core_virtual_network" "main" {
  compartment_id = local.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "main"
  dns_label      = "main"

  freeform_tags = local.common_tags
}

# Internet gateway enabling outbound internet access for the public subnet.
resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_virtual_network.main.id
  display_name   = "main"
  enabled        = true

  freeform_tags = local.common_tags
}

# Public route table attached to the regional subnet. Default route 0.0.0.0/0
# points at the internet gateway so anything in the public subnet can egress.
resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_virtual_network.main.id
  display_name   = "public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = local.common_tags
}

# Public security list: SSH (22), HTTP (80), HTTPS (443) ingress from anywhere;
# all egress permitted. Tighten the source CIDRs before exposing anything real.
resource "oci_core_security_list" "public" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_virtual_network.main.id
  display_name   = "public"

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    tcp_options {
      min = 443
      max = 443
    }
  }

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
  }

  freeform_tags = local.common_tags
}

# Regional public subnet (10.0.1.0/24). Public IPs are permitted on attached VNICs.
resource "oci_core_subnet" "public" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_virtual_network.main.id
  cidr_block                 = "10.0.1.0/24"
  display_name               = "public"
  dns_label                  = "public"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]

  freeform_tags = local.common_tags
}
