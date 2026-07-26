#!/usr/bin/env bash
set -euo pipefail

die()
{
	echo "error: $*" >&2
	exit 1
}

require()
{
	local name=$1
	[ -n "${!name:-}" ] || die "$name is required"
}

set_output()
{
	local name=$1
	local value=$2
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		echo "$name=$value" >> "$GITHUB_OUTPUT"
	fi
}

LAST_REQUEST_ERROR=
request()
{
	local method=$1
	local endpoint=$2
	local output_file=$3
	local payload_file=${4:-}
	local http_code
	local -a args=(
		--silent
		--show-error
		--connect-timeout 10
		--max-time 60
		--output "$output_file"
		--write-out "%{http_code}"
		--config "$CURL_API_CONFIG"
	)

	LAST_REQUEST_ERROR=
	if [ "$method" = POST ]; then
		args+=(
			--request POST
			--header "Content-Type: application/json"
			--data-binary "@$payload_file"
		)
	fi

	if ! http_code=$(curl "${args[@]}" "$DOKPLOY_BASE_URL/api/$endpoint"); then
		LAST_REQUEST_ERROR="Dokploy API request failed: $method /api/$endpoint"
		echo "error: $LAST_REQUEST_ERROR" >&2
		return 1
	fi
	case "$http_code" in
		2??) return 0 ;;
	esac

	local message
	message=$(jq -r '.message // .error.message // "no error message returned"' "$output_file" 2> /dev/null || true)
	LAST_REQUEST_ERROR="Dokploy returned HTTP $http_code for $method /api/$endpoint: $message"
	echo "error: $LAST_REQUEST_ERROR" >&2
	return 1
}

probe_url()
{
	local url=$1
	local response_file=$2

	if curl \
		--fail \
		--silent \
		--connect-timeout 5 \
		--max-time 10 \
		--output "$response_file" \
		"$url"; then
		return 0
	fi

	echo "$APP is not healthy at $url" >&2
	return 1
}

probe_basic_health()
{
	probe_url "$PRODUCTION_APP_URL/health" "$WORK_DIR/current.response"
}

probe_release_health()
{
	local expected_version=$1
	local response_file=$WORK_DIR/release.response

	probe_url "$PRODUCTION_APP_URL/health" "$response_file" || return 1

	if ! jq -e \
		--arg version "$expected_version" \
		'.status == "ok" and .version == $version' \
		"$response_file" > /dev/null; then
		echo "$APP health response does not identify release $expected_version" >&2
		return 1
	fi
}

wait_for_health()
{
	local mode=$1
	local expected_version=${2:-}
	local deadline=$((SECONDS + DOKPLOY_HEALTH_TIMEOUT_SECONDS))

	while ((SECONDS < deadline)); do
		case "$mode" in
			basic)
				if probe_basic_health; then
					echo "the previous public endpoint is healthy"
					return 0
				fi
				;;
			release)
				[ -n "$expected_version" ] \
					|| die "release health verification requires an expected version"
				if probe_release_health "$expected_version"; then
					echo "release $expected_version is healthy on the public endpoint"
					return 0
				fi
				;;
			*) die "unsupported health verification mode '$mode'" ;;
		esac
		sleep "$DOKPLOY_HEALTH_POLL_INTERVAL_SECONDS"
	done

	return 1
}

update_compose()
{
	local compose_file=$1
	local prefix=$2
	local payload=$WORK_DIR/$prefix-update.json

	jq -n \
		--arg composeId "$DOKPLOY_COMPOSE_ID" \
		--rawfile composeFile "$compose_file" \
		'{composeId: $composeId, composeFile: $composeFile, sourceType: "raw"}' \
		> "$payload"
	request POST compose.update "$WORK_DIR/$prefix-update-response.json" "$payload"
}

