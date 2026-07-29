# WireGuard Key Rotator

This Elixir controller performs staged WireGuard server/peer key rotation for
the root Compose topology. The preferred flow keeps the active proxy available
while a candidate starts, waits for every configured peer to produce a recent
candidate handshake, then promotes the generation.

```bash
bin/wg_key_rotator stage
bin/wg_key_rotator start-next
bin/wg_key_rotator status
bin/wg_key_rotator promote
```

`rotate --scheduled` is the cron-safe wrapper. It stages and starts a candidate
when none is pending, then promotes only after the configured peers migrate.

## Configuration

Copy `.env.example` only for local development; do not commit `.env` or key
material.

| Variable | Purpose |
|---|---|
| `ROTATOR_REPO_ROOT` | Absolute parent `ssl-proxy` checkout |
| `ROTATOR_STATE_DIR` | Generated rotation state, default `secrets/wg-rotation` |
| `ROTATOR_FRONTDOOR_CONFIG_PATH` | Frontdoor backend TOML |
| `WG_PEERS` | Stack-wide peer list, default `peer1,peer2` |
| `ROTATOR_PEERS` | Optional rotator-only peer override |
| `ROTATOR_MIGRATION_TIMEOUT_SECS` | Pending-generation expiry, default 24 hours |
| `ROTATOR_HANDSHAKE_GRACE_SECS` | Maximum age of a migrated handshake, default 10 minutes |
| `ROTATOR_NEXT_ADMIN_PORT` | Candidate admin port, default `3012` |
| `ROTATOR_HEALTH_URL` | Active proxy health URL |
| `ROTATOR_HEALTH_TIMEOUT_MS` | Health request timeout |
| `ROTATOR_COMMAND_TIMEOUT_MS` | Per-Docker-command timeout |

Active key destinations default to
`config/server/privatekey-server` and `config/server/publickey-server` under
the parent repository. Relative paths are resolved from `ROTATOR_REPO_ROOT`.

## Optional WAHA notifications

| Variable | Purpose |
|---|---|
| `WAHA_BASE_URL` | WAHA API; host default matches port `3006` |
| `WAHA_SESSION` | Session name, default `default` |
| `WAHA_CHAT_ID` | Notification chat; required only by the legacy one-shot flow |
| `WAHA_API_KEY` / `WAHA_API_KEY_FILE` | WAHA API credential |

The root `rotator` Compose profile enables WAHA authentication. Generate and
materialize root-stack secrets with the parent repository's
`scripts/gen-secrets` commands.

## Run

Staged/scheduled flow:

```bash
bin/wg_key_rotator rotate --scheduled
```

Inspect without promoting:

```bash
bin/wg_key_rotator status
```

Rollback disables candidate frontdoor backends and stops the candidate:

```bash
bin/wg_key_rotator rollback
```

With the parent Compose profile:

```bash
docker compose --profile rotator up -d waha
docker compose --profile rotator run --rm wg-key-rotator rotate --scheduled
```

The legacy one-shot `rotate` command remains for compatibility and can notify
the server public key, but it does not provide the staged peer migration
window. Prefer the scheduled staged flow.

## Secret bootstrap

Run these from the parent repository:

```bash
scripts/gen-secrets generate
scripts/gen-secrets env
scripts/gen-secrets check
scripts/gen-secrets repair
```

`generate` refuses to overwrite managed secrets without `--force`. Save
one-time tokens in the approved secret manager and remove their temporary file.
`repair` fixes permissions and candidate copies without replacing root
secrets.

## Development

```bash
mix test
mix format --check-formatted
bin/wg_key_rotator rotate --dry-run
```

Use `ops/wg-key-rotator.crontab.example` in the parent repository as a schedule
template.
