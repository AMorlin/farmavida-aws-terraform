#!/bin/bash
# Boot das instâncias web da FarmaVida (Amazon Linux 2023, arm64).
# Sobe um nginx que responde qual instância e qual AZ atenderam a requisição,
# o que deixa visível o balanceamento do ALB entre as duas zonas.
set -euo pipefail

dnf install -y nginx

# IMDSv2 (o launch template exige token)
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCIA=$(meta instance-id)
ZONA=$(meta placement/availability-zone)
TIPO=$(meta instance-type)

cat > /usr/share/nginx/html/index.html <<HTML
<!doctype html>
<html lang="pt-BR">
<head><meta charset="utf-8"><title>FarmaVida</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 640px; margin: 64px auto; color: #1f2a44">
  <h1>FarmaVida — loja online</h1>
  <p>Página servida por <strong>${INSTANCIA}</strong> (${TIPO}) na zona <strong>${ZONA}</strong>.</p>
  <p>Recarregue algumas vezes: o Application Load Balancer alterna entre as instâncias das duas AZs.</p>
</body>
</html>
HTML

# Health check do target group
printf 'ok\n' > /usr/share/nginx/html/health

systemctl enable --now nginx