LAST_DEPLOYMENT_ID=
LAST_DEPLOYMENT_ERROR=
DEPLOYMENT_ACKNOWLEDGED=false
wait_for_deployment()
{
	local title=$1
	local description=$2
	local prefix=$3
	local deadline=$((SECONDS + DOKPLOY_DEPLOY_TIMEOUT_SECONDS))

	LAST_DEPLOYMENT_ID=
	LAST_DEPLOYMENT_ERROR=
	while ((SECONDS < deadline)); do
		local deployments_response=$WORK_DIR/$prefix-deployments.json
		if ! request GET "deployment.allByCompose?composeId=$DOKPLOY_COMPOSE_ID" "$deployments_response"; then
			LAST_DEPLOYMENT_ERROR=$LAST_REQUEST_ERROR
			return 2
		fi
		if ! jq -e 'type == "array"' "$deployments_response" > /dev/null; then
			LAST_DEPLOYMENT_ERROR="Dokploy returned an invalid deployment list"
			return 2
		fi

		local deployment
		deployment=$(jq -c \
			--arg title "$title" \
			--arg description "$description" \
			'[.[] | select(.title == $title and .description == $description)] | first // empty' \
			"$deployments_response")

		if [ -z "$deployment" ]; then
			sleep "$DOKPLOY_POLL_INTERVAL_SECONDS"
			continue
		fi

		local deployment_id
		deployment_id=$(jq -r '.deploymentId // empty' <<< "$deployment")
		LAST_DEPLOYMENT_ID=
		if [[ "$deployment_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
			LAST_DEPLOYMENT_ID=$deployment_id
		else
			echo "::warning::Dokploy returned a deployment ID with unsupported characters; omitting it from GitHub outputs." >&2
		fi
		local status
		status=$(jq -r '.status // empty' <<< "$deployment")
		echo "Dokploy deployment ${LAST_DEPLOYMENT_ID:-unknown}: ${status:-unknown}"
		case "$status" in
			done) return 0 ;;
			running)
				sleep "$DOKPLOY_POLL_INTERVAL_SECONDS"
				;;
			error | cancelled)
				local error_message
				error_message=$(jq -r '.errorMessage // empty' <<< "$deployment")
				LAST_DEPLOYMENT_ERROR="Dokploy deployment $status: ${error_message:-no error message returned}"
				return 1
				;;
			*)
				LAST_DEPLOYMENT_ERROR="Dokploy returned unknown deployment status '$status'"
				return 2
				;;
		esac
	done

	LAST_DEPLOYMENT_ERROR="Dokploy deployment did not finish within $DOKPLOY_DEPLOY_TIMEOUT_SECONDS seconds"
	return 2
}

submit_deployment()
{
	local title=$1
	local description=$2
	local prefix=$3
	local payload=$WORK_DIR/$prefix-deploy.json

	DEPLOYMENT_ACKNOWLEDGED=false
	jq -n \
		--arg composeId "$DOKPLOY_COMPOSE_ID" \
		--arg title "$title" \
		--arg description "$description" \
		'{composeId: $composeId, title: $title, description: $description}' \
		> "$payload"
	if ! request POST compose.deploy "$WORK_DIR/$prefix-deploy-response.json" "$payload"; then
		LAST_DEPLOYMENT_ERROR=$LAST_REQUEST_ERROR
		return 2
	fi
	if ! jq -e '.success == true' "$WORK_DIR/$prefix-deploy-response.json" > /dev/null; then
		LAST_DEPLOYMENT_ERROR="Dokploy did not acknowledge the deployment request"
		return 2
	fi

	DEPLOYMENT_ACKNOWLEDGED=true
	wait_for_deployment "$title" "$description" "$prefix"
}

