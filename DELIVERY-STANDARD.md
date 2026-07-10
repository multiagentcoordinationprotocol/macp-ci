# MACP Delivery Standard

The uniform CI/CD model for every `macp-*` repository. Where repos legitimately
differ (build toolchain, publish target), that difference is called out and kept
local; everything else is shared here.

Unlike a single-hub SDK org, MACP's hub is the **proto/spec repo**
(`multiagentcoordinationprotocol`). It has no runtime; it fans a `proto-v*` tag
out to seven language ecosystems, four of which are consumed in-org.

## Publish topology

| Package | Workflow (in the spec repo) | Trigger | Registry | Credential |
|---|---|---|---|---|
| `macp-proto` (7 ecosystems) | `publish-proto-packages.yml` | tag `proto-v*` | npm(GH-Pkg), PyPI, crates.io, Go, Maven×2, NuGet | `GITHUB_TOKEN`, `PYPI_TOKEN`, `CARGO_REGISTRY_TOKEN` |
| `macp-sdk-typescript` | `publish.yml` (in that repo) | GitHub release | public npm | `NPM_TOKEN` (provenance) |
| `macp-sdk-python` | `publish.yml` (in that repo) | tag `v*` | PyPI | OIDC |

## Propagation graph

```
multiagentcoordinationprotocol (proto/spec)
  └ tag proto-v* → publish-proto-packages.yml → macp-proto to 7 ecosystems
       proto-released dispatch → 4 in-org proto consumers:
         crates.io  macp-proto  ─▶ macp-runtime         (cargo)
         PyPI       macp-proto  ─▶ macp-sdk-python       (pip, range-widen)
         npm GH-Pkg @…/proto    ─▶ macp-sdk-typescript   (npm-ghpackages)
         npm GH-Pkg @…/proto    ─▶ macp-control-plane    (npm-ghpackages)
  macp-sdk-typescript (public npm) ── release → sdk-released dispatch ─▶ macp-playground (npm)
leaves: macp-ui-console, website (Vercel) · macp-auth-service (GHCR, no in-org dep)
```

Each publish job fires `repository_dispatch: proto-released` (payload
`{version, ecosystem}`) at its consumer(s) using a `macp-deps-bot` App token.
The consumer's `bump-proto.yml` calls `bump-consume.yml`. Dependabot's weekly
group is the safety net if a dispatch is ever missed.

Leaves — standardized (CI + auto-merge + Dependabot) but with no in-org SDK
dependency, so no `bump-*`:

- **macp-ui-console** — Next.js console, Vercel deploy; talks REST/SSE to the
  control-plane, no build-time dependency.
- **website** — Fumadocs docs site, Vercel deploy; docs-sync only.
- **macp-auth-service** — standalone JWT/JWKS service, GHCR image.

## Propagation mechanics

Two propagation lanes, both event-driven, both App-authenticated, both with a
Dependabot safety net.

### Proto propagation (a new `macp-proto` → its 4 consumers)

1. The spec repo publishes (`publish-proto-packages.yml` on a `proto-v*` tag).
   After the fan-out publishes, the workflow mints an App token scoped to each
   consumer and POSTs `repository_dispatch: proto-released` with
   `client_payload {version, ecosystem}` — `cargo`→runtime, `pip`→sdk-python,
   `npm`→sdk-typescript, `npm`→control-plane.
2. The consumer's thin `bump-proto.yml` calls `bump-consume.yml@v1`, which
   resolves the target, **waits for the registry to actually serve it**, edits
   the manifest + lockfile for the ecosystem, opens a PR, and arms auto-merge
   **unless the bump is breaking** (major, or a `0.x` minor).
3. Missed dispatch → Dependabot's weekly group opens the same PR later.

The four ecosystems differ in mechanics:

- **`cargo`** (macp-runtime) — crates.io (`User-Agent` required). Virtual
  workspace: edit the version in `[workspace.dependencies]` in place preserving
  features, then `cargo update -p macp-proto --precise`.
- **`pip`** (macp-sdk-python) — setuptools, **no lockfile**. An in-range publish
  is a **no-op** (pip resolves latest-in-range at build). An out-of-range version
  opens a PR that widens the `pyproject.toml` range. Do not churn PRs for in-range
  bumps.
