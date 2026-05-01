#!/usr/bin/env bash
set -u

CLIENT="clab-dnslab-client"
RESOLVER="clab-dnslab-resolver"
SRV11="clab-dnslab-srv11"
SRV12="clab-dnslab-srv12"
SRV2="clab-dnslab-srv2"

CLIENT_IP="10.10.10.2"
RESOLVER_IP="10.10.10.53"
RESOLVER_UPLINK_IP="10.10.20.53"
SRV11_IP="10.10.20.11"
SRV12_IP="10.10.20.12"
SRV2_IP="10.10.20.2"

WWW_IP="10.10.20.22"
API_IP="10.10.20.23"

TOTAL=0
PASSED=0
FAILED=0

green="\033[32m"
red="\033[31m"
cyan="\033[36m"
dim="\033[2m"
reset="\033[0m"

section() {
  printf "\n${cyan}══════════════════════════════════════════════════════${reset}\n"
  printf "${cyan}  %s${reset}\n" "$1"
  printf "${cyan}══════════════════════════════════════════════════════${reset}\n"
}

show_output() {
  if [ -n "${1:-}" ]; then
    printf "${dim}%s${reset}\n" "$1" | sed 's/^/    /'
  fi
}

pass() {
  PASSED=$((PASSED + 1))
  printf "${green}[PASS]${reset} %s\n" "$1"
  show_output "${2:-}"
}

fail() {
  FAILED=$((FAILED + 1))
  printf "${red}[FAIL]${reset} %s\n" "$1"
  show_output "${2:-}"
}

# Универсальная проверка:
#   check DESC GREP_PATTERN cmd...
#
# Выполняет cmd, показывает вывод,
# проверяет что вывод содержит GREP_PATTERN
# Если GREP_PATTERN пустой ("") — проверяет только exit code
check() {
  local desc="$1"
  local pattern="$2"
  shift 2
  TOTAL=$((TOTAL + 1))

  local out rc
  out=$("$@" 2>&1) || true
  rc=$?

  if [ -z "$pattern" ]; then
    # проверяем только exit code
    if [ $rc -eq 0 ]; then
      pass "$desc" "$out"
    else
      fail "$desc" "$out"
    fi
  else
    if echo "$out" | grep -qE "$pattern"; then
      pass "$desc" "$out"
    else
      fail "$desc" "$out"
    fi
  fi
}

# Проверка равенства двух значений с показом обоих
check_eq() {
  local desc="$1"
  local val1_name="$2"
  local val1="$3"
  local val2_name="$4"
  local val2="$5"
  TOTAL=$((TOTAL + 1))

  local detail="${val1_name}: ${val1}
${val2_name}: ${val2}"

  if [ "$val1" = "$val2" ]; then
    pass "$desc" "$detail"
  else
    fail "$desc" "$detail"
  fi
}

prepare_anchor() {
  docker exec "$CLIENT" rm -f /tmp/my.anchor >/dev/null 2>&1 || true

  local line flags proto alg key anchor_text

  line=$(docker exec "$CLIENT" sh -lc \
    "dig @${RESOLVER_IP} DNSKEY my.lab.test +short | awk '\$1==257 {key=\"\"; for(i=4;i<=NF;i++) key=key \$i; print \$1, \$2, \$3, key; exit}'")

  [ -n "$line" ] || return 1
  read -r flags proto alg key <<< "$line"

  anchor_text="trust-anchors { my.lab.test. static-key ${flags} ${proto} ${alg} \"${key}\"; };"
  docker exec "$CLIENT" sh -c "echo '${anchor_text}' > /tmp/my.anchor"
}

# ─────────────────────────────────────────────────
# Сброс кэша перед тестами
# ─────────────────────────────────────────────────
docker exec "$RESOLVER" rndc flush >/dev/null 2>&1 || true

# ═════════════════════════════════════════════════
section "1. Проверка стенда и адресации"
# ═════════════════════════════════════════════════

for c in "$CLIENT" "$RESOLVER" "$SRV11" "$SRV12" "$SRV2"; do
  check "Контейнер $c запущен" "" \
    sh -c "[ \"\$(docker inspect -f '{{.State.Running}}' $c 2>/dev/null)\" = true ]"
done

check "client: eth1 = ${CLIENT_IP}/24" "${CLIENT_IP}" \
  docker exec "$CLIENT" ip -4 -br a show dev eth1

check "resolver: eth1 = ${RESOLVER_IP}/24" "${RESOLVER_IP}" \
  docker exec "$RESOLVER" ip -4 -br a show dev eth1

check "resolver: eth2 = ${RESOLVER_UPLINK_IP}/24" "${RESOLVER_UPLINK_IP}" \
  docker exec "$RESOLVER" ip -4 -br a show dev eth2

check "srv11: eth1 = ${SRV11_IP}/24" "${SRV11_IP}" \
  docker exec "$SRV11" ip -4 -br a show dev eth1

check "srv12: eth1 = ${SRV12_IP}/24" "${SRV12_IP}" \
  docker exec "$SRV12" ip -4 -br a show dev eth1

check "srv2: eth1 = ${SRV2_IP}/24" "${SRV2_IP}" \
  docker exec "$SRV2" ip -4 -br a show dev eth1

# ═════════════════════════════════════════════════
section "2. DNS-резолвер на выходном шлюзе"
# ═════════════════════════════════════════════════

check "resolver слушает 53/udp" ":53" \
  docker exec "$RESOLVER" ss -lun

check "resolver слушает 53/tcp" ":53" \
  docker exec "$RESOLVER" ss -ltn

check "Клиент резолвит google.com через resolver" "^[0-9]" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} google.com +short

# ═════════════════════════════════════════════════
section "3. Зона lab.test на SRV11 и SRV12"
# ═════════════════════════════════════════════════

