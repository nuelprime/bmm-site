// Snapshot BMM holders on Base at a fixed block.
// node snapshot.js <blockNumber>
//
// Correctness gate: the sum of every balance (including excluded addresses)
// MUST equal totalSupply at that block. If it doesn't, a log chunk was dropped
// and the script throws instead of writing a wrong snapshot.

import { createPublicClient, http, parseAbiItem } from "viem";
import { base } from "viem/chains";
import fs from "fs";

const RPC = process.env.BASE_RPC;
const BMM = "0x3c9831aaa34ffbd84d9956ac050ba347cdebdba3"; // Based Thinking Cat
const DEPLOY_BLOCK = 0n;                                                // <-- deploy block
const ZERO = "0x0000000000000000000000000000000000000000";

// Anything here is NOT a real holder. Missing one of these = the pool becomes
// your biggest "holder" and eats most of the distribution.
const EXCLUDE = new Set([
  ZERO,
  "0x000000000000000000000000000000000000dead",
  // Uniswap v4 keeps every pool's inventory in one singleton PoolManager.
  // It held 100% of supply at launch. Miss this and it eats the distribution.
  "0x498581fF718922c3f8e6A244956aF099B2652b2b",
  "0x9982538f41f2ae29ddb9d3d9307010052984fdbb", // Doppler fees contract
  "0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544", // Fees Manager / initializer
  "0xD795eB3C59718f615E13a9d1BF7C8bf4F1F5A73B", // treasury
].map((a) => a.toLowerCase()));

const DUST = 1_000_000_000_000_000n; // 0.001 BMM min to be eligible
const STEP = 2000n;                  // getLogs range per call

const client = createPublicClient({ chain: base, transport: http(RPC) });
const TRANSFER = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)"
);

const snapshotBlock = BigInt(process.argv[2]);
if (!snapshotBlock) throw new Error("pass a block number");

const bal = new Map();
const bump = (a, v) => bal.set(a, (bal.get(a) ?? 0n) + v);

let scanned = 0n;
for (let from = DEPLOY_BLOCK; from <= snapshotBlock; from += STEP) {
  const to = from + STEP - 1n > snapshotBlock ? snapshotBlock : from + STEP - 1n;

  const logs = await client.getLogs({
    address: BMM,
    event: TRANSFER,
    fromBlock: from,
    toBlock: to,
  });

  for (const l of logs) {
    const f = l.args.from.toLowerCase();
    const t = l.args.to.toLowerCase();
    const v = l.args.value;
    if (f !== ZERO) bump(f, -v);
    if (t !== ZERO) bump(t, v);
  }

  scanned = to;
  process.stderr.write(`\r${to} / ${snapshotBlock}  (${bal.size} addrs)`);
}
process.stderr.write("\n");

if (scanned !== snapshotBlock) throw new Error("scan did not reach target block");

// ---- gate 1: does everything add up to total supply? -----------------------

const totalSupply = await client.readContract({
  address: BMM,
  abi: [parseAbiItem("function totalSupply() view returns (uint256)")],
  functionName: "totalSupply",
  blockNumber: snapshotBlock,
});

const summed = [...bal.values()].reduce((a, b) => a + b, 0n);
if (summed !== totalSupply) {
  throw new Error(`RECONCILE FAIL: replayed ${summed} vs supply ${totalSupply}`);
}

// ---- gate 2: spot-check 3 wallets against balanceOf -----------------------

const sample = [...bal.entries()].filter(([, v]) => v > 0n).slice(0, 3);
for (const [addr, expected] of sample) {
  const onchain = await client.readContract({
    address: BMM,
    abi: [parseAbiItem("function balanceOf(address) view returns (uint256)")],
    functionName: "balanceOf",
    args: [addr],
    blockNumber: snapshotBlock,
  });
  if (onchain !== expected) {
    throw new Error(`SPOT FAIL ${addr}: replay ${expected} vs chain ${onchain}`);
  }
}

// ---- eligible set ---------------------------------------------------------

const holders = {};
let eligibleTotal = 0n;
for (const [addr, v] of bal) {
  if (v < DUST) continue;
  if (EXCLUDE.has(addr)) continue;
  holders[addr] = v.toString();
  eligibleTotal += v;
}

const out = {
  block: snapshotBlock.toString(),
  totalSupply: totalSupply.toString(),
  eligibleTotal: eligibleTotal.toString(),
  holderCount: Object.keys(holders).length,
  holders,
};

fs.writeFileSync(`snapshots/${snapshotBlock}.json`, JSON.stringify(out, null, 2));
console.log(`ok — ${out.holderCount} holders, ${eligibleTotal} eligible units`);
