// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// PushDistributor — lives on Robinhood Chain. Holds HMM. Pushes it out.
///
/// This replaces the merkle/claim version. Holders do nothing: HMM lands in
/// their wallet. You call distribute() with the snapshot list.
///
/// It stores no pot and no schedule. The pot is your Base treasury's ETH
/// balance, which empties the moment you spend it. This contract only ever
/// hands out HMM it is already holding, so it cannot go insolvent and it
/// cannot owe anyone anything.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PushDistributor {
    IERC20  public immutable hmm;
    address public owner;

    uint256 public epoch;        // distributions completed
    uint256 public totalPaid;    // lifetime HMM delivered
    uint256 public lastPaidAt;

    /// One per distribution. The site reads these to build the ledger,
    /// so you never maintain a list anywhere else.
    event Distributed(
        uint256 indexed epoch,
        uint256 snapshotBlock,   // the BASE block the snapshot was taken at
        uint256 recipients,
        uint256 amount
    );
    /// Emitted instead of reverting when one recipient rejects the transfer.
    event Skipped(uint256 indexed epoch, address holder, uint256 amount);
    event OwnerChanged(address newOwner);

    error NotOwner();
    error LengthMismatch();
    error EmptyBatch();
    error Underfunded(uint256 need, uint256 have);
    error TooSoon();

    constructor(address _hmm) {
        hmm = IERC20(_hmm);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------ pay

    /// Fund by plain HMM transfer to this address. No deposit function needed.
    ///
    /// @param to     holder addresses from the snapshot, pool/treasury/pad excluded
    /// @param amt    HMM per holder, pro rata, same order as `to`
    /// @param snapBlock the Base block the snapshot was taken at, for the receipt
    /// @param bumpEpoch true on the LAST chunk of a distribution, false on
    ///        earlier chunks. Lets you split 500 holders across several
    ///        transactions while it still counts as one epoch.
    ///
    /// Each transfer is isolated. A holder with a blacklist flag, a max-wallet
    /// cap, or any other rejecting condition gets skipped and logged. One bad
    /// address cannot kill the batch, which is the failure mode that would
    /// otherwise brick every distribution.
    function distribute(
        address[] calldata to,
        uint256[] calldata amt,
        uint256 snapBlock,
        bool bumpEpoch
    ) external onlyOwner {
        uint256 n = to.length;
        if (n == 0) revert EmptyBatch();
        if (n != amt.length) revert LengthMismatch();

        uint256 need;
        for (uint256 i; i < n; ++i) need += amt[i];

        uint256 have = hmm.balanceOf(address(this));
        if (need > have) revert Underfunded(need, have);

        uint256 sent;
        uint256 e = epoch + 1;

        for (uint256 i; i < n; ++i) {
            if (amt[i] == 0) continue;
            // isolate every transfer: catch a revert AND a false return
            bool ok;
            try hmm.transfer(to[i], amt[i]) returns (bool r) {
                ok = r;
            } catch {
                ok = false;
            }
            if (ok) {
                sent += amt[i];
            } else {
                emit Skipped(e, to[i], amt[i]);
            }
        }

        totalPaid += sent;
        lastPaidAt = block.timestamp;

        if (bumpEpoch) {
            epoch = e;
            emit Distributed(e, snapBlock, n, sent);
        }
    }

    // ---------------------------------------------------------------- admin

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerChanged(_owner);
    }

    /// Escape hatch so HMM is not bricked forever if the flywheel is retired.
    /// Locked while the machine is running: 180 days with no distribution.
    function sweep(address to) external onlyOwner {
        if (block.timestamp < lastPaidAt + 180 days) revert TooSoon();
        hmm.transfer(to, hmm.balanceOf(address(this)));
    }

    // ----------------------------------------------------------------- read

    function funded() external view returns (uint256) {
        return hmm.balanceOf(address(this));
    }
}

/*
 RUNBOOK — one distribution, start to finish.

  0. Watch the pot. It is just eth_getBalance(treasury) on Base.
     Full at 0.001 ETH x holder count, floor 0.3 ETH.

  1. Pot is full. Pick a random block inside the last hour and run
     snapshot.js against it. Both its gates must pass.

  2. Collect LP fees to the treasury if they are not there already.

  3. Bridge the pot to your own address on Robinhood Chain.

  4. Buy HMM with it. Check tick depth first, split the order if it
     would move the price against you.

  5. Send the HMM to this contract.

  6. Call distribute(holders, amounts, snapBlock, true).
     Over ~250 holders, chunk it: false on every chunk except the last.

  7. Check the Skipped events. Any address there is telling you HMM has a
     blacklist or a wallet cap. Roll those amounts into the next epoch.

 That is the whole loop. The site needs no update: the pot gauge reads the
 treasury balance, and the ledger reads Distributed events off this contract.

 BEFORE THE FIRST RUN: send 1 HMM here and compare balanceOf before and
 after. If it arrives short, HMM has a transfer tax and every amount you
 calculate will be wrong.
*/
