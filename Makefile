.PHONY: default rotate rotate-dry-run rotate-scheduled stage start-next status promote rollback test help

default: help

# Run a full key rotation (requires WAHA_CHAT_ID)
rotate:
	@echo "=== wg-key-rotator: rotate ==="
	mix run -e 'WgKeyRotator.CLI.rotate()'

# Dry-run: preview changes without executing them
rotate-dry-run:
	@echo "=== wg-key-rotator: rotate --dry-run ==="
	mix run -e 'WgKeyRotator.CLI.main(["rotate", "--dry-run"])'

# Scheduled rotation: check handshakes before proceeding
rotate-scheduled:
	@echo "=== wg-key-rotator: rotate --scheduled ==="
	mix run -e 'WgKeyRotator.CLI.main(["rotate", "--scheduled"])'

# Stage: generate and stage new keys
stage:
	@echo "=== wg-key-rotator: stage ==="
	mix run -e 'WgKeyRotator.CLI.main(["stage"])'

# Start-next: deploy next server with staged keys
start-next:
	@echo "=== wg-key-rotator: start-next ==="
	mix run -e 'WgKeyRotator.CLI.main(["start-next"])'

# Status: show current rotation state
status:
	@echo "=== wg-key-rotator: status ==="
	mix run -e 'WgKeyRotator.CLI.main(["status"])'

# Promote: promote the staged rotation
promote:
	@echo "=== wg-key-rotator: promote ==="
	mix run -e 'WgKeyRotator.CLI.main(["promote"])'

# Rollback: roll back to previous keys
rollback:
	@echo "=== wg-key-rotator: rollback ==="
	mix run -e 'WgKeyRotator.CLI.main(["rollback"])'

# Run tests
test:
	@echo "=== wg-key-rotator: test ==="
	mix test

# Show usage
help:
	@echo "wg-key-rotator Makefile targets:"
	@echo ""
	@echo "  rotate              Full key rotation (requires WAHA_CHAT_ID)"
	@echo "  rotate-dry-run      Preview changes without executing"
	@echo "  rotate-scheduled    Scheduled rotation with handshake checks"
	@echo "  stage               Generate and stage new keys"
	@echo "  start-next          Deploy next server with staged keys"
	@echo "  status              Show current rotation state"
	@echo "  promote             Promote the staged rotation"
	@echo "  rollback            Roll back to previous keys"
	@echo "  test                Run test suite (mix test)"
	@echo "  help                Show this help"
	@echo ""
	@echo "Environment variables:"
	@echo "  WAHA_CHAT_ID        (required) WhatsApp chat ID for notifications"
	@echo "  WAHA_BASE_URL       (optional, default: http://127.0.0.1:3006)"
	@echo "  ROTATOR_REPO_ROOT   (optional, auto-detected)"
	@echo ""
	@echo "Example:"
	@echo "  WAHA_CHAT_ID=12132132130@c.us make rotate"
