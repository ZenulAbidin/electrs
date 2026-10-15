# SIGTERM lost during a bitcoind reconnect (mempool/electrs#164)

Reproduces the bug where electrs ignores SIGTERM/SIGINT that arrives while a
mempool update is waiting to reconnect to bitcoind. The process keeps running
until it is SIGKILLed (under systemd: until the stop timeout expires).

Fix: https://github.com/ZenulAbidin/electrs/tree/fix-sticky-shutdown-signal

## Run it

Needs `bitcoind`, `bitcoin-cli` and `python3` on `PATH`.

```sh
cargo build --bin electrs
contrib/sigterm-hang-repro/repro.sh target/debug/electrs periodic
contrib/sigterm-hang-repro/repro.sh target/debug/electrs startup
```

The script starts a throwaway regtest bitcoind and puts `proxy.py` in front of
it. The proxy drops every `getrawmempool` call while a flag file exists. When
electrs logs `reconnecting to bitcoind`, the script sends SIGTERM, heals the
proxy 2 s later, and checks whether electrs exits within 20 s.

- `periodic`: the proxy breaks after electrs is serving. The SIGTERM hits the
  main-loop `Mempool::update`.
- `startup`: the proxy is broken from the start. The SIGTERM hits the initial
  mempool update loop.

Ports 18943-18948 are used; set `BASE_PORT` to move them.

## Results

On `mempool` at eda20be, 3 runs per case:

| Build | periodic | startup |
| --- | --- | --- |
| eda20be (unpatched) | still running 20 s after SIGTERM, 3/3 | still running 20 s after SIGTERM, 3/3 |
| eda20be + fix | `stopping server` → `server stopped`, exit 0, 3/3 | `server failed: Interrupted by signal 15`, exit 1, 3/3 |

On the startup path, exit code 1 is the existing behaviour for an interrupt
during startup: the initial update loop already returns the error with
`signal.wait(...)?`. The fix only makes sure the signal gets that far.

Unpatched log, periodic case:

```
WARN - reconnecting to bitcoind: disconnected from daemon while receiving
WARN - Error updating mempool, skipping mempool update: Error: failed to update mempool from daemon
Caused by: Iterrupted by signal 15
```

and electrs carries on running.

## Why

`Waiter` (`src/signal.rs`) delivers each signal through a channel exactly once.
`Daemon::retry_request_batch` waits on it between reconnect attempts, so the
SIGTERM is received there and returned as `ErrorKind::Interrupt`. Both mempool
update call sites in `src/bin/electrs.rs` log that error and carry on, so the
signal is gone. The main loop's own `signal.wait()` never sees it.
