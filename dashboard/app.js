// Ledgerline dashboard: reads Lasna, Base Sepolia and Unichain Sepolia directly over public RPC.
// No backend. Addresses come from ../deployments/testnet.json (written by script/deploy.sh).
import { ethers } from "https://cdn.jsdelivr.net/npm/ethers@6.13.4/dist/ethers.min.js";

const NETWORKS = {
  lasna: { name: "Lasna", rpc: "https://lasna-rpc.rnk.dev/", explorer: "https://lasna.reactscan.net" },
  base: { name: "Base Sepolia", chainId: 84532, rpc: "https://sepolia.base.org", explorer: "https://sepolia.basescan.org" },
  unichain: { name: "Unichain Sepolia", chainId: 1301, rpc: "https://sepolia.unichain.org", explorer: "https://sepolia.uniscan.xyz" },
};
const REFRESH_MS = Number(new URLSearchParams(location.search).get("refresh")) || 3000;
const FEED_LOOKBACK_BLOCKS = 20000; // ~5.5 h of Lasna blocks
const DECIMALS = 6;

const LEDGER_ABI = [
  "function assetCount() view returns (uint256)",
  "function asset(uint256) view returns (tuple(bytes32 symbol,uint256 dailyLimit,uint16 savingsBps,uint256 minIncome,uint256 totalIn,uint256 totalOut,uint256 spentToday,uint256 spentDay,uint256 lockedDay,uint256 savedRequested,uint256 savedConfirmed))",
  "function spentToday(uint256) view returns (uint256)",
  "function tokenCount() view returns (uint256)",
  "function tokenAt(uint256) view returns (tuple(uint256 chainId,address token,uint256 assetId,bool active,uint256 totalIn,uint256 totalOut,uint256 internalMoves))",
  "function wallets() view returns (address[])",
  "event SpendRecorded(uint256 indexed originTxHash, uint256 indexed assetId, address indexed wallet, uint256 chainId, uint256 amount, uint256 spentToday)",
  "event IncomeRecorded(uint256 indexed originTxHash, uint256 indexed assetId, address indexed wallet, uint256 chainId, uint256 amount)",
  "event InternalMoveRecorded(uint256 indexed originTxHash, uint256 indexed assetId, uint256 chainId, uint256 amount)",
  "event SavingsConfirmed(uint256 indexed originTxHash, uint256 indexed assetId, address indexed wallet, uint256 chainId, uint256 amount)",
  "event SpendWarning(uint256 indexed assetId, uint256 spentToday, uint256 dailyLimit)",
  "event BudgetExceeded(uint256 indexed assetId, uint256 spentToday, uint256 dailyLimit, uint256 lockedUntil)",
  "event SweepRequested(bytes32 indexed ref, uint256 indexed chainId, address wallet, address token, uint256 amount)",
  "event StatementRequested(uint256 indexed seq, uint256 asOf, uint256 lines)",
];
const VAULT_ABI = [
  "function lockedUntil() view returns (uint256)",
  "function isLocked() view returns (bool)",
  "function savingsOf(address,address) view returns (uint256)",
];
const STATEMENT_ABI = [
  "function latest() view returns (uint256 seq, uint256 asOf, tuple(bytes32 asset,uint256 totalIn,uint256 totalOut,uint256 spentToday,uint256 dailyLimit,uint256 savedRequested,uint256 savedConfirmed)[] lines)",
];

const EVENT_CLASS = {
  IncomeRecorded: "Income", SavingsConfirmed: "Savings", SpendRecorded: "Spend", SpendWarning: "Warning", BudgetExceeded: "Budget",
};

const $ = (id) => document.getElementById(id);
const fmt = (v) => Number(ethers.formatUnits(v, DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 2 });
const sym = (b) => ethers.decodeBytes32String(b);
const short = (h) => `${h.slice(0, 8)}…${h.slice(-4)}`;
const chainName = (id) => Object.values(NETWORKS).find((n) => n.chainId === Number(id))?.name ?? `chain ${id}`;
const time = (ts) => new Date(Number(ts) * 1000).toLocaleTimeString();

