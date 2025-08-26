#!/usr/bin/env bash
set -euo pipefail

COL_RESET="\033[0m"
COL_RED="\033[31m"
COL_GREEN="\033[32m"
COL_YELLOW="\033[33m"
COL_BLUE="\033[34m"
COL_BOLD="\033[1m"

# Logging functions
log_info() {
  echo -e "${COL_BLUE}INFO: $*${COL_RESET}"
}

log_success() {
  echo -e "${COL_GREEN}SUCCESS: $*${COL_RESET}"
}

log_warning() {
  echo -e "${COL_YELLOW}WARNING: $*${COL_RESET}"
}

log_error() {
  echo -e "${COL_RED}ERROR: $*${COL_RESET}" >&2
}

log_header() {
  echo -e "--- ${COL_BOLD}$*${COL_RESET}"
}

trap 'echo "^^^ +++"; echo "Exit status $? at line $LINENO from: $BASH_COMMAND"' ERR

PLUGIN_PREFIX="AWS_LAMBDA_DEPLOY"

# Reads either a value or a list from the given env prefix
function prefix_read_list() {
  local prefix="$1"
  local parameter="${prefix}_0"

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      echo "${!parameter}"
      # i=$((i + 1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    echo "${!prefix}"
  fi
}

# Reads either a value or a list from plugin config
function plugin_read_list() {
  prefix_read_list "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

# Reads either a value or a list from plugin config into a global result array
# Returns success if values were read
function prefix_read_list_into_result() {
  local prefix="$1"
  local parameter="${prefix}_0"
  result=()

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    local parameter="${prefix}_${i}"
    while [[ -n "${!parameter:-}" ]]; do
      result+=("${!parameter}")
      i=$((i + 1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    result+=("${!prefix}")
  fi

  [[ ${#result[@]} -gt 0 ]] || return 1
}

# Reads either a value or a list from plugin config
function plugin_read_list_into_result() {
  prefix_read_list_into_result "BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
}

function set_build_metadata() {
  local key="$1"
  local value="$2"

  log_info "Setting build metadata: ${key}=${value}"
  buildkite-agent meta-data set "${key}" "${value}"
}

function get_build_metadata() {
  local key="$1"
  local default_value="${2:-}"

  if buildkite-agent meta-data exists "${key}" 2>/dev/null; then
    buildkite-agent meta-data get "${key}"
  else
    echo "${default_value}"
  fi
}

function create_annotation() {
  local style="$1"
  local context="$2"
  local body="$3"

  buildkite-agent annotate --style "${style}" --context "${context}" "${body}"
}

function get_alias_target() {
  local function_name="$1"
  local alias_name="$2"
  local aws_args=("${@:3}")

  aws lambda get-alias \
    "${aws_args[@]}" \
    --function-name "${function_name}" \
    --name "${alias_name}" \
    --query 'FunctionVersion' \
    --output text 2>/dev/null || echo ""
}

function get_function_arn() {
  local function_name="$1"
  local version="$2"
  local aws_args=("${@:3}")

  aws lambda get-function \
    "${aws_args[@]}" \
    --function-name "${function_name}" \
    --qualifier "${version}" \
    --query 'Configuration.FunctionArn' \
    --output text
}

function wait_for_function_active() {
  local function_name="$1"
  local version="$2"
  local timeout="${3:-300}"
  local aws_args=("${@:4}")

  log_info "Waiting for function ${function_name}:${version} to become active..."

  local end_time=$((SECONDS + timeout))
  while [[ $SECONDS -lt $end_time ]]; do
    local state
    state=$(aws lambda get-function \
      "${aws_args[@]}" \
      --function-name "${function_name}" \
      --qualifier "${version}" \
      --query 'Configuration.State' \
      --output text)

    if [[ "${state}" == "Active" ]]; then
      log_success "Function is active"
      return 0
    elif [[ "${state}" == "Failed" ]]; then
      log_error "Function deployment failed"
      return 1
    fi

    log_info "Function state: ${state}, waiting..."
    sleep 10
  done

  log_error "Timeout waiting for function to become active"
  return 1
}

function test_function_invocation() {
  local function_name="$1"
  local version="$2"
  local payload_file="$3"
  local expected_status="${4:-200}"
  local aws_args=("${@:5}")

  log_info "Testing function invocation..."

  local response_file
  response_file=$(mktemp)
  # The aws cli lambda invoke command sends the function's response to the nominated file
  # and sends metadata about the request to stdout. If the request fails, it sends error
  # information to stderr. We need to capture all of that.
  local invoke_output
  if ! invoke_output=$(aws lambda invoke \
    "${aws_args[@]}" \
    --cli-binary-format raw-in-base64-out \
    --function-name "${function_name}" \
    --qualifier "${version}" \
    --payload "file://${payload_file}" \
    "${response_file}" 2>&1); then
    log_error "'aws lambda invoke' command failed"
    log_info "Error details:"
    echo "${invoke_output}"
    rm -f "${response_file}"
    return 1
  fi

  # The command succeeded, so invoke_output contains the metadata from stdout
  local status_code
  status_code=$(echo "${invoke_output}" | jq -r '.StatusCode')

  local response_payload
  response_payload=$(cat "${response_file}")

  if [[ "${status_code}" -ne "${expected_status}" ]]; then
    log_error "Function invocation failed with status: ${status_code} (expected ${expected_status})"
    log_info "Response payload:"
    echo "${response_payload}"
    rm -f "${response_file}"
    return 1
  fi

  # Check for a business-logic error in the function's response.
  # This occurs when the function itself traps an error and reports it, but still returns a 200 status code.
  if echo "${response_payload}" | jq -e '.FunctionError' >/dev/null; then
    local function_error
    function_error=$(echo "${response_payload}" | jq -r '.FunctionError')
    log_error "Function execution returned an error: ${function_error}"
    log_info "Response payload:"
    echo "${response_payload}"
    rm -f "${response_file}"
    return 1
  fi

  log_success "Function invocation successful (status: ${status_code})"
  rm -f "${response_file}"
  return 0
}

function create_lambda_function() {
  local function_name="$1"
  local alias_name="$2"
  local aws_args=("${@:3}")

  log_header ":construction: Creating Lambda function ${function_name}"

  # Get required parameters
  local package_type="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE:-Zip}"
  local runtime="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_RUNTIME:-python3.9}"
  local handler="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HANDLER:-lambda_function.lambda_handler}"
  local role="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ROLE?Missing role for function creation}"
  local timeout="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_TIMEOUT:-30}"
  local memory_size="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MEMORY_SIZE:-128}"

  local create_command=(aws lambda create-function "${aws_args[@]}" --function-name "${function_name}")
  create_command+=(--role "${role}")
  create_command+=(--timeout "${timeout}")
  create_command+=(--memory-size "${memory_size}")

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_DESCRIPTION:-}" ]]; then
    create_command+=(--description "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_DESCRIPTION}")
  fi

  case "${package_type}" in
  "Zip")
    create_command+=(--runtime "${runtime}")
    create_command+=(--handler "${handler}")
    if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE:-}" ]]; then
      local zip_file="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE}"
      # If relative path, make it relative to BUILDKITE_BUILD_CHECKOUT_PATH
      if [[ "${zip_file}" != /* ]]; then
        zip_file="${BUILDKITE_BUILD_CHECKOUT_PATH:-$(pwd)}/${zip_file}"
      fi
      log_info "Debug: Resolved zip file path: ${zip_file}"
      create_command+=(--zip-file "fileb://${zip_file}")
    elif [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_BUCKET:-}" && -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_KEY:-}" ]]; then
      create_command+=(--code "S3Bucket=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_BUCKET},S3Key=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_KEY}")
      if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_OBJECT_VERSION:-}" ]]; then
        create_command[-1]="${create_command[-1]},S3ObjectVersion=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_OBJECT_VERSION}"
      fi
    else
      log_error "For Zip package type, either zip-file or s3-bucket+s3-key must be specified"
      return 1
    fi
    ;;
  "Image")
    create_command+=(--package-type "Image")
    if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_URI:-}" ]]; then
      create_command+=(--code "ImageUri=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_URI}")
    else
      log_error "For Image package type, image-uri must be specified"
      return 1
    fi
    ;;
  *)
    log_error "Invalid package type: ${package_type}"
    return 1
    ;;
  esac

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ENVIRONMENT:-}" ]]; then
    create_command+=(--environment "Variables=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ENVIRONMENT}")
  fi

  if ! "${create_command[@]}"; then
    log_error "Failed to create Lambda function"
    return 1
  fi

  log_success "Function ${function_name} created successfully"

  if ! wait_for_function_active "${function_name}" "\$LATEST" 300 "${aws_args[@]}"; then
    log_error "Function failed to become active after creation"
    return 1
  fi

  # Create alias if it doesn't exist
  log_info "Creating alias ${alias_name} for function ${function_name}"
  if ! aws lambda create-alias \
    "${aws_args[@]}" \
    --function-name "${function_name}" \
    --name "${alias_name}" \
    --function-version "\$LATEST" 2>/dev/null; then
    log_warning "Could not create alias ${alias_name} (may already exist)"
  fi

  return 0
}
