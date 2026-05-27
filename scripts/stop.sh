#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════
#  stop.sh
#  [GPU 서버에서 실행] 모니터링 스택 중지
#
#  Usage:
#    bash scripts/stop.sh                # 컨테이너만 중지 (데이터 보존)
#    bash scripts/stop.sh --purge        # 컨테이너 + 볼륨(수집 데이터) 삭제
#    bash scripts/stop.sh --purge-all    # 컨테이너 + 볼륨 + 이미지 전체 삭제
#    bash scripts/stop.sh --status       # 현재 상태만 확인
# ════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_DIR="$ROOT_DIR/compose"

MODE="${1:-stop}"

print_section() { echo ""; echo "━━━ $1 ━━━"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
info() { echo "  ℹ️  $*"; }

# ── 현재 상태 출력 ──────────────────────────────────────────
show_status() {
  print_section "현재 컨테이너 상태"
  cd "$COMPOSE_DIR"
  docker compose ps 2>/dev/null || echo "  (실행 중인 컨테이너 없음)"

  print_section "볼륨 목록"
  docker volume ls --filter name=compose_ 2>/dev/null | grep -v "^DRIVER" || echo "  (볼륨 없음)"
}

# ── 컨테이너 중지 (데이터 보존) ─────────────────────────────
do_stop() {
  print_section "모니터링 스택 중지"
  cd "$COMPOSE_DIR"

  running=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l)
  if [ "$running" -eq 0 ]; then
    info "이미 중지된 상태입니다."
    return
  fi

  echo "  중지 대상 컨테이너:"
  docker compose ps --services --filter status=running 2>/dev/null | sed 's/^/    - /'

  docker compose --env-file .env down
  ok "모든 컨테이너 중지 완료"
  info "수집 데이터(볼륨)는 보존됩니다. 재시작하면 이어서 사용 가능합니다."
  info "재시작: bash scripts/deploy.sh --up-only"
}

# ── 컨테이너 + 볼륨 삭제 ────────────────────────────────────
do_purge() {
  print_section "스택 중지 및 볼륨(수집 데이터) 삭제"
  warn "Prometheus 수집 데이터와 Grafana 설정이 모두 삭제됩니다."
  warn "이 작업은 되돌릴 수 없습니다."
  echo ""

  cd "$COMPOSE_DIR"
  docker compose --env-file .env down --volumes --remove-orphans
  ok "컨테이너 및 볼륨 삭제 완료"
}

# ── 컨테이너 + 볼륨 + 이미지 전체 삭제 ─────────────────────
do_purge_all() {
  print_section "스택 전체 삭제 (컨테이너 + 볼륨 + 이미지)"
  warn "모든 데이터와 이미지가 삭제됩니다."
  warn "재설치 시 images/*.tar를 다시 로드해야 합니다."
  echo ""

  cd "$COMPOSE_DIR"
  source .env 2>/dev/null || true
  docker compose --env-file .env down --volumes --remove-orphans --rmi all 2>/dev/null || true
  ok "컨테이너, 볼륨, 이미지 삭제 완료"
}

# ── 메인 ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " GPU 서버 모니터링 스택 중지"
echo " 모드: $MODE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "$MODE" in
  --status)
    show_status
    ;;
  --purge)
    show_status
    do_purge
    ;;
  --purge-all)
    show_status
    do_purge_all
    ;;
  stop|*)
    show_status
    do_stop
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 완료. 수집 데이터는 그대로 보존됩니다."
    echo ""
    echo " 옵션 안내:"
    echo "   bash scripts/stop.sh              # 중지만 (데이터 보존)"
    echo "   bash scripts/stop.sh --purge      # 중지 + 데이터 삭제"
    echo "   bash scripts/stop.sh --purge-all  # 중지 + 데이터 + 이미지 삭제"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;
esac