- **`npm-ghpackages`** (macp-sdk-typescript, macp-control-plane) — `@…/proto` from
  **GitHub Packages**. `npm view` against GH Packages needs auth, so the version
  comes from the dispatch payload. The lockfile is regenerated with a temporary
  App-token `.npmrc` (`//npm.pkg.github.com/:_authToken=…`) supplied via
  `NPM_CONFIG_USERCONFIG`, so the repo's own `.npmrc` is never modified. The
  bot's `packages:write` covers read.

### SDK propagation (a new `macp-sdk-typescript` → macp-playground)

`macp-sdk-typescript`'s `publish.yml` (on release) dispatches
`repository_dispatch: sdk-released {version, ecosystem: npm}` to
`macp-playground`, whose `bump-sdk.yml` calls `bump-consume.yml` with the public
`npm` ecosystem. `macp-sdk-python` has **no in-org consumer**, so it dispatches
nothing.

### No spec-SHA propagation

MACP does not pin the spec by git SHA — conformance fixtures track the proto
**package version**, which *is* the spec pin. So there is no `bump-spec-ref`
lane. (A future hardening could pin a `PROTO_VERSION`/SHA in the three
fixture-checkout workflows for reproducible conformance — optional, out of scope.)

## Merge policy

Patch + minor auto-merge on a green pipeline; **majors are held** for a human
(Dependabot majors, and breaking bumps — `major`, or a `minor` while `0.x` —
from `bump-consume`).

## CI baseline

Auto-merge only ships what CI vouches for, so every repo's `main` protection must
require a pipeline that meets this bar. **The principles are uniform; how each
ecosystem satisfies them is not** — do not port one repo's tooling into another.

Every repo:

- [ ] **Format** enforced — rustfmt / ruff format / prettier
- [ ] **Lint** at zero warnings — clippy `-D warnings` / ruff / eslint
- [ ] **Type-check** — `tsc --noEmit` / mypy (native to Rust)
- [ ] **Tests + coverage gate** — thresholds enforced in CI, not merely measured
- [ ] **Convention / supply-chain checks** where the repo defines them

Ships a container image → additionally:

- [ ] **`docker build` (no push) on PRs** — a broken Dockerfile fails at PR time
- [ ] **Boot / smoke before publish**

The jobs satisfying this bar are the **required status checks** on `main`
(configured by `scripts/standardize.sh`).

## Credentials

One GitHub App (`macp-deps-bot`, App ID `4261746`), installed org-wide, key
stored once as org secrets `MACP_BOT_APP_ID` / `MACP_BOT_PRIVATE_KEY`. Every
cross-repo dispatch and every bot PR mints a short-lived installation token from
it — **zero PATs**. It also authenticates GitHub Packages reads for the
`npm-ghpackages` lockfile regen. Registry-publish tokens stay in the publishing
repos.

App repository permissions: Contents R/W (commit bump branches, POST dispatch),
Pull requests R/W (open PRs), Packages R/W (GH-Packages proto reads). Workflows
R/W is present but not required — MACP bumps edit manifests/lockfiles only.

## Repo matrix

| Repo | Lang | auto-merge | Dependabot | bump caller | Publish | Graph role |
|---|---|---|---|---|---|---|
| multiagentcoordinationprotocol | proto/spec | add | add | — (sends dispatch) | macp-proto ×7 | **hub** |
| macp-runtime | Rust | ✅ | group cargo | `cargo` | crates + GHCR | consumes crate |
| macp-sdk-python | Python | add | group pip | `pip` | PyPI | consumes pip |
| macp-sdk-typescript | TS | add | group npm(GH-Pkg) | `npm-ghpackages` | public npm | consumes + sends dispatch |
| macp-control-plane | TS | add | group npm(GH-Pkg) | `npm-ghpackages` | GHCR | consumes npm |
| macp-playground | TS | add | group npm | `npm` | GHCR | consumes SDK |
| macp-ui-console | TS | add | add | — | Vercel | leaf |
| macp-auth-service | TS | add | add | — | GHCR | leaf |
| website | MDX | add | add | — | Vercel | leaf (private) |

`website` is a private repo on a Free org, so `scripts/standardize.sh` cannot set
branch protection on it (GitHub 403); it still gets auto-merge + Dependabot.
