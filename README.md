# CI/CD Workflows (Reusable)

Repository with reusable GitHub Actions workflows for automated build, test,
and deploy of serverless components.

## Structure
- `.github/workflows/lambda-ci.yml` - Reusable Lambda CI/CD pipeline (tests, packaging, terraform plan/apply)
- `.github/workflows/infra-ci.yml` - Reusable Infrastructure CI/CD pipeline (tests, terraform plan/apply)
- `.github/workflows/ci.yml` - Generic Terraform reusable workflow
- `.github/workflows/release.yml` - Release workflow (semantic versioning, tagging, changelog)
- `.github/workflows/archive/` - Legacy workflows (archived, not used)

## Current Version
**v1.1.0** (main branch) — `@main` reference + semantic versioning + security hardening.

## Usage

### Option 1: Always latest (recommended for most repos)

Reference the `main` branch to automatically pick up the latest workflow on every run:

```yaml
jobs:
  ci-cd:
    uses: FlavinhoZero/ci-cd-workflow/.github/workflows/lambda-ci.yml@main
    with:
      aws_region: "sa-east-1"
      confirm_production_deploy: ${{ github.event.inputs.confirm_production_deploy == 'true' }}
    secrets:
      AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
      AWS_DEPLOY_ROLE_NAME: ${{ secrets.AWS_DEPLOY_ROLE_NAME }}
      TF_STATE_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
      TF_LOCK_TABLE: ${{ secrets.TF_LOCK_TABLE }}
```

**Trade-off**: `@main` is a mutable branch reference. Any merge to `main` is immediately picked up by all consumers. This is mitigated by layered security controls (see Security section).

### Option 2: Pin to a specific version (for critical repos)

Reference a semantic version tag for stability:

```yaml
jobs:
  ci-cd:
    uses: FlavinhoZero/ci-cd-workflow/.github/workflows/lambda-ci.yml@v1.1.0
    with:
      aws_region: "sa-east-1"
      confirm_production_deploy: ${{ github.event.inputs.confirm_production_deploy == 'true' }}
    secrets:
      AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
      AWS_DEPLOY_ROLE_NAME: ${{ secrets.AWS_DEPLOY_ROLE_NAME }}
      TF_STATE_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
      TF_LOCK_TABLE: ${{ secrets.TF_LOCK_TABLE }}
```

Use this for repos that need version stability (e.g., payments, core). The workflow records the version in its output (`workflow_version`) for auditability.

### Pipeline stages
1. **Test** - runs pytest (requires `requirements-test.txt`), pip-audit, Trivy filesystem scan
2. **Package Lambda** - builds `lambda_package.zip` (deps + src)
3. **Terraform Plan** - `terraform plan` with S3 backend (lazy/on-demand creation)
4. **Deploy Test** - applies plan to `test` environment (branch `develop`, skipped on production dispatch)
5. **Deploy Production** - applies plan to `production` environment (manual `workflow_dispatch` with `confirm_production_deploy=true`), then auto-merges source branch into `main`

## Requirements on the consuming repository
- `AWS_ACCOUNT_ID` secret at **repository level** (Environment secrets do NOT propagate to reusable workflow callers)
- `AWS_DEPLOY_ROLE_NAME`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE` secrets in `test` and `production` GitHub Environments
- OIDC provider + IAM role configured in AWS (trust policy includes both legacy and new `sub` formats, `aud=sts.amazonaws.com`)
- `terraform/` directory with `backend.tf` (S3) and resource definitions
- `requirements.txt` with exact version pins (`==`), `requirements-test.txt` for test dependencies

## Security (Public Repository)
- **Zero infrastructure names in workflow YAML** — all resource names (bucket, table, role) passed via secrets
- **Zero AWS access keys** — OIDC-based authentication only
- **IAM role trust policy** restricted to explicit repo list (13 repos) with both `sub` formats + `aud=sts.amazonaws.com`
- **GitHub Actions permissions**: `GITHUB_TOKEN` read-only by default; Actions allowlist restricted to `actions/*`, `aws-actions/*`, `hashicorp/*`, `aquasecurity/*`, `softprops/*`, `github/codeql-action`
- **All actions pinned to full commit SHA** (no floating tags)
- **Dependencies pinned to exact versions** (`==`) in consuming repos; workflow uses `--only-binary :all:` and `pip-audit` on every run
- **Trivy installed via official APT repository** (not `trivy-action` — upstream releases unreliable)
- **curl uses `--proto '=https' --tlsv1.2`** for all external downloads
- **Terraform provider mirror** from `releases.hashicorp.com` (avoids registry signature errors)

## Scripts
- `scripts/sync-environments.ps1` / `scripts/sync-secrets.ps1` - local setup helpers.
  They read repo list from `scripts/repos-config.local.json` (git-ignored, not published).
- `scripts/pin-github-actions.ps1` - bulk SHA-pinning automation for workflow files.

## Governance Rule (2026-08-18)
**Resource names and TF_VAR_* are Terraform's responsibility, not the workflow's.**
The reusable workflow accepts ONLY orchestration inputs (account ID, region, tfvars file, environment).
All resource names live in the consuming repo's `terraform/` (variables.tf defaults, locals.tf, tfvars).

## Security Model: `@main` Reference + Layered Hardening (2026-09-13)

Since this repo is public and consumers reference workflows via `@main` (mutable branch), security relies on **5 layers of defense**:

### Layer 1 — Producer Branch Protection (CRITICAL)
`main` branch of `ci-cd-workflow` is protected:
- Require PR review (≥1 approval from CODEOWNERS)
- Dismiss stale reviews
- Block force pushes
- Require linear history
- Restrict push to owner only
- Require signed commits
- No admin bypass

### Layer 2 — Owner Account Hardening
- 2FA mandatory (TOTP/passkey)
- Fine-grained PAT with minimal scope
- SSH key with passphrase
- Periodic token rotation
- Secret scanning (push protection)
- Audit log monitoring

### Layer 3 — Deploy Path Protection
- Manual approval gate on `production` environment (required reviewers)
- OIDC with least-privilege IAM role
- IAM trust policy restricted to explicit repo list + `aud=sts.amazonaws.com`
- Separate prod vs test secrets

### Layer 4 — Supply Chain Integrity
- All third-party actions pinned by SHA (via `pin-github-actions.ps1`)
- Diff review required before production approval
- Commit signing (GPG/SSH)

### Layer 5 — Blast Radius Limitation
- Automated phased deploy (canary: 1 repo → validate → rest)
- Fast rollback capability (git revert + Terraform state)
- Version recorded in every deploy output (`workflow_version`)

### Free-Tier Constraint
Branch protection rules only work on **public repositories** in GitHub Free tier. This repo **must remain public** for Layer 1 to function. Making it private would require Pro/Team or silently remove the primary protection.

### Version Auditability
Every deploy logs `workflow_version` output:
- `@main` reference → `main-<short-sha>`
- `@vX.Y.Z` reference → `vX.Y.Z`

This enables audit: "which workflow version ran in deploy X of repo Y".