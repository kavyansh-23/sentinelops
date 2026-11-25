data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Reports go to a SEPARATE topic, otherwise the agent would trigger itself
resource "aws_sns_topic" "reports" {
  name = "${var.name}-incident-reports"
}

resource "aws_sns_topic_subscription" "reports_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.reports.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_dynamodb_table" "audit" {
  name         = "${var.name}-agent-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"
  range_key    = "ts"

  attribute {
    name = "incident_id"
    type = "S"
  }

  attribute {
    name = "ts"
    type = "S"
  }
}

data "archive_file" "agent" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/agent.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.name}-agent"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "agent" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.llm_secret_arn]
  }
  statement {
    actions = ["logs:FilterLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}:*",
    ]
  }
  statement {
    actions   = ["cloudwatch:GetMetricData"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecs:DescribeServices"]
    resources = ["*"]
  }
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.audit.arn]
  }
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.reports.arn]
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "agent-read-only-tools"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/lambda/${var.name}-agent"
  retention_in_days = 7
}

resource "aws_lambda_function" "agent" {
  function_name    = "${var.name}-agent"
  role             = aws_iam_role.agent.arn
  runtime          = "python3.12"
  handler          = "agent.handler"
  filename         = data.archive_file.agent.output_path
  source_code_hash = data.archive_file.agent.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      LOG_GROUP         = var.log_group_name
      CLUSTER           = var.cluster_name
      SERVICE           = var.service_name
      ALB_ARN_SUFFIX    = var.alb_arn_suffix
      TG_ARN_SUFFIX     = var.target_group_arn_suffix
      REPORT_TOPIC_ARN  = aws_sns_topic.reports.arn
      AUDIT_TABLE       = aws_dynamodb_table.audit.name
      LLM_SECRET_ARN    = var.llm_secret_arn
      LLM_PROVIDER      = var.llm_provider
      LLM_MODEL         = var.llm_model
      STATE_MACHINE_ARN = aws_sfn_state_machine.approval.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.agent]
}

resource "aws_lambda_permission" "from_sns" {
  statement_id  = "AllowAlarmTopic"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.alarm_topic_arn
}

resource "aws_sns_topic_subscription" "agent" {
  topic_arn = var.alarm_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.agent.arn
}

# ---------- Guarded actions: human approval through Step Functions ----------
resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.name}-approval-notify"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "execute" {
  name              = "/aws/lambda/${var.name}-action-execute"
  retention_in_days = 7
}

resource "aws_iam_role" "notify" {
  name               = "${var.name}-approval-notify"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "notify_basic" {
  role       = aws_iam_role.notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notify" {
  name = "notify-minimal"
  role = aws_iam_role.notify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "dynamodb:PutItem", Resource = aws_dynamodb_table.audit.arn },
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.reports.arn },
    ]
  })
}

resource "aws_iam_role" "execute" {
  name               = "${var.name}-action-execute"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execute_basic" {
  role       = aws_iam_role.execute.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "execute" {
  name = "execute-minimal"
  role = aws_iam_role.execute.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "dynamodb:PutItem", Resource = aws_dynamodb_table.audit.arn },
      { Effect = "Allow", Action = ["ecs:DescribeServices", "ecs:ListTaskDefinitions"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = "ecs:UpdateService"
        Resource = "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:service/${var.cluster_name}/${var.service_name}"
      },
    ]
  })
}

resource "aws_lambda_function" "notify" {
  function_name    = "${var.name}-approval-notify"
  role             = aws_iam_role.notify.arn
  runtime          = "python3.12"
  handler          = "actions.notify"
  filename         = data.archive_file.agent.output_path
  source_code_hash = data.archive_file.agent.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      AUDIT_TABLE      = aws_dynamodb_table.audit.name
      REPORT_TOPIC_ARN = aws_sns_topic.reports.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify]
}

resource "aws_lambda_function" "execute" {
  function_name    = "${var.name}-action-execute"
  role             = aws_iam_role.execute.arn
  runtime          = "python3.12"
  handler          = "actions.execute"
  filename         = data.archive_file.agent.output_path
  source_code_hash = data.archive_file.agent.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      AUDIT_TABLE = aws_dynamodb_table.audit.name
      CLUSTER     = var.cluster_name
      SERVICE     = var.service_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.execute]
}

data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name}-approval-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

resource "aws_iam_role_policy" "sfn" {
  name = "invoke-two-lambdas"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = [aws_lambda_function.notify.arn, aws_lambda_function.execute.arn]
    }]
  })
}

resource "aws_sfn_state_machine" "approval" {
  name     = "${var.name}-approval"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Human approval gate for agent-proposed fixes"
    StartAt = "RequestApproval"
    States = {
      RequestApproval = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.notify.arn
          Payload      = { "input.$" = "$", "token.$" = "$$.Task.Token" }
        }
        TimeoutSeconds = 900
        ResultPath     = "$.approval"
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotApproved" }]
        Next           = "Execute"
      }
      Execute = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.execute.arn
          "Payload.$"  = "$"
        }
        ResultSelector = { "payload.$" = "$.Payload" }
        ResultPath     = "$.result"
        End            = true
      }
      NotApproved = { Type = "Pass", End = true }
    }
  })
}

resource "aws_iam_role_policy" "agent_start_approval" {
  name = "start-approval-workflow"
  role = aws_iam_role.agent.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.approval.arn
    }]
  })
}
