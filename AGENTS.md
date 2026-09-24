# AGENTS.md

## What this is
Single-root Terraform module that provisions an **OCI Always-Free tier** fleet in the home region, incrementally expanded. Current scope:
- VCN, regional public subnet, internet gateway, route table, security list (22/80/443 ingress, all egress)
- 2x `VM.Standard.E2.1.Micro` (Canonical Ubuntu 24.04 Minimal x86, 50 GB boot each, reserved public IPv4, region-scoped — survives instance reboot)
- 1x `VM.Standard.A1.Flex` at max free quota: 2 OCPUs / 12 GB RAM (Canonical Ubuntu 24.04 Minimal arm64, 50 GB boot, public IPv4) — **commented out 2026-09-22, see Issue log**

Default home region: **`eu-frankfurt-1`** (change `oci_region` to use any other OC1 home region — no code edits required; the AD picker is region-agnostic).

## SSH access
- Image: Canonical Ubuntu 24.04 Minimal → default SSH user is **`ubuntu`** (not `opc`) on both x86 and arm64.
- Key pushed from `var.oci_ssh_public_key_path` via `metadata.ssh_authorized_keys`.

## Hard facts
- **No `*.tfvars` is checked in.** The template `dev.tfvars.example` is committed; the real `dev.tfvars` is gitignored. All identifying inputs (OCIDs, fingerprint) live there — never paste them into source or chat.
- **Home region is permanent.** It must be selected at OCI signup (https://signup.cloud.oracle.com) and matches `var.oci_region`. Changing it after signup is not possible; Always-Free compute only works in the home region.
- **Public IPv4 is $0.00 on OCI** (both ephemeral and reserved). Always-Free has no charge for assigning one. The only networking cost is **outbound data transfer** past 10 TB/month; inbound is free.
- **No remote backend.** State is local (`.tfstate*` are gitignored). Add a `backend` block deliberately if shared state is needed.
- **Provider pinned:** `oracle/oci` `~> 6.0` (`versions.tf`).
- **Always-Free ceilings this plan respects:**
  - 2x E2.1.Micro (1 OCPU / 1 GB each, total 2 OCPUs / 2 GB) — full E2 quota
  - 1x A1.Flex (2 OCPUs / 12 GB) — full A1 core/memory quota (Always-Free tenancy) — **commented out 2026-09-22**
  - Combined compute: 2 OCPUs, 2 GB RAM (A1 not counted while commented out)
  - 2x 50 GB boot volumes = 100 GB block storage (200 GB combined allotment)
- **Free Trial ends 30 days after signup.** After that, Always-Free resources continue; over-quota A1 (>2 OCPU/12 GB total) is **disabled then deleted after another 30 days** unless the tenancy is upgraded to Pay-As-You-Go. See 2026-09-22 entry in Issue log.

## Non-obvious things worth knowing
- **Idle-reclamation policy.** Always-Free compute with <20% CPU/network over 7 days is reclaimed by Oracle. Not preventable via Terraform; keep workloads warm if you need persistence.
- **AD quota distribution is uneven.** Always-Free compute quotas are not spread evenly across ADs in every region — `eu-frankfurt-1` distributes the 2-micro allowance to one AD (AD2) while AD1/AD3 report 0. Launching into an AD with 0 quota returns a misleading `404-NotAuthorizedOrNotFound "service Core Instance need policy"`. `locals.tf` enumerates each AD's `vm-standard-e2-1-micro-count` quota via a single `oci_limits_resource_availability.micro_quota` data source with `count = length(data.oci_identity_availability_domains.ads.availability_domains)`, and picks the first AD with `available > 0`. The picker is region-agnostic — it discovers ADs via API, so changing `oci_region` requires no code edits. When adding more instances later, extend this same pattern (one quota data source per candidate AD per shape).
- **A1.Flex quota is not queryable via the Limits API in `eu-frankfurt-1`.** The well-known name `vm-standard-a1-core-count` returns `400-InvalidParameter: Invalid parameter 'serviceName' and/or 'limitName'` from both `oci_limits_resource_availability` and `oci_limits_limit_values` under `service_name = "compute"`. The Always-Free A1 budget per tenancy is **2 OCPUs / 12 GB total** (≈ 1,500 OCPU-hrs + 9,000 GB-hrs per month) — per the official Oracle Free Tier docs at `https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm`. The OCI Console warning banner on the instances page shows the *paid-tier* allowance (4 OCPUs / 24 GB ≈ 3,000/18,000) and applies the same text to all tenancies; the price list footnote confirms this is paid-tier language. Since A1 can be created in any AD except South Korea North (Chuncheon), `local.a1_ad = local.micro_ad` colocates the A1 flex with the micro fleet in AD-2. If A1 launch fails with capacity, fall back to a different AD manually. *(Currently commented out 2026-09-22 — see Issue log.)*
- **Trial-end cliff for over-quota A1.** During the 30-day Free Trial, the $300 credit absorbs any usage — over-quota A1 is not charged to the card. After the trial ends, any A1 exceeding 2 OCPU/12 GB total is **disabled, then deleted after 30 days** unless the tenancy is upgraded to Pay-As-You-Go. The card is never charged for the over-quota portion; it just disappears. If you upgrade, 4 OCPU/24 GB is within the paid-tier free allowance (3,000 OCPU-hrs / 18,000 GB-hrs per month).
- **Region portability.** The module is region-agnostic by construction. `oci_identity_availability_domains` lists the home region's ADs at runtime; the quota picker iterates over them via `count = length(...)`; the fallback picks the first AD. The only region-specific string is the variable `oci_region` in `dev.tfvars`. Set it to any OC1 home region — no code edits required.
- **Existing AD placement is preserved.** The `oci_core_instance.micro` resource uses `lifecycle { ignore_changes = [availability_domain] }`. After the initial apply, the picker reports `available = 0` everywhere (slots consumed), at which point the picker returns null and the fallback would otherwise pick a different AD than what's in state. `ignore_changes` defuses that — the existing placement survives subsequent refreshes until a destroy + apply re-runs the picker fresh.
- **Reserved public IPv4 pattern (current code).** Per micro instance, two resources: the instance with `assign_public_ip=false` on the VNIC, and an `oci_core_public_ip` (`lifetime = "RESERVED"`) bound via inline `private_ip_id`. Provider v6 has **no separate `oci_core_public_ip_assignment` resource** — the `CreatePublicIp` API takes `privateIpId` at creation time. Getting `private_ip_id` requires a chain of three data lookups because `oci_core_vnic` exposes `private_ip` as a string (not OCID): `oci_core_instance.micro[i]` → `oci_core_vnic_attachments.micro[i]` → `oci_core_vnic.micro[i]` → `oci_core_private_ips.micro[i]`. Ephemeral (`assign_public_ip=true` on VNIC) IPs are free but die with the instance. RESERVED IPs are region-scoped by default, reassignable to another VNIC later, and survive OS reboot and instance stop/start. They do **not** survive `terraform destroy` + re-`apply` unless `prevent_destroy` is set (deliberately not set — IP is free and interchangeable).
- **Stale paid-tier comment trap in `locals.tf:92-97`.** The explanatory comment block above the commented-out `a1_ad` line still says "Always-Free A1 budget is tenancy-wide (4 OCPUs / 24 GB)". That figure is paid-tier language — for Always-Free the ceiling is 2 OCPUs / 12 GB (see Issue log). The block is commented out only at the HCL line, not at the comment text. If the goal is to re-enable A1 later, treat that comment as suspect until cross-checked against `https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm`.
- **Plan size baseline.** After both micro instances are up, `terraform plan` reports **9 resources** (2 instance + 5 network + 2 reserved public_ip) plus 6 data source blocks (1 identity ads, 1 micro image, 1 E2 micro quota `count = length(ads)`, 1 each of vnic_attachments/vnic/private_ips at `count = 2`). Anything beyond that is new infrastructure. The A1 flex block is currently fully commented out across `locals.tf` (image data, image id local, ad local) and `compute.tf` (instance resource) — re-enable in those four spots.

## Common commands
```sh
terraform fmt -recursive
terraform init
terraform validate
terraform plan -var-file=dev.tfvars -out=tfplan
terraform apply tfplan
terraform output -json > outputs.json   # capture public IP / OCID
```

## File map
- `versions.tf` — terraform + `oracle/oci` provider pin
- `providers.tf` — OCI API-key provider config
- `variables.tf` — all inputs
- `locals.tf` — compartment resolution, dynamic AD enumeration via `oci_identity_availability_domains`, per-AD quota lookups via a single `count`-driven `oci_limits_resource_availability.micro_quota`, smart AD picker (`micro_ad`), Ubuntu 24.04 Minimal image lookup (x86 + arm64), shared `common_tags`. A1.Flex reuses `local.micro_ad` — see Non-obvious things below.
- `network.tf` — VCN, IGW, route table, security list, subnet + RT/SL associations
- `compute.tf` — 2x E2.1.Micro (Canonical Ubuntu 24.04 Minimal x86, 50 GB boot) with reserved public IPv4 each. The `oci_core_public_ip.micro` resource is bound inline via `private_ip_id`, which requires the chained data lookups `oci_core_vnic_attachments.micro` → `oci_core_vnic.micro` → `oci_core_private_ips.micro` above it. A1.Flex resource is commented out (see Issue log).
- `outputs.tf` — `instance_public_ips`: map of name → public IP
- `dev.tfvars.example` — committed template (rename to `dev.tfvars` and fill in)

## Conventions
- Resource addresses are role-based, no `de_` prefix: `oci_core_virtual_network.main`, `oci_core_internet_gateway.main`, `oci_core_route_table.public`, `oci_core_security_list.public`, `oci_core_subnet.public`, `oci_core_instance.micro`. (Same local name across different resource types is fine; the full address includes the type.)
- Freeform tags applied to every Always-Free resource via `local.common_tags`: `AlwaysFree = "true"` and `Module = "de-ar/oracle-forever-free"` for cost-tracking queries.
- `display_name` matches the resource local name (no underscores): `main`, `public`. For counted resources, append `count.index + 1` (so the E2 micros are `micro-1`, `micro-2`).
- `description` is set on every variable and output (Terraform-native). The `oracle/oci` provider v6 does not expose `description` as a top-level argument on core compute/network resources or data sources, so resource/data purpose is documented in a leading `#` comment block instead.

## Verification
No automated test suite. The verification chain is `fmt → init → validate → plan`. `terraform plan` with the expected resource list and zero errors is the green signal. `apply` is run by the user after manually confirming the plan output.

## Issue log
- **2026-09-22 — Reserved public IPv4 pattern adopted.** Each `oci_core_instance.micro` now gets a region-scoped reserved IPv4 (free on OCI) instead of an ephemeral IP. The IP is bound inline: instance (`assign_public_ip=false`) + `oci_core_public_ip` (`lifetime = "RESERVED"`, `private_ip_id` set). Provider v6 has no separate `oci_core_public_ip_assignment` resource, so the OCID for `private_ip_id` is fetched via three chained data sources (`vnic_attachments` → `vnic` → `private_ips`) since `oci_core_vnic` exposes the private IP as a string, not an OCID. Stable plan: 2 instance + 5 network + 2 reserved IP = **9 resources**. Reserved IP survives OS reboot and instance stop/start; does not survive `terraform destroy` (no `prevent_destroy` — IP is free, escape hatch via `state rm` or comment-and-destroy if ever needed).
- **2026-09-22 — flex commented out per user decision.** The `oci_core_instance.flex` resource in `compute.tf`, the `data oci_core_images.a1_image` block in `locals.tf`, and the `local.a1_image_id` / `local.a1_ad` lines in `locals.tf` are all wrapped in `/* */` (resource + data) or `# `-prefixed (locals). Re-enable by uncommenting those four locations. Current plan: 2 micro + 5 network = 7 resources (no flex).
- `data "oci_core_images" "a1_image"` uses `operating_system_version = "24.04 Minimal aarch64"`, not `"24.04 Minimal"`. The aarch64 suffix is required to disambiguate from the x86 Ubuntu image; without it OCI returns an empty image list.
- When A1 was active, `local.a1_ad = local.micro_ad` (no A1 quota lookup). The OCI Limits API rejects `vm-standard-a1-core-count` as invalid under `service_name = "compute"` in `eu-frankfurt-1` (400 InvalidParameter from both `oci_limits_resource_availability` and `oci_limits_limit_values`). The whole A1 block (`a1_image_id`, `a1_ad`, image data, instance resource) is currently commented out — uncomment all four if re-enabling.
- `local.micro_ad` uses `coalesce(one([...]), data.oci_identity_availability_domains.ads.availability_domains[0].name)` to handle post-deploy refresh. After 2 E2.1.Micro instances land in the picked AD, that AD's quota drops to 0; the picker filter (`available > 0`) then matches nothing and `one([])` returns null. Without a fallback, Terraform would fail subsequent `plan`/`destroy` with "Missing required argument: availability_domain". The fallback is the first AD listed by the API, but the instance resource carries `lifecycle { ignore_changes = [availability_domain] }` so the existing placement survives even when the fallback points elsewhere.
- **`oci_core_instance.flex` was sized at 4 OCPUs / 24 GB based on the OCI Console warning banner ("3,000 OCPU hours and 18,000 GB hours per month... equivalent to 4 OCPUs and 24 GB").** That wording is the **paid-tier** free allowance (Universal Credits) — the price-list footnote on `oracle.com/cloud/price-list/` explicitly says "Each *paid* tenancy gets the first 3,000 OCPU hours and 18,000 GB hours per month for free." The Console applies the same text to all tenancies, including Always-Free. The official Oracle Free Tier docs (`docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm`) give the Always-Free ceiling: **1,500 OCPU-hrs + 9,000 GB-hrs per month = 2 OCPUs + 12 GB**. Reverted to 2 OCPUs / 12 GB to stay within Always-Free limits. Lesson: the price-list Console warning is paid-tier language. For Always-Free quotas, the official Free Tier docs page is authoritative.

### 2026-09-22 — `404-NotAuthorizedOrNotFound` on `LaunchInstance` despite admin permissions

**Symptom.** Every `oci_core_instance` resource failed with:

```
Error: 404-NotAuthorizedOrNotFound, Authorization failed or requested resource not found.
Suggestion: ... service Core Instance need policy to access this resource.
```

Networking resources (VCN, IGW, route table, security list, subnet) all created successfully. Only `LaunchInstance` failed — same error against `VM.Standard.E2.1.Micro` regardless of image (Oracle Linux 8 or Canonical Ubuntu 24.04), boot volume size, or subnet. Three-instance plan and single-instance plan both failed identically on the instance step.

**Misleading part.** The error message says "policy", which suggests an IAM problem. Verified false:

- User `<oci-user>` was in the `Administrators` group.
- Root compartment had `Tenant Admin Policy: ALLOW GROUP Administrators to manage all-resources IN TENANCY`.
- API key fingerprint matched; user OCID was valid.

**Actual cause.** Always-Free compute quotas in `eu-frankfurt-1` are distributed unevenly across availability domains — `oci_limits_resource_availability` for `vm-standard-e2-1-micro-count` returned:

| AD      | Available | Used |
|---------|-----------|------|
| AD-1    | 0         | 0    |
| **AD-2**| **2**     | 0    |
| AD-3    | 0         | 0    |

The first instance was being launched into AD-1 (first in `oci_identity_availability_domains`), which had zero slots. OCI surfaced this as a 404 ("no host with capacity for this AD") wrapped in the same generic `NotAuthorizedOrNotFound` code that auth failures use — but the failure was quota, not authorization.

**Fix in `locals.tf`.** Query quota per AD dynamically via `count = length(data.oci_identity_availability_domains.ads.availability_domains)`, then pick the first AD with `available > 0` via a `one([for ...])` expression. The picker is region-agnostic — works in any home region without code edits:

```hcl
data "oci_limits_resource_availability" "micro_quota" {
  count               = length(data.oci_identity_availability_domains.ads.availability_domains)
  compartment_id      = var.oci_tenancy_ocid
  service_name        = "compute"
  limit_name          = "vm-standard-e2-1-micro-count"
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index].name
}

locals {
  micro_ad = coalesce(
    one([
      for q in data.oci_limits_resource_availability.micro_quota :
      q.availability_domain if try(q.available, 0) > 0
    ]),
    data.oci_identity_availability_domains.ads.availability_domains[0].name,
  )
}
```

Add `lifecycle { ignore_changes = [availability_domain] }` to the instance resource so the picker changing AD on refresh (post-deploy, quota exhausted) doesn't force a recreate.

With this in place, the plan landed on `pfmj:EU-FRANKFURT-1-AD-2` and `LaunchInstance` succeeded. SSH confirmed working within ~60s of instance boot.

**Diagnostic command** (no Terraform needed):

```sh
oci limits resource-availability get \
  --compartment-id <tenancy-ocid> \
  --service-name compute \
  --limit-name vm-standard-e2-1-micro-count \
  --availability-domain "pfmj:EU-FRANKFURT-1-AD-2"
```

**When scaling up.** Replicate the per-AD quota data sources for each new shape — A1.Flex uses `vm-standard-a1-core-count` (although it's rejected by the Limits API in `eu-frankfurt-1`; see Issue log). When launching multiple instances of the same shape, distribute across ADs that each have capacity for at least one slot, not all instances into the same AD.

### 2026-09-24 — Module made region-agnostic

Originally the three E2.1.Micro quota data sources in `locals.tf` were hardcoded to Frankfurt's `pfmj:EU-FRANKFURT-1-AD-{1,2,3}` and the post-deploy fallback inside `local.micro_ad` was `"pfmj:EU-FRANKFURT-1-AD-2"`. Both now derive from `data.oci_identity_availability_domains.ads` via `count = length(...)` and the `coalesce(...ads.availability_domains[0].name)` fallback. The data source block renames from `micro_quota_adN` to `micro_quota[N]` — Terraform handles the migration transparently for data sources.

Because the new fallback resolves to a *different* AD than the one already in state (Frankfurt: `[0]` is AD-1 but the existing instances live in AD-2), the `oci_core_instance.micro` resource picked up `lifecycle { ignore_changes = [availability_domain] }`. Without it, the migration would have planned `replace` for both running instances. With it, `terraform plan` reports `No changes` even though the underlying `local.micro_ad` value differs from state — placement is pinned to whatever was originally applied, and only a destroy + apply re-evaluates.

If you re-run `terraform destroy && terraform apply` later, instances land in whatever AD the picker finds with quota at that moment. To force a specific AD on a fresh deploy, the picker would need a `var.oci_target_ad` override — currently absent; add it when needed.
