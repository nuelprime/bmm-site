# BMM site

Single HTML file. No build step, no npm, no server needed.

## Get it running

1. Open this folder in VS Code: **File > Open Folder**, pick `bmm-site`.
2. Drop your two images into `img/` named exactly `bg.jpg` and `banner.jpg`.
3. Double-click `index.html` to view it in a browser.

If a file is missing nothing breaks. The background falls back to a gradient
and the banner falls back to an empty frame.

Optional: install the **Live Server** extension in VS Code, then right-click
`index.html` > *Open with Live Server*. Page reloads itself on every save.

## Changing things

Everything you'd change is in one block near the bottom of `index.html`,
search for `var CONFIG`:

| Key | What it is |
|---|---|
| `banner` | path to the banner image |
| `threshold` | full pot in ETH. Rule: `0.001 x holder count`, floor `0.3` |
| `treasury` | Base wallet that holds the pot |
| `distributor` | Robinhood Chain contract that pushes HMM |
| `bmm` / `hmm` | token addresses |
| `mock` | fake numbers. Delete once the reads are wired. |

Image paths, if you use `.png` instead of `.jpg`:
- background: search `img/bg.jpg` in the CSS near the top
- banner: `CONFIG.banner`

## Going live

The site stores nothing. Three reads replace `CONFIG.mock`:

- **pot** = `eth_getBalance(treasury)` on Base
- **paid** = count of `Distributed` events on the distributor
- **price** = (BMM/WETH from its V3 pool) / (HMM/WETH from its V3 pool)

The pot gauge empties by itself when you spend the ETH, because the gauge
*is* the treasury balance. Nothing to reset, nothing to update.

## Also here

- `contracts/PushDistributor.sol` — holds HMM, pushes payouts. Runbook at the bottom.
- `scripts/snapshot.js` — builds the holder list. Both its checks must pass.

## Before the first distribution

Send 1 HMM to the distributor and compare `balanceOf` before and after.
If it arrives short, HMM has a transfer tax and every amount the snapshot
calculates will be wrong.
