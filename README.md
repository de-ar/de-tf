# Always-Free OCI Fleet

Terraform module that provisions **2 `VM.Standard.E2.1.Micro` instances** in any OCI home region, each with its own reserved public IPv4, behind a single public subnet. Region-agnostic by construction — the AD picker enumerates availability domains via the OCI API, so changing `oci_region` in `dev.tfvars` requires no code edits. Running cost: **$0.00/mo** for compute, networking, storage, and the public IPv4s. The only thing that can ever cost money here is outbound data transfer past 10 TB/month.

Default home region in the example: **`eu-frankfurt-1`** — pick any OC1 region at OCI signup; the rest of the module works in any of them.

Provisioned in ~5 minutes after the OCI account is set up.

---

## Table of contents

- [What you get](#what-you-get)
- [Prerequisites](#prerequisites)
- [One-time OCI setup](#one-time-oci-setup)
- [Provision](#provision)
- [SSH to the instances](#ssh-to-the-instances)
- [Re-apply and teardown](#re-apply-and-teardown)
- [Troubleshooting](#troubleshooting)
- [Limits this plan respects](#limits-this-plan-respects)
- [Project layout](#project-layout)

---

## What you get

| Resource | Count | Notes |
|---|---|---|
| VCN `main` | 1 | CIDR `10.0.0.0/16`, regional |
| Regional public subnet `public` | 1 | CIDR `10.0.1.0/24`, route table + security list attached |
| Internet gateway `main` | 1 | Default route `0.0.0.0/0 → IGW` |
| Route table `public` | 1 | — |
| Security list `public` | 1 | Ingress: TCP 22/80/443 from anywhere · Egress: all |
| `VM.Standard.E2.1.Micro` instance | 2 | Ubuntu 24.04 Minimal (x86), 50 GB boot |
| Reserved public IPv4 | 2 | One per instance, region-scoped, survives reboot |

Both instances land in whichever AD in the home region has available E2.1.Micro quota (e.g. `pfmj:EU-FRANKFURT-1-AD-2` in Frankfurt). The module picks the AD automatically — see [Troubleshooting](#404-on-launchinstance-is-quota-not-iam) for why this matters.

---

## Prerequisites

Install on your workstation:

- **Terraform ≥ 1.5** — `brew install terraform` or [download](https://developer.hashicorp.com/terraform/install).
- **OpenSSH** (for the SSH key pair). macOS and Linux ship with it.
- **OCI CLI** *(optional but useful)* — `brew install oci-cli`. Only needed for the quota-diagnostic command in [Troubleshooting](#404-on-launchinstance-is-quota-not-iam).

OCI-side, before touching Terraform:

- **An OCI account** at <https://signup.cloud.oracle.com>. Pick any OC1 region (e.g. **Germany Central (Frankfurt)**) as the home region — the choice is permanent and only the home region runs Always-Free compute ([details](#1-lock-in-your-home-region)).
- **An IAM user** with admin permissions (the account you created at signup is `Administrators`-group by default).
- **An API key** uploaded to that user (instructions below).

---

## One-time OCI setup

Three things to do once before any `terraform apply`. None of them are repeatable — do them carefully.

### 1. Lock in your home region

OCI lets you pick one "home region" per tenancy during signup. Always-Free compute can **only** be launched in the home region, and the choice **cannot be changed** later. The example `dev.tfvars` uses `eu-frankfurt-1`; you can use any OC1 home region — set `oci_region` in `dev.tfvars` to whatever you picked at signup. The AD picker discovers the region's ADs via API and picks the first with available E2.1.Micro quota, so no code edits are required for any region.

### 2. Gather the five identifiers Terraform needs

You need five values. All live in the OCI Console.

| # | Value | Where to find it |
|---|-------|------------------|
| 1 | **Tenancy OCID** (`ocid1.tenancy.oc1..…`) | Profile menu (top right) → **Tenancy** → **OCID** |
| 2 | **User OCID** (`ocid1.user.oc1..…`) | Profile menu → **User Settings** → **User OCID** |
| 3 | **API key fingerprint** (`aa:bb:cc:…`) | See step 3 below — generated as part of uploading the API key |
| 4 | **Path to the OCI API private key** (PEM, `chmod 600`) | Downloaded in step 3 |
| 5 | **Path to your SSH public key** | Generated in step 4 below |

### 3. Create an OCI API key

You need a PEM key pair whose **public half** you upload to OCI; Terraform signs API requests with the **private half**.

1. Profile menu → **User Settings** → **API Keys** → **Add API Key**.
2. Choose **Generate API Key Pair** (the Console generates the pair for you).
3. Click **Download Private Key** — saves a `.pem` file. Save it somewhere safe, e.g. `~/.oci/api_key.pem`.
4. The Console displays the **fingerprint** in `aa:bb:cc:…` form. Copy it.
5. Click **Add**.

Move the key to a permanent location and tighten permissions — OCI rejects the key if it is world-readable:

```sh
mkdir -p ~/.oci
mv ~/Downloads/api_key.pem ~/.oci/api_key.pem
chmod 600 ~/.oci/api_key.pem
ls -l ~/.oci/api_key.pem   # confirm: -rw-------
```

### 4. Generate an SSH key pair for the instances

If you already have one (`~/.ssh/id_ed25519.pub`), reuse it. Otherwise:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/oci_id_ed25519 -N ""
```

You'll SSH as the user `ubuntu` using this key (Ubuntu cloud images don't ship `root` SSH).

### 5. Fill in `dev.tfvars`

Copy the template and edit it:

```sh
cp dev.tfvars.example dev.tfvars
$EDITOR dev.tfvars
```

The file looks like this — fill in the five placeholders for the values from step 2:

```hcl
oci_region              = "eu-frankfurt-1"
oci_tenancy_ocid        = "ocid1.tenancy.oc1..aaaaaaaaxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
oci_user_ocid           = "ocid1.user.oc1..aaaaaaaaxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
oci_fingerprint         = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd"
oci_private_key_path    = "/Users/you/.oci/api_key.pem"
oci_ssh_public_key_path = "/Users/you/.ssh/oci_id_ed25519.pub"
```

> **Use absolute paths.** Terraform does not expand `~`. `~/.oci/api_key.pem` will be read literally as a directory named `~` and fail.

`dev.tfvars` is in `.gitignore`. Never commit it — it carries identifiers tied to your account.

---

## Provision

```sh
terraform init
terraform plan -var-file=dev.tfvars -out=tfplan
terraform apply tfplan
```

What to expect:

- `init` downloads the `oracle/oci` provider pinned to `~> 6.0` (see `versions.tf`).
- `plan` reads the API key, queries E2.1.Micro quota per AD in your home region, picks the first AD with `available > 0`, and lists **9 resources to create** + **6 data sources** the first time:
    - 5 network (VCN, IGW, route table, security list, subnet)
    - 2 instances (E2.1.Micro)
    - 2 reserved public IPv4
- `apply` takes ~2–4 minutes. The two Ubuntu instances boot and reach `Running` shortly after.

If the plan output shows anything other than 9 resources, stop and read [Troubleshooting](#plan-shows-an-unexpected-resource-count).

### Capture the public IPs

When apply finishes:

```sh
terraform output -json instance_public_ips
```

You get something like:

```json
{ "micro-1": "141.144.xx.xx", "micro-2": "158.179.yy.yy" }
```

These IPs survive `stop` / `start` and OS reboots. The reserved IP detaches if you `terraform destroy`, but it's free, so this is fine — re-apply just gets new IPs. Persist the output for your records:

```sh
terraform output -json > outputs.json
```

---

## SSH to the instances

```sh
ssh -i ~/.ssh/oci_id_ed25519 ubuntu@$(terraform output -raw instance_public_ips | jq -r '."micro-1"')
# or for micro-2:
ssh -i ~/.ssh/oci_id_ed25519 ubuntu@<micro-2-ip>
```

**Username is `ubuntu`.** It is **not** `opc` — that's Oracle Linux's default. Ubuntu's cloud image template sets `ubuntu` as the default SSH user.

The first SSH to a freshly-provisioned instance can take 30–60 seconds after `apply` finishes, while the cloud-init finishes. Just retry.

---

## Re-apply and teardown

### Re-apply

Editing any `.tf` file and re-running the same `plan`/`apply` cycle updates the fleet in place. The reserved public IPv4s are unaffected by re-launches because Terraform preserves them in state.

### Teardown

```sh
terraform destroy -var-file=dev.tfvars
```

This removes all 9 resources. The reserved IPv4 OCIDs are released. No charges accrued at any point — compute and IPv4s were free, and you presumably haven't pushed 10 TB outbound.

If you want to keep the public IPs (so you can re-attach them later without new addresses), add `prevent_destroy = true` to each `oci_core_public_ip.micro` block in `compute.tf` before running destroy. The repo leaves this off deliberately — the IPs are free and interchangeable.

After `destroy`, the Always-Free E2.1.Micro quota is released, and a subsequent `apply` will succeed with fresh instances and IPs in the AD the picker finds with quota at that moment.

---

## Troubleshooting

### `404` on `LaunchInstance` is quota, not IAM

If you bypass this module and try to launch into an AD that has zero quota, OCI fails with:

```
Error: 404-NotAuthorizedOrNotFound, Authorization failed or requested resource not found.
Suggestion: ... service Core Instance need policy to access this resource.
```

The error mentions "policy", but the failure is **always-free quota for that AD**, not an IAM problem. Frankfurt distributes both E2.1.Micro slots to `AD-2` and 0 to `AD-1` and `AD-3`; other regions distribute quota differently.

This repo handles that automatically via `oci_limits_resource_availability` data sources in `locals.tf` driven by `oci_identity_availability_domains`, so the picker discovers and uses whatever AD has capacity in your region. If you're rolling your own code, query quota first:

```sh
oci limits resource-availability get \
  --compartment-id <tenancy-ocid> \
  --service-name compute \
  --limit-name vm-standard-e2-1-micro-count \
  --availability-domain "pfmj:EU-FRANKFURT-1-AD-2"
```

### Plan shows an unexpected resource count

- First-ever apply against an empty state: **9 resources, 6 data source blocks**.
- Re-apply with no changes: `No changes. Your infrastructure matches the configuration.`
- Anything else = something was edited. Check `git status` and `terraform plan -no-color` for the diff.

### `terraform apply` complains about the API key permissions

`oci: fingerprint does not match` or `failed to read private key` means the PEM file is missing or has wrong perms. Re-confirm:

```sh
ls -l ~/.oci/api_key.pem     # must be -rw------- (600)
chmod 600 ~/.oci/api_key.pem
```

### `404`/empty image list for Ubuntu 24.04 arm64

`data "oci_core_images"` for the A1 flex shape needs `operating_system_version = "24.04 Minimal aarch64"` (with the `aarch64` suffix). Without it OCI returns zero matches because `24.04 Minimal` alone matches only x86. This repo currently has the A1 flex resource commented out — see the notes on re-enabling in [AGENTS.md](AGENTS.md).

### Always-Free compute gets reclaimed for idleness

If a micro instance runs below ~20% CPU/network for 7 days, Oracle reclaims it. There's no Terraform knob to prevent this. If you need persistence, keep the instance warm (cron a `yes > /dev/null` once an hour, or run an actual workload).

---

## Limits this plan respects

| Quota | Always-Free ceiling | This plan |
|---|---|---|
| E2.1.Micro instances | 2 per tenancy | 2 (full) |
| A1.Flex cores | 2 OCPUs total | 0 (commented out, see [Issue log in AGENTS.md](AGENTS.md#issue-log)) |
| A1.Flex memory | 12 GB total | 0 |
| Boot volume | 200 GB combined | 100 GB (2× 50 GB) |
| Public IPv4 | unlimited | 2 RESERVED — free, both always |
| Outbound data transfer | 10 TB/month free | $0 if under; overage billed |

After the **30-day Free Trial** ends (you'll get an email), Always-Free resources continue. Anything over the Always-Free ceilings above is **disabled, then deleted 30 days later** unless you upgrade to Pay-As-You-Go. The credit card on file is never charged for the over-quota portion; the resources simply disappear.

The OCI Console sometimes warns about "3,000 OCPU hours and 18,000 GB hours per month, equivalent to 4 OCPUs and 24 GB". That's the **paid-tier** free allowance (Universal Credits) — it's not the Always-Free ceiling. For Always-Free sizing, the official page at `https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm` is authoritative (1,500 OCPU-hrs + 9,000 GB-hrs = 2 OCPUs + 12 GB).

---

## Project layout

```
versions.tf      terraform + oracle/oci provider pin
providers.tf     OCI API-key provider config
variables.tf     inputs (region, OCIDs, fingerprint, key paths)
dev.tfvars       NOT committed — your identifying values
network.tf       VCN, IGW, route table, security list, subnet
locals.tf        AD picker, image lookup, common_tags
compute.tf       2× E2.1.Micro + reserved public IPv4 each
outputs.tf       instance_public_ips map
AGENTS.md        deeper gotchas, debugging history, conventions
```

Every resource carries two freeform tags: `AlwaysFree = "true"` and `Module = "de-ar/oracle-forever-free"`. Query them in the Console (`Tag Search` → `AlwaysFree:true`) to see every resource this module manages.

---

## Further reading

- [OCI Free Tier docs](https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) — authoritative for Always-Free ceilings.
- [oracle/oci Terraform provider docs](https://registry.terraform.io/providers/oracle/oci/latest/docs).
- [AGENTS.md](AGENTS.md) — gotchas, debugging history, and conventions for working on this repo.