ROLLBACK_AVAILABLE=false
rollback()
{
	local reason=$1
	local health_mode

	if [ "$ROLLBACK_AVAILABLE" != true ]; then
		echo "automatic rollback is unavailable because no healthy previous Compose deployment was captured" >&2
		set_output rollback_outcome unavailable
		return 1
	fi

	echo "release failed: $reason" >&2
	echo "restoring the previous Dokploy Compose configuration" >&2
	if ! update_compose "$PREVIOUS_COMPOSE" rollback; then
		set_output rollback_outcome failed
		return 1
	fi

	local title="Automatic rollback after $RELEASE_TAG"
	local description="run=$GITHUB_RUN_ID attempt=$GITHUB_RUN_ATTEMPT failed_sha=$RELEASE_SHA"
	local result
	if submit_deployment "$title" "$description" rollback; then
		result=0
	else
		result=$?
	fi
	if [ "$result" -ne 0 ]; then
		echo "automatic rollback deployment failed: $LAST_DEPLOYMENT_ERROR" >&2
		set_output rollback_outcome failed
		[ -n "$LAST_DEPLOYMENT_ID" ] && set_output rollback_deployment_id "$LAST_DEPLOYMENT_ID"
		return 1
	fi

	[ -n "$LAST_DEPLOYMENT_ID" ] && set_output rollback_deployment_id "$LAST_DEPLOYMENT_ID"
	if [ -n "$PREVIOUS_VERSION" ]; then
		health_mode=release
	else
		health_mode=basic
	fi
	if ! wait_for_health "$health_mode" "$PREVIOUS_VERSION"; then
		echo "automatic rollback finished, but the previous public endpoint did not recover" >&2
		set_output rollback_outcome failed
		return 1
	fi

	echo "automatic rollback succeeded" >&2
	set_output rollback_outcome success
	return 0
}

restore_unacknowledged_config()
{
	local reason=$1

	if [ "$ROLLBACK_AVAILABLE" != true ]; then
		set_output rollback_outcome unavailable
		die "$reason; deployment was not acknowledged and no verified previous Compose configuration is available to restore"
	fi

	echo "deployment was not acknowledged; restoring the previous Dokploy Compose configuration without starting a deployment" >&2
	if ! update_compose "$PREVIOUS_COMPOSE" config-restore; then
		set_output rollback_outcome failed
		die "$reason; deployment was not acknowledged and the previous Compose configuration could not be restored"
	fi

	set_output rollback_outcome config-restored
	die "$reason; deployment was not acknowledged, so the previous Compose configuration was restored without starting a deployment"
}

fail_with_rollback()
{
	local reason=$1

	if rollback "$reason"; then
		die "$reason; automatic rollback succeeded"
	fi
	die "$reason; automatic rollback did not restore a verified healthy state"
}

# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap.
cleanup()
{
	rm -rf -- "$WORK_DIR"
}

command -v curl > /dev/null || die "curl is required"
command -v docker > /dev/null || die "docker is required"
command -v jq > /dev/null || die "jq is required"
docker compose version > /dev/null 2>&1 || die "docker compose is required"

for name in \
	DOKPLOY_BASE_URL \
	DOKPLOY_API_KEY \
	DOKPLOY_COMPOSE_ID \
	PRODUCTION_APP_URL \
	APP \
	RELEASE_VERSION \
	RELEASE_TAG \
	RELEASE_SHA \
	APP_IMAGE; do
	require "$name"
done

DRY_RUN=${DRY_RUN:-false}
DOKPLOY_DEPLOY_TIMEOUT_SECONDS=${DOKPLOY_DEPLOY_TIMEOUT_SECONDS:-900}
DOKPLOY_POLL_INTERVAL_SECONDS=${DOKPLOY_POLL_INTERVAL_SECONDS:-5}
DOKPLOY_HEALTH_TIMEOUT_SECONDS=${DOKPLOY_HEALTH_TIMEOUT_SECONDS:-120}
DOKPLOY_HEALTH_POLL_INTERVAL_SECONDS=${DOKPLOY_HEALTH_POLL_INTERVAL_SECONDS:-5}
DOKPLOY_BASE_URL=${DOKPLOY_BASE_URL%/}
PRODUCTION_APP_URL=${PRODUCTION_APP_URL%/}

[ "$DRY_RUN" = true ] || [ "$DRY_RUN" = false ] \
	|| die "DRY_RUN must be true or false"
