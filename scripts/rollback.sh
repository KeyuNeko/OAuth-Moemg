#!/usr/bin/env bash
# Restore a pre-update database dump and the matching Git revision.
# Usage: scripts/rollback.sh backups/20260101T000000Z-before-v1.2.3.dump <previous-git-ref>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法：$0 <更新前备份.dump> <更新前 Git 引用>" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
backup_file="$1"
previous_ref="$2"

[[ -f "$backup_file" ]] || { echo "找不到数据库备份：$backup_file" >&2; exit 1; }
git rev-parse --verify "$previous_ref^{commit}" >/dev/null
[[ -z "$(git status --porcelain)" ]] || { echo "工作区有未提交修改，停止回滚。" >&2; exit 1; }
docker compose version >/dev/null

echo "停止登录服务并恢复数据库。这会覆盖备份之后的数据库变更。"
docker compose stop keycloak
git switch --detach "$previous_ref"
docker compose up -d postgres
docker compose exec -T postgres sh -c 'exec pg_restore --clean --if-exists --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$backup_file"
docker compose up -d --force-recreate keycloak

host_port="$(docker compose port keycloak 8080 | sed -E 's/.*:([0-9]+)$/\1/')"
[[ "$host_port" =~ ^[0-9]+$ ]] || { echo "无法读取 Keycloak 本机端口。" >&2; exit 1; }
for attempt in $(seq 1 60); do
  if curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:$host_port/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
    echo "回滚完成：$previous_ref"
    exit 0
  fi
  sleep 3
done
echo "数据库已恢复，但登录服务未通过检查；请查看 docker compose logs keycloak。" >&2
exit 1
