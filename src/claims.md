The claims order distributes a fixed pool of output tokens to a set of
recipients committed to by a merkle root.

The order owner sets the merkle root at deploy time and deposits the output
token. Each leaf of the tree commits to a recipient's index, address and
claimable amount. A recipient claims by taking the order with a signed context
of `[index, amount, proof...]`; the order verifies the proof against the root,
checks the leaf has not been claimed already, and pays out exactly `amount`.
The input side is irrelevant: the IO ratio is always 0.

Proofs are fixed at depth 8, so a tree must have exactly 256 leaves (pad with
zero-amount entries).

Albion uses this strategy for the monthly USDC royalty distributions to
tokenised royalty holders on Base (see `albion.rewards`).
