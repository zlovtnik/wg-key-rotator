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

Required values:

- `WAHA_BASE_URL`
- `WAHA_CHAT_ID`

`ROTATOR_REPO_ROOT` is optional when commands run inside the `ssl-proxy` checkout; otherwise set it to the absolute repo path. `ROTATOR_STATE_DIR` defaults to `secrets/wg-rotation` under the target repo. `WAHA_SESSION` defaults to `default`. For host-run commands, `WAHA_BASE_URL` defaults to `http://127.0.0.1:3006`, matching the root compose `rotator` profile's `WAHA_HOST_PORT`. Set `WAHA_API_KEY` or `WAHA_API_KEY_FILE` when WAHA is protected by an API key.

The compose profile defaults WAHA to `devlikeapro/waha` on `linux/amd64` because the Core image does not publish a multi-arch manifest for every host. On native ARM deployments, set `WAHA_IMAGE=devlikeapro/waha:arm` and `WAHA_PLATFORM=linux/arm64`.

For local compose use, WAHA auth is disabled by default with `WAHA_NO_API_KEY=True` because the service binds only to localhost. To protect WAHA, set `WAHA_NO_API_KEY=False`, provide `WAHA_API_KEY`, and pass the same key to the rotator.

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

With the root compose profile, start WAHA and run the containerized rotator from the repository root:

```sh
docker compose --profile rotator up -d waha
docker compose --profile rotator run --rm wg-key-rotator rotate --scheduled
```

Manual staged rotation:

```sh
bin/wg_key_rotator stage
bin/wg_key_rotator start-next
bin/wg_key_rotator status
bin/wg_key_rotator promote
```

Rollback disables the candidate frontdoor backends and stops `ssl-proxy-next`:

```sh
bin/wg_key_rotator rollback
```

Dry run writes generated keys under a temporary directory and stubs deploy and WhatsApp:

```sh
bin/wg_key_rotator rotate --dry-run
```

## Schedule

Use `ops/wg-key-rotator.crontab.example` as a starting point for a morning cron entry.
