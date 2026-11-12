#!/usr/bin/env python3
"""Ledgerline end-to-end run on public testnets.

Fires real origin transactions on Base Sepolia / Unichain Sepolia (and one on Lasna), then follows each
one through Reactive Network: the reactive transaction on Lasna, and the callback transaction it
triggers on the destination chain. Every hop is recorded with its tx hash, block timestamp and the
wall-clock moment this script first saw it, so the full-loop latency can be reported two ways:

  * chain time: destination block timestamp - origin block timestamp (1 s resolution)
  * wall time:  callback first seen by this script - origin tx confirmed (includes RPC polling, ~0.3 s)

Results go to deployments/e2e-<utc timestamp>.json and deployments/e2e-latest.json.

Usage:  python3 script/e2e.py            (needs deployments/testnet.json from script/deploy.sh)
Only needs Python 3 and Foundry's `cast` (used to sign and send transactions).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLL_SECONDS = 0.3
TIMEOUT_SECONDS = 180
SHOP = "0x000000000000000000000000000000000000dEaD"  # where demo "purchases" go
UNIT = 10**6  # lUSD has 6 decimals


# --------------------------------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------------------------------

def read_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip()
    return env


def load_private_key(env: dict[str, str], var: str = "PRIVATE_KEY", file_var: str = "KEY_FILE") -> str:
    """Return a key from the environment or a `cast wallet new --json` file. Never printed."""
    if os.environ.get(var) or env.get(var):
        return os.environ.get(var) or env[var]
    path = Path(env[file_var])
    if not path.is_absolute():
        path = ROOT / path
    data = json.loads(path.read_text())
    data = data.get("data", data)
    data = data[0] if isinstance(data, list) else data
    return data["private_key"]


def keccak(text: str) -> str:
    return subprocess.run(["cast", "keccak", text], check=True, capture_output=True, text=True).stdout.strip()


# --------------------------------------------------------------------------------------------------
# Chains
# --------------------------------------------------------------------------------------------------

@dataclass
class Chain:
    name: str
    rpc: str
    chain_id: int
    explorer: str

    def call(self, method: str, params: list) -> object:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.rpc, body, {"Content-Type": "application/json", "User-Agent": "ledgerline-e2e"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    out = json.loads(resp.read())
                if "error" in out:
                    raise RuntimeError(f"{self.name} {method}: {out['error']}")
                return out["result"]
            except (OSError, RuntimeError):
                if attempt == 4:
                    raise
                time.sleep(1 + attempt)
        raise AssertionError("unreachable")

    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def block_timestamp(self, number: int) -> int:
        return int(self.call("eth_getBlockByNumber", [hex(number), False])["timestamp"], 16)

    def receipt(self, tx_hash: str) -> dict:
        return self.call("eth_getTransactionReceipt", [tx_hash])

    def logs(self, address: str, topics: list, from_block: int) -> list[dict]:
        return self.call("eth_getLogs", [{"address": address, "topics": topics, "fromBlock": hex(from_block), "toBlock": "latest"}])

    def tx_url(self, tx_hash: str) -> str:
        return f"{self.explorer}/tx/{tx_hash}"


@dataclass
class Hop:
    """One transaction in a loop."""
    chain: str
    tx_hash: str
    block: int
    block_timestamp: int
    seen_at: float  # wall clock, unix seconds
    url: str
    note: str = ""


@dataclass
class Loop:
    name: str
    description: str
    hops: list[Hop] = field(default_factory=list)
    skipped: str = ""

    def summary(self) -> dict:
        out = {"name": self.name, "description": self.description, "hops": [h.__dict__ for h in self.hops]}
        if self.skipped:
            out["skipped"] = self.skipped
        if len(self.hops) >= 2:
            first, last = self.hops[0], self.hops[-1]
            out["latency"] = {
                "chain_time_s": last.block_timestamp - first.block_timestamp,
                "wall_time_s": round(last.seen_at - first.seen_at, 2),
                "origin_to_reactive_wall_s": round(self.hops[1].seen_at - first.seen_at, 2),
            }
        return out


# --------------------------------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------------------------------

class Runner:
    def __init__(self) -> None:
        env = {**read_env(ROOT / "script/networks.env"), **read_env(ROOT / ".env")}
        self.key = load_private_key(env)
        self.deploy = json.loads((ROOT / "deployments/testnet.json").read_text())
        self.me = self.deploy["deployer"]
        self.second = env.get("SECOND_WALLET")

        self.lasna = Chain("lasna", env["LASNA_RPC"], int(env["LASNA_CHAIN_ID"]), env["LASNA_EXPLORER"])
        self.base = Chain("base-sepolia", env["BASE_RPC"], int(env["BASE_CHAIN_ID"]), env["BASE_EXPLORER"])
        self.uni = Chain("unichain-sepolia", env["UNI_RPC"], int(env["UNI_CHAIN_ID"]), env["UNI_EXPLORER"])
        self.ledger = self.deploy["lasna"]["ledgerline"]

        sig = {
            "income": "IncomeRecorded(uint256,uint256,address,uint256,uint256)",
            "spend": "SpendRecorded(uint256,uint256,address,uint256,uint256,uint256)",
            "internal": "InternalMoveRecorded(uint256,uint256,uint256,uint256)",
            "saved": "SavingsConfirmed(uint256,uint256,address,uint256,uint256)",
            "exceeded": "BudgetExceeded(uint256,uint256,uint256,uint256)",
            "sweep_req": "SweepRequested(bytes32,uint256,address,address,uint256)",
            "stmt_req": "StatementRequested(uint256,uint256,uint256)",
            "swept": "Swept(bytes32,address,address,uint256)",
            "skipped": "SweepSkipped(bytes32,address,address,uint256,string)",
            "locked": "BudgetLocked(bytes32,uint256,uint256,uint256)",
            "stmt": "StatementRecorded(uint256,uint256,(bytes32,uint256,uint256,uint256,uint256,uint256,uint256)[])",
        }
        self.topic = {k: keccak(v) for k, v in sig.items()}
        self.loops: list[Loop] = []

    # --- primitives ------------------------------------------------------------------------------

    def send(self, chain: Chain, to: str, signature: str, *args: str, key: str | None = None) -> Hop:
        cmd = ["cast", "send", "--json", "--rpc-url", chain.rpc, "--private-key", key or self.key, to, signature, *args]
        out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
        seen = time.time()
        receipt = json.loads(out)
        if receipt["status"] != "0x1":
            raise RuntimeError(f"origin tx reverted: {chain.tx_url(receipt['transactionHash'])}")
        block = int(receipt["blockNumber"], 16)
        return Hop(chain.name, receipt["transactionHash"], block, chain.block_timestamp(block), seen, chain.tx_url(receipt["transactionHash"]))

    def wait_log(self, chain: Chain, address: str, topics: list, from_block: int, note: str) -> tuple[Hop, dict]:
        deadline = time.time() + TIMEOUT_SECONDS
        while time.time() < deadline:
            found = chain.logs(address, topics, from_block)
            if found:
                log = found[0]
                seen = time.time()
                block = int(log["blockNumber"], 16)
                hop = Hop(chain.name, log["transactionHash"], block, chain.block_timestamp(block), seen, chain.tx_url(log["transactionHash"]), note)
                return hop, log
            time.sleep(POLL_SECONDS)
        raise TimeoutError(f"no {note} on {chain.name} after {TIMEOUT_SECONDS}s")

    def lasna_logs(self, tx_hash: str, topic0: str) -> list[dict]:
        return [l for l in self.lasna.receipt(tx_hash)["logs"] if l["topics"][0] == topic0 and l["address"].lower() == self.ledger.lower()]

    def heads(self) -> dict[str, int]:
        return {c.name: c.block_number() for c in (self.lasna, self.base, self.uni)}

    def ledger_call(self, signature: str, *args: str) -> str:
        return subprocess.run(["cast", "call", self.ledger, signature, *args, "--rpc-url", self.lasna.rpc], check=True, capture_output=True, text=True).stdout.strip()

    def report(self, loop: Loop) -> None:
        self.loops.append(loop)
        s = loop.summary()
        lat = s.get("latency", {})
        print(f"  ✓ {loop.name}: {len(loop.hops)} hops, chain {lat.get('chain_time_s', '-')} s, wall {lat.get('wall_time_s', '-')} s" + (f" ({loop.skipped})" if loop.skipped else ""))
        for h in loop.hops:
            print(f"      {h.chain:17} {h.tx_hash}  {h.note}")

    # --- scenarios -------------------------------------------------------------------------------

    def income_and_sweep(self, chain: Chain, amount: int) -> None:
        """Origin: income (mint) -> Lasna: IncomeRecorded + SweepRequested -> dest: vault Swept."""
        token = self.deploy[self._key(chain)]["token"]
        vault = self.deploy[self._key(chain)]["vault"]
        start = self.heads()
        origin = self.send(chain, token, "mint(address,uint256)", self.me, str(amount))
        origin.note = f"income: {amount / UNIT:g} lUSD minted to wallet"
        reactive, _ = self.wait_log(self.lasna, self.ledger, [self.topic["income"], origin.tx_hash], start["lasna"], "react(): IncomeRecorded + SweepRequested")
        ref = self.lasna_logs(reactive.tx_hash, self.topic["sweep_req"])[0]["topics"][1]
        callback, log = self.wait_log(chain, vault, [[self.topic["swept"], self.topic["skipped"]], ref], start[chain.name], "callback: SavingsVault.sweep")
        if log["topics"][0] == self.topic["skipped"]:
            callback.note += " (skipped)"
        loop = Loop(f"auto-save on {chain.name}", "Income arrives -> 10% swept into the SavingsVault on the same chain", [origin, reactive, callback])
        self.report(loop)

        # Second-order loop: the sweep's own Transfer comes back to Lasna as confirmed savings.
        confirm, _ = self.wait_log(self.lasna, self.ledger, [self.topic["saved"], callback.tx_hash], start["lasna"], "react(): SavingsConfirmed")
        self.report(Loop(f"savings confirmed ({chain.name})", "The vault's pull is seen on Lasna and booked as savings, not spending", [callback, confirm]))

    def spend(self, chain: Chain, amount: int, expect_lock: bool) -> None:
        """Origin: purchase -> Lasna: SpendRecorded (+ BudgetExceeded) -> dest: vault BudgetLocked on every chain."""
        token = self.deploy[self._key(chain)]["token"]
        start = self.heads()
        origin = self.send(chain, token, "transfer(address,uint256)", SHOP, str(amount))
        origin.note = f"purchase: {amount / UNIT:g} lUSD to a shop"
        reactive, _ = self.wait_log(self.lasna, self.ledger, [self.topic["spend"], origin.tx_hash], start["lasna"], "react(): SpendRecorded")
        if not expect_lock:
            self.report(Loop(f"spend on {chain.name}", "Purchase recorded in the cross-chain daily budget", [origin, reactive]))
            return
        assert self.lasna_logs(reactive.tx_hash, self.topic["exceeded"]), "expected BudgetExceeded"
        reactive.note = "react(): SpendRecorded + BudgetExceeded"
        for dest in (self.base, self.uni):
            vault = self.deploy[self._key(dest)]["vault"]
            callback, _ = self.wait_log(dest, vault, [self.topic["locked"]], start[dest.name], f"callback: SavingsVault.lock on {dest.name}")
            self.report(Loop(f"budget lock: spend on {chain.name} -> lock on {dest.name}", "Daily budget (summed across chains) exceeded -> every vault locked until UTC midnight", [origin, reactive, callback]))

    def internal_move(self) -> None:
        if not self.second:
            return
        start = self.heads()
        origin = self.send(self.base, self.deploy["base"]["token"], "transfer(address,uint256)", self.second, str(5 * UNIT))
        origin.note = "move 5 lUSD between two of my own wallets"
        reactive, _ = self.wait_log(self.lasna, self.ledger, [self.topic["internal"], origin.tx_hash], start["lasna"], "react(): InternalMoveRecorded")
        self.report(Loop("internal move", "Transfer between tracked wallets: neither income nor spending", [origin, reactive]))

    def statement(self) -> None:
        start = self.heads()
        origin = self.send(self.lasna, self.ledger, "requestStatement()")
        origin.note = "owner asks for a statement now (cron does it on schedule)"
        seq_topic = self.lasna_logs(origin.tx_hash, self.topic["stmt_req"])[0]["topics"][1]
        callback, _ = self.wait_log(self.base, self.deploy["base"]["statement"], [self.topic["stmt"], seq_topic], start[self.base.name], "callback: Statement.record")
        self.report(Loop("statement", "Snapshot of every asset written to the Statement contract on Base Sepolia", [origin, callback]))

    # --- main ------------------------------------------------------------------------------------

    def run(self) -> None:
        print(f"Ledgerline e2e — wallet {self.me}, reactive {self.ledger}")
        self.income_and_sweep(self.base, 500 * UNIT)
        self.income_and_sweep(self.uni, 200 * UNIT)

        # Spend 70 on Unichain, then enough on Base to cross the daily limit (if not already locked today).
        limit, spent, locked_day = self._budget()
        today = int(time.time()) // 86400
        first = 70 * UNIT
        self.spend(self.uni, first, expect_lock=False)
        if locked_day == today:
            self.loops.append(Loop("budget lock", "", skipped="budget already locked today; lock fires once per UTC day"))
            print("  - budget lock skipped: already locked today")
        else:
            second = max(40 * UNIT, limit - (spent + first) + 10 * UNIT)
            self.spend(self.base, second, expect_lock=True)

        self.internal_move()
        self.statement()
        self.save()

    def _budget(self) -> tuple[int, int, int]:
        raw = self.ledger_call("asset(uint256)((bytes32,uint256,uint16,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))", "0")
        fields = [f.strip().split(" ")[0] for f in raw.strip("()").split(",")]
        limit, spent_today, spent_day, locked_day = int(fields[1]), int(fields[6]), int(fields[7]), int(fields[8])
        today = int(time.time()) // 86400
        return limit, spent_today if spent_day == today else 0, locked_day

    @staticmethod
    def _key(chain: Chain) -> str:
        return {"base-sepolia": "base", "unichain-sepolia": "unichain"}[chain.name]

    def save(self) -> None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        loops = [l.summary() for l in self.loops]
        timed = [l["latency"] for l in loops if "latency" in l and len(l["hops"]) == 3]
        result = {
            "run_at_utc": stamp,
            "deployments": self.deploy,
            "loops": loops,
            "full_loop_latency": {
                "count": len(timed),
                "chain_time_s": sorted(t["chain_time_s"] for t in timed),
                "wall_time_s": sorted(t["wall_time_s"] for t in timed),
            },
        }
        for name in (f"e2e-{stamp}.json", "e2e-latest.json"):
            (ROOT / "deployments" / name).write_text(json.dumps(result, indent=2))
        print(f"Saved deployments/e2e-{stamp}.json")


if __name__ == "__main__":
    try:
        Runner().run()
    except subprocess.CalledProcessError as exc:  # don't echo the command line: it contains the key
        sys.exit(f"command failed: {exc.cmd[:3]}... stderr: {exc.stderr.strip()[:500]}")