for url_name in DOKPLOY_BASE_URL PRODUCTION_APP_URL; do
	[[ "${!url_name}" == https://* ]] \
		|| die "$url_name must use HTTPS"
	[[ "${!url_name}" != *[$'\r\n\t ']* ]] \
		|| die "$url_name must not contain whitespace"
done
[[ "$DOKPLOY_API_KEY" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
	|| die "DOKPLOY_API_KEY has an invalid format"
[[ "$DOKPLOY_COMPOSE_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
	|| die "DOKPLOY_COMPOSE_ID contains unsupported characters"
[[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] \
	|| die "RELEASE_SHA must be a full commit SHA"
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
	|| die "RELEASE_VERSION must be a semantic version without a v prefix"
for number_name in \
	DOKPLOY_DEPLOY_TIMEOUT_SECONDS \
	DOKPLOY_POLL_INTERVAL_SECONDS \
	DOKPLOY_HEALTH_TIMEOUT_SECONDS \
	DOKPLOY_HEALTH_POLL_INTERVAL_SECONDS; do
	[[ "${!number_name}" =~ ^[1-9][0-9]*$ ]] \
		|| die "$number_name must be a positive integer"
done

[[ "$APP_IMAGE" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]] \
	|| die "APP_IMAGE must be an immutable GHCR repository@sha256 reference"

if [ "$DRY_RUN" = false ]; then
	require GITHUB_RUN_ID
	require GITHUB_RUN_ATTEMPT
fi

# The Compose file belongs to the application repository, which is the working
# directory here — unlike this script, which arrives from the workflow
# repository through an action.
COMPOSE_FILE=${COMPOSE_FILE:-$PWD/compose.dokploy.yaml}
[ -f "$COMPOSE_FILE" ] || die "$COMPOSE_FILE is missing"

WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/dokploy-deploy.XXXXXX")
chmod 700 "$WORK_DIR"
trap cleanup EXIT

CURL_API_CONFIG=$WORK_DIR/curl-api.conf
{
	echo 'header = "Accept: application/json"'
	echo "header = \"x-api-key: $DOKPLOY_API_KEY\""
} > "$CURL_API_CONFIG"
chmod 600 "$CURL_API_CONFIG"

COMPOSE_RESPONSE=$WORK_DIR/compose.json
request GET "compose.one?composeId=$DOKPLOY_COMPOSE_ID" "$COMPOSE_RESPONSE" \
	|| die "$LAST_REQUEST_ERROR"
if ! jq -e \
	'type == "object" and .sourceType == "raw" and .composeType == "docker-compose" and (.composeFile | type == "string")' \
	"$COMPOSE_RESPONSE" > /dev/null; then
	# Naming the actual values turns "fix your service" into a concrete task.
	observed=$(jq -r '
		if type == "object" then
			"sourceType=\(.sourceType // "absent") composeType=\(.composeType // "absent") composeFile=\(.composeFile | type)"
		else
			"the API did not return an object"
		end' "$COMPOSE_RESPONSE" 2> /dev/null || echo "unreadable response")
	die "the Dokploy service must use Raw source and Docker Compose, but reports $observed"
fi

PREVIOUS_COMPOSE=$WORK_DIR/previous-compose.yaml
jq -j '.composeFile' "$COMPOSE_RESPONSE" > "$PREVIOUS_COMPOSE"
PREVIOUS_SPEC=$WORK_DIR/previous-compose.json
PREVIOUS_VERSION=
PREVIOUS_COMPOSE_VALID=false
if [ -s "$PREVIOUS_COMPOSE" ] \
	&& ! grep -Fq "\${" "$PREVIOUS_COMPOSE" \
	&& docker compose -f "$PREVIOUS_COMPOSE" config --format json > "$PREVIOUS_SPEC" 2> /dev/null \
	&& jq -e --arg app "$APP" '
		.services[$app].image
		| type == "string" and test("^ghcr[.]io/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")
	' "$PREVIOUS_SPEC" > /dev/null; then
	PREVIOUS_COMPOSE_VALID=true
	PREVIOUS_VERSION=$(jq -r --arg app "$APP" '
		.services[$app].environment.RELEASE_VERSION as $version
		| if ($version | type) == "string" then $version else "" end
	' "$PREVIOUS_SPEC")
fi

DEPLOYMENTS_RESPONSE=$WORK_DIR/previous-deployments.json
request GET "deployment.allByCompose?composeId=$DOKPLOY_COMPOSE_ID" "$DEPLOYMENTS_RESPONSE" \
	|| die "$LAST_REQUEST_ERROR"
jq -e 'type == "array"' "$DEPLOYMENTS_RESPONSE" > /dev/null \
	|| die "Dokploy returned an invalid deployment list"
PREVIOUS_STATUS=$(jq -r '.[0].status // empty' "$DEPLOYMENTS_RESPONSE")
[ "$PREVIOUS_STATUS" != running ] \
	|| die "another Dokploy deployment is already running"

PREVIOUS_HEALTHY=false
if [ -n "$PREVIOUS_VERSION" ]; then
	probe_release_health "$PREVIOUS_VERSION" && PREVIOUS_HEALTHY=true
else
	probe_basic_health && PREVIOUS_HEALTHY=true
fi

if [ "$PREVIOUS_COMPOSE_VALID" = true ] \
	&& { [ "$PREVIOUS_STATUS" = "done" ] || [ -z "$PREVIOUS_STATUS" ]; } \
	&& [ "$PREVIOUS_HEALTHY" = true ]; then
	ROLLBACK_AVAILABLE=true
	echo "captured a healthy previous Compose configuration for rollback"
else
	echo "::warning::No verified healthy previous Compose deployment is available; this release cannot be rolled back automatically."
fi

RENDERED_COMPOSE=$WORK_DIR/docker-compose.yaml
# "docker compose config" adds a top-level "name:" derived from the working
# directory. Dokploy starts the stack under its own project name via -p, and
# the two disagree: the network ends up created under one name while carrying
# the label of the other, which fails the next deployment with
# "incorrect label com.docker.compose.network". Dropping the field leaves the
# project name to Dokploy alone.
docker compose -f "$COMPOSE_FILE" config | sed '/^name: /d' > "$RENDERED_COMPOSE"
[ -s "$RENDERED_COMPOSE" ] || die "rendering $COMPOSE_FILE produced nothing"
grep -q '^services:' "$RENDERED_COMPOSE" \
	|| die "the rendered Compose file has no services section"

if [ "$DRY_RUN" = true ]; then
	echo "dry run: Dokploy API access, Compose source, the public endpoint and the rendered image digest were verified"
	exit 0
fi

if ! update_compose "$RENDERED_COMPOSE" release; then
	die "$LAST_REQUEST_ERROR; the running deployment was not changed"
fi

DEPLOYMENT_TITLE="Release $RELEASE_TAG from GitHub Actions"
DEPLOYMENT_DESCRIPTION="run=$GITHUB_RUN_ID attempt=$GITHUB_RUN_ATTEMPT sha=$RELEASE_SHA"
DEPLOYMENT_RESULT=
if submit_deployment "$DEPLOYMENT_TITLE" "$DEPLOYMENT_DESCRIPTION" release; then
	DEPLOYMENT_RESULT=0
else
	DEPLOYMENT_RESULT=$?
fi
[ -z "$LAST_DEPLOYMENT_ID" ] || set_output deployment_id "$LAST_DEPLOYMENT_ID"

case "$DEPLOYMENT_RESULT" in
	0) ;;
	1) fail_with_rollback "$LAST_DEPLOYMENT_ERROR" ;;
	2)
		if [ "$DEPLOYMENT_ACKNOWLEDGED" = true ]; then
			die "$LAST_DEPLOYMENT_ERROR; deployment state is unknown, so no concurrent rollback was started"
		fi
		restore_unacknowledged_config "$LAST_DEPLOYMENT_ERROR"
		;;
	*) die "unexpected deployment result '$DEPLOYMENT_RESULT'" ;;
esac

if ! wait_for_health release "$RELEASE_VERSION"; then
	fail_with_rollback "release $RELEASE_VERSION did not become healthy within $DOKPLOY_HEALTH_TIMEOUT_SECONDS seconds"
fi

set_output rollback_outcome not-needed
echo "Dokploy release $RELEASE_TAG deployed and verified successfully"
