variable "name" {
  type = string
}

variable "alarm_topic_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "llm_secret_arn" {
  type = string
}

variable "llm_provider" {
  type    = string
  default = "gemini"
}

variable "llm_model" {
  type    = string
  default = ""
}

variable "alert_email" {
  type    = string
  default = ""
}
