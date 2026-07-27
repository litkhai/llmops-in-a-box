# Task: PR 5 — AWS EC2 deployment documentation

## Branch
`pr/5-aws-docs` — base: `main`

## Goal
Replace the placeholder AWS EC2 section in `docs/deployment.md` with a
complete, accurate guide. Add an AWS pointer in `docs/getting-started.md`.
No code changes.

## Context: commands that will exist after PRs 2-4 merge

By the time this doc lands, the following will work:

```bash
# Upload secrets to SSM (PR 4)
./scripts/stack.sh secrets push --target aws-ec2

# Provision EC2 + bootstrap (PR 2 + PR 3 + PR 4)
./scripts/stack.sh up --target aws-ec2 \
  --tf-var key_name=<keypair> \
  --tf-var allowed_cidr=<your-ip>/32

# Verify (already works via target_host())
./scripts/stack.sh status --target aws-ec2
./scripts/stack.sh urls --target aws-ec2

# SSH into instance (PR 4)
./scripts/stack.sh ssh --target aws-ec2

# Tear down
./scripts/stack.sh down --target aws-ec2
```

## Changes required

### 1. `docs/deployment.md`

Read the file first. Replace the entire `## AWS EC2` section (everything from
`## AWS EC2` up to but not including the next `##` heading, which is
`## External vLLM serving`).

Replace it with:

---

```markdown
## AWS EC2

A single EC2 instance running the same Docker Compose stack as the local
target. Region: `ap-northeast-2`. Instance: `t3.xlarge`, 100 GiB gp3.

### Prerequisites

| Requirement | Check |
|---|---|
| AWS CLI v2 configured | `aws sts get-caller-identity` |
| EC2 key pair in `ap-northeast-2` | AWS console → EC2 → Key Pairs |
| Terraform ≥ 1.5 | `terraform version` |
| Phase 1 credentials set locally | `./scripts/stack.sh secrets status --phase 1` |

### 1. Push credentials to SSM

The EC2 instance reads Phase 1 credentials from SSM Parameter Store at boot.
Push them before provisioning:

```bash
./scripts/stack.sh secrets push --target aws-ec2
```

This writes every set Phase 1 credential as an SSM `SecureString` parameter
under `/sais/phase-1/`. The EC2 IAM role (provisioned by Terraform) grants
read access to that prefix only — no other AWS resources are reachable.

Verify:

```bash
aws ssm get-parameters-by-path \
  --region ap-northeast-2 \
  --path /sais/phase-1 \
  --query 'Parameters[*].Name'
```

### 2. Provision and bootstrap

```bash
./scripts/stack.sh up --target aws-ec2 \
    --tf-var key_name=<your-key-pair-name> \
    --tf-var allowed_cidr=<your-ip>/32
```

This runs `terraform apply`, then waits up to 5 minutes for the bootstrap
script to complete. The bootstrap script installs Docker, clones this
repository, pulls credentials from SSM, and starts the Phase 1 compose stack.

Get your public IP: `curl -s https://checkip.amazonaws.com`

!!! warning "Never use `0.0.0.0/0` for `allowed_cidr`"
    The stack holds live provider API keys. An open security group is a
    billing and data-exposure risk. Terraform's variable validation will
    reject `0.0.0.0/0` outright.

### 3. Verify

```bash
./scripts/stack.sh status --target aws-ec2
./scripts/stack.sh urls --target aws-ec2
```

If bootstrap is still running, inspect the log:

```bash
./scripts/stack.sh ssh --target aws-ec2
# on the instance:
sudo tail -f /var/log/bootstrap-ec2.log
```

### 4. Tear down

```bash
./scripts/stack.sh down --target aws-ec2
```

Runs `terraform destroy`. Removes the EC2 instance and security group. SSM
parameters are **not** deleted automatically — clean them up separately:

```bash
aws ssm delete-parameters \
  --region ap-northeast-2 \
  --names $(aws ssm get-parameters-by-path \
    --region ap-northeast-2 \
    --path /sais/phase-1 \
    --query 'Parameters[*].Name' \
    --output text)
```

### Credential rotation

Database credentials written into persistent volumes (Postgres, ClickHouse,
MinIO, MongoDB) do not rotate when SSM parameters change. After changing a
credential:

1. Update the SSM value: `./scripts/stack.sh secrets push --target aws-ec2`
2. Either recreate the affected service volume, or run `down --purge` and
   reprovision from scratch.

### Approximate cost

| Resource | On-demand, ap-northeast-2 |
|---|---|
| t3.xlarge | ~$120 / month |
| 100 GiB gp3 EBS | ~$8 / month |
| Data transfer | usage-dependent |

Stop or terminate the instance when not in use. This is a demo stack, not a
production service.
```

---

### 2. `docs/getting-started.md`

Read the file first. Locate the section that describes starting the stack
(Quick start or equivalent). Add a short callout after that section:

```markdown
To deploy to AWS EC2 instead of running locally, follow the
[AWS EC2 deployment guide](deployment.md#aws-ec2). You will need Terraform ≥ 1.5,
an AWS account with EC2 and SSM access, and an EC2 key pair in `ap-northeast-2`.
```

Place it where it flows naturally — after the Docker quick-start, before
any "next steps" or workshop links.

## Validation (run before committing)

```bash
# MkDocs must build without errors
mkdocs build --strict

# Every stack.sh command in the doc must exist
./scripts/stack.sh help | grep -E 'push|ssh|up|down|status|urls'

# Confirm the SSM path in the doc matches stack.yaml
grep ssm_path_prefix stack.yaml
grep '/sais/phase-1' docs/deployment.md
```

## Commit

```
git add docs/deployment.md docs/getting-started.md
git commit -m "Document AWS EC2 deployment: SSM push, provision, verify, teardown"
```

## PR

```bash
gh pr create \
  --base main \
  --head pr/5-aws-docs \
  --title "Document AWS EC2 deployment" \
  --body "$(cat <<'EOF'
## Summary
- Replaces the placeholder AWS EC2 section in \`docs/deployment.md\` with a complete step-by-step guide covering: prerequisites, SSM credential push, \`terraform apply\` via \`stack.sh up\`, verify, teardown, credential rotation, and cost table
- Adds an AWS EC2 pointer in \`docs/getting-started.md\`
- All commands documented match the implementations in PRs 2–4

## Test plan
- [ ] \`mkdocs build --strict\` passes with no errors or warnings
- [ ] Every \`./scripts/stack.sh\` command in the doc exists and accepts the documented flags
- [ ] The SSM path \`/sais/phase-1\` matches \`stack.yaml targets.aws-ec2.vars.ssm_path_prefix\`
- [ ] The \`allowed_cidr\` warning in the doc is consistent with Terraform variable validation (PR 2)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

## Working agreements (from AGENTS.md)
- Update README and `docs/` when behavior, commands, profiles, phases, or
  architecture change — this PR is exactly that update
- Do not claim the aws-ec2 target is implemented until PRs 2, 3, and 4 land;
  use present tense only for commands that will exist when this doc is read
  (i.e., after all PRs merge)
- Preserve the existing structure and tone of the docs pages
- Run `mkdocs build --strict` — broken links or missing admonition syntax
  will fail the build
