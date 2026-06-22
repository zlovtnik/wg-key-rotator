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

- `ROTATOR_REPO_ROOT`
- `WAHA_BASE_URL`
- `WAHA_CHAT_ID`

`ROTATOR_STATE_DIR` defaults to `secrets/wg-rotation` under the target repo. `WAHA_SESSION` defaults to `default`. Set `WAHA_API_KEY_FILE` when WAHA is protected by an API key.

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