const providers = Object.fromEntries(
  Object.entries(NETWORKS).map(([k, n]) => [k, new ethers.JsonRpcProvider(n.rpc, undefined, { staticNetwork: true })]),
);

let deploy, ledger, seenFeed = new Set();

// ?compact=1 fits everything on one screen (used when recording the demo).
if (new URLSearchParams(location.search).has("compact")) document.body.classList.add("compact");

async function init() {
  deploy = await (await fetch("../deployments/testnet.json", { cache: "no-store" })).json();
  ledger = new ethers.Contract(deploy.lasna.ledgerline, LEDGER_ABI, providers.lasna);
  $("wallet").textContent = `wallet ${short(deploy.deployer)}`;
  $("ledger-link").textContent = short(deploy.lasna.ledgerline);
  $("ledger-link").href = `${NETWORKS.lasna.explorer}/address/${deploy.lasna.ledgerline}`;
  refresh();
  setInterval(refresh, REFRESH_MS);
}

async function refresh() {
  try {
    await Promise.all([
      renderChains(), renderAssets(), renderTokens(), renderVaults(), renderStatement(), renderFeed(), loadLatency(),
    ]);
    $("updated").textContent = new Date().toLocaleTimeString();
  } catch (err) {
    console.error(err);
  }
}

async function renderChains() {
  const heads = await Promise.all(Object.keys(NETWORKS).map((k) => providers[k].getBlockNumber()));
  $("chains").innerHTML = Object.values(NETWORKS)
    .map((n, i) => `<span class="chip">${n.name} <b>#${heads[i].toLocaleString()}</b></span>`)
    .join("");
}

async function renderAssets() {
  const count = Number(await ledger.assetCount());
  const cards = [];
  for (let i = 0; i < count; i++) {
    const [a, spent] = await Promise.all([ledger.asset(i), ledger.spentToday(i)]);
    const limit = a.dailyLimit;
    const pct = limit > 0n ? Number((spent * 1000n) / limit) / 10 : 0;
    const cls = pct > 100 ? "over" : pct >= 80 ? "warn" : "";
    cards.push(`
      <div class="asset">
        <div class="muted">${sym(a.symbol)} · spent today</div>
        <div class="big">${fmt(spent)} <span class="muted">/ ${limit > 0n ? fmt(limit) : "no limit"}</span></div>
        <div class="bar ${cls}"><div style="width:${Math.min(pct, 100)}%"></div></div>
        <div class="kv">
          <span>Income (all chains)</span><span>${fmt(a.totalIn)}</span>
          <span>Spending (all chains)</span><span>${fmt(a.totalOut)}</span>
          <span>Auto-save rate</span><span>${Number(a.savingsBps) / 100}%</span>
          <span>Saved (requested / confirmed)</span><span>${fmt(a.savedRequested)} / ${fmt(a.savedConfirmed)}</span>
        </div>
      </div>`);
  }
  $("assets").innerHTML = cards.join("") || `<span class="muted">No assets configured.</span>`;
}

async function renderTokens() {
  const n = Number(await ledger.tokenCount());
  const rows = await Promise.all([...Array(n).keys()].map((i) => ledger.tokenAt(i)));
  $("tokens").innerHTML =
    `<tr><th>Chain</th><th>Token</th><th>In</th><th>Out</th><th>Own moves</th></tr>` +
    rows
      .map((t) => `<tr><td>${chainName(t.chainId)}</td><td>${short(t.token)}${t.active ? "" : " (off)"}</td>
        <td>${fmt(t.totalIn)}</td><td>${fmt(t.totalOut)}</td><td>${t.internalMoves}</td></tr>`)
      .join("");
}

async function renderVaults() {
  const parts = [];
  for (const key of ["base", "unichain"]) {
    const d = deploy[key];
    const vault = new ethers.Contract(d.vault, VAULT_ABI, providers[key]);
    const [locked, until, saved, gas] = await Promise.all([
      vault.isLocked(), vault.lockedUntil(), vault.savingsOf(deploy.deployer, d.token), providers[key].getBalance(d.vault),
    ]);
    parts.push(`
      <div class="kv" style="margin-bottom:0.8rem">
        <span>${NETWORKS[key].name}</span>
        <span class="${locked ? "locked" : "open"}">${locked ? `LOCKED until ${time(until)}` : "open"}</span>
        <span>My savings</span><span>${fmt(saved)} lUSD</span>
        <span>Callback gas left</span><span>${Number(ethers.formatEther(gas)).toFixed(5)} ETH</span>
      </div>`);
  }
  $("vaults").innerHTML = parts.join("");
}

