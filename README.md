# oci-a1-hunter

Oracle Cloud Always Free Ampere A1 VM(Singapore West, `ap-singapore-2`)을 GitHub Actions로 자동 재신청함.

- 사양: `VM.Standard.A1.Flex` 2 OCPU / 12 GB / 부트 100 GB, Ubuntu (Always Free 상한)
- 주기: 매시간 시작, 약 48분 동안 60~90초 간격으로 재시도
- 성공 시: OCI 알림 토픽 `a1-hunter-alert` → `NOTIFY_EMAIL` 로 메일 발송, 이 저장소에 이슈 생성, 워크플로 자동 비활성화
- 필요한 Secrets: `OCI_USER`, `OCI_TENANCY`, `OCI_FINGERPRINT`, `OCI_KEY`, `SSH_PUBLIC_KEY`, `NOTIFY_EMAIL`

※ 개인키는 저장소 Secrets에만 보관함. 파일로 커밋하지 않음.
※ 공개 저장소의 예약 실행은 60일간 저장소 활동이 없으면 GitHub이 자동으로 멈춤 — 멈추면 Actions 탭에서 다시 켜면 됨.
