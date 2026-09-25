#!/usr/bin/env bash
# Validate local deployment settings before starting the identity service.
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
[[ -f .env ]] || { echo "缺少 .env；先复制 .env.example 并填写配置。" >&2; exit 1; }

read_value() {
  local key="$1"
  awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' .env
}

postgres_password="$(read_value POSTGRES_PASSWORD)"
admin_password="$(read_value KC_BOOTSTRAP_ADMIN_PASSWORD)"
hostname="$(read_value KC_HOSTNAME)"
bind_address="$(read_value BIND_ADDRESS)"

if [[ ${#postgres_password} -lt 32 || "$postgres_password" == replace-* ]]; then
  echo "POSTGRES_PASSWORD 必须改为至少 32 字符的独立随机值。" >&2
  exit 1
fi
if [[ ${#admin_password} -lt 32 || "$admin_password" == replace-* || "$admin_password" == "$postgres_password" ]]; then
  echo "KC_BOOTSTRAP_ADMIN_PASSWORD 必须改为至少 32 字符的另一随机值。" >&2
  exit 1
fi
if [[ ! "$hostname" =~ ^https://[^/]+$ || "$hostname" == *example.com* ]]; then
  echo "KC_HOSTNAME 必须是实际公开登录域名的完整 HTTPS URL。" >&2
  exit 1
fi
if [[ -n "$bind_address" && "$bind_address" != 127.0.0.1 ]]; then
  echo "BIND_ADDRESS 必须为 127.0.0.1；由本机 Nginx 对外代理。" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1; then
  docker compose config --quiet
fi
echo "部署配置检查通过。"
