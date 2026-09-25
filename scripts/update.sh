#!/usr/bin/env bash
# Run from a privileged, local operations session (for example, a BT scheduled task).
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
umask 077
bash scripts/preflight.sh

for command in git docker curl; do
  command -v "$command" >/dev/null || { echo "缺少命令：$command" >&2; exit 1; }
done
docker compose version >/dev/null
[[ -f .env ]] || { echo "缺少 .env" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "工作区有未提交修改，停止更新。" >&2; exit 1; }

latest="$(git ls-remote --tags --refs origin 'v*' | awk '{sub("refs/tags/", "", $2); if ($2 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) print $2}' | sort -V | tail -n 1)"
[[ -n "$latest" ]] || { echo "没有可用的 vX.Y.Z 发布标签。" >&2; exit 1; }
current="$(git describe --tags --exact-match 2>/dev/null || true)"
if [[ "$current" == "$latest" ]]; then
  echo "已经是 $latest，无需更新。"
  exit 0
fi

previous_ref="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
previous_commit="$(git rev-parse HEAD)"
git fetch origin "refs/tags/$latest:refs/tags/$latest"
if ! git merge-base --is-ancestor "$previous_commit" "$latest"; then
  echo "当前版本不是 $latest 的祖先，停止更新以避免降级或覆盖分叉。" >&2
  exit 1
fi
backup_dir="$project_dir/backups"
mkdir -p "$backup_dir"
backup_file="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-before-$latest.dump"

echo "备份 PostgreSQL 到 $backup_file"
if ! docker compose exec -T postgres sh -c 'exec pg_dump -Fc -U "$POSTGRES_USER" "$POSTGRES_DB"' > "$backup_file"; then
  rm -f -- "$backup_file"
  echo "数据库备份失败，未执行更新。" >&2
  exit 1
fi
printf '%s\n' "$previous_ref" > "$backup_file.previous-ref"

echo "获取 $latest 并更新容器"
git switch --detach "$latest"
if ! docker compose pull || ! docker compose up -d --remove-orphans; then
  echo "容器更新失败。数据库备份：$backup_file" >&2
  echo "回滚命令：bash scripts/rollback.sh '$backup_file' '$previous_ref'" >&2
  exit 1
fi

host_port="$(docker compose port keycloak 8080 | sed -E 's/.*:([0-9]+)$/\1/')"
[[ "$host_port" =~ ^[0-9]+$ ]] || { echo "无法读取 Keycloak 本机端口。" >&2; exit 1; }
healthy=0
for attempt in $(seq 1 60); do
  if curl --silent --show-error --fail --max-time 5 "http://127.0.0.1:$host_port/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 3
done

if [[ "$healthy" -ne 1 ]]; then
  echo "更新后登录服务未通过检查。数据库备份：$backup_file" >&2
  echo "先查看 docker compose logs keycloak；必要时执行 bash scripts/rollback.sh '$backup_file' '$previous_ref'。" >&2
  exit 1
fi

echo "更新完成：$latest"
echo "更新前 Git 引用：$previous_ref"
echo "数据库备份：$backup_file"
