# Lists all availability domains in the home region. Used as a sanity reference;
# AD selection for compute is driven by the quota lookups below.
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.oci_tenancy_ocid
}

# Latest Canonical Ubuntu 24.04 Minimal platform image compatible with the
# VM.Standard.E2.1.Micro shape. Sorted by TIMECREATED descending; first match wins.
data "oci_core_images" "micro_image" {
  compartment_id           = local.compartment_id
  shape                    = "VM.Standard.E2.1.Micro"
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04 Minimal"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Latest Canonical Ubuntu 24.04 Minimal aarch64 platform image compatible with
# the VM.Standard.A1.Flex shape. Note the "aarch64" suffix on the version
# string: x86 Ubuntu uses "24.04 Minimal", aarch64 uses "24.04 Minimal aarch64".
# COMMENTED OUT 2026-09-22 along with the A1.Flex resource — see Issue log.
#
# data "oci_core_images" "a1_image" {
#   compartment_id           = local.compartment_id
#   shape                    = "VM.Standard.A1.Flex"
#   operating_system         = "Canonical Ubuntu"
#   operating_system_version = "24.04 Minimal aarch64"
#   sort_by                  = "TIMECREATED"
#   sort_order               = "DESC"
# }

# E2.1.Micro count quotas are unevenly distributed across ADs in some regions
# (e.g. Frankfurt: AD-1=0, AD-2=2, AD-3=0). Query every AD in the home region
# and pick the first with available > 0. The count is driven dynamically from
# oci_identity_availability_domains above, so the module works in any OC1
# home region without code changes. The try() in the picker handles ADs
# that return null fields (e.g. quota not applicable in that AD).

data "oci_limits_resource_availability" "micro_quota" {
  count = length(data.oci_identity_availability_domains.ads.availability_domains)

  compartment_id      = var.oci_tenancy_ocid
  service_name        = "compute"
  limit_name          = "vm-standard-e2-1-micro-count"
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index].name
}

locals {
  # Root compartment. All resources live here in this single-root module.
  compartment_id = var.oci_tenancy_ocid

  # AD names in the home region, in OCI's canonical order. Used for diagnostics
  # and as a sanity reference; the picker below drives actual compute placement.
  ad_names = [for ad in data.oci_identity_availability_domains.ads.availability_domains : ad.name]

  # OCIDs of the Ubuntu 24.04 Minimal images for each shape.
  micro_image_id = data.oci_core_images.micro_image.images[0].id
  # a1_image_id — COMMENTED OUT 2026-09-22 along with the A1.Flex resource.
  # a1_image_id = data.oci_core_images.a1_image.images[0].id

  # First AD whose E2.1.Micro quota reports available > 0. On initial apply
  # the picker always succeeds; this is empty only on post-deploy refresh
  # (the two micro slots are consumed and every AD reports available = 0).
  # In that case we fall through to the first AD listed in the home region
  # rather than failing the refresh. The instance resource ignores changes
  # to availability_domain so the existing placement survives even when
  # the picker value differs from state. Region-agnostic — no code
  # editing required when changing the home region.
  micro_ad = coalesce(
    one([
      for q in data.oci_limits_resource_availability.micro_quota :
      q.availability_domain if try(q.available, 0) > 0
    ]),
    data.oci_identity_availability_domains.ads.availability_domains[0].name,
  )

  # A1.Flex quota is not queryable through the Limits API in eu-frankfurt-1
  # (the well-known limit name returns 400 InvalidParameter). The Always-Free
  # A1 budget is tenancy-wide (4 OCPUs / 24 GB), so any AD with capacity
  # works — colocate with the micro fleet rather than guess.
  # COMMENTED OUT 2026-09-22 along with the A1.Flex resource — see Issue log.
  # a1_ad = local.micro_ad

  # Freeform tags applied to every Always-Free resource. Drives cost-tracking
  # queries in the OCI Console (e.g. "show me all resources with
  # AlwaysFree=true tagged on tag Module=de-ar/always-free").
  common_tags = {
    "AlwaysFree" = "true"
    "Module"     = "de-ar/always-free"
  }
}
