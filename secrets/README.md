# Secrets

Infisical is now the source of truth for application secrets — see
`system/infisical/README.md` for how it works and how to recover it. This
registry is down to two rows: the bootstrap values Infisical itself can't hold,
because they're needed to bring Infisical up in the first place. Adding a
secret for a new app is no longer a registry row — it's an entry in the
Infisical UI plus an `InfisicalStaticSecret` manifest (see the "Secrets"
section of the root `CLAUDE.md`).

How the two bootstrap secrets get from plaintext on your machine to sealed
manifests in git.

## Pieces

| Path | Committed? | What it holds |
|------|------------|----------------|
| `secrets/.secrets` | No (gitignored) | Plaintext values, `KEY=value` per line, sourced by `just` recipes |
| `secrets/.secrets.generated` | No (gitignored) | Auto-generated values (see `generate:` below), cached so they don't rotate every reseal |
| `pub-cert.pem` (repo root, gitignored) | No | sealed-secrets controller's public cert, used to encrypt |
| `secrets/registry.tsv` | Yes | Which secrets exist: name, namespace, output path, which keys pull from which vars |
| `secrets/seal.sh` | Yes | Reads the registry, does the `kubectl create secret \| kubeseal` work. Called by `just seal`, not run directly |
| `apps/**/*.yaml`, `platform/**/*.yaml`, etc. | Yes | The sealed (encrypted) `SealedSecret` manifests ArgoCD actually applies |

`kubeseal` encrypts with the cluster's public cert, so only that cluster's controller can decrypt — sealed output is safe to commit.

## First-time setup

```bash
just kubeseal-fetch-cert   # fetch pub-cert.pem from the cluster (run after bootstrap)
cp secrets/.secrets.example secrets/.secrets  # if starting fresh — otherwise fill in secrets/.secrets yourself
```

Fill in the values `secrets/registry.tsv` references (see below).

## Sealing a secret

```bash
just seal                          # reseal everything in the registry
just seal infisical-secrets        # reseal just one
```

Both call `secrets/seal.sh`, which reads `secrets/registry.tsv`, pulls the referenced vars out of `secrets/.secrets` (or auto-generates them — see below), and writes the sealed manifest to the registry's `outfile` column. The script assumes it's run from the repo root (as `just` does) — don't run it directly from elsewhere.

An `ENVVAR` in the registry can be prefixed `generate:` instead of requiring a value in `secrets/.secrets` — use this for arbitrary internal shared secrets, never for credentials that must match an external system. The first `just seal` invents the value and caches it in `secrets/.secrets.generated`; later runs reuse it instead of rotating it. Its only remaining users are Infisical's `ENCRYPTION_KEY` and `AUTH_SECRET`.

`secrets/.secrets.generated` still holds the arr stack's API keys from before the Infisical migration, but nothing reads them from there any more: the registry no longer lists them, so `seal.sh` doesn't maintain them, and the `wire-*` Justfile recipes read the live Secrets instead. That matters because this file is gitignored and won't exist after a rebuild, which is exactly when those recipes run.

## Adding a new secret

This only applies to the two bootstrap rows below — everything else is an
Infisical entry, not a registry row.

1. Add the plaintext value(s) to `secrets/.secrets` (or use `generate:VAR` in the row below if it's an arbitrary internal secret, not one from an external system).
2. Add a row to `secrets/registry.tsv`:
   ```
   my-secret-name    my-namespace    apps/myapp/my-secret.yaml    key=MY_ENV_VAR
   ```
   Multiple keys on one secret: comma-separate them — `key1=VAR1,key2=VAR2`.
3. `just seal my-secret-name`
4. Reference the resulting `SealedSecret` manifest from your app's kustomization/values as usual, commit, push — ArgoCD applies it.

## What's *not* in the registry

Two recipes stay hand-written in the `Justfile` because they don't fit the static table shape:

- `seal-argocd-token` — generates a fresh ArgoCD API token at seal-time (port-forward + login), not a static value from `secrets/.secrets`.
- `seal-secret <file>` — seals an arbitrary existing plain `Secret` YAML file directly, for one-offs that don't go through `secrets/.secrets` at all.

## Rotating the cluster's cert

If sealed-secrets is redeployed and generates a new keypair, re-fetch and reseal everything:

```bash
just kubeseal-fetch-cert
just seal
git add -A && git commit -m "reseal secrets after cert rotation"
```
