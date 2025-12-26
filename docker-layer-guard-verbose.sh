#!/usr/bin/env bash
set -euo pipefail

# ===== 可配置项 =====
THRESHOLD_GB="${1:-100}"                         # 超过多少 GB 就停用
THRESHOLD_BYTES=$(( THRESHOLD_GB * 1024 * 1024 * 1024 ))

TOPN="${TOPN:-15}"                               # verbose: 打印 TopN 大目录/文件夹
DETAIL_DEPTH="${DETAIL_DEPTH:-2}"                # verbose: du -d 深度（建议 2~3）

LOG_FILE="${LOG_FILE:-/var/log/docker-layer-guard.log}"

# ===== 工具函数 =====
ts() { date '+%F %T%z'; }

log() {
  # 同时写日志和 stdout（systemd 下会进 journal）
  echo "[$(ts)] $*" | tee -a "$LOG_FILE" >/dev/null
}

die() {
  log "FATAL: $*"
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "请用 root 运行（sudo）。因为需要读取 /var/lib/docker 下的 UpperDir 目录做 du。"
  fi
}

bytes_to_gib() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}

cmd() {
  # verbose 执行器：打印命令 + 返回码
  log "CMD: $*"
  set +e
  "$@"
  local rc=$?
  set -e
  log "RC: $rc"
  return $rc
}

print_top_usage() {
  local upper="$1"
  log "DETAIL: Top ${TOPN} entries under UpperDir (depth=${DETAIL_DEPTH}) -> $upper"
  # -x: 不跨文件系统（UpperDir 自身一般是同 FS，防止奇怪挂载）
  # --apparent-size 不用：我们要真实占用，因此保留默认块占用
  # sort -nr: 按字节降序
  # head -n TOPN
  cmd du -x -b -d "$DETAIL_DEPTH" "$upper" 2>/dev/null \
    | sort -nr \
    | head -n "$TOPN" \
    | awk '{printf("  - %s bytes\t%s\n",$1,$2)}' \
    | tee -a "$LOG_FILE" >/dev/null || true
}

# ===== 主流程 =====
main() {
  require_root

  command -v docker >/dev/null 2>&1 || die "docker 命令不存在"
  command -v du >/dev/null 2>&1 || die "du 命令不存在"

  local driver
  driver="$(docker info --format '{{.Driver}}' 2>/dev/null || true)"
  [[ -n "$driver" ]] || die "docker info 失败，无法获取 storage driver"

  # overlay2 才用 UpperDir 这套
  if [[ "$driver" != "overlay2" && "$driver" != "overlay" ]]; then
    die "当前 storage driver=$driver，本脚本只适配 overlay/overlay2（避免误判）。"
  fi

  log "===== docker-layer-guard (verbose) start ====="
  log "Config: threshold=${THRESHOLD_GB}GB (${THRESHOLD_BYTES} bytes), TOPN=$TOPN, depth=$DETAIL_DEPTH, driver=$driver"
  log "DockerRootDir=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo unknown)"

  # 扫描所有容器（运行+停止）
  local total=0 skipped=0 checked=0 tripped=0
  local cid

  while read -r cid; do
    [[ -z "$cid" ]] && continue
    total=$((total+1))

    # 支持 label 跳过
    local ignore
    ignore="$(docker inspect -f '{{ index .Config.Labels "size.guard.ignore" }}' "$cid" 2>/dev/null || true)"
    if [[ "$ignore" == "true" ]]; then
      skipped=$((skipped+1))
      log "SKIP: ${cid:0:12} reason=label size.guard.ignore=true"
      continue
    fi

    local name running upper
    name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')"
    running="$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")"
    upper="$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' "$cid" 2>/dev/null || true)"

    if [[ -z "$upper" ]]; then
      skipped=$((skipped+1))
      log "SKIP: $name (${cid:0:12}) reason=UpperDir empty"
      continue
    fi
    if [[ ! -d "$upper" ]]; then
      skipped=$((skipped+1))
      log "SKIP: $name (${cid:0:12}) reason=UpperDir not exists: $upper"
      continue
    fi

    checked=$((checked+1))

    # 统计实际占用（字节）
    local bytes gb
    bytes="$(du -s --block-size=1 "$upper" 2>/dev/null | awk '{print $1}' || echo 0)"
    gb="$(bytes_to_gib "$bytes")"

    log "CHECK: name=$name id=${cid:0:12} running=$running"
    log "      UpperDir=$upper"
    log "      WritableUsed=${bytes} bytes (${gb} GiB)"

    # 超阈值处理
    if (( bytes > THRESHOLD_BYTES )); then
      tripped=$((tripped+1))
      log "ALERT: $name (${cid:0:12}) writable layer ${gb}GiB > ${THRESHOLD_GB}GB"

      # 打印 TopN 占用，帮你定位是谁写爆
      print_top_usage "$upper"

      # 停用策略：先取消 restart，再 stop
      cmd docker update --restart=no "$cid" || true

      if [[ "$running" == "true" ]]; then
        cmd docker stop --time 30 "$cid" || true
        log "ACTION: disabled (restart=no) + stopped container=$name id=${cid:0:12}"
      else
        log "ACTION: disabled (restart=no) container already stopped: $name id=${cid:0:12}"
      fi
    fi

  done < <(docker ps -a -q)

  log "SUMMARY: total=$total checked=$checked skipped=$skipped tripped=$tripped"
  log "===== docker-layer-guard (verbose) done ====="
}

main "$@"
