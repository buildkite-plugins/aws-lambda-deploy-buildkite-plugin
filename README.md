# AWS Lambda Deploy Buildkite Plugin

A Buildkite plugin for deploying AWS Lambda functions with alias management, health checks, and automatic rollback capabilities.

## Features

- ✅ **Deploy & Rollback**: Deploy new Lambda versions and rollback on failure
- ✅ **Package Types**: Support for both Zip files and Container images
- ✅ **Alias Management**: Manages Lambda aliases for blue/green deployments
- ✅ **Health Checks**: Optional function invocation testing
- ✅ **Auto Rollback**: Automatic rollback on deployment or health check failures
- ✅ **Build Metadata**: Tracks deployment state across pipeline steps
- ✅ **Annotations**: Creates detailed deployment and rollback annotations

## Example

This example deploys a Lambda function from a zip file.

```yaml
steps:
  - label: ":rocket: Deploy Lambda"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-function"
          alias: "production" 
          mode: "deploy"
          zip-file: "function.zip"
```

## Quick Start

### Basic Zip File Deployment

Add the following to your `pipeline.yml`:

```yaml
steps:
  - label: ":rocket: Deploy Lambda"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-function"
          alias: "production"
          mode: "deploy"
          zip-file: "function.zip"
          region: "us-east-1"

  - block: ":thinking_face: Review deployment"

  - label: ":leftwards_arrow_with_hook: Rollback assessment"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-function"
          alias: "production"
          mode: "rollback"
          region: "us-east-1"
```

### Container Image Deployment

```yaml
steps:
  - label: ":rocket: Deploy Lambda container"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-container-function"
          alias: "production"
          mode: "deploy"
          package-type: "Image"
          image-uri: "123456789012.dkr.ecr.us-east-1.amazonaws.com/my-function:latest"
          region: "us-east-1"
          auto-rollback: true
          health-check-enabled: true
```

## Configuration

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `function-name` | AWS Lambda function name |
| `alias` | Lambda alias to manage (e.g., "production", "staging") |
| `mode` | Operation mode: `deploy` or `rollback` |

### Deploy Mode Parameters

#### Package Configuration

| Parameter | Type | Description | Required |
|-----------|------|-------------|----------|
| `package-type` | String | Package type: `Zip` or `Image` | No (default: `Zip`) |

**For Zip packages (choose one):**

| Parameter | Type | Description |
|-----------|------|-------------|
| `zip-file` | String | Path to local zip file |
| `s3-bucket` + `s3-key` | String | S3 location of zip file |
| `s3-object-version` | String | S3 object version (optional) |

**For Container images:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `image-uri` | String | ECR image URI |
| `image-config` | Object | Container configuration (entrypoint, command, working-directory) |

#### Function Configuration

| Parameter | Type | Description |
|-----------|------|-------------|
| `runtime` | String | Lambda runtime (for Zip packages) |
| `handler` | String | Function handler (for Zip packages) |
| `timeout` | Integer | Function timeout in seconds |
| `memory-size` | Integer | Memory allocation in MB |
| `description` | String | Function description |
| `environment` | Object | Environment variables |

#### Health Checks & Rollback

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `auto-rollback` | Boolean | `false` | Enable automatic rollback on failure |
| `health-check-enabled` | Boolean | `false` | Enable health check testing |
| `health-check-timeout` | Integer | `300` | Health check timeout in seconds |
| `health-check-payload` | String | `{}` | JSON payload for test invocation |
| `health-check-expected-status` | Integer | `200` | Expected HTTP status code |

### Common Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `region` | String | AWS region |

## How It Works

### Deploy Mode

1. **Capture Current State**: Records the current alias target for potential rollback
2. **Update Function Code**: Publishes new Lambda version with provided package
3. **Wait for Active**: Ensures the new version becomes active
4. **Update Configuration**: Applies any function configuration changes
5. **Health Checks**: Runs optional health checks on the new version
6. **Update Alias**: Points the alias to the new version
7. **Post-deployment Checks**: Final health validation
8. **Auto Rollback**: Automatically rolls back if any step fails (when enabled)

### Rollback Mode

The rollback mode assesses the deployment state and takes appropriate action:

- **Failed Deployment**: Rolls back alias to previous version and deletes failed version
- **Successful Deployment**: Creates success annotation
- **Manual Rollback**: Allows manual rollback regardless of deployment state

### Build Metadata

The plugin uses Buildkite build metadata to track deployment state:

- `deployment:aws_lambda:current_version` - Current Lambda version
- `deployment:aws_lambda:previous_version` - Previous version for rollback
- `deployment:aws_lambda:result` - Deployment result (success/failed/rolled_back)
- `deployment:aws_lambda:package_type` - Package type used
- `deployment:aws_lambda:auto_rollback` - Whether auto-rollback was triggered

## Examples

See the [examples](examples/) directory for complete pipeline configurations:

- [deploy-zip-file.yml](examples/deploy-zip-file.yml) - Deploy from local zip file
- [deploy-s3.yml](examples/deploy-s3.yml) - Deploy from S3-stored package
- [deploy-container.yml](examples/deploy-container.yml) - Deploy container image
- [manual-rollback.yml](examples/manual-rollback.yml) - Manual rollback operation

## Advanced Usage

### Environment Variables

You can use Buildkite environment variables in your configuration:

```yaml
plugins:
  - aws-lambda-deploy:
      function-name: "my-function"
      alias: "production"
      mode: "deploy"
      s3-key: "releases/${BUILDKITE_BUILD_NUMBER}/function.zip"
      description: "Deployed from build ${BUILDKITE_BUILD_NUMBER}"
```

### Multi-Stage Deployments

```yaml
steps:
  # Deploy to staging
  - label: ":rocket: Deploy to staging"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-function"
          alias: "staging"
          mode: "deploy"
          zip-file: "function.zip"

  # Manual approval
  - block: ":thinking_face: Approve production deployment"

  # Deploy to production
  - label: ":rocket: Deploy to production"
    plugins:
      - aws-lambda-deploy#v1.0.0:
          function-name: "my-function"
          alias: "production"
          mode: "deploy"
          zip-file: "function.zip"
          auto-rollback: true
          health-check-enabled: true
```

## Requirements

- AWS CLI v2
- jq
- Appropriate AWS IAM permissions for Lambda operations

### Required IAM Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:GetFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:PublishVersion",
        "lambda:GetAlias",
        "lambda:UpdateAlias",
        "lambda:CreateAlias",
        "lambda:DeleteFunction",
        "lambda:InvokeFunction"
      ],
      "Resource": "arn:aws:lambda:*:*:function:*"
    }
  ]
}
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add my feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

MIT License - see [LICENSE](LICENSE) file for details.

