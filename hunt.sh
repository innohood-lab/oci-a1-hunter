#!/usr/bin/env bash
# Oracle Cloud Always Free A1 VM 자동 신청 (Singapore West, ap-singapore-2)
# GitHub Actions에서 실행됨. 성공하면 OCI 알림(이메일)과 GitHub 이슈로 알리고 종료 코드 10을 반환함.
set -uo pipefail

: "${OCI_TENANCY:?}" "${NOTIFY_EMAIL:?}"
NAME="${VM_NAME:-llm-wiki-server}"
OCPUS="${VM_OCPUS:-2}"
MEM="${VM_MEM_GB:-12}"
BOOT_GB="${VM_BOOT_GB:-100}"
RUN_MINUTES="${RUN_MINUTES:-50}"
SSH_PUB_FILE="$HOME/.oci/ssh_key.pub"
TEN="$OCI_TENANCY"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }
q() { local v; v="$("$@" 2>/dev/null)"; [ "$v" = "null" ] && v=""; echo "$v"; }

existing_vm() {
  q oci compute instance list --compartment-id "$TEN" --display-name "$NAME" \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].id | [0]' --raw-output
}

ensure_topic() {
  TOPIC_ID=$(q oci ons topic list --compartment-id "$TEN" --name a1-hunter-alert --query 'data[0]."topic-id"' --raw-output)
  if [ -z "$TOPIC_ID" ]; then
    TOPIC_ID=$(q oci ons topic create --compartment-id "$TEN" --name a1-hunter-alert \
      --description "A1 VM hunter success alert" --query 'data."topic-id"' --raw-output)
    log "알림 토픽 생성: ${TOPIC_ID:-실패}"
  fi
  [ -z "$TOPIC_ID" ] && return 0
  SUB=$(q oci ons subscription list --compartment-id "$TEN" --topic-id "$TOPIC_ID" \
    --query "data[?endpoint=='$NOTIFY_EMAIL'].\"lifecycle-state\" | [0]" --raw-output)
  if [ -z "$SUB" ]; then
    oci ons subscription create --compartment-id "$TEN" --topic-id "$TOPIC_ID" \
      --protocol EMAIL --subscription-endpoint "$NOTIFY_EMAIL" >/dev/null 2>&1 \
      && log "이메일 구독 생성 — $NOTIFY_EMAIL 로 온 확인 메일에서 Confirm 필요"
  else
    log "이메일 구독 상태: $SUB"
  fi
}

