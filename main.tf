provider "aws" {
    region = "${var.aws_region}"
}

resource "aws_vpc" "video-insight-bot_terraform_vpc" {
    cidr_block = "12.0.0.0/16"
    tags = {
        Name = "video-insight-botVPCTerraform"
    }
}

resource "aws_subnet" "video-insight-bot_public_subnet1" {
    vpc_id                  = aws_vpc.video-insight-bot_terraform_vpc.id
    cidr_block              = "12.0.1.0/24"
    availability_zone       = "${var.aws_region}a"
}

resource "aws_subnet" "video-insight-bot_public_subnet2" {
    vpc_id                  = aws_vpc.video-insight-bot_terraform_vpc.id
    cidr_block              = "12.0.2.0/24"
    availability_zone       = "${var.aws_region}b"
}

resource "aws_internet_gateway" "video-insight-bot_terraform_igw" {
    vpc_id = aws_vpc.video-insight-bot_terraform_vpc.id
}

resource "aws_route_table" "video-insight-bot_terraform_route_table" {
    vpc_id = aws_vpc.video-insight-bot_terraform_vpc.id
}

resource "aws_route" "video-insight-bot_public_subnet" {
    route_table_id         = aws_route_table.video-insight-bot_terraform_route_table.id
    destination_cidr_block = "0.0.0.0/0"
    gateway_id             = aws_internet_gateway.video-insight-bot_terraform_igw.id
}

resource "aws_route_table_association" "video-insight-bot_public_subnet_association" {
    subnet_id      = aws_subnet.video-insight-bot_public_subnet1.id
    route_table_id = aws_route_table.video-insight-bot_terraform_route_table.id
}

resource "aws_route_table_association" "video-insight-bot_public_subnet_association2" {
    subnet_id      = aws_subnet.video-insight-bot_public_subnet2.id
    route_table_id = aws_route_table.video-insight-bot_terraform_route_table.id
}


resource "aws_ecr_repository" "video-insight-bot_ecr" {
  name                 = "video-insight-bot-ecr"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "video-insight-bot_ecr_lifecycle_policy" {
    repository = aws_ecr_repository.video-insight-bot_ecr.name

    policy = <<EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Expire images older than 30 days",
            "selection": {
                "tagStatus": "any",
                "countType": "sinceImagePushed",
                "countUnit": "days",
                "countNumber": 30
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF
}


data "aws_caller_identity" "current" {}

resource "null_resource" "docker_build_and_push" {
  provisioner "local-exec" {
    command = <<EOF
      aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
      docker build -t video-insight-bot-ecr .
      docker tag video-insight-bot-ecr:latest ${aws_ecr_repository.video-insight-bot_ecr.repository_url}:latest
      docker push ${aws_ecr_repository.video-insight-bot_ecr.repository_url}:latest
    EOF
  }

  triggers = {
    docker_file = md5(file("${path.module}/Dockerfile"))
  }
}

# Create ECS Task Role
resource "aws_iam_role" "video-insight-bot_task_role" {
  name = "video-insight-bot-task-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "video-insight-bot_task_role_policy_attachment" {
  role       = aws_iam_role.video-insight-bot_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Create ECS Task Execution Role
resource "aws_iam_role" "video-insight-bot_task_execution_role" {
  name = "video-insight-bot-task-execution-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "video-insight-bot_task_execution_role_policy_attachment" {
  role       = aws_iam_role.video-insight-bot_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "video-insight-bot_task_execution_role_s3_policy_attachment" {
  role       = aws_iam_role.video-insight-bot_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "video-insight-bot_task_execution_role_bedrock_policy_attachment" {
  role       = aws_iam_role.video-insight-bot_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
}
resource "aws_cloudwatch_log_group" "video-insight-bot_log_group" {
  name = "/ecs/video-insight-bot"
}


resource "aws_ecs_task_definition" "video-insight-bot_task_definition" {
  family                   = "video-insight-bot-task-definition"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.video-insight-bot_task_execution_role.arn
  task_role_arn            = aws_iam_role.video-insight-bot_task_role.arn

  runtime_platform {
    cpu_architecture        = "${var.cpu_architecture}"
    operating_system_family = "${var.os}"
  }

  container_definitions = <<DEFINITION
[
  {
    "name": "video-insight-bot-container",
    "image": "${aws_ecr_repository.video-insight-bot_ecr.repository_url}:latest",
    "portMappings": [
      {
        "name": "8000",
        "containerPort": 8000,
        "hostPort": 8000,
        "protocol": "tcp",
        "appProtocol": "http"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${aws_cloudwatch_log_group.video-insight-bot_log_group.name}",
        "awslogs-region": "${var.aws_region}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
DEFINITION
}

resource "aws_ecs_cluster" "video-insight-bot_cluster" {
  name = "water-bot-cluster"
}

resource "aws_ecs_service" "video-insight-bot_service" {
  name            = "video-insight-bot-service"
  cluster         = aws_ecs_cluster.video-insight-bot_cluster.id
  task_definition = aws_ecs_task_definition.video-insight-bot_task_definition.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.video-insight-bot_public_subnet1.id, aws_subnet.video-insight-bot_public_subnet2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.video-insight-bot_service_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.video-insight-bot_tg.arn
    container_name   = "video-insight-bot-container"
    container_port   = 8000
  }

  depends_on = [aws_lb.video-insight-bot_lb]
}




resource "aws_security_group" "video-insight-bot_lb_sg" {
  name        = "video-insight-bot-lb-security-group"
  description = "Security group for video-insight-bot load balancer"
  vpc_id      = aws_vpc.video-insight-bot_terraform_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}




resource "aws_security_group" "video-insight-bot_service_sg" {
  name        = "video-insight-bot-service-security-group"
  description = "Security group for video-insight-bot ECS service"
  vpc_id      = aws_vpc.video-insight-bot_terraform_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.video-insight-bot_lb_sg.id]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_lb" "video-insight-bot_lb" {
  name               = "video-insight-bot-lb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.video-insight-bot_lb_sg.id]
  subnets            = [aws_subnet.video-insight-bot_public_subnet1.id, aws_subnet.video-insight-bot_public_subnet2.id]
}
resource "aws_lb_target_group" "video-insight-bot_tg" {
  name        = "video-insight-bot-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.video-insight-bot_terraform_vpc.id
  target_type = "ip"

  health_check {
    path = "/"
  }
}

# Create Listener
resource "aws_lb_listener" "video-insight-bot_listener" {
  load_balancer_arn = aws_lb.video-insight-bot_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.video-insight-bot_tg.arn
  }
}

output "video-insight-bot_lb_dns_name" {
  description = "The DNS name of the video-insight-bot Load Balancer"
  value       = aws_lb.video-insight-bot_lb.dns_name
}

