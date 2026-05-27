# GPU 서버 모니터링 스택 설치 가이드

> **대상 독자**: 현장 방문 설치 엔지니어  
> **설치 환경**: Airgap GPU 서버 (인터넷 차단, Docker 설치 완료)  
> **소요 시간**: 약 30~60분

---

## 📦 반입 파일 확인

설치 전 아래 번들 파일이 USB(또는 전달 매체)에 있는지 확인합니다.

```
gpu_monitoring_bundle.tar.gz
```

압축 해제 후 아래 구조여야 합니다:

```
gpu_monitoring/
├── images/                        ← Docker 이미지 tar 파일 5개
│   ├── prometheus.tar
│   ├── grafana.tar
│   ├── node-exporter.tar
│   ├── cadvisor.tar
│   └── dcgm-exporter.tar
├── compose/
│   ├── docker-compose.yml
│   └── .env                       ← ★ 현장에서 수정하는 파일
├── prometheus/
│   └── prometheus.yml
├── grafana/
│   ├── provisioning/
│   │   ├── datasources/prometheus.yml
│   │   └── dashboards/dashboards.yml
│   └── dashboards/
│       ├── 01-container-list.json
│       ├── 02-host-resources.json
│       └── 03-gpu-resources.json
└── scripts/
    └── deploy.sh                  ← 자동 배포 스크립트
```

---

## ✅ STEP 0. 사전 조건 점검

설치 전 GPU 서버에서 아래 항목을 반드시 확인합니다.

### 0-1. Docker 동작 확인

```bash
docker version
docker ps
```

**기대 결과**: Docker Engine 버전 출력, 오류 없음

---

### 0-2. NVIDIA 드라이버 확인

```bash
nvidia-smi
```

**기대 결과** (예시):
```
+-----------------------------------------------------------------------------+
| NVIDIA-SMI 535.xx    Driver Version: 535.xx    CUDA Version: 12.x          |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA A100 ...      Off | 00000000:xx:xx.0 Off |                    0 |
+-----------------------------------------------------------------------------+
```

