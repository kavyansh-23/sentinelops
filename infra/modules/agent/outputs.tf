output "function_name" {
  value = aws_lambda_function.agent.function_name
}

output "audit_table" {
  value = aws_dynamodb_table.audit.name
}
