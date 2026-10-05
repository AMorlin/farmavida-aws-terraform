# ---------------------------------------------------------------- VPC e subnets
# 10.0.0.0/16 -> públicas 10.0.1-2.0/24 · app 10.0.11-12.0/24 · dados 10.0.21-22.0/24
# Blocos /24 por camada deixam espaço para novas camadas e AZs sem renumerar.

resource "aws_vpc" "principal" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.nome}-vpc" }
}

resource "aws_subnet" "publica" {
  count                   = 2
  vpc_id                  = aws_vpc.principal.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1 + count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # nada recebe IP público por padrão; só ALB e NAT ficam aqui
  tags                    = { Name = "${local.nome}-publica-${count.index == 0 ? "a" : "b"}", Camada = "publica" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.principal.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11 + count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.nome}-app-${count.index == 0 ? "a" : "b"}", Camada = "app" }
}

resource "aws_subnet" "dados" {
  count             = 2
  vpc_id            = aws_vpc.principal.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 21 + count.index)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.nome}-dados-${count.index == 0 ? "a" : "b"}", Camada = "dados" }
}

# ---------------------------------------------------------------- Internet e NAT (um por AZ)

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nome}-igw" }
}

resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
  tags   = { Name = "${local.nome}-nat-eip-${count.index == 0 ? "a" : "b"}" }
}

# NAT por AZ: se uma AZ cair, a outra continua com saída para a internet (requisito de 99,9%)
resource "aws_nat_gateway" "nat" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.publica[count.index].id
  tags          = { Name = "${local.nome}-nat-${count.index == 0 ? "a" : "b"}" }
  depends_on    = [aws_internet_gateway.igw]
}

# ---------------------------------------------------------------- Tabelas de rota

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.nome}-rt-publica" }
}

resource "aws_route_table_association" "publica" {
  count          = 2
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table" "app" {
  count  = 2
  vpc_id = aws_vpc.principal.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }
  tags = { Name = "${local.nome}-rt-app-${count.index == 0 ? "a" : "b"}" }
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Camada de dados sem rota para a internet (nem via NAT): banco isolado
resource "aws_route_table" "dados" {
  vpc_id = aws_vpc.principal.id
  tags   = { Name = "${local.nome}-rt-dados" }
}

resource "aws_route_table_association" "dados" {
  count          = 2
  subnet_id      = aws_subnet.dados[count.index].id
  route_table_id = aws_route_table.dados.id
}

# Gateway endpoint do S3 (gratuito): tráfego app -> S3 não passa pelo NAT (custo e segurança)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.principal.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${local.nome}-vpce-s3" }
}

# ---------------------------------------------------------------- NACL da camada de dados
# Segunda barreira (stateless) além do SG: só PostgreSQL vindo das subnets de app

resource "aws_network_acl" "dados" {
  vpc_id     = aws_vpc.principal.id
  subnet_ids = aws_subnet.dados[*].id

  dynamic "ingress" {
    for_each = aws_subnet.app
    content {
      rule_no    = 100 + ingress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = ingress.value.cidr_block
      from_port  = 5432
      to_port    = 5432
    }
  }

  # Replicação síncrona Multi-AZ entre as subnets de dados
  ingress {
    rule_no    = 200
    protocol   = "-1"
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 7, 10) # 10.0.20.0/23 = dados-a + dados-b
    from_port  = 0
    to_port    = 0
  }

  dynamic "egress" {
    for_each = aws_subnet.app
    content {
      rule_no    = 100 + egress.key
      protocol   = "tcp"
      action     = "allow"
      cidr_block = egress.value.cidr_block
      from_port  = 1024
      to_port    = 65535 # portas efêmeras de retorno
    }
  }

  egress {
    rule_no    = 200
    protocol   = "-1"
    action     = "allow"
    cidr_block = cidrsubnet(var.vpc_cidr, 7, 10)
    from_port  = 0
    to_port    = 0
  }

  tags = { Name = "${local.nome}-nacl-dados" }
}
