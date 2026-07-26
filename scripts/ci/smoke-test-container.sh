#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

[ "$#" -ge 2 ] || die "usage: $0 <image> <container-port> [health-path]"

IMAGE=$1
CONTAINER_PORT=$2
HEALTH_PATH=${3:-/health}

command -v curl > /dev/null || die "curl is required"
command -v docker > /dev/null || die "docker is required"
command -v jq > /dev/null || die "jq is required"

CONTAINER_NAME="smoke-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${RANDOM}"
WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/container-smoke.XXXXXX")
RESPONSE_FILE=$WORK_DIR/response.json

# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup()
{
	local exit_code=$?
	if [ "$exit_code" -ne 0 ] && docker inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
		echo "container logs:" >&2
		docker logs "$CONTAINER_NAME" >&2 || true
	fi
	docker rm --force "$CONTAINER_NAME" > /dev/null 2>&1 || true
	rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

# Let the daemon pick the host port. A fixed mapping collides as soon as two
# jobs share a runner, and nothing here needs a predictable port.
docker run \
	--detach \
	--name "$CONTAINER_NAME" \
	--publish "127.0.0.1::${CONTAINER_PORT}" \
	"$IMAGE" > /dev/null

PORT_BINDING=$(docker port "$CONTAINER_NAME" "$CONTAINER_PORT/tcp" | head -n 1)
HOST_PORT=${PORT_BINDING##*:}
[[ "$HOST_PORT" =~ ^[0-9]+$ ]] || die "could not resolve the published port"
HEALTH_URL="http://127.0.0.1:$HOST_PORT$HEALTH_PATH"

for _ in {1..30}; do
	if curl --fail --silent --max-time 2 "$HEALTH_URL" > "$RESPONSE_FILE" \
		&& jq -e '.status == "ok"' "$RESPONSE_FILE" > /dev/null; then
		# The health contract is status plus the exact release version. A
		# response without one is a broken contract, not a slow start.
		jq -e 'has("version")' "$RESPONSE_FILE" > /dev/null \
			|| die "health response carries no version: $(cat "$RESPONSE_FILE")"
		echo "$IMAGE is healthy at $HEALTH_URL: $(cat "$RESPONSE_FILE")"
		exit 0
	fi

	if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != true ]; then
		die "$IMAGE stopped before becoming healthy"
	fi
	sleep 1
done

die "$IMAGE did not become healthy within 30 seconds"
