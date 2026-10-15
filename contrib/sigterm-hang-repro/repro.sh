#!/bin/bash
# Reproduces mempool/electrs#164: SIGTERM is lost if it arrives while a
# mempool update is waiting to reconnect to bitcoind.
#
# Usage: repro.sh <path-to-electrs-binary> [periodic|startup]
#
#   periodic  break getrawmempool after electrs is serving (main-loop update)
#   startup   break getrawmempool before electrs starts (initial update loop)
#
# Starts a throwaway regtest bitcoind and a JSON-RPC proxy that drops
# getrawmempool calls while a flag file exists. Sends SIGTERM while electrs is
# in its "reconnecting to bitcoind" wait, heals the proxy 2 s later, then
# checks whether electrs exits within 20 s.
#
# Needs bitcoind, bitcoin-cli and python3 on PATH. Uses ports BASE_PORT to
# BASE_PORT+5 (default 18943).
set -u
BIN=$(realpath "$1"); MODE=${2:-periodic}
P=${BASE_PORT:-18943}
HERE=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d); mkdir -p "$D/btc"; FLAG=$D/break-mempool
CLI="bitcoin-cli -regtest -datadir=$D/btc -rpcuser=u -rpcpassword=p -rpcport=$P"

bitcoind -regtest -datadir="$D/btc" -rpcuser=u -rpcpassword=p -rpcport=$P -port=$((P+1)) \
  -listen=0 -fallbackfee=0.0001 -daemon >/dev/null
for i in $(seq 30); do $CLI getblockcount >/dev/null 2>&1 && break; sleep 1; done
$CLI createwallet w >/dev/null
$CLI generatetoaddress 101 "$($CLI getnewaddress)" >/dev/null

python3 -I "$HERE/proxy.py" $((P+2)) "http://127.0.0.1:$P/" "$FLAG" > "$D/proxy.log" 2>&1 & PX=$!
[ "$MODE" = startup ] && touch "$FLAG"

"$BIN" -vvv --network regtest --daemon-dir "$D/btc" --cookie u:p \
  --daemon-rpc-addr 127.0.0.1:$((P+2)) --jsonrpc-import --db-dir "$D/db" \
  --electrum-rpc-addr 127.0.0.1:$((P+3)) --http-addr 127.0.0.1:$((P+4)) \
  --monitoring-addr 127.0.0.1:$((P+5)) > "$D/electrs.log" 2>&1 & EP=$!

if [ "$MODE" = periodic ]; then
  for i in $(seq 120); do grep -q "REST server running\|Electrum RPC server running" "$D/electrs.log" && break; sleep 1; done
  sleep 3; touch "$FLAG"
fi
for i in $(seq 60); do grep -q "reconnecting to bitcoind" "$D/electrs.log" && break; sleep 0.5; done
sleep 1

echo "[$MODE] electrs is reconnecting to bitcoind; sending SIGTERM"
kill -TERM $EP
sleep 2; rm -f "$FLAG"
for i in $(seq 20); do kill -0 $EP 2>/dev/null || break; sleep 1; done
if kill -0 $EP 2>/dev/null; then
  echo "[$MODE] RESULT: BUG - electrs still running 20 s after SIGTERM"; kill -KILL $EP; wait $EP 2>/dev/null; RC=1
else
  wait $EP; echo "[$MODE] RESULT: OK - electrs exited with code $?"; RC=0
fi
echo "[$MODE] relevant log lines:"
grep -E "reconnecting to bitcoind|by signal|stopping server|server stopped" "$D/electrs.log" \
  | sed 's/^/    /' | cut -c1-170 | uniq | head -8

kill $PX; $CLI stop >/dev/null; sleep 2
echo "[$MODE] logs kept in $D"
exit $RC
