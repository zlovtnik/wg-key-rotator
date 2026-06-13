# WireGuard Key Rotator

Small one-shot Elixir app for daily WireGuard server key rotation in the local Docker Compose stack.

It rotates `config/server/privatekey-server` and `config/server/publickey-server`, runs:

```sh
docker compose up -d --build ssl-proxy
```

Then it checks `http://127.0.0.1:3002/health` and sends a WAHA `POST /api/sendText` notification.

## Configure

```sh
cp .env.example .env
$EDITOR .env
```

Required values:

- `ROTATOR_REPO_ROOT`
- `WAHA_BASE_URL`
- `WAHA_CHAT_ID`

`WAHA_SESSION` defaults to `default`. Set `WAHA_API_KEY` when WAHA is protected by an API key.

## Run

```sh
mix run -e 'WgKeyRotator.CLI.rotate()'
```

or:

```sh
bin/wg_key_rotator rotate
```

Dry run writes generated keys under a temporary directory and stubs deploy and WhatsApp:

```sh
bin/wg_key_rotator rotate --dry-run
```

## Schedule

Use `ops/wg-key-rotator.crontab.example` as a starting point for a morning cron entry.
