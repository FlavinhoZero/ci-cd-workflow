# CI/CD Workflows (Reusable)

Repository with reusable GitHub Actions workflows for automated build, test,
and deploy of serverless components.

## Structure
- `.github/workflows/lambda-ci.yml` - Reusable Lambda CI/CD pipeline (tests, packaging, terraform plan/apply)
- `.github/workflows/ci.yml` - Generic Terraform reusable workflow
- `.github/workflows/archive/` - Legacy workflows (archived, not used)

## Current Version
**v1.0.1** (commit `14d2bb3`) — includes fetch-depth fix for production auto-merge.

## Usage

Call the reusable workflow from any consuming repository:

```yaml
jobs:
  ci-cd:
    uses: FlavinhoZero/ci-cd-workflow/.github/workflows/lambda-ci.yml@14d2bb342f1a9e08ab5abbd414d1d1fe3a0736ff
    with:
      aws_region: "sa-east-1"
      confirm_production_deploy: ${{ github.event.inputs.confirm_production_deploy == 'true' }}
    secrets:
      AWS_ACCOUNT_ID: ${{ secrets.AWS_ACCOUNT_ID }}
      AWS_DEPLOY_ROLE_NAME: ${{ secrets.AWS_DEPLOY_ROLE_NAME }}
      TF_STATE_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
      TF_LOCK_TABLE: ${{ secrets.TF_LOCK_TABLE }}
```

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