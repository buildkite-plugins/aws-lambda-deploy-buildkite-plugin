#!/usr/bin/env bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/plugin.bash
. "${DIR}/plugin.bash"

function deploy_lambda() {
  deploy_aws_cli "$@"
}

function deploy_aws_cli() {
  local function_name="$1"
  local alias_name="$2"
  local aws_args=("${@:3}")

  log_header "λ Starting Lambda deployment for ${function_name}"

  # Get current alias target for rollback
  local previous_version
  previous_version=$(get_alias_target "${function_name}" "${alias_name}" "${aws_args[@]+${aws_args[@]}}")

  if [[ -n "${previous_version}" ]]; then
    local previous_arn
    previous_arn=$(get_function_arn "${function_name}" "${previous_version}" "${aws_args[@]+${aws_args[@]}}")
    set_build_metadata "deployment:aws_lambda:${function_name}:previous_version" "${previous_version}"
    set_build_metadata "deployment:aws_lambda:${function_name}:previous_arn" "${previous_arn}"
    log_info "Current alias ${alias_name} points to version ${previous_version}"
  else
    log_info "Alias ${alias_name} does not exist or has no target"
    set_build_metadata "deployment:aws_lambda:${function_name}:previous_version" ""
    set_build_metadata "deployment:aws_lambda:${function_name}:previous_arn" ""
  fi

  # If alias target is $LATEST create a baseline numeric version for canary deployments
  if [[ "${previous_version}" == "\$LATEST" ]]; then
    log_header ":lambda: Alias ${alias_name} is pointing at \$LATEST – publishing baseline version"
    local baseline_output
    baseline_output=$(aws lambda publish-version \
      "${aws_args[@]+${aws_args[@]}}" \
      --function-name "${function_name}" \
      --description "Baseline published automatically by Buildkite before canary $(date)")
    local baseline_version
    baseline_version=$(echo "${baseline_output}" | jq -r '.Version')
    log_info "Published baseline version: ${baseline_version}"

    # Point alias 100% to baseline version so we can shift some traffic later
    if aws lambda update-alias \
      "${aws_args[@]+${aws_args[@]}}" \
      --function-name "${function_name}" \
      --name "${alias_name}" \
      --function-version "${baseline_version}"; then
      previous_version="${baseline_version}"
      set_build_metadata "deployment:aws_lambda:${function_name}:previous_version" "${baseline_version}"
      set_build_metadata "deployment:aws_lambda:${function_name}:previous_arn" "$(get_function_arn "${function_name}" "${baseline_version}" "${aws_args[@]+${aws_args[@]}}")"
    else
      log_error "Failed to update alias to baseline version"
      return 1
    fi
  fi

  local update_command=(aws lambda update-function-code "${aws_args[@]+${aws_args[@]}}" --function-name "${function_name}" --publish)

  local deployment_strategy="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_STRATEGY:-direct}"

  local package_type="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE:-Zip}"
  set_build_metadata "deployment:aws_lambda:${function_name}:package_type" "${package_type}"

  case "${package_type}" in
  "Zip")
    if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE:-}" ]]; then
      local zip_file="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE}"
      # Clean up the path (remove ./ if present)
      zip_file="${zip_file#./}"
      # Convert to absolute path
      if [[ "${zip_file}" != /* ]]; then
        zip_file="$(pwd)/${zip_file}"
      fi
      update_command+=(--zip-file "fileb://${zip_file}")
    elif [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_BUCKET:-}" && -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_KEY:-}" ]]; then
      update_command+=(--s3-bucket "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_BUCKET}")
      update_command+=(--s3-key "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_KEY}")
      if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_OBJECT_VERSION:-}" ]]; then
        update_command+=(--s3-object-version "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_OBJECT_VERSION}")
      fi
    else
      log_error "For Zip package type, either zip-file or s3-bucket+s3-key must be specified"
      return 1
    fi
    ;;
  "Image")
    if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_URI:-}" ]]; then
      update_command+=(--image-uri "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_URI}")
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

  # Update function code
  log_info "Updating function code"
  local update_output
  update_output=$("${update_command[@]}")
  local update_exit_code=$?

  if [[ $update_exit_code -ne 0 ]]; then
    log_error "Failed to update function code"
    set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
    return $update_exit_code
  fi

  # Get the new version from the update response
  local new_version
  new_version=$(echo "${update_output}" | jq -r '.Version')
  log_info "Updated function code, new version: ${new_version}"

  # Fallback: some runtimes/CLI versions may still return $LATEST even with --publish
  if [[ "${new_version}" == "\$LATEST" ]]; then
    log_header ":lambda: Detected \$LATEST, publishing explicit version"
    local publish_output
    publish_output=$(aws lambda publish-version \
      "${aws_args[@]+${aws_args[@]}}" \
      --function-name "${function_name}" \
      --description "Published by Buildkite deployment at $(date)")
    new_version=$(echo "${publish_output}" | jq -r '.Version')
    log_info "Published version: ${new_version}"
  fi

  # Wait for function to be active
  if ! wait_for_function_active "${function_name}" "${new_version}" 300 "${aws_args[@]+${aws_args[@]}}"; then
    log_error "Function failed to become active"
    set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
    return 1
  fi

  # Update function configuration if provided
  if should_update_configuration; then
    log_info "Updating function configuration"
    if ! update_function_configuration "${function_name}" "${new_version}" "${aws_args[@]+${aws_args[@]}}"; then
      log_error "Failed to update function configuration"
      set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
      return 1
    fi
  fi

  # Store new version info
  local new_arn
  new_arn=$(get_function_arn "${function_name}" "${new_version}" "${aws_args[@]+${aws_args[@]}}")
  set_build_metadata "deployment:aws_lambda:${function_name}:current_version" "${new_version}"
  set_build_metadata "deployment:aws_lambda:${function_name}:current_arn" "${new_arn}"

  # Run health checks if enabled
  local health_check_enabled="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HEALTH_CHECK_ENABLED:-false}"
  if [[ "${health_check_enabled}" == "true" ]]; then
    log_header ":lambda: Running health checks"
    if ! run_health_checks "${function_name}" "${new_version}" "${aws_args[@]+${aws_args[@]}}"; then
      log_warning "Health checks failed"

      local auto_rollback="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_AUTO_ROLLBACK:-false}"
      if [[ "${auto_rollback}" == "true" ]]; then
        log_header ":lambda: Auto-rollback enabled, rolling back deployment"
        set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
        set_build_metadata "deployment:aws_lambda:${function_name}:auto_rollback" "true"
        return 1
      else
        log_warning "Auto-rollback not enabled, continuing with deployment"
      fi
    else
      log_success "Health checks passed"
    fi
  fi

  # Update alias with traffic shifting strategy
  log_info "Updating alias ${alias_name} with ${deployment_strategy} strategy"
  log_info "Deployment strategy: '${deployment_strategy}'"
  log_info "Canary weight: '${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_WEIGHT:-0.05}'"

  if [[ "${deployment_strategy}" == "canary" ]]; then
    local canary_type="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_TYPE:-all-at-once}"

    if [[ "${canary_type}" == "linear" ]]; then
      local canary_steps="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_STEPS:-1}"
      local canary_interval="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_INTERVAL:-60}"

      log_header ":lambda: Starting linear canary deployment over ${canary_steps} steps"

      for i in $(seq 1 "${canary_steps}"); do
        local weight
        weight=$(awk -v i="$i" -v steps="${canary_steps}" 'BEGIN { print i / steps }')
        local percent
        percent=$(awk -v w="${weight}" 'BEGIN { print w * 100 }')

        log_info "Step ${i}/${canary_steps}: Shifting ${percent}% traffic to version ${new_version}"

        if ! aws lambda update-alias \
          "${aws_args[@]+${aws_args[@]}}" \
          --function-name "${function_name}" \
          --name "${alias_name}" \
          --routing-config "{\"AdditionalVersionWeights\": {\"${new_version}\": ${weight}}}"; then
          log_error "Failed to update alias during linear canary deployment"
          set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
          return 1
        fi

        if [[ "$i" -lt "${canary_steps}" ]]; then
          log_info "Waiting for ${canary_interval} seconds before next step..."
          sleep "${canary_interval}"
        fi
      done

      log_success "Linear canary deployment complete. 100% traffic on version ${new_version}."
      set_build_metadata "deployment:aws_lambda:${function_name}:result" "success"
      create_linear_canary_success_annotation "${function_name}" "${alias_name}" "${new_version}" "${previous_version}" "${canary_steps}"

    else # all-at-once
      # Canary deployment with traffic shifting
      local canary_weight="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_WEIGHT:-0.05}"
      log_info "Starting canary deployment with ${canary_weight} traffic to version ${new_version}"

      log_info "Updating alias with canary configuration"
      if ! aws lambda update-alias \
        "${aws_args[@]+${aws_args[@]}}" \
        --function-name "${function_name}" \
        --name "${alias_name}" \
        --routing-config "{\"AdditionalVersionWeights\": {\"${new_version}\": ${canary_weight}}}"; then
        log_error "Failed to start canary deployment"
        set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
        echo '^^^ +++'
        return 1
      fi
      echo '^^^ +++'

      local canary_percent
      canary_percent=$(awk -v weight="${canary_weight}" 'BEGIN { print weight * 100 }')

      set_build_metadata "deployment:aws_lambda:${function_name}:canary_version" "${new_version}"
      set_build_metadata "deployment:aws_lambda:${function_name}:canary_weight" "${canary_weight}"
      log_info "Canary deployment active - ${canary_percent}% traffic to version ${new_version}"
      create_annotation "info" "aws-lambda-deploy-${function_name}" "Canary deployment active - ${canary_percent}% traffic to version ${new_version}"
      log_info "Use 'promote-canary' mode to shift 100% traffic to new version"
    fi
  else
    # Direct deployment (immediate 100% traffic)
    if ! aws lambda update-alias \
      "${aws_args[@]+${aws_args[@]}}" \
      --function-name "${function_name}" \
      --name "${alias_name}" \
      --function-version "${new_version}"; then
      log_error "Failed to update alias"
      set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
      return 1
    fi
  fi

  # Run post-deployment health checks
  if [[ "${health_check_enabled}" == "true" ]]; then
    log_header ":lambda: Running post-deployment health checks"
    if ! run_health_checks "${function_name}" "${alias_name}" "${aws_args[@]+${aws_args[@]}}"; then
      log_warning "Post-deployment health checks failed"

      local auto_rollback="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_AUTO_ROLLBACK:-false}"
      if [[ "${auto_rollback}" == "true" ]]; then
        log_header ":lambda: Auto-rollback enabled, rolling back deployment"
        set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
        set_build_metadata "deployment:aws_lambda:${function_name}:auto_rollback" "true"
        return 1
      fi
    else
      log_success "Post-deployment health checks passed"
      local canary_auto_promote="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_AUTO_PROMOTE:-false}"
      local canary_type="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_CANARY_TYPE:-all-at-once}"

      if [[ "${deployment_strategy}" == "canary" && "${canary_type}" == "all-at-once" && "${canary_auto_promote}" == "true" ]]; then
        log_header ":lambda: Auto-promoting canary deployment"
        if promote_canary "${function_name}" "${alias_name}" "${aws_args[@]+${aws_args[@]}}"; then
          log_success "Canary auto-promotion successful"
        else
          log_error "Canary auto-promotion failed"
          # The promote_canary function will set the build metadata
          return 1
        fi
      fi
    fi
  fi

  # Create success annotation only for direct strategy; avoid overriding canary warning
  if [[ "${deployment_strategy}" != "canary" ]]; then
    set_build_metadata "deployment:aws_lambda:${function_name}:result" "success"
    create_deployment_success_annotation "${function_name}" "${alias_name}" "${previous_version}" "${new_version}" "${deployment_strategy}"
  fi
  log_success "🚀 Lambda deployment for ${function_name} to version ${new_version} completed successfully"
  return 0
}

function should_update_configuration() {
  [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ENVIRONMENT:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_TIMEOUT:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MEMORY_SIZE:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_RUNTIME:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HANDLER:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_DESCRIPTION:-}" ]] \
    || [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_CONFIG:-}" ]]
}

function update_function_configuration() {
  local function_name="$1"
  local version="$2"
  local aws_args=("${@:3}")

  local config_command=(aws lambda update-function-configuration "${aws_args[@]+${aws_args[@]}}" --function-name "${function_name}")

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ENVIRONMENT:-}" ]]; then
    config_command+=(--environment "Variables=${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ENVIRONMENT}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_TIMEOUT:-}" ]]; then
    config_command+=(--timeout "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_TIMEOUT}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MEMORY_SIZE:-}" ]]; then
    config_command+=(--memory-size "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MEMORY_SIZE}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_RUNTIME:-}" ]]; then
    config_command+=(--runtime "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_RUNTIME}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HANDLER:-}" ]]; then
    config_command+=(--handler "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HANDLER}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_DESCRIPTION:-}" ]]; then
    config_command+=(--description "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_DESCRIPTION}")
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_CONFIG:-}" ]]; then
    config_command+=(--image-config "${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_CONFIG}")
  fi

  "${config_command[@]}"
}

function run_health_checks() {
  local function_name="$1"
  local version="$2"
  local aws_args=("${@:3}")

  local payload="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HEALTH_CHECK_PAYLOAD:-}"
  local expected_status="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HEALTH_CHECK_EXPECTED_STATUS:-200}"
  local timeout="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HEALTH_CHECK_TIMEOUT:-300}"
  # shellcheck disable=SC2034
  local error_threshold="${BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_HEALTH_CHECK_ERROR_THRESHOLD:-0.1}"

  # Simple invocation test
  # Use printf to avoid adding a trailing newline to the payload file, which would corrupt the JSON.
  local payload_file
  payload_file=$(mktemp)
  printf '%s' "${payload}" >"${payload_file}"

  if ! test_function_invocation "${function_name}" "${version}" "${payload_file}" "${expected_status}" "${aws_args[@]+${aws_args[@]}}"; then
    rm -f "${payload_file}"
    return 1
  fi

  rm -f "${payload_file}"

  # Additional CloudWatch metrics check could be added here
  # For now, we'll just do the basic invocation test

  return 0
}

# Promote canary deployment to 100% traffic
function promote_canary() {
  local function_name="$1"
  local alias_name="$2"
  local aws_args=("${@:3}")

  log_header ":lambda: Promoting canary deployment for ${function_name}"

  # Get canary deployment metadata
  local canary_version
  canary_version=$(get_build_metadata "deployment:aws_lambda:${function_name}:canary_version" "")

  local canary_weight
  canary_weight=$(get_build_metadata "deployment:aws_lambda:${function_name}:canary_weight" "")

  if [[ -z "${canary_version}" ]]; then
    log_error "No canary deployment found. Use 'deploy' mode with strategy 'canary' first."
    return 1
  fi

  log_info "Promoting canary version ${canary_version} (currently at ${canary_weight} traffic) to 100%"

  # Update alias to point 100% traffic to canary version
  if ! aws lambda update-alias \
    "${aws_args[@]+${aws_args[@]}}" \
    --function-name "${function_name}" \
    --name "${alias_name}" \
    --function-version "${canary_version}" \
    --routing-config '{}'; then
    log_error "Failed to promote canary deployment"
    set_build_metadata "deployment:aws_lambda:${function_name}:result" "failed"
    return 1
  fi

  set_build_metadata "deployment:aws_lambda:${function_name}:result" "promoted"
  set_build_metadata "deployment:aws_lambda:${function_name}:current_version" "${canary_version}"

  # Get previous version for annotation
  local previous_version
  previous_version=$(get_build_metadata "deployment:aws_lambda:${function_name}:previous_version" "")

  create_canary_promotion_annotation "${function_name}" "${alias_name}" "${canary_version}" "${previous_version}"
  log_success "🚀 Canary promoted - 100% traffic now on version ${canary_version}"

  return 0
}

function create_deployment_success_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local previous_version="$3"
  local current_version="$4"
  local deployment_strategy="$5"

  local package_type
  package_type=$(get_build_metadata "deployment:aws_lambda:${function_name}:package_type" "Zip")

  local annotation_body
  annotation_body="🚀 **Lambda Deployment Successful**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`
**Package Type:** \`${package_type}\`
**Strategy:** \`${deployment_strategy}\`

**Version Changes:**
- **Previous:** \`${previous_version:-"(none)"}\`
- **Current:** \`${current_version}\`

Deployment completed successfully and is ready for use."

  create_annotation "success" "aws-lambda-deploy-${function_name}" "${annotation_body}"
}

function create_canary_promotion_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local canary_version="$3"
  local previous_version="$4"

  local package_type
  package_type=$(get_build_metadata "deployment:aws_lambda:${function_name}:package_type" "Zip")

  local canary_weight
  canary_weight=$(get_build_metadata "deployment:aws_lambda:${function_name}:canary_weight" "unknown")

  local annotation_body
  annotation_body="🚀 **Canary Promotion Successful**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`
**Package Type:** \`${package_type}\`

**Promotion Details:**
- **Previous Version:** \`${previous_version:-"(none)"}\`
- **Promoted Version:** \`${canary_version}\`
- **Previous Canary Weight:** \`${canary_weight}\`
- **Current Traffic:** \`100%\`

Canary deployment has been promoted to receive 100% of traffic."

  create_annotation "success" "aws-lambda-deploy-${function_name}" "${annotation_body}"
}

function create_linear_canary_success_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local current_version="$3"
  local previous_version="$4"
  local canary_steps="$5"

  local package_type
  package_type=$(get_build_metadata "deployment:aws_lambda:${function_name}:package_type" "Zip")

  local annotation_body
  annotation_body="🚀 **Linear Canary Deployment Successful**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`
**Package Type:** \`${package_type}\`

**Deployment Details:**
- **Previous Version:** \`${previous_version:-"(none)"}\`
- **Current Version:** \`${current_version}\`
- **Canary Steps:** \`${canary_steps}\`
- **Traffic Distribution:** \`100% on new version\`

Linear canary deployment completed successfully over ${canary_steps} step(s)."

  create_annotation "success" "aws-lambda-deploy-${function_name}" "${annotation_body}"
}
