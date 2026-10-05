# ---------------------------------------------------------------- Launch Template

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${local.nome}-app-"
  image_id      = data.aws_ami.al2023_arm64.id
  instance_type = var.instance_type
  user_data     = filebase64("${path.module}/../../app/user_data.sh")

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true # chave aws/ebs: dispensa grants de KMS para o Auto Scaling
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true # métricas de 1 min para reagir rápido a picos
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.nome}-app" }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.nome}-app" }
  }
}

# ---------------------------------------------------------------- ALB

resource "aws_lb" "web" {
  name                       = "${local.nome}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.publica[*].id
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.nome}-tg"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = aws_vpc.principal.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Área administrativa nunca é servida pela internet: só via Session Manager (port forwarding)
resource "aws_lb_listener_rule" "bloqueia_admin" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Acesso restrito a rede interna"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/admin", "/admin/*"]
    }
  }
}

# ---------------------------------------------------------------- Auto Scaling Group

resource "aws_autoscaling_group" "app" {
  name                      = "${local.nome}-asg"
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  desired_capacity          = var.asg_min
  vpc_zone_identifier       = aws_subnet.app[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50 # troca de AMI/user_data sem derrubar o site
    }
  }

  dynamic "tag" {
    for_each = {
      Projeto  = "ecommerce-farmavida"
      Grupo    = var.grupo
      Ambiente = var.ambiente
      Owner    = var.owner
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Escala pela carga real: mantém ~50% de CPU média (sobe em minutos na Black Friday)
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${local.nome}-cpu-50"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

# E por requisições por instância (pico de acessos antes de a CPU subir)
resource "aws_autoscaling_policy" "requisicoes" {
  name                   = "${local.nome}-req-por-alvo"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.web.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 1000
  }
}
