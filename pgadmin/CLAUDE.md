# CLAUDE.md — pgAdmin4 Component

## Chart

`runix/pgadmin4` v1.62.0 (app v9.13). Helm repo: `https://helm.runix.net`.

## Server Pre-configuration

The `serverDefinitions` block in `values.yaml` creates `/pgadmin4/servers.json` on startup, which pgAdmin uses to pre-populate the server tree. The server username `polaris` matches the CNPG bootstrap user. The password is not stored in the config — pgAdmin prompts for it on first connect.

The PostgreSQL password is in the CNPG-managed secret `polaris-pg-app` in the `dwh` namespace (key: `password`).

## Namespace

pgAdmin is deployed in the `dwh` namespace alongside Polaris and CNPG, simplifying DNS-based connection config (`polaris-pg-rw.dwh.svc.cluster.local`).

## NodePort

Exposed on NodePort `30543`. UI at `http://<node-ip>:30543`.

## Credentials

Default: `admin@lakehouse.local` / `admin123` — set via `env.email` and `env.password`. For production, use `existingSecret` to avoid plaintext passwords in values.yaml.

## Persistence

Uses a 1Gi PVC on `local-path` for pgAdmin's own config storage (saved queries, preferences). Without persistence, all UI customizations are lost on pod restart.
