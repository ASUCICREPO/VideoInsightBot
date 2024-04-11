variable "aws_region" {
  description = "AWS region to create resources"
  default     = "us-east-2"
}

# Define variables
variable "cpu" {
  description = "CPU units for the ECS task"
  default     = 1024
}

variable "memory" {
  description = "Memory in MB for the ECS task"
  default     = 4096
}

variable "os" {
  description = "Operating system for the ECS task"
  default     = "LINUX"
}

variable "cpu_architecture" {
  description = "cpu_architecture for the ECS task"
  default     = "ARM64"
}