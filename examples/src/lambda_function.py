import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def lambda_handler(event, context):
    """
    Simple Lambda function that demonstrates basic functionality.

    Args:
        event: The event dict that contains the data sent to the Lambda
        context: The context in which the Lambda is executed

    Returns:
        dict: Response with statusCode and body
    """

    logger.info(f"Received event: {json.dumps(event)}")

    log_level = os.environ.get("LOG_LEVEL", "INFO")
    stage = os.environ.get("STAGE", "development")

    name = event.get("name", "World")

    response = {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": f"Hello, {name}!",
                "stage": stage,
                "log_level": log_level,
                "function_version": context.function_version if context else "unknown",
            }
        ),
    }

    logger.info(f"Returning response: {json.dumps(response)}")
    return response

