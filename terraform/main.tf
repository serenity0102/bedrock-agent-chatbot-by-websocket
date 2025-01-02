# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lambda_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for Lambda to access Bedrock and API Gateway
resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_execution_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:*",
          "execute-api:*",
          "logs:*"
        ]
        Resource = "*"
      }
    ]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "."
  output_path = "lambda.zip"
}



# Lambda Function
resource "aws_lambda_function" "agent_chat" {
  filename         = "lambda.zip"
  function_name    = "bedrock-agent-chat"
  role            = aws_iam_role.lambda_role.arn
  handler         = "app.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  publish         = true
  runtime         = "python3.9"
  timeout         = 600  # 10 minutes in seconds
  memory_size     = 256  # Increased memory for longer running processes

  environment {
    variables = {
      AGENT_ID     = "AHI8QU5ELZ"
      AGENT_ALIAS  = "4DTQI5D9JW"
      
      # AGENT_ALIAS  = "LEK3LQJD1Q" 
    }
  }
}

# API Gateway WebSocket API
resource "aws_apigatewayv2_api" "websocket" {
  name                       = "agent-chat-websocket"
  protocol_type             = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}
# CloudWatch Log Group for API Gateway
resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.websocket.name}"
  retention_in_days = 7
}


# IAM Role for API Gateway Logging
resource "aws_iam_role" "apigateway_cloudwatch" {
  name = "apigateway-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "apigateway.amazonaws.com"
      }
    }]
  })
}
# Attach CloudWatch logging policy to the role
resource "aws_iam_role_policy_attachment" "apigateway_cloudwatch" {
  role       = aws_iam_role.apigateway_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}
# IAM Policy for CloudWatch Logging
resource "aws_iam_role_policy" "apigateway_cloudwatch" {
  name = "apigateway-cloudwatch-policy"
  role = aws_iam_role.apigateway_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
        "logs:GetLogEvents",
        "logs:FilterLogEvents"
      ]
      Resource = "*"
    }]
  })
}


# Update API Gateway Account Settings
resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigateway_cloudwatch.arn
}



# API Gateway Stage
resource "aws_apigatewayv2_stage" "prod" {
  api_id = aws_apigatewayv2_api.websocket.id
  name   = "prod"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    logging_level           = "INFO"
    data_trace_enabled      = true
    throttling_burst_limit  = 5000
    throttling_rate_limit   = 10000
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
     requestId               = "$context.requestId"
      sourceIp               = "$context.identity.sourceIp"
      requestTime            = "$context.requestTime"
      protocol              = "$context.protocol"
      routeKey              = "$context.routeKey"
      status                = "$context.status"
      responseLength        = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
      connectionId          = "$context.connectionId"
      messageId             = "$context.messageId"
      requestBody           = "$context.requestBody"        # Log request body
      responseBody          = "$context.responseBody"       # Log response body
      errorMessage          = "$context.error.message"
      errorResponseType     = "$context.error.responseType"
      integrationLatency    = "$context.integration.latency"
      integrationStatus     = "$context.integration.status"
      integrationErrorMessage = "$context.integration.error"
      }
    )
  }

  depends_on = [aws_api_gateway_account.main]
}

# Lambda Integration for Connect
resource "aws_apigatewayv2_integration" "connect" {
  api_id           = aws_apigatewayv2_api.websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.agent_chat.invoke_arn
}

# Lambda Integration for Disconnect
resource "aws_apigatewayv2_integration" "disconnect" {
  api_id           = aws_apigatewayv2_api.websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.agent_chat.invoke_arn
}

# Lambda Integration for Messages
resource "aws_apigatewayv2_integration" "message" {
  api_id           = aws_apigatewayv2_api.websocket.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.agent_chat.invoke_arn
}

# Routes
resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.connect.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.disconnect.id}"
}

resource "aws_apigatewayv2_route" "message" {
  api_id    = aws_apigatewayv2_api.websocket.id
  route_key = "sendmessage"
  target    = "integrations/${aws_apigatewayv2_integration.message.id}"
}

# Lambda Permission for API Gateway
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent_chat.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.websocket.execution_arn}/*/*"
}

# Outputs
output "websocket_url" {
  value = "${aws_apigatewayv2_stage.prod.invoke_url}"
}
