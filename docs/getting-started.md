# Getting started

Prepare the deployment target and credentials here. Once both are ready, the
[Phase 1 workshop](workshop.md) is the same regardless of where the stack
eventually runs.

## 1. Choose a target

| Target | Use it for | Status |
|---|---|---|
| `docker` | Local development and the current demo | **Runnable** |
| `aws-ec2` | A single EC2 host running the same Compose stack | **Runnable** |
| `k8s` | A future production deployment | Planned |

## 2. Prepare Docker

Requirements:

- Docker 24+ with Compose v2
- [mikefarah/yq](https://github.com/mikefarah/yq) v4
- about 5 GiB of free Docker memory; 8 GiB works, 12 GiB is comfortable
- at least one OpenAI or Anthropic API key

On macOS:

```bash
brew install yq
docker info --format 'CPUs={{.NCPU}}  Memory={{.MemTotal}}'
```

The stack publishes ports `3000`, `3080`, `4000`, `8123`, `9001`, and `9002`.
If one is occupied, either stop its owner or override the corresponding port
when starting the stack.

## 3. Configure credentials

Initialize the private inventory and open the Phase 1 menu:

```bash
./scripts/stack.sh secrets init
./scripts/stack.sh secrets setup --phase 1
```

Use the main menu in this order:

1. `d` — set shared demo login defaults: ID, email, and password.
2. Open **Model providers** and add at least one provider API key.
3. `g` — generate missing internal keys, salts, and service passwords.
4. `w` — validate the inventory and write `.env`.
5. `q` — finish.

The shared login is only a local-demo convenience. It is applied to compatible
service accounts, not to provider keys, gateway keys, JWTs, salts, or
encryption keys. Use unique service passwords outside a disposable demo.

`secrets/credentials.yaml` is the private source of truth. `.env` is generated
and overwritten by `secrets write`; do not edit it manually.

For the complete inventory, AWS authentication choices, validation behavior,
and leak response, see [Credentials](credentials.md).

## 4. Run the preflight

```bash
./scripts/stack.sh secrets status --phase 1
./scripts/stack.sh secrets validate --phase 1
./scripts/stack.sh doctor
```

`doctor` checks only the selected profile by default, so it does not require
future-phase credentials. A missing optional provider key is acceptable if the
other Phase 1 provider is configured.

## 5. Continue to the workshop

The machine and credentials are now ready:

```bash
./scripts/stack.sh up
./scripts/stack.sh status
```

Continue with the [Phase 1 workshop](workshop.md) to send a request, inspect
its trace, compare providers, and tear the stack down.

To deploy to AWS EC2 instead of running locally, follow the
[AWS EC2 deployment guide](deployment.md#aws-ec2). You will need Terraform ≥ 1.5,
an AWS account with EC2 and SSM access, and an EC2 key pair in `ap-northeast-2`.
