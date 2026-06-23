# WireGuard Key Rotator

Small Elixir controller for scheduled WireGuard security rotation in the local Docker Compose stack.

It can still run the legacy one-shot server-key rotation, but the preferred flow is now staged:

```sh
bin/wg_key_rotator stage
bin/wg_key_rotator start-next
bin/wg_key_rotator status
bin/wg_key_rotator promote
```

`rotate --scheduled` is the cron-safe wrapper: it stages and starts a candidate when no generation is pending, and promotes only after every configured peer has a recent candidate handshake.

## Configure

```sh
cp .env.example .env
$EDITOR .env
```

The rotator reads configuration from environment variables. Most are optional and have sensible defaults.

### Notification

- `WAHA_BASE_URL` — WAHA HTTP endpoint. Defaults to `http://127.0.0.1:3006` for host-run commands, matching the root compose `rotator` profile's `WAHA_HOST_PORT`.
- `WAHA_SESSION` — WAHA session name. Defaults to `default`.
- `WAHA_CHAT_ID` — WhatsApp chat ID for notifications. Required for the legacy `rotate` command; optional for staged rotation commands.
- `WAHA_API_KEY` or `WAHA_API_KEY_FILE` — WAHA API key. Use `WAHA_API_KEY_FILE` to read the key from a file path.

The compose profile defaults the WAHA image to `devlikeapro/waha` on `linux/amd64` because the Core image does not publish a multi-arch manifest for every host. On native ARM deployments, set `WAHA_IMAGE=devlikeapro/waha:arm` and `WAHA_PLATFORM=linux/arm64`.

For local compose use, WAHA auth is enabled by default. Generate root stack credentials with `scripts/gen-secrets generate`, then materialize `.env` with `scripts/gen-secrets env` so WAHA and the rotator share the same API key.

### Secret bootstrap

The rotator owns root stack secret bootstrap:

```sh
scripts/gen-secrets generate
scripts/gen-secrets env
scripts/gen-secrets check
scripts/gen-secrets repair
```

`generate` refuses to overwrite existing managed secret files unless `--force` is passed. A dry run is available with `scripts/gen-secrets --dry-run`.
`repair` fixes managed permissions and candidate secret copies without replacing root secrets.

The raw Atheros API token is written once to `secrets/ONE_TIME_TOKENS`. Save it outside the repository and delete that file; `scripts/gen-secrets check` fails while it exists.

### Repository and state

- `ROTATOR_REPO_ROOT` — Absolute path to the `ssl-proxy` checkout. Auto-discovered when the rotator runs from inside the repo. Set this when running from elsewhere.
- `ROTATOR_STATE_DIR` — Directory for rotation state and generated keys. Defaults to `secrets/wg-rotation` under `ROTATOR_REPO_ROOT`.
- `ROTATOR_FRONTDOOR_CONFIG_PATH` — Path to the frontdoor TOML config. Defaults to `secrets/wg-rotation/frontdoor/wg-udp-frontdoor.toml` under `ROTATOR_REPO_ROOT`.
- `ROTATOR_COMMAND_TIMEOUT_MS` — Timeout for each Docker command. Defaults to `600000` (10 minutes).

### Key material

- `ROTATOR_PRIVATE_KEY_PATH` — Where the active server private key is written. Defaults to `config/server/privatekey-server`.
- `ROTATOR_PUBLIC_KEY_PATH` — Where the active server public key is written. Defaults to `config/server/publickey-server`.
- `ROTATOR_INCLUDE_PUBLIC_KEY` — Include the server public key in WhatsApp notifications for the legacy `rotate` flow. Defaults to `true`.

### Peers and migration

- `ROTATOR_PEERS` — Comma-separated peer names. Defaults to `peer1,peer2`.
- `ROTATOR_MIGRATION_TIMEOUT_SECS` — Max age of a pending generation before it is considered expired. Defaults to `86400` (24 hours).
- `ROTATOR_HANDSHAKE_GRACE_SECS` — Max age of a peer handshake to count as migrated. Defaults to `600` (10 minutes).
- `ROTATOR_NEXT_ADMIN_PORT` — Admin port for the `ssl-proxy-next` candidate container. Defaults to `3012`.
- `ROTATOR_HEALTH_URL` — Health check URL. Defaults to `http://127.0.0.1:3002/health`.
- `ROTATOR_HEALTH_TIMEOUT_MS` — Health check timeout. Defaults to `5000`.

All key paths and the frontdoor config path are resolved relative to `ROTATOR_REPO_ROOT` unless they are absolute paths.

## Run

```sh
mix run -e 'WgKeyRotator.CLI.rotate()'
```

or:

```sh
bin/wg_key_rotator rotate
```

Scheduled full rotation:

```sh
bin/wg_key_rotator rotate --scheduled
```


### Legacy one-shot rotation

The legacy flow generates keys, deploys `ssl-proxy`, and sends a WhatsApp notification with the new server public key. It requires `WAHA_CHAT_ID`.

```sh
bin/wg_key_rotator rotate
```

Or via Elixir directly:

```sh
mix run -e 'WgKeyRotator.CLI.rotate()'
```

Dry run writes generated keys under a temporary directory and stubs deploy and WhatsApp:

```sh
bin/wg_key_rotator rotate --dry-run
```

### Staged rotation

The staged flow generates candidate keys, brings up `ssl-proxy-next`, waits for peers to connect with a recent handshake, then promotes the candidate to active. It is safe to run from cron.

```sh
bin/wg_key_rotator stage
bin/wg_key_rotator start-next
bin/wg_key_rotator status
bin/wg_key_rotator promote
```

`rotate --scheduled` wraps the staged flow into a single cron-safe command. It stages and starts a candidate when no generation is pending. If a pending generation exists, it polls peer handshakes and promotes automatically once every peer has a recent handshake. If the candidate container is unavailable, it starts it automatically.

```sh
bin/wg_key_rotator rotate --scheduled
```

Rollback disables the candidate frontdoor backends and stops `ssl-proxy-next`:

```sh
bin/wg_key_rotator rollback
```

With the root compose profile, start WAHA and run the containerized rotator from the repository root:

```sh
docker compose --profile rotator up -d waha
docker compose --profile rotator run --rm wg-key-rotator rotate --scheduled
```

## Schedule

Use `ops/wg-key-rotator.crontab.example` as a starting point for a morning cron entry.
