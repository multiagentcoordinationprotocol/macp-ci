# macp-ci

Shared CI/CD building blocks for the **macp-\*** repositories — one place to
define how the whole org builds, propagates dependencies, and ships, so every
repo stays uniform instead of drifting.

MACP's topology differs from a single-hub SDK org: the **proto/spec repo**
(`multiagentcoordinationprotocol`) fans one `proto-v*` tag out to 7 language
ecosystems, and four in-org repos consume the resulting `macp-proto` package.
These reusable workflows implement that propagation.

## What's here

| Reusable workflow | Purpose |
|---|---|
| [`.github/workflows/auto-merge.yml`](.github/workflows/auto-merge.yml) | Auto-merge Dependabot PRs once required checks pass. Patch + minor unattended; **majors held** for review. |
| [`.github/workflows/bump-consume.yml`](.github/workflows/bump-consume.yml) | Consume a new `macp-proto` / SDK release: resolve → wait for registry → bump manifest + lockfile → PR → arm auto-merge. Ecosystems: `cargo`, `npm`, `npm-ghpackages`, `pip`. |

| Script | Purpose |
|---|---|
| [`scripts/standardize.sh`](scripts/standardize.sh) | Apply uniform branch protection + `allow_auto_merge` + required checks to every repo. |

See **[DELIVERY-STANDARD.md](DELIVERY-STANDARD.md)** for the full model
(propagation graph, credential design, per-repo matrix, rollout).

## How a repo uses it

`auto-merge` — commit `.github/workflows/auto-merge.yml`:

```yaml
name: auto-merge
on: pull_request
permissions: { contents: write, pull-requests: write }
jobs:
  call:
    uses: multiagentcoordinationprotocol/macp-ci/.github/workflows/auto-merge.yml@v1
```

`bump-proto` (proto consumers) — commit `.github/workflows/bump-proto.yml`:

```yaml
name: bump proto
on:
  repository_dispatch: { types: [proto-released] }
  workflow_dispatch:   { inputs: { version: { required: false, default: '' } } }
jobs:
  bump:
    uses: multiagentcoordinationprotocol/macp-ci/.github/workflows/bump-consume.yml@v1
    with:  { ecosystem: cargo, package: macp-proto }   # per repo, see matrix
    secrets: inherit
```

### Ecosystem per consumer

| Repo | ecosystem | package |
|---|---|---|
| `macp-runtime` | `cargo` | `macp-proto` |
| `macp-sdk-python` | `pip` | `macp-proto` |
| `macp-sdk-typescript` | `npm-ghpackages` | `@multiagentcoordinationprotocol/proto` |
| `macp-control-plane` | `npm-ghpackages` | `@multiagentcoordinationprotocol/proto` |
| `macp-playground` | `npm` | `macp-sdk-typescript` |

- **`pip`** is range-widen: an in-range publish is a no-op (setuptools resolves
  latest-in-range at build, no lockfile); only an out-of-range version opens a PR
  that widens `pyproject.toml`.
- **`npm-ghpackages`** consumes `@…/proto` from **GitHub Packages** — the version
  comes from the dispatch payload (GH Packages can't be resolved unauthenticated)
  and the lockfile is regenerated with an App-token `.npmrc`.

## Credentials

The **only** cross-repo credential is the `macp-deps-bot` GitHub App (App ID
`4261746`), stored once as org secrets `MACP_BOT_APP_ID` / `MACP_BOT_PRIVATE_KEY`.
Workflows mint a short-lived installation token via
`actions/create-github-app-token`. **No PATs.** Registry-publish tokens
(`NPM_TOKEN`, `CARGO_REGISTRY_TOKEN`, `PYPI_TOKEN`; PyPI SDK is OIDC) live in the
publishing repos and are a separate concern.

## Conventions

- Third-party actions are **SHA-pinned**; first-party `actions/*` use major tags.
- Pin callers to a release tag (`@v1`), not `@main`.
