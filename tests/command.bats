#!/usr/bin/env bats

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  # Stub buildkite-agent command for metadata operations
  stub buildkite-agent \
    "meta-data set * * : echo Setting metadata" \
    "meta-data get * : echo" \
    "meta-data exists * : exit 1" \
    "annotate --style * --context * * : echo Annotation created"

  # Stub jq command for JSON parsing
  stub jq \
    "-r .Version : echo 1" \
    "-r '.Version' : echo 1"
}

teardown() {
  if command -v unstub >/dev/null 2>&1; then
    unstub aws || true
    unstub buildkite-agent || true
    unstub jq || true
  fi
}

@test "Missing function-name fails" {
  unset BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Missing function-name'
}

@test "Missing alias fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  unset BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Missing alias'
}

@test "Missing mode fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  unset BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Missing mode'
}

@test "Invalid mode fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='invalid'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Invalid mode: invalid'
}

@test "Deploy mode with Zip package but missing zip-file and S3 details fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE='Zip'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'either zip-file or s3-bucket+s3-key must be specified'
}

@test "Deploy mode with Image package but missing image-uri fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE='Image'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'image-uri must be specified'
}

@test "Invalid package type fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE='Invalid'

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Invalid package-type: Invalid'
}

@test "Function does not exist fails" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='nonexistent-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='rollback'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE='test.zip'

  stub aws \
    "lambda get-function --function-name nonexistent-function --query Configuration.FunctionName --output text : exit 1"

  run "$PWD"/hooks/post-command

  assert_failure
  assert_output --partial 'Function nonexistent-function does not exist and mode is rollback'
}

@test "Deploy mode with zip-file succeeds" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE='/tmp/test.zip'

  # Create test zip file
  echo "test" >/tmp/test.zip

  stub aws \
    "lambda get-function --function-name test-function --query Configuration.FunctionName --output text : echo test-function" \
    "lambda get-alias --function-name test-function --name test --query FunctionVersion --output text : exit 1" \
    "lambda update-function-code --function-name test-function --publish --zip-file fileb:///tmp/test.zip : echo '{\"Version\":\"$LATEST\"}'" \
    "lambda publish-version --function-name test-function --description * : echo '{\"Version\":\"1\"}'" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.State --output text : echo Active" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.FunctionArn --output text : echo arn:aws:lambda:us-east-1:123456789012:function:test-function:1" \
    "lambda update-alias --function-name test-function --name test --function-version 1 : echo '{\"FunctionVersion\":\"1\"}'"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial '--- ✅ Deployment Result'
  assert_output --partial 'Deploy of test-function to test completed successfully'
}

@test "Deploy mode with S3 details succeeds" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_BUCKET='test-bucket'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_S3_KEY='test-key'

  stub aws \
    "lambda get-function --function-name test-function --query Configuration.FunctionName --output text : echo test-function" \
    "lambda get-alias --function-name test-function --name test --query FunctionVersion --output text : exit 1" \
    "lambda update-function-code --function-name test-function --publish --s3-bucket test-bucket --s3-key test-key : echo '{\"Version\":\"$LATEST\"}'" \
    "lambda publish-version --function-name test-function --description * : echo '{\"Version\":\"1\"}'" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.State --output text : echo Active" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.FunctionArn --output text : echo arn:aws:lambda:us-east-1:123456789012:function:test-function:1" \
    "lambda update-alias --function-name test-function --name test --function-version 1 : echo '{\"FunctionVersion\":\"1\"}'"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial '--- ✅ Deployment Result'
  assert_output --partial 'Deploy of test-function to test completed successfully'
}

@test "Deploy mode with image-uri succeeds" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_PACKAGE_TYPE='Image'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_IMAGE_URI='123456789012.dkr.ecr.us-east-1.amazonaws.com/my-func:latest'

  stub aws \
    "lambda get-function --function-name test-function --query Configuration.FunctionName --output text : echo test-function" \
    "lambda get-alias --function-name test-function --name test --query FunctionVersion --output text : exit 1" \
    "lambda update-function-code --function-name test-function --publish --image-uri 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-func:latest : echo '{\"Version\":\"$LATEST\"}'" \
    "lambda publish-version --function-name test-function --description * : echo '{\"Version\":\"1\"}'" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.State --output text : echo Active" \
    "lambda get-function --function-name test-function --qualifier 1 --query Configuration.FunctionArn --output text : echo arn:aws:lambda:us-east-1:123456789012:function:test-function:1" \
    "lambda update-alias --function-name test-function --name test --function-version 1 : echo '{\"FunctionVersion\":\"1\"}'"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial '--- ✅ Deployment Result'
  assert_output --partial 'Deploy of test-function to test completed successfully'
}