async function renderStatement() {
  const st = new ethers.Contract(deploy.base.statement, STATEMENT_ABI, providers.base);
  const { seq, asOf, lines } = await st.latest();
  if (seq === 0n) {
    $("statement").innerHTML = `<span class="muted">No statement yet.</span>`;
    return;
  }
  $("statement").innerHTML =
    `<div class="muted">#${seq} as of ${new Date(Number(asOf) * 1000).toLocaleString()}</div>
     <table><tr><th>Asset</th><th>In</th><th>Out</th><th>Today</th><th>Saved</th></tr>` +
    lines.map((l) => `<tr><td>${sym(l.asset)}</td><td>${fmt(l.totalIn)}</td><td>${fmt(l.totalOut)}</td>
      <td>${fmt(l.spentToday)}</td><td>${fmt(l.savedConfirmed)}</td></tr>`).join("") +
    `</table>`;
}

async function renderFeed() {
  const head = await providers.lasna.getBlockNumber();
  const logs = await providers.lasna.getLogs({
    address: deploy.lasna.ledgerline,
    fromBlock: Math.max(0, head - FEED_LOOKBACK_BLOCKS),
    toBlock: head,
  });
  const items = [];
  for (const log of logs.slice(-60).reverse()) {
    const ev = ledger.interface.parseLog(log);
    if (!ev) continue;
    const a = ev.args;
    const text = {
      IncomeRecorded: () => `+${fmt(a.amount)} on ${chainName(a.chainId)}`,
      SpendRecorded: () => `−${fmt(a.amount)} on ${chainName(a.chainId)} · today ${fmt(a.spentToday)}`,
      InternalMoveRecorded: () => `${fmt(a.amount)} between own wallets on ${chainName(a.chainId)}`,
      SavingsConfirmed: () => `${fmt(a.amount)} landed in the ${chainName(a.chainId)} vault`,
      SpendWarning: () => `80% of daily budget used (${fmt(a.spentToday)} / ${fmt(a.dailyLimit)})`,
      BudgetExceeded: () => `limit ${fmt(a.dailyLimit)} passed → locking every vault until ${time(a.lockedUntil)}`,
      SweepRequested: () => `callback → save ${fmt(a.amount)} on ${chainName(a.chainId)}`,
      StatementRequested: () => `callback → statement #${a.seq}`,
    }[ev.name];
    if (!text) continue;
    const id = `${log.transactionHash}:${log.index}`;
    const fresh = seenFeed.size > 0 && !seenFeed.has(id);
    seenFeed.add(id);
    items.push(`<li class="${fresh ? "fresh" : ""}"><span class="muted">#${log.blockNumber}</span>
      <span class="ev ${EVENT_CLASS[ev.name] ?? ""}">${ev.name}</span>
      <span>${text()}</span>
      <a href="${NETWORKS.lasna.explorer}/tx/${log.transactionHash}" target="_blank" rel="noopener">${short(log.transactionHash)}</a></li>`);
  }
  $("feed").innerHTML = items.join("") || `<li class="muted">Waiting for the first event…</li>`;
}

async function loadLatency() {
  try {
    const r = await fetch("../deployments/e2e-latest.json", { cache: "no-store" });
    if (!r.ok) return;
    const run = await r.json();
    const rows = run.loops.filter((l) => l.latency).map((l) =>
      `<tr><td>${l.name}</td><td>${l.hops.length}</td><td>${l.latency.chain_time_s} s</td><td>${l.latency.wall_time_s} s</td></tr>`);
    $("latency").innerHTML = `<div class="muted">run ${run.run_at_utc}</div>
      <table><tr><th>Loop</th><th>Hops</th><th>Chain time</th><th>Wall time</th></tr>${rows.join("")}</table>`;
  } catch {
    /* no run yet */
  }
}

init();