check "dig srv11.lab.test -> ${SRV11_IP}" "${SRV11_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} srv11.lab.test +short

check "dig srv12.lab.test -> ${SRV12_IP}" "${SRV12_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} srv12.lab.test +short

check "dig srv2.lab.test -> ${SRV2_IP}" "${SRV2_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} srv2.lab.test +short

check "lab.test NS содержит srv11.lab.test" "srv11\\.lab\\.test" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} lab.test NS +short

check "lab.test NS содержит srv12.lab.test" "srv12\\.lab\\.test" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} lab.test NS +short

# ═════════════════════════════════════════════════
section "4. Синхронизация primary (SRV11) и secondary (SRV12)"
# ═════════════════════════════════════════════════

SERIAL11=$(docker exec "$RESOLVER" dig @${SRV11_IP} lab.test SOA +short 2>/dev/null | awk '{print $3}')
SERIAL12=$(docker exec "$RESOLVER" dig @${SRV12_IP} lab.test SOA +short 2>/dev/null | awk '{print $3}')
check_eq "SOA Serial совпадает" \
  "SRV11" "$SERIAL11" \
  "SRV12" "$SERIAL12"

A11=$(docker exec "$RESOLVER" dig @${SRV11_IP} srv2.lab.test +short 2>/dev/null | tr -d '\r')
A12=$(docker exec "$RESOLVER" dig @${SRV12_IP} srv2.lab.test +short 2>/dev/null | tr -d '\r')
check_eq "srv2.lab.test одинаково отдается обоими серверами" \
  "SRV11" "$A11" \
  "SRV12" "$A12"

NS11=$(docker exec "$RESOLVER" dig @${SRV11_IP} lab.test NS +short 2>/dev/null | sort | tr -d '\r')
NS12=$(docker exec "$RESOLVER" dig @${SRV12_IP} lab.test NS +short 2>/dev/null | sort | tr -d '\r')
check_eq "NS-записи lab.test одинаковы на обоих серверах" \
  "SRV11" "$NS11" \
  "SRV12" "$NS12"

# ═════════════════════════════════════════════════
section "5. Делегирование my.lab.test -> SRV2"
# ═════════════════════════════════════════════════

check "SRV11 отдает referral: my.lab.test NS -> srv2.lab.test" \
  "my\\.lab\\.test\\..*NS.*srv2\\.lab\\.test\\." \
  docker exec "$RESOLVER" dig @${SRV11_IP} my.lab.test NS +norecurse

check "SRV2 authoritative для my.lab.test (SOA)" \
  "srv2\\.lab\\.test\\." \
  docker exec "$RESOLVER" dig @${SRV2_IP} my.lab.test SOA +short

check "dig my.lab.test -> ${SRV2_IP}" "${SRV2_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} my.lab.test +short

check "dig www.my.lab.test -> ${WWW_IP}" "${WWW_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} www.my.lab.test +short

check "dig api.my.lab.test -> ${API_IP}" "${API_IP}" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} api.my.lab.test +short

# ═════════════════════════════════════════════════
section "6. DNSSEC для my.lab.test"
# ═════════════════════════════════════════════════

check "SRV2 отдает RRSIG для my.lab.test" "RRSIG" \
  docker exec "$RESOLVER" dig @${SRV2_IP} my.lab.test +dnssec

check "SRV2 отдает RRSIG для www.my.lab.test" "RRSIG" \
  docker exec "$RESOLVER" dig @${SRV2_IP} www.my.lab.test +dnssec

check "SRV2 отдает DNSKEY (ZSK=256 и KSK=257)" "DNSKEY[[:space:]]+257" \
  docker exec "$RESOLVER" dig @${SRV2_IP} DNSKEY my.lab.test

check "Через resolver видны DNSKEY my.lab.test" "DNSKEY" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} DNSKEY my.lab.test +dnssec

check "В родительской зоне есть DS для my.lab.test" "IN[[:space:]]+DS" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} DS my.lab.test +dnssec

check "Через resolver для www.my.lab.test виден RRSIG" "RRSIG" \
  docker exec "$CLIENT" dig @${RESOLVER_IP} www.my.lab.test +dnssec

# ═════════════════════════════════════════════════
section "7. Валидация DNSSEC через delv"
# ═════════════════════════════════════════════════

TOTAL=$((TOTAL + 1))
if prepare_anchor; then
  ANCHOR_CONTENT=$(docker exec "$CLIENT" cat /tmp/my.anchor 2>&1)
  pass "Сформирован trust-anchor для delv" "$ANCHOR_CONTENT"
else
  fail "Сформирован trust-anchor для delv" "Не удалось собрать KSK"
fi

check "delv валидирует www.my.lab.test: fully validated" \
  "fully validated" \
  docker exec "$CLIENT" delv -a /tmp/my.anchor +root=my.lab.test @${RESOLVER_IP} www.my.lab.test

check "delv валидирует my.lab.test: fully validated" \
  "fully validated" \
  docker exec "$CLIENT" delv -a /tmp/my.anchor +root=my.lab.test @${RESOLVER_IP} my.lab.test

# ═════════════════════════════════════════════════
section "Итог"
# ═════════════════════════════════════════════════

printf "\n"
printf "Всего тестов:  %s\n" "$TOTAL"
printf "${green}Успешно:       %s${reset}\n" "$PASSED"
if [ "$FAILED" -eq 0 ]; then
  printf "${green}Ошибок:        %s${reset}\n" "$FAILED"
  printf "\n${green}Все проверки пройдены!${reset}\n"
  exit 0
else
  printf "${red}Ошибок:        %s${reset}\n" "$FAILED"
  printf "\n${red}Есть проблемы, см. вывод выше.${reset}\n"
  exit 1
fi