ensure_network() {
  VCN_ID=$(q oci network vcn list --compartment-id "$TEN" --display-name a1-vcn --lifecycle-state AVAILABLE --query 'data[0].id' --raw-output)
  if [ -z "$VCN_ID" ]; then
    VCN_ID=$(q oci network vcn create --compartment-id "$TEN" --cidr-block 10.0.0.0/16 --display-name a1-vcn \
      --dns-label a1vcn --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  fi
  [ -z "$VCN_ID" ] && return 1
  IGW_ID=$(q oci network internet-gateway list --compartment-id "$TEN" --vcn-id "$VCN_ID" --query 'data[0].id' --raw-output)
  if [ -z "$IGW_ID" ]; then
    IGW_ID=$(q oci network internet-gateway create --compartment-id "$TEN" --vcn-id "$VCN_ID" --is-enabled true \
      --display-name a1-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  fi
  RT_ID=$(q oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output)
  oci network route-table update --rt-id "$RT_ID" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_ID\"}]" >/dev/null 2>&1
  SUBNET_ID=$(q oci network subnet list --compartment-id "$TEN" --vcn-id "$VCN_ID" --display-name a1-subnet --query 'data[0].id' --raw-output)
  if [ -z "$SUBNET_ID" ]; then
    SUBNET_ID=$(q oci network subnet create --compartment-id "$TEN" --vcn-id "$VCN_ID" --cidr-block 10.0.0.0/24 \
      --display-name a1-subnet --dns-label a1sub --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  fi
  [ -n "$SUBNET_ID" ]
}

ensure_image_ad() {
  for ver in 24.04 22.04; do
    IMAGE_ID=$(q oci compute image list --compartment-id "$TEN" --operating-system "Canonical Ubuntu" \
      --operating-system-version "$ver" --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
      --limit 1 --query 'data[0].id' --raw-output)
    [ -n "$IMAGE_ID" ] && break
  done
  ADS=$(q oci iam availability-domain list --compartment-id "$TEN" --query 'join(`,`, data[].name)' --raw-output)
  [ -n "$IMAGE_ID" ] && [ -n "$ADS" ]
}

notify_success() {
  local id="$1" ip="$2"
  local msg="Oracle A1 VM 생성 성공! 이름: $NAME / ${OCPUS} OCPU / ${MEM}GB / 부트 ${BOOT_GB}GB / 리전 ap-singapore-2 / 공인 IP: ${ip:-콘솔에서 확인} / 접속: ssh -i ~/.ssh/oci_a1_ed25519 ubuntu@${ip}"
  [ -n "${TOPIC_ID:-}" ] && oci ons message publish --topic-id "$TOPIC_ID" --title "[OCI] A1 VM 생성 성공" --body "$msg" >/dev/null 2>&1
  echo "$msg" > success.txt
  log "$msg"
}

# ---------- main ----------
ensure_topic

id=$(existing_vm)
if [ -n "$id" ]; then log "이미 '$NAME' VM 있음 ($id) — 더 신청하지 않음"; exit 10; fi

if ! ensure_network; then log "네트워크 준비 실패"; exit 1; fi
if ! ensure_image_ad; then log "이미지/가용성 도메인 조회 실패"; exit 1; fi
log "준비 완료. 사양 ${OCPUS} OCPU / ${MEM}GB / 부트 ${BOOT_GB}GB, AD: $ADS"

end=$(( $(date +%s) + RUN_MINUTES*60 ))
attempt=0; other=0
while [ "$(date +%s)" -lt "$end" ]; do
  IFS=',' read -ra AD_LIST <<< "$ADS"
  for AD in "${AD_LIST[@]}"; do
    attempt=$((attempt+1))
    out=$(oci --no-retry --read-timeout 120 compute instance launch --availability-domain "$AD" --compartment-id "$TEN" \
      --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
      --image-id "$IMAGE_ID" --subnet-id "$SUBNET_ID" --assign-public-ip true \
      --boot-volume-size-in-gbs "$BOOT_GB" --display-name "$NAME" \
      --ssh-authorized-keys-file "$SSH_PUB_FILE" --query 'data.id' --raw-output 2>&1)
    if [ $? -eq 0 ] && [[ "$out" == ocid1.instance* ]]; then
      log "★ 성공 (시도 ${attempt}회): $out"
      ip=""
      for _ in $(seq 1 12); do
        sleep 20
        ip=$(q oci compute instance list-vnics --instance-id "$out" --query 'data[0]."public-ip"' --raw-output)
        [ -n "$ip" ] && break
      done
      notify_success "$out" "$ip"
      exit 10
    fi
    if grep -qiE 'capacity' <<< "$out"; then
      other=0; log "용량 부족 (시도 ${attempt}회, $AD)"
      sleep $((60 + RANDOM % 30))
    elif grep -qiE 'TooManyRequests|429' <<< "$out"; then
      other=0; log "요청 제한(429) — 3분 대기"; sleep 180
    elif grep -qiE 'LimitExceeded' <<< "$out"; then
      log "무료 한도 초과 오류 — 사양 또는 기존 자원 확인 필요: $(tr '\n' ' ' <<< "$out" | cut -c1-300)"; exit 1
    else
      other=$((other+1)); log "기타 오류 (연속 ${other}회): $(tr '\n' ' ' <<< "$out" | cut -c1-300)"
      [ "$other" -ge 5 ] && exit 1
      sleep 120
    fi
  done
done
log "이번 실행 종료 (시도 ${attempt}회). 다음 예약 실행에서 계속함."
exit 0
