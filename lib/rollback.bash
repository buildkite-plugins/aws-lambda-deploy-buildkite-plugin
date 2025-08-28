#!/usr/bin/env bash
set -euo pipefail

trap 'echo "^^^ +++"; echo "Exit status $? at line $LINENO from: $BASH_COMMAND"' ERR

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/plugin.bash
. "${DIR}/plugin.bash"

function rollback_lambda() {
  local function_name="$1"
  local alias_name="$2"
  local aws_args=("${@:3}")

  log_header ":lambda: Starting Lambda rollback assessment for ${function_name}"

  # Get deployment metadata
  local deployment_result
  deployment_result=$(get_build_metadata "deployment:aws_lambda:result" "unknown")

  local current_version
  current_version=$(get_build_metadata "deployment:aws_lambda:current_version" "")

  local previous_version
  previous_version=$(get_build_metadata "deployment:aws_lambda:previous_version" "")

  local previous_arn
  # shellcheck disable=SC2034
  previous_arn=$(get_build_metadata "deployment:aws_lambda:previous_arn" "")

  local auto_rollback
  auto_rollback=$(get_build_metadata "deployment:aws_lambda:auto_rollback" "false")

  log_info "Deployment result: ${deployment_result}"
  log_info "Current version: ${current_version}"
  log_info "Previous version: ${previous_version}"
  log_info "Auto rollback triggered: ${auto_rollback}"

  case "${deployment_result}" in
  "failed")
    log_header ":lambda: Deployment failed, performing rollback"
    if ! perform_rollback "${function_name}" "${alias_name}" "${previous_version}" "${current_version}" "${aws_args[@]+${aws_args[@]}}"; then
      log_error "Rollback failed"
      create_rollback_failed_annotation "${function_name}" "${alias_name}" "${current_version}" "${previous_version}"
      return 1
    fi

    create_rollback_success_annotation "${function_name}" "${alias_name}" "${current_version}" "${previous_version}"
    log_success ":leftwards_arrow_with_hook: Rollback completed successfully"
    ;;
  "success")
    log_header ":lambda: Deployment succeeded, creating success annotation"
    create_deployment_success_annotation "${function_name}" "${alias_name}" "${previous_version}" "${current_version}"
    log_success ":white_check_mark: Deployment was successful, no rollback needed"
    ;;
  *)
    log_warning "Unknown deployment result: ${deployment_result}"
    if [[ -n "${current_version}" && -n "${previous_version}" ]]; then
      log_header ":lambda: Performing manual rollback"
      if ! perform_rollback "${function_name}" "${alias_name}" "${previous_version}" "${current_version}" "${aws_args[@]+${aws_args[@]}}"; then
        log_error "Manual rollback failed"
        create_rollback_failed_annotation "${function_name}" "${alias_name}" "${current_version}" "${previous_version}"
        return 1
      fi

      create_rollback_success_annotation "${function_name}" "${alias_name}" "${current_version}" "${previous_version}"
      log_success ":leftwards_arrow_with_hook: Manual rollback completed successfully"
    else
      log_warning "Insufficient metadata for rollback"
      create_annotation "warning" "lambda-rollback" \
        "⚠️ **Lambda Rollback Warning**\n\nInsufficient deployment metadata found for function \`${function_name}\`.\nCannot perform automatic rollback."
      return 1
    fi
    ;;
  esac

  return 0
}

function perform_rollback() {
  local function_name="$1"
  local alias_name="$2"
  local rollback_version="$3"
  local failed_version="$4"
  local aws_args=("${@:5}")

  if [[ -z "${rollback_version}" ]]; then
    log_warning "No previous version found, cannot rollback"
    return 1
  fi

  log_info "Rolling back alias ${alias_name} from version ${failed_version} to version ${rollback_version}"

  # Update alias to point to previous version
  if ! aws lambda update-alias \
    "${aws_args[@]+${aws_args[@]}}" \
    --function-name "${function_name}" \
    --name "${alias_name}" \
    --function-version "${rollback_version}"; then
    log_error "Failed to update alias during rollback"
    return 1
  fi

  log_success "Alias ${alias_name} updated to point to version ${rollback_version}"

  if [[ -n "${failed_version}" && "${failed_version}" != "\$LATEST" ]]; then
    log_info ":information_source: Failed version ${failed_version} preserved for analysis"
    log_info "To manually delete later: aws lambda delete-function --function-name ${function_name} --qualifier ${failed_version}"
    set_build_metadata "deployment:aws_lambda:failed_version_preserved" "${failed_version}"
  fi

  # Update metadata to reflect rollback
  set_build_metadata "deployment:aws_lambda:result" "rolled_back"
  set_build_metadata "deployment:aws_lambda:rollback_completed" "true"

  return 0
}

function create_deployment_success_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local previous_version="$3"
  local current_version="$4"

  local package_type
  package_type=$(get_build_metadata "deployment:aws_lambda:package_type" "Zip")

  local annotation_body
  annotation_body="🚀 **Lambda Deployment Successful**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`
**Package Type:** \`${package_type}\`

**Version Changes:**
- **Previous:** \`${previous_version:-"(none)"}\`
- **Current:** \`${current_version}\`

Deployment completed successfully and is ready for use."

  create_annotation "success" "lambda-deployment" "${annotation_body}"
}

function create_rollback_success_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local failed_version="$3"
  local rollback_version="$4"

  local package_type
  package_type=$(get_build_metadata "deployment:aws_lambda:package_type" "Zip")

  local annotation_body
  annotation_body="↩️ **Lambda Rollback Successful**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`
**Package Type:** \`${package_type}\`

**Rollback Details:**
- **Failed Version:** \`${failed_version}\` (preserved for analysis)
- **Restored Version:** \`${rollback_version}\`

The deployment has been rolled back due to failures during deployment or health checks."

  create_annotation "warning" "lambda-rollback" "${annotation_body}"
}

function create_rollback_failed_annotation() {
  local function_name="$1"
  local alias_name="$2"
  local failed_version="$3"
  local intended_rollback_version="$4"

  local annotation_body
  annotation_body="❌ **Lambda Rollback Failed**

**Function:** \`${function_name}\`
**Alias:** \`${alias_name}\`

**Rollback Attempt:**
- **Failed Version:** \`${failed_version}\`
- **Intended Rollback Version:** \`${intended_rollback_version}\`

**Action Required:** Manual intervention needed to restore the function to a working state."

  create_annotation "error" "lambda-rollback-failed" "${annotation_body}"
}