@test "Rollback mode succeeds" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='rollback'

  # Override the buildkite-agent stub for this test
  unstub buildkite-agent || true
  stub buildkite-agent \
    "meta-data exists deployment:aws_lambda:test-function:result : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:result : echo success" \
    "meta-data exists deployment:aws_lambda:test-function:current_version : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:current_version : echo 2" \
    "meta-data exists deployment:aws_lambda:test-function:previous_version : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:previous_version : echo 1" \
    "meta-data exists deployment:aws_lambda:test-function:previous_arn : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:previous_arn : echo arn:aws:lambda:us-east-1:123456789012:function:test-function:1" \
    "meta-data exists deployment:aws_lambda:test-function:auto_rollback : exit 1" \
    "meta-data exists deployment:aws_lambda:test-function:package_type : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:package_type : echo Zip" \
    "annotate --style success --context lambda-deployment * : echo Annotation created"

  stub aws \
    "lambda get-function --function-name test-function --query Configuration.FunctionName --output text : echo test-function"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial 'Deployment was successful, no rollback needed'
}

@test "Rollback mode after failed deployment succeeds" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='rollback'

  # Override the buildkite-agent stub for this test
  unstub buildkite-agent || true
  stub buildkite-agent \
    "meta-data exists deployment:aws_lambda:test-function:result : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:result : echo failure" \
    "meta-data exists deployment:aws_lambda:test-function:current_version : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:current_version : echo 2" \
    "meta-data exists deployment:aws_lambda:test-function:previous_version : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:previous_version : echo 1" \
    "meta-data exists deployment:aws_lambda:test-function:auto_rollback : exit 0" \
    "meta-data get deployment:aws_lambda:test-function:auto_rollback : echo true" \
    "annotate --style success --context lambda-deployment * : echo Annotation created"

  stub aws \
    "lambda get-function --function-name test-function --query Configuration.FunctionName --output text : echo test-function" \
    "lambda update-alias --function-name test-function --name test --function-version 1 : echo '{"FunctionVersion":"1"}'"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial '--- ✅ Rollback Result'
  assert_output --partial 'Rollback of test-function on test completed successfully'
}

@test "Region argument is passed to AWS CLI" {
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_FUNCTION_NAME='test-function'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ALIAS='test'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_MODE='deploy'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_ZIP_FILE='/tmp/test.zip'
  export BUILDKITE_PLUGIN_AWS_LAMBDA_DEPLOY_REGION='test-region'

  # Create test zip file
  echo "test" >/tmp/test.zip

  stub aws \
    "lambda get-function --region test-region --function-name test-function --query Configuration.FunctionName --output text : echo test-function" \
    "lambda get-alias --region test-region --function-name test-function --name test --query FunctionVersion --output text : exit 1" \
    "lambda update-function-code --region test-region --function-name test-function --publish --zip-file fileb:///tmp/test.zip : echo '{\"Version\":\"$LATEST\"}'" \
    "lambda publish-version --region test-region --function-name test-function --description * : echo '{\"Version\":\"1\"}'" \
    "lambda get-function --region test-region --function-name test-function --qualifier 1 --query Configuration.State --output text : echo Active" \
    "lambda get-function --region test-region --function-name test-function --qualifier 1 --query Configuration.FunctionArn --output text : echo arn:aws:lambda:us-east-1:123456789012:function:test-function:1" \
    "lambda update-alias --region test-region --function-name test-function --name test --function-version 1 : echo '{\"FunctionVersion\":\"1\"}'"

  run "$PWD"/hooks/post-command

  assert_success
  assert_output --partial '--- ✅ Deployment Result'
  assert_output --partial 'Deploy of test-function to test completed successfully'
}