> ❌ `nvidia-smi` 명령이 없거나 오류가 나면 NVIDIA 드라이버가 설치되지 않은 것입니다.  
> → GPU 메트릭(DCGM Exporter)을 제외한 나머지는 정상 설치 가능합니다.  
> → 드라이버 설치는 [STEP 0-4](#0-4-nvidia-container-toolkit-확인) 참고

---

### 0-3. 포트 사용 여부 확인

기본 포트가 이미 사용 중인지 확인합니다.

```bash
ss -tlnp | grep -E ':3000|:9090|:9100|:8080|:9400'
```

**기대 결과**: 아무 출력도 없으면 모든 포트 사용 가능

> ⚠️ 이미 사용 중인 포트가 있으면 `.env` 파일에서 해당 포트 번호를 변경합니다.  
> 예: `GRAFANA_PORT=3001`

---

### 0-4. NVIDIA Container Toolkit 확인

GPU 컨테이너가 GPU에 접근하려면 `nvidia-container-toolkit`이 필요합니다.

```bash
# 설치 여부 확인
dpkg -l | grep nvidia-container-toolkit 2>/dev/null || \
  rpm -qa | grep nvidia-container 2>/dev/null || \
  echo "미설치"
```

설치된 경우, 컨테이너에서 GPU가 보이는지 테스트:

```bash
docker run --rm --gpus all --entrypoint nvidia-smi \
  nvcr.io/nvidia/k8s/dcgm-exporter:latest
```

> ❌ 오류 발생 시: DCGM Exporter 컨테이너만 실패하며, 나머지 모니터링은 정상 동작합니다.  
> 설치 후 `docker compose restart dcgm-exporter` 로 재시작하면 됩니다.

---

### 0-5. 디스크 파티션 확인 ★

모니터링할 파티션 경로를 미리 파악합니다.

```bash
df -h
```

**출력 예시**:
```
Filesystem              Size  Used Avail Use% Mounted on
/dev/mapper/root-lv      98G   72G   20G  79% /
/dev/sdb1               3.6T  2.1T  1.4T  60% /data
/dev/sdc1               7.2T  6.8T  200G  97% /mnt/model_weights
tmpfs                    63G     0   63G   0% /dev/shm
```

> ★ 위 예시에서 `/` (79%), `/data` (60%), `/mnt/model_weights` (**97% — 위험!**) 이 모니터링 대상입니다.  
> 이 경로들은 STEP 2에서 `.env` 파일에 입력합니다.

---

## 🚀 STEP 1. 파일 압축 해제

USB(또는 전달 매체)의 번들을 서버에 복사한 후 압축 해제합니다.

```bash
# 작업 디렉토리로 이동 (원하는 경로로 변경 가능)
cd /opt
# 또는
cd /home/<username>

# 압축 해제
tar -xzf gpu_monitoring_bundle.tar.gz

# 디렉토리 이동
cd gpu_monitoring

# 파일 확인
ls -lh images/
```

**기대 결과**:
```
-rw-r--r-- 1 ... prometheus.tar     (~150MB)
-rw-r--r-- 1 ... grafana.tar        (~350MB)
-rw-r--r-- 1 ... node-exporter.tar  (~14MB)
-rw-r--r-- 1 ... cadvisor.tar       (~31MB)
-rw-r--r-- 1 ... dcgm-exporter.tar  (~300MB)
```

---

## ⚙️ STEP 2. 환경변수 설정 (`.env` 수정) ★★

**이 단계가 가장 중요합니다.** GPU 서버 환경에 맞게 `.env` 파일을 수정합니다.

```bash
vi compose/.env
# 또는
nano compose/.env
```

### 반드시 확인·수정할 항목

```env
# ── [필수] 디스크 모니터링 대상 경로 ──────────────────────
# STEP 0-5에서 확인한 위협 파티션 경로를 | 로 구분하여 입력
# 예시: /, /data, /mnt/model_weights 를 모니터링하려면:
DISK_MONITOR_PATHS=^(/|/data|/mnt/model_weights)$

# ── [권장] Grafana 관리자 비밀번호 변경 ───────────────────
GF_ADMIN_PASSWORD=변경할비밀번호

# ── [필요시] 포트 충돌이 있으면 변경 ─────────────────────
GRAFANA_PORT=3000
PROMETHEUS_PORT=9090
```

### `DISK_MONITOR_PATHS` 작성 규칙

| 모니터링 경로 | DISK_MONITOR_PATHS 값 |
|---|---|
| `/` 만 | `^(/)$` |
| `/`, `/data` | `^(/\|/data)$` |
| `/`, `/data`, `/mnt/weights` | `^(/\|/data\|/mnt/weights)$` |
| 전체 (`tmpfs` 제외) | `.+` |

---

## 📥 STEP 3. Docker 이미지 로드

```bash
# gpu_monitoring 디렉토리에서 실행
docker load -i images/prometheus.tar    && echo "✅ prometheus"
docker load -i images/grafana.tar       && echo "✅ grafana"
docker load -i images/node-exporter.tar && echo "✅ node-exporter"
docker load -i images/cadvisor.tar      && echo "✅ cadvisor"
docker load -i images/dcgm-exporter.tar && echo "✅ dcgm-exporter"
```

**기대 결과**: 각 줄에 `Loaded image: ...` 메시지와 `✅` 출력

```bash
# 로드 확인
docker images | grep -E "prometheus|grafana|node-exporter|cadvisor|dcgm"
```

---

## ▶️ STEP 4. 스택 구동

```bash
cd compose
docker compose --env-file .env up -d
```

**기대 결과**:
```
 ✔ Container prometheus     Started
 ✔ Container node-exporter  Started
 ✔ Container cadvisor       Started
 ✔ Container dcgm-exporter  Started
 ✔ Container grafana        Started
```

컨테이너 상태 확인:

```bash
docker compose ps
```

**기대 결과** (모든 컨테이너 `running` 상태):
```
NAME             IMAGE                              STATUS
cadvisor         gcr.io/cadvisor/cadvisor:latest    Up (healthy)
dcgm-exporter    nvcr.io/nvidia/k8s/dcgm-exporter   Up
grafana          grafana/grafana:latest              Up (healthy)
node-exporter    prom/node-exporter:latest           Up
prometheus       prom/prometheus:latest              Up (healthy)
```

---

## 🔍 STEP 5. 동작 검증

### 5-1. Exporter 메트릭 응답 확인

```bash
# Node Exporter (호스트 리소스)
curl -s http://localhost:9100/metrics | grep "node_cpu_seconds_total" | head -3

# cAdvisor (컨테이너 메트릭)
curl -s http://localhost:8080/metrics | grep "container_cpu_usage" | head -3

# DCGM Exporter (GPU 메트릭)
curl -s http://localhost:9400/metrics | grep "DCGM_FI_DEV_GPU_TEMP" | head -3

# Prometheus 상태
curl -s http://localhost:9090/-/healthy
```

**기대 결과**:
- 상위 3개: 메트릭 데이터 출력
- Prometheus: `Prometheus Server is Healthy.`

---

### 5-2. Prometheus Targets 확인

브라우저 또는 curl로 확인:

```bash
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['labels']['job'], '->', t['health'], t['scrapeUrl'])
"
```

**기대 결과** (모두 `up`):
```
cadvisor      -> up  http://cadvisor:8080/metrics
dcgm-exporter -> up  http://dcgm-exporter:9400/metrics
node-exporter -> up  http://node-exporter:9100/metrics
prometheus    -> up  http://prometheus:9090/metrics
```

---

### 5-3. Grafana 대시보드 접속

브라우저에서 접속:

```
http://<서버 IP>:3000
```

> 서버 IP 확인: `hostname -I | awk '{print $1}'`

로그인:
- **ID**: `admin`
- **PW**: `.env`에서 설정한 `GF_ADMIN_PASSWORD` 값

**확인 항목**:
1. 좌측 메뉴 → `Dashboards` → `GPU Server` 폴더
2. 아래 3개 대시보드가 목록에 있어야 함:
   - `① 컨테이너 목록`
   - `② 서버 리소스`
   - `③ GPU 리소스`
3. 각 대시보드 클릭 → 데이터가 표시되는지 확인

---

## 🛠️ 문제 해결

### ❌ 컨테이너가 `Exited` 상태

```bash
# 로그 확인
docker compose logs <컨테이너명>
# 예: docker compose logs dcgm-exporter
```

---

### ❌ DCGM Exporter가 계속 재시작됨

**원인**: NVIDIA Container Toolkit 미설치 또는 GPU 드라이버 문제

```bash
docker compose logs dcgm-exporter | tail -20
```

**임시 조치**: DCGM Exporter를 제외하고 나머지만 구동

```bash
docker compose --env-file .env up -d prometheus grafana node-exporter cadvisor
```

> GPU 메트릭을 제외한 모든 모니터링은 정상 동작합니다.

---

### ❌ Grafana 대시보드가 `No data` 표시

**원인 1**: Prometheus가 아직 데이터를 수집 중 (구동 직후 1~2분 소요)
- 해결: 1~2분 기다린 후 새로고침

**원인 2**: Prometheus Targets에 `down` 상태 항목이 있음
```bash
# Targets 상태 재확인
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import json,sys; [print(t['labels']['job'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
```

**원인 3**: Grafana Datasource 설정 오류
- Grafana 접속 → `Connections` → `Data sources` → `Prometheus` → `Save & test` 클릭

---

### ❌ Prometheus Target이 `connection refused`

**원인**: 컨테이너가 `monitoring` 네트워크에 연결되지 않음

```bash
# 네트워크 확인
docker network inspect compose_monitoring

# 컨테이너 재시작
docker compose --env-file .env down && docker compose --env-file .env up -d
```

---

### ❌ 디스크 대시보드에 파티션이 안 보임

**원인**: `.env`의 `DISK_MONITOR_PATHS` 경로가 실제 마운트 경로와 다름

현재 수집 중인 마운트 경로 확인:
```bash
curl -s http://localhost:9100/metrics | grep 'node_filesystem_size_bytes{' | \
  grep -v 'tmpfs\|overlay' | awk -F'"' '{for(i=1;i<=NF;i++) if($i=="mountpoint") print $(i+2)}'
```

출력된 경로로 `.env` 수정 후 재시작:
```bash
# .env 수정 후
docker compose --env-file .env restart grafana
```

---

## 📋 설치 완료 체크리스트

설치 후 아래 항목을 모두 확인하고 서명합니다.

| # | 확인 항목 | 결과 |
|---|---|---|
| 1 | `docker compose ps` — 5개 컨테이너 모두 `Up` 상태 | ☐ |
| 2 | `curl http://localhost:9100/metrics` — 응답 있음 | ☐ |
| 3 | `curl http://localhost:8080/metrics` — 응답 있음 | ☐ |
| 4 | `curl http://localhost:9400/metrics` — 응답 있음 | ☐ |
| 5 | `curl http://localhost:9090/-/healthy` — `Healthy` 응답 | ☐ |
| 6 | Prometheus Targets 페이지 — 4개 모두 `UP` | ☐ |
| 7 | Grafana 로그인 — 3개 대시보드 목록 확인 | ☐ |
| 8 | `① 컨테이너 목록` 대시보드 — 컨테이너 데이터 표시 | ☐ |
| 9 | `② 서버 리소스` 대시보드 — CPU/Mem/Disk 데이터 표시 | ☐ |
| 10 | `③ GPU 리소스` 대시보드 — GPU 온도/사용률 데이터 표시 | ☐ |
| 11 | `.env` 비밀번호 변경 완료 | ☐ |
| 12 | 서버 담당자에게 접속 URL 및 계정 인수인계 완료 | ☐ |

---

## 📌 설치 후 운영 참고

### 서비스 관리 명령어

```bash
# 스택 시작
cd /opt/gpu_monitoring/compose   # 설치 경로에 맞게 변경
docker compose --env-file .env up -d

# 스택 중지
docker compose --env-file .env down

# 특정 컨테이너만 재시작
docker compose --env-file .env restart grafana

# 로그 확인
docker compose logs -f prometheus
docker compose logs -f grafana

# 전체 상태
docker compose ps
```

### 서버 재부팅 시

`docker-compose.yml`의 모든 컨테이너에 `restart: unless-stopped`가 설정되어 있으므로,  
**서버 재부팅 시 Docker 데몬이 시작되면 자동으로 컨테이너가 재구동됩니다.**

Docker 자동 시작 설정 확인:
```bash
systemctl is-enabled docker
# 결과가 'enabled'이면 정상
```

### 데이터 보존

- Prometheus 수집 데이터: **15일** 보존 (Docker volume `compose_prometheus_data`)
- Grafana 설정 데이터: 영구 보존 (Docker volume `compose_grafana_data`)
- 데이터 위치: `docker volume inspect compose_prometheus_data`

---

## 📞 문의

설치 중 해결되지 않는 문제 발생 시 아래로 연락:

| 항목 | 내용 |
|---|---|
| 담당팀 | _(기입)_ |
| 연락처 | _(기입)_ |
| 원격 지원 가능 여부 | _(기입)_ |
