# action-semantic-release

Composite GitHub Action that fully automates version management, changelog generation, and release publishing based on [conventional commits](https://www.conventionalcommits.org/).

## How It Works

The action analyzes your commit history since the last release, determines the next version number based on commit types, generates release notes, creates a Git tag, and publishes a GitHub Release — all in a single step.

## Quick Start

```yaml
- uses: b1e90ff/action-semantic-release@v1
  with:
    github-token: ${{ inputs.token }}
```

### Branch Protection / Elevated Permissions

When your default branch has protection rules, provide a separate token with bypass permissions:

```yaml
- uses: b1e90ff/action-semantic-release@v1
  with:
    github-token: ${{ inputs.token }}
    push-token: ${{ inputs.release-token }}
```

### Monorepo

Release each module independently:

```yaml
- uses: b1e90ff/action-semantic-release@v1
  with:
    github-token: ${{ inputs.token }}
    enable-monorepo: true
```

Modules are auto-discovered by scanning for directories with a `package.json`. Each module gets its own independent version and changelog.

### Consuming Outputs

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    outputs:
      published: ${{ steps.rel.outputs.new_release_published }}
      version: ${{ steps.rel.outputs.new_release_version }}
    steps:
      - id: rel
        uses: b1e90ff/action-semantic-release@v1
        with:
          github-token: ${{ inputs.token }}

  deploy:
    needs: release
    if: needs.release.outputs.published == 'true'
    runs-on: ubuntu-latest
    steps:
      - run: echo "Shipping ${{ needs.release.outputs.version }}"
```

## Inputs

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `github-token` | **yes** | — | Token for GitHub API access |
| `push-token` | no | `github-token` | Write token for release commits and tags |
| `ref` | no | `''` | Branch or tag to check out |
| `dry-run` | no | `false` | Analyze commits without publishing |
| `extra-plugins` | no | `''` | Additional plugins (whitespace-separated) |
| `node-version` | no | `22` | Node.js version |
| `npm-registry-scope` | no | `''` | npm scope for private registry auth |
| `npm-registry-url` | no | `https://npm.pkg.github.com` | npm registry URL |
| `checkout-repository` | no | `true` | Skip checkout if already done |
| `enable-monorepo` | no | `false` | Independent per-module releases |

## Outputs

| Name | Description |
|------|-------------|
| `release_tag` | Git tag (e.g., `v2.1.0`) |
| `new_release_published` | `true` when a version was published |
| `new_release_version` | Version string without prefix (e.g., `2.1.0`) |
| `release_type` | `major`, `minor`, or `patch` |

## Bring Your Own Config

Drop any standard semantic-release config file in your repo root (`.releaserc.js`, `.releaserc.json`, `release.config.cjs`, etc.) and the action will use it. When no config is found, a sensible default is applied automatically.

## Conventional Commits Quick Reference

| Prefix | Bump |
|--------|------|
| `feat:` | minor |
| `fix:`, `perf:`, `chore:`, `refactor:`, `revert:` | patch |
| `feat!:`, `fix!:`, or footer `BREAKING CHANGE:` | **major** |

## Pinning

```yaml
uses: b1e90ff/action-semantic-release@v1   # tracks latest v1.x
uses: b1e90ff/action-semantic-release@v1.3.0  # exact version
```
