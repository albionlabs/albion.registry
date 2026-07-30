# Curve-NPV template migration notes (DRAFT for review)

Date: 2026-07-30
Branch: `feat/curve-npv-strategy` (albionlabs/albion.registry)
Files: `src/oil-token-curve-npv-limit.rain`, `src/oil-token-curve-npv-dca.rain`

## 0. What this is

The two templates on `albion.dex@origin/feat/curve-npv-strategy`
(`src/lib/strategies/oil-token-curve-npv-{dca,limit}.rain`) were written against
the design spec's §15 frame: **one** signed context, 19 rows, asset-bound,
`oracle-schema-version: 1`. The oracle server that actually shipped
(`albionlabs/albion.oracle-server`, live on Cloud Run) publishes something
different: a **fixed positional bundle of five independently signed frames**,
four generic per-benchmark strips (schema **2**, 10 rows) plus one asset
metahash frame (schema **3**, 5 rows).

These files are those templates, imported verbatim (commit `103fe69`) and then
migrated (commit `adab302`) so the migration reads as a diff. The valuation
math is carried over; the oracle interface is rewritten.

Normative source for the frame layout is `albion.oracle-server/README.md` +
`src/oracle.rs`. Rationale is design spec §16
(`albion.dex@origin/docs/curve-oracle-spec-v4`).

## 1. Frame layout consumed

Bundle from `POST /context/v1` — order is fixed and pinned positionally
(`oracle.rs:54` `BUNDLE_BENCHMARKS`, `oracle.rs:63` `BUNDLE_LEN = 5`):

| Slot | Frame | Schema | Rows |
|-----:|-------|-------:|-----:|
| 0 | Brent benchmark | 2 | 10 |
| 1 | WTI benchmark | 2 | 10 |
| 2 | NBP benchmark | 2 | 10 |
| 3 | TTF benchmark | 2 | 10 |
| 4 | asset metahash | 3 | 5 |

Benchmark frame rows (`oracle.rs:201` `build_benchmark_frame`), all DecimalFloat:
`0` schema=2, `1` benchmark id, `2` issued-at (settlement clock), `3` expires-at,
`4` **base_year = current UTC year at request time**, `5..9` Bal/Cal prices for
`base_year+0..+4`.

Asset frame rows (`oracle.rs:244` `build_asset_frame`): `0` schema=3 (Float),
`1` asset address left-padded (**raw bytes32**), `2` metaHash (**raw bytes32**,
zero when unknown), `3` issued-at (Goldsky clock, Float), `4` expires-at (Float).

Verified live against staging on 2026-07-30 —
`GET https://albion-oracle-mrflki6foq-ey.a.run.app/context/v1/brent` returned
signer `0xced8aab28809fbeaa9de9e576a6255663c58dc78` and rows:

```
row 0 0x…0002                         -> 2      (schema)
row 1 0x…0001                         -> 1      (Brent)
row 2 0x…6a6b6e75                     -> 1785425525 (issued-at)
row 3 0x…6a70b475                     -> 1785771125 (expires-at)
row 4 0x…07ea                         -> 2026   (base_year)
row 5 0xfffffffc…000d1137             -> 85.6375  (exp -4, coeff 856375)
```

`GET /strip` independently reports Brent `2026:85.6375 2027:76.29833
2028:73.0825 2029:71.33667 2030:70.44`. Row positions and the DecimalFloat
encoding are therefore confirmed empirically, not just from source.

## 2. Guard-by-guard mapping

`#frame-guards`, in order, with the §15/§16 rationale it implements.

### Benchmark slot (`benchmark-slot`, pinned = 0 for Wressle/Brent)

| # | Guard | Rationale |
|---|-------|-----------|
| 1 | `equal-to(signer<benchmark-slot>() oracle-signer)` | §16.4(b): signature verification is **per signed context**. Slot 0's authenticity says nothing about slot 4, so each consumed slot needs its own check. §15 item 1 had one signer check because there was one frame. |
| 2 | `equal-to(signed-context<benchmark-slot 0>() benchmark-schema-version)` (=2) | §15 item 2, retargeted. D19 puts both schema ids in one numbering space so a strategy reading the wrong slot fails row 0 instead of reading a price where it expected a hash. |
| 3 | `equal-to(signed-context<benchmark-slot 1>() benchmark-id)` | §15 item 6 (`row 6 == benchmark-id`), **strengthened** per §16.4(b): the id row pins the *series* on top of the slot position, so a server-side bundle reorder cannot silently swap Brent for TTF at a fixed slot. |
| 4 | `greater-than-or-equal-to(now() row2)` | §15 item 4 lower half. Frame from the future = broken clock. |
| 5 | `less-than-or-equal-to(now() row3)` | §15 item 4: server-declared validity window. |
| 6 | `less-than(sub(now() row2) oracle-price-timeout)` | §15 item 4: deployer-bound max age, semantics "age since issued-at". Row 2 is the **settlement** timestamp, not serve time. |

### Asset metahash slot (`asset-slot`, pinned = 4)

| # | Guard | Rationale |
|---|-------|-----------|
| 7 | `equal-to(signer<asset-slot>() oracle-signer)` | §16.4(b), same reasoning as #1. |
| 8 | `equal-to(signed-context<asset-slot 0>() asset-schema-version)` (=3) | D19. |
| 9 | `equal-to(signed-context<asset-slot 1>() asset-id)` | §16.4(b) new row: the asset frame is the *only* place asset identity lives now. |
| 10 | `any(equal-to(asset-id input-token()) equal-to(asset-id output-token()))` | §16.4(b) explicit requirement: ties the baked asset id to the live pair so slot 4 cannot be satisfied by a frame minted for a different pair. Replaces §15 item 3, which pair-bound the benchmark rows — impossible now, benchmark frames carry no token rows (D14). |
| 11 | `equal-to(signed-context<asset-slot 2>() meta-hash)` | §15 item 5 / D3 metadata-revision halt, moved to slot 4 row 2. Unknown asset ⇒ zero row ⇒ mismatch ⇒ halt (D18); DecimalFloat 0 and raw zero bytes32 coincide, so it fires either way. |
| 12 | `greater-than-or-equal-to(now() row3)` | Freshness on the **Goldsky** clock — independent of the settlement clock, hence a separate set (§16.4(b)). |
| 13 | `less-than-or-equal-to(now() row4)` | idem. |
| 14 | `less-than(sub(now() row3) oracle-price-timeout)` | idem. A prolonged Goldsky outage ages the frame out instead of making a held-last-good hash look perpetually fresh. |

### Product 2 (`#product-2-live` only)

Guards 1–6 repeat verbatim against `benchmark-2-slot`, plus
`equal-to(signed-context<benchmark-2-slot 4>() base)` — both benchmark frames
are built in the same request from the same clock, so their base years agree;
asserted rather than assumed because the two rows drive independent year
dispatches.

### Per-bucket and lifecycle

| Guard | Where | Rationale |
|---|---|---|
| `any(is-zero(weight) in-band)` with `in-band = every(greater-than(price price-min) less-than(price price-max))` | `#bucket-contribution` | §15 item 7 / D11 unchanged. Rainlang evaluates eagerly, so a drained, clamped or disabled bucket carrying price 0 must not trip the band and halt the whole order. |
| `greater-than(fair-value 0)` | `#curve-npv-floor` | **New.** Once every bucket has drained or been clamped past, a sell order would otherwise quote `hard-floor` (default 0) for the whole vault. Halting is correct, and it gives a readable revert instead of the `inv` divide-by-zero the buy orientation would hit. |
| `greater-than-or-equal-to(now() start-time)`, `less-than(now() add(start-time bp-horizon))` | `#calculate-io` | §7 guardrail 1, unchanged. Also bounds how many New Year rollovers an order can survive before its whole grid is behind `base_year`. |
| add-order binding consistency | `#handle-add-order` | §7 add-order list. Kept from v1; **added** `equal-to(benchmark-schema-version 2)`, `equal-to(asset-schema-version 3)`, `less-than-or-equal-to(benchmark-slot 3)`, `equal-to(asset-slot 4)`, `equal-to(benchmark-slot sub(benchmark-id 1))`, `is-zero(is-zero(meta-hash))`, and the product-2 slot/id pairing. |
| `any(is-zero(total2-a0) product-2-enabled)` | `#handle-add-order` | **New (H2).** `product-2-fn` is a *source* binding — invisible to every numeric guard — so a non-zero db2 grid deployed against `'product-2-off` passed everything and then quoted product-1-only fair value with no revert. That is a mispricing, not a halt. `product-2-enabled` is a numeric mirror of the fn binding (scenario-only, never a GUI field) so add-order can see the mismatch. |

### Deliberately removed

- `equal-to(signed-context<0 1>() input-token())` / `<0 2>() output-token()` —
  benchmark frames carry no token rows (D14); replay across assets is
  *intended*. Replaced by guard 10.
- `equal-to(signed-context<0 7>() year-0)` — the time bomb. See §3.
- `benchmark-2-id = 0` as the product-2 disable sentinel — there is no all-zero
  second series row any more (§16.4(c)). Replaced by the `product-2-fn` binding.

## 3. The year-offset pattern

`base_year` is derived per request as the current UTC year
(`oracle.rs:127` `current_utc_year`, `oracle.rs:186` comment "Always the current
UTC year"). It rolls at 00:00 UTC on 1 January. The bucket years `year-0..year-4`
are frozen at deploy. The v1 guard `row 7 == year-0` therefore halts every
order deployed in 2026 on 2027-01-01.

Rainlang cannot compute a row index — `signed-context<C R>()` resolves **both**
operands at parse time (`rain.orderbook/src/lib/LibOrderBookSubParser.sol:357`
`subParserSignedContext`, which masks `column` and `row` straight out of the
operand). But the *choice among five parse-time rows* can be made at run time.

```rainlang
#price-for-year
base year p0 p1 p2 p3 p4:,
_: conditions(
     equal-to(year base)          p0
     equal-to(year add(base 1))   p1
     equal-to(year add(base 2))   p2
     equal-to(year add(base 3))   p3
     equal-to(year add(base 4))   p4
     1 0
   );
```

Called once per bucket from `#curve-npv-floor` with
`base: signed-context<benchmark-slot 4>()` and `p0..p4:
signed-context<benchmark-slot 5..9>()`.

Three properties this gives:

1. **Rollover is a no-op.** On 2027-01-01 `base` becomes 2027; the `year-1`
   bucket now matches `equal-to(2027 base)` and reads row 5, the Bal-2027 level.
   No redeploy, no halt.
2. **Years above the strip contribute nothing.** `year-4 = 2030` with
   `base = 2026` matches row 9; with `base = 2025` it would match nothing and
   fall to the `1 0` default.
3. **Past years read 0 and are separately clamped.** The server emits `0` for a
   strip year below `base_year` and never back-fills (D16). Price 0 would trip
   the sanity band, so the weight is *forced* to zero:

```rainlang
live0: greater-than-or-equal-to(year-0 base),
...
weight: if(live raw-weight 0)     /* inside #bucket-contribution */
```

§16.4(a) is explicit that this must be *forced*, not merely relied on: linear
interpolation smears a dying bucket's weight a little past 31 December, and the
as-built server refuses to back-fill that year. What is discarded is bounded by
one breakpoint interval (~5 months at K=6 over 24 months) of a bucket already
drained to near-zero — a marginal under-valuation, preferred over halting every
order on New Year's Day. The §4/§6 previous-year republish grace period and
§13 open question 7 are both void.

**Deliberate deviation from the §16.4(a) snippet.** The spec's snippet writes
the `conditions` with five pairs and no default. That reverts on a past-year
bucket (`conditions` reverts when nothing matches — see §5 below), which
reintroduces exactly the halt it is meant to remove. The `1 0` default pair is
load-bearing.

**Terminal bucket.** `c5`/`d5` reuse `py4`/`live4` — strip-then-flat, unchanged
in substance from v1 (§6 "the terminal bucket consumes no feed key of its own").
What changed is that "the last strip year" now resolves dynamically through the
same dispatch instead of being pinned to a deploy-time row index.

## 4. The `conditions` default-value bug

`rain.interpreter/src/lib/op/logic/LibOpConditions.sol` `run`:

```solidity
oddInputs := mod(inputs, 2)
end := add(cursor, mul(sub(inputs, oddInputs), 0x20))
if oddInputs { reason := mload(end) }
...
if (conditionIsZero) { revert(reason.toString()); }
```

An odd input count makes the trailing item the **revert reason**, not a
fallback value. The authoring meta says the same
(`rain.interpreter/src/lib/op/LibAllStandardOps.sol`, `conditions`): *"If no
conditions are nonzero, the expression reverts. Provide a constant nonzero
value to define a fallback case."*

The v1 `#bucket-interp` ended in a bare `v4` — **9 inputs** (4 cond/value pairs
plus the trailing item), odd — so `seg-index 4`, reached for **every** `t-frac`
in `[0.8, 1]`, reverted with the message `"v4"` instead of returning the last
segment.

Both `conditions` in these templates now use an explicit `1 <default>` **pair**,
keeping the input count even (10 and 12). `#bucket-interp` additionally gained a
`less-than(seg-index 5) v4` pair so its default returns `bp-f` — see L3 below.

**Input cap.** `LibOpConditions.integrity` and `run` mask the input count with
`0x0F`, and the parser refuses to encode more than 15 either way:
`rain.interpreter/src/lib/parse/LibParseState.sol:408` reverts
`OpcodeIOOverflow` when `opInputs > 0x0F`. Both uses here are within it.

**Correction to an earlier claim in this document.** The shipped
`oil-token-projection-npv-dca.rain` `#bbl-remaining-per-token` uses a 23-input
`conditions`. That is **above the parser's 15-input ceiling**, so it is not a
runtime revert at `t-frac = 1` as previously written here — as written, that
source **cannot parse at all**. Either the file was never deployed in this form,
or the deployed Base parser differs from the interpreter source read here.
Flagged as open question 10; it needs an on-chain check, not a code change in
these templates.

**L3 — `#bucket-interp`'s default endpoint.** With a plain `1 v4` default,
`seg-index == 5` (i.e. `t-frac == 1`, `within == 0`) evaluates `v4` to
`bp-e + (bp-f - bp-e)*0 = bp-e`, the *second-to-last* anchor. That is wrong, and
it was unreachable only because `#calculate-io` enforces
`now < start-time + bp-horizon` **strictly**. The dispatch now carries an
explicit `less-than(seg-index 5) v4` pair and defaults to `bp-f`, so the shared
function is correct independent of its caller's guard.

## 5. Every Rainlang word used, with a citation

Word definitions: `rain.interpreter/src/lib/op/LibAllStandardOps.sol`
(`authoringMetaV2()`), unless noted.
Orderbook subparser words: `rain.orderbook/src/lib/LibOrderBookSubParser.sol`.
Paths are relative to `/Users/alastairong/Albion/albion.rest.api/lib/rain.orderbook`.

| Word | Citation | Semantics relied on |
|---|---|---|
| `add` | LibAllStandardOps.sol | "Adds all numbers together." |
| `any` | LibAllStandardOps.sol | "The first non-zero value out of all inputs, or 0 if every input is 0." |
| `call<'src>(…)` | LibAllStandardOps.sol | "Calls a source by index in the same Rain bytecode… The first operand is the source index." |
| `conditions` | LibAllStandardOps.sol + `src/lib/op/logic/LibOpConditions.sol` | pairwise cond/value; reverts if none match; odd input ⇒ trailing item is the revert reason; ≤15 inputs. |
| `div` | LibAllStandardOps.sol | "Divides the first number by all other numbers. Errors if any divisor is zero." |
| `ensure` | LibAllStandardOps.sol | "Reverts if the first input is 0… The second input is a string used as the revert reason. Has 0 outputs." |
| `equal-to` | LibAllStandardOps.sol | "1 if all inputs are equal, 0 otherwise. **Equality is numerical.**" — the bytes32 caveat in §6 below. |
| `every` | LibAllStandardOps.sol | "The last nonzero value out of all inputs, or 0 if any input is 0." |
| `floor` | LibAllStandardOps.sol | "Floor of a number." |
| `frac` | LibAllStandardOps.sol | "Fractional part of a number." |
| `get` / `set` / `hash` | LibAllStandardOps.sol | DCA epoch state; unchanged from the shipped DCA template. |
| `greater-than` | LibAllStandardOps.sol | "true if the first input is greater than the second input." |
| `greater-than-or-equal-to` | LibAllStandardOps.sol | as named. |
| `if` | LibAllStandardOps.sol | "If the first input is nonzero, the second input is used. Otherwise, the third. **If is eagerly evaluated.**" |
| `inv` | LibAllStandardOps.sol | "The inverse (1 / x)… Errors if the number is zero." |
| `is-zero` | LibAllStandardOps.sol | "1 if the input is 0, 0 otherwise. The input is any **numerical** 0 value." |
| `less-than` | LibAllStandardOps.sol | as named. |
| `less-than-or-equal-to` | LibAllStandardOps.sol | as named. |
| `linear-growth` | LibAllStandardOps.sol + `src/lib/op/math/growth/LibOpLinearGrowth.sol` | `base + rate*t` — **not** a lerp. Only used in the untouched DCA `#amount-for-epoch`. |
| `max` / `min` | LibAllStandardOps.sol | as named. |
| `max-positive-value` | LibAllStandardOps.sol | "so large that it is effectively infinity." Untouched from v1 limit template — but see open question 7. |
| `mul` | LibAllStandardOps.sol | "Multiplies all numbers together." |
| `now` | LibAllStandardOps.sol | "The current block timestamp." |
| `power` | LibAllStandardOps.sol | "Raises the first number to the power of the second number." Only in the untouched DCA `#halflife`. |
| `sub` | LibAllStandardOps.sol | "Subtracts all numbers from the first number." |
| `input-token` / `output-token` | LibOrderBookSubParser.sol:58,63 | order's live IO addresses. |
| `order-hash` | LibOrderBookSubParser.sol:53 | DCA state keys; untouched. |
| `output-vault-decrease` | LibOrderBookSubParser.sol:67 | DCA `#handle-io`; untouched. |
| `signer<N>()` | LibOrderBookSubParser.sol:440 + :261 | "The addresses of the signers of the signed context. The indexes of the signers matches the column they signed in the signed context grid." Operand = signer index. |
| `signed-context<C R>()` | LibOrderBookSubParser.sol:446 + :357 | operand low byte = column offset from `CONTEXT_SIGNED_CONTEXT_START_COLUMN` (=6, `src/lib/LibOrderBook.sol:92`), next byte = row. Both parse-time. |
| `using-words-from` | precedent: every `.rain` in this repo; ST0x `st0x-oracle-limit-v4.rain` | subparser pragma; kept at the document-top entrypoints only. |

Dotrain-level constructs, all evidenced from shipped files rather than
invented:

| Construct | Precedent |
|---|---|
| `#name !description` elided binding | every `src/*.rain` in this repo |
| function binding `target-io-fn: '''curve-npv-limit-io'` + `call<'target-io-fn>()` | `src/auction-dca.rain` (`baseline-fn`), imported v1 templates |
| `${order.outputs.0.token.address}` scenario interpolation | `src/fixed-limit.rain` (`fixed-io-output-token`) |
| `oracle-url:` in the order block | ST0x `strategy/st0x-oracle-limit-v4.rain` + `strategy/settings.yaml` (recovered from `albion.oracle-server` git history, blobs `6fb425c…` / `655bf99…`; also live at `ST0x-Technology/st0x-oracle-server@main`) |
| a **numeric binding in operand position** (`signed-context<benchmark-slot 4>()`, `signer<asset-slot>()`) | **Not** previously shipped. Verified empirically — see §7. |

## 6. The `equal-to`-on-raw-bytes32 caveat, restated

Carried forward verbatim from §15 item 5, and re-affirmed by §16.4(b):

> `equal-to` has DecimalFloat numeric semantics, not bitwise; acceptable because
> the frame is signed by the trusted key (collision requires our own server
> signing a numerically-equal-but-different hash — negligible, and failure mode
> is a missed halt bounded by price bands). st0x ships the same
> equal-to-on-bytes32 pattern in production.

Concretely, asset frame rows 1 and 2 are raw bytes32
(`oracle.rs:249-250`), so `equal-to` reinterprets them as DecimalFloat — top
4 bytes exponent, low 28 bytes coefficient.

- **Row 1 (address) is safe unconditionally.** A left-padded 20-byte address has
  all-zero bytes 0..11, so the exponent field is 0 and numeric equality is exact.
  This is the same case st0x ships (`st0x-oracle-limit-v4.rain` rows 6/7).
- **Row 2 (metaHash) carries the caveat.** Arbitrary 32 bytes ⇒ arbitrary
  exponent. Two distinct hashes could in principle normalise equal; the failure
  mode is a *missed* halt, bounded by the price bands, never a wrong price.

`binary-equal-to` ("1 if all inputs are equal, 0 otherwise. **Equality is
binary.**", `LibAllStandardOps.sol`) would remove the caveat for row 2. It is
**not** used, because these templates have not been parsed against the deployed
Base rainlang parser (`0xd905B56949284Bb1d28eeFC05be78Af69cCf3668` per
`settings.yaml`) and its availability there is unverified. Flagged as open
question 1.

Related: the add-order guard is written `is-zero(is-zero(meta-hash))` rather
than `greater-than(meta-hash 0)`, precisely to avoid an *ordering* comparison at
an arbitrary exponent. `is-zero` only inspects the coefficient.

## 7. Validation — what was and was not done

### Achieved: dotrain parse + compose

`rain` CLI: **not available.** The registry repo has no `flake.nix` and no nix
dev shell (`ls` shows only `README.md registry scripts settings.yaml src
token-lists .github`); `which rain` finds nothing.

Fallback (b) was used: `@rainlanguage/orderbook` **0.0.1-alpha.229** from
`/Users/alastairong/Albion/wt-thin-ui/node_modules`, via
`DotrainOrder.create()` → `composeDeploymentToRainlang()` /
`composeScenarioToPostTaskRainlang()`.

Both templates compose cleanly, in both product-2 modes:

| Template | product-2 mode | `calculate-io` doc | `handle-add-order` doc |
|---|---|---|---|
| limit | `'product-2-off` | OK, 11155 chars, 9 sources | OK, 2952 chars |
| limit | `'product-2-live` | OK, 12202 chars, 9 sources | OK, 2952 chars |
| dca | `'product-2-off` | OK, 13163 chars, 16 sources | OK, 3099 chars |
| dca | `'product-2-live` | OK, 14221 chars, 16 sources | OK, 3099 chars |

(Re-run after the review fixes in `44d37af`; the earlier run of the same suite
on `adab302` also passed, at slightly smaller sizes.)

Confirmed by inspecting composed output: `signed-context<benchmark-slot 4>()`
emits `signed-context<0 4>()`, `signer<asset-slot>()` emits `signer<4>()` — so
**a numeric dotrain binding is legal in operand position**, which the whole
slot-pinning design depends on. This was verified first in isolation with a
5-line probe dotrain before being relied on.

Compose also confirms that `benchmark-id` / `benchmark-2-id` moving from GUI
fields to scenario bindings (M3) leaves only `start-time` and `bp-horizon`
elided on the real `sell` / `buy` deployments — i.e. exactly the two the GUI is
meant to supply.

Compose ran against a throwaway `validate` scenario supplying all 101 (limit) /
110 (dca) elided bindings, plus the repo's own `settings.yaml`. Only the
`version:` field had to change (6 → 5) because alpha.229 rejects spec version 6;
the frontmatter vocabulary (`raindex:`, `rainlang:`, `oracle-url:`) is accepted
as written. The probe harness lives in the session scratchpad and is not
committed.

### NOT achieved: on-chain parse

Composition validates dotrain syntax, binding resolution, `call<>` targets and
source assembly. It does **not** invoke the Rainterpreter parser, so none of the
following is verified:

- word availability and **arity/operand limits** on the deployed Base parser
  (`0xd905B5…3668`), in particular `conditions` with 12 inputs and `call` with
  11 stack inputs;
- expression size and stack-depth limits;
- gas.

Blocked by: no `rain` CLI in this repo's toolchain, no local anvil/Base fork set
up in this session, and `@rainlanguage/orderbook` exposing no parse-only entry
point that does not need an RPC.

### Independently verified by adversarial review

A separate review of this branch checked and found **clean**: all frame row
indices against `oracle.rs`; both `conditions` input counts (10 and 12, even,
≤ 15); `equal-to` on the address rows (sound — zero exponent field short-circuits
the normalisation concern); a simulated 1 January base_year remap through
`#price-for-year`; guard ordering within `#frame-guards`; the additivity of the
`handle-add-order` additions; and `now()` type discipline across the freshness
comparisons. It also confirmed `binary-equal-to` exists in this interpreter
source (`LibAllStandardOps.sol:222`). The findings it raised are fixed in
`44d37af` (C1, H2, H3, M2, M3, L1, L3) or recorded in §8.2 and §9 (M1, M4, M5,
H4, L2).

**Also not done:** no numeric quote was computed against a real frame. The live
strip values were fetched (see §1) and hand-checked against the DecimalFloat
encoding, but no end-to-end "given this grid and this strip, io = X" assertion
exists. §14's integration matrix — especially §16.8 item 2, a fixture crossing a
UTC year boundary mid-deployment — is still owed.

## 8. Placeholder / unresolved values

Everything below must be replaced or confirmed before a real deploy.

| Value | Current state | What it needs |
|---|---|---|
| `oracle-url` | **v1 placeholder, injected at deploy** — see §8.1. Do not edit. | nothing in this file; configure `PUBLIC_CURVE_ORACLE_URL`. |
| `oracle-signer` | **zero-address placeholder, injected at deploy** — see §8.1. Do not edit. | nothing in this file; configure `PUBLIC_CURVE_ORACLE_SIGNER`. |
| `meta-hash` | no default; add-order rejects zero | **No real Goldsky `metaV1S.metaHash` exists anywhere in the local repos** — every occurrence is a placeholder (`'0xhash'`, `"0x1234"`, `"0x"`). A genuine production CBOR payload does exist (`Albion-issuance-site/src/e2e/http-mock.ts:12`) but its hash is not recorded. Read it from Goldsky at deploy. |
| `db-y*-bp*` grid (36 cells) | no defaults | Produced by `computeBucketNpvGrid()` in `albion.dex/src/lib/services/deploymentArgs.ts` (not yet written for this frame version). Inputs below. |
| `raindex-subparser` | `0x22839F16281E67E5Fd395fAFd1571e820CbD46cB` | Copied from `src/fixed-limit.rain` scenario `base` in this repo. Confirm it is current. |
| `benchmark-slot` / `benchmark-id` | `0` / `1` (Brent), both scenario bindings | Correct for Wressle-1. A gas asset needs a sibling scenario binding **slot and id together** (2/3 for NBP, 3/4 for TTF) — `handle-add-order` enforces `slot == id - 1`. Neither is a GUI field any more (M3). |
| `start-time` / `bp-horizon` | no defaults | §13 open question 2: 24 months proposed. Note this also bounds how many New Year rollovers an order survives (see open question 3). |
| `price-min` / `price-max` | 10 / 500 (carried from v1) | Brent-appropriate. **These defaults brick any NBP/TTF scenario** — NBP is currently ~$19.4/MMBtu falling to ~$8.9 by 2030, so a floor of 10 halts the 2028+ buckets on day one. See M4 in §8.2: the band is a whole-order kill switch, and its defaults must be set per benchmark by the deploy-side builder, not carried. |
| `oracle-price-timeout` | default now **345600** (= the server validity window) | Confirm 96h is the intended availability/optionality trade-off; see H3/H4 in §8.2. |
| `price-multiplier` | 0.80 | Spec default. |

### 8.1 The oracle injection contract — do not hard-code

`oracle-url` and `oracle-signer` are **placeholders that the consumer rewrites
at deploy**. `albion.dex/src/lib/clients/rainStrategies.ts` holds them as exact
string constants and rewrites them with `replaceAll`:

```ts
const ORACLE_URL_PLACEHOLDER = 'oracle-url: https://oracle.albionlabs.org/context/v1';
const ORACLE_SIGNER_PLACEHOLDER = 'oracle-signer: 0x0000000000000000000000000000000000000000';
...
return text
    .replaceAll(ORACLE_URL_PLACEHOLDER, `oracle-url: ${baseUrl}/context/v1`)
    .replaceAll(ORACLE_SIGNER_PLACEHOLDER, `oracle-signer: ${signer}`);
```

The zero-address signer is **fail-safe by construction**: it matches no real
signer, and the UI additionally gates the deploy on
`isCurveOracleConfigured()`, so an un-injected template cannot reach the chain.

An earlier revision of this branch pasted the live staging URL and signer into
the frontmatter. That is a **fail-open** change: `replaceAll` silently finds
nothing, and every environment — production included — deploys orders bound to
staging. Both placeholders are now restored byte-for-byte, and the surrounding
comment is worded so it does not itself contain either constant (otherwise
`replaceAll` would also rewrite the documentation).

Environment values, for reference only — **never paste these into a template**
(spec §16.6, `/status` verified 2026-07-30):

| Env | URL | Signer |
|---|---|---|
| staging | `https://albion-oracle-mrflki6foq-ey.a.run.app` | `0xCEd8AAb28809FbeAa9DE9E576A6255663C58DC78` |
| production | `https://albion-oracle-nu5w4hcuuq-ey.a.run.app` | `0x818D8Db28E07eaE7c75026D53cA4CCBeB5ee7b3D` |

URL and signer are one unit: either alone halts every order. A KMS
`cryptoKeyVersion` bump changes the signer address, so signer rotation is a
strategy migration (halt + redeploy every live order), not an ops action.

**Follow-up owed on the dex side (out of scope for this repo):** the injector
should **fail loudly when a placeholder is not found**, rather than returning
the text unchanged. Today the only thing standing between a mis-edited template
and a wrong-oracle deploy is code review. A post-replacement assertion — that
each placeholder was found at least once, and that no `oracle-url` /
`oracle-signer` line still holds a non-injected value — turns C1's failure class
from silent to loud.

### 8.2 Review findings recorded here rather than fixed in the templates

**M1 — the 1 January weight cliff may be a material step, not a rounding
error.** §3 argues the past-year clamp discards "a bucket already drained to
near-zero". That is an assumption about the *shape* of the grid, not a
guarantee. With the spec's default K=6 anchors over a 24-month horizon the
anchor spacing is ~4.8 months, and the year-0 column's value at 31 December is
whatever `computeBucketNpvGrid` put there — for a front-loaded profile it can
still be a meaningful fraction of total NPV. The clamp then removes it in a
single block. Before shipping, `computeBucketNpvGrid` must be **quantified
against this**: compute the year-0 column's residual at the last instant of the
deploy year for each real asset and state the resulting price step. If it is not
negligible, the deploy-side builder should **pre-drain the year-0 column** so
the grid itself reaches zero at the year boundary and the clamp becomes a no-op.

**M4 — the price band is a whole-order kill switch.** `#bucket-contribution`
halts the *entire* order when any **weighted** bucket's strip price falls outside
`(price-min, price-max)`. A single live far-year bucket with a 0 or out-of-band
price therefore stops all trading, not just that bucket's contribution. That is
halt-not-misprice and it is intentional (§5, D11) — but it makes the band
defaults load-bearing, and the carried-over `price-min: 10` is a Brent number
that would brick any NBP or TTF scenario immediately (2030 NBP ≈ $8.9/MMBtu).
Band defaults must be **set per benchmark at deploy**, alongside the
slot/id pair.

**M5 — nothing ties `year-0` to wall-clock time.** `handle-add-order` checks
that `year-0..year-4` are consecutive, but not that `year-0` is the current or
an upcoming calendar year: there is no year word, and `now()` is a unix
timestamp, not a year. A grid baked with a wrong `year-0` therefore **deploys
cleanly and halts on the first quote** (no slot matches, every weight clamps,
the new `fair-value > 0` guard fires). Fail-safe, but a silent one: the user
learns after the add-order transaction. Validating `year-0` against the
deployment date is a **deploy-side builder responsibility** and should be an
explicit check there.

### Real Wressle-1 data found (for the grid builder, not baked here)

Sourced from `albion.rewards/schemas/example.wressle.json` and the published
per-month metadata dumps under `albion.rewards/output/*/0xf836…/metadata.json`
(identical across 19 dumps):

- **Production forecast**: 32 monthly points, 2025-05 → **2027-12**, total
  8,644.72 bbl. Annual totals 2025 2,586.96 / 2026 3,574.17 / 2027 2,483.595.
  `asset.technical.expectedEndDate = "2027-12"`.
- Remaining as at 2026-07-30: 2026 Aug–Dec = **1,542.465 bbl**; 2027 =
  **2,483.595 bbl**; 2028 onward = **0**. So bucket years 2028/2029/2030 and the
  terminal bucket are all zero for this asset — the past-year clamp and the
  strip-then-flat terminal both go untested by Wressle and need a synthetic
  fixture.
- **Royalty share**: `sharePercentage` 2.5 (R1) / 7.5 (R2) of a 4.5% gross
  royalty already netted upstream; supply **12,000** (R1, not the 20,000 in the
  token list) / **36,000** (R2). Both give the same per-token factor
  `0.025/12000 = 0.075/36000 = 1/480000`. So bbl/token: 2026 remaining
  **0.00321346875**, 2027 **0.00517415625**.
- **Differential**: `benchmarkPremium = -1.3`, `transportCosts = 0` ⇒
  `net-price-adjustment = transportCosts - benchmarkPremium = **1.3** $/bbl`
  (deducted from the strip price).
- **Discount rate**: no Wressle-specific value exists. The UI default is
  **10%/yr**, converted as `monthlyRate = (1+annual)^(1/12) - 1`
  (`deploymentArgs.ts:417`).

Sanity check at the live strip (Brent 2026 85.6375, 2027 76.29833) with 10%/yr
mid-period discounting: fair value ≈ **0.62 USD/token**, floor at ×0.80 ≈
**0.50 USD/token**. Same order of magnitude as the hardcoded R1 auction reserve
price of 0.88 in `albion.dex/src/lib/config/network.ts` (itself flagged
in-comment as an estimate).

## 9. Open questions for review

1. **`binary-equal-to` for the metaHash row — do it.** Review confirmed the word
   **exists** in this interpreter source (`LibAllStandardOps.sol:222`, raw `eq`),
   so the only open part is whether the deployed Base parser
   (`0xd905B56949284Bb1d28eeFC05be78Af69cCf3668`) carries it. `equal-to`'s
   float-normalisation caveat on an arbitrary bytes32 (§6) is a real defect, not
   a theoretical one — it is currently fail-safe (a missed halt bounded by the
   price bands, never a wrong price), which is why it is not being changed blind.
   **Switch guard 11 to `binary-equal-to` in the same pass that does the on-chain
   parse verification**, so word availability and the switch are confirmed
   together in one round trip.
2. **Where do these files live?** They are on `feat/curve-npv-strategy` in
   `albion.registry` because that is where this task was scoped, but the
   originals are `albion.dex/src/lib/strategies/`. If they stay in the registry,
   `src/registry` needs two new lines and a re-pin. If they go back to
   `albion.dex`, `raindex:` reverts to `orderbook:` in the order and both
   scenarios (three lines per file) — that is the only repo-specific difference.
3. **Rollover budget.** With `bp-horizon` = 24 months an order survives at most
   two 1-January rollovers before `year-4` can fall below `base_year` and the
   whole grid clamps to zero weight (halting on the new `fair-value > 0`
   guard). Is that the intended lifetime, or should the deploy-side grid be
   built with a forward-shifted `year-0` so the horizon and the strip coverage
   line up?
4. **Front-year Bal semantics.** The base_year strip level is a
   *balance-of-year* average, i.e. the price of the months still to come, while
   `db-y0-bp*` is the discounted production of those same months. That pairing
   is right at breakpoint 0 and drifts within a segment. Was that intended, and
   does `computeBucketNpvGrid` build the year-0 column on remaining months only?
5. ~~**Buy-side token labelling.**~~ **RESOLVED (M2).** The imported `buy` GUI
   block had `sell`'s labels. The binding was right — for a buy order the *input*
   is the royalty token — so the labels were corrected, and both orientations now
   state explicitly which side must be the Albion asset token.
6. **Product-2 `benchmark-2-slot` / `benchmark-2-id` when disabled.** Bound to
   `1` / `2` and never read in the `'product-2-off` scenarios. They are kept
   internally consistent (slot 1 == WTI == id 2) so flipping `product-2-fn`
   needs no other edit, and `product-2-enabled` (H2) now stops a stray db2 grid
   from being silently ignored. A reviewer may still prefer an obviously-inert
   value or a separate elided-binding set.
7. **`max-output: max-positive-value()` in the limit template.** Carried over
   unchanged, but combined with the new `fair-value > 0` halt it means the order
   offers the entire vault at the computed floor with no per-trade cap. Worth
   confirming that is still wanted for a royalty token.
8. **`conditions` 15-input cap.** `LibOpConditions` masks the input count with
   `0x0F`. Both uses here are within it (10 and 12), but any future extension of
   the year dispatch past 7 pairs would silently misbehave. Worth a comment in
   the deploy-side builder.
9. **`oracle-price-timeout` = 96h is now the default** (H3), which makes the
   frame's own `expires-at` row the effective freshness guard and removes the
   predictable weekend halt. The cost is taker optionality (H4): within the
   window a taker may replay whichever signed frame prices most favourably, so
   96h is 96h of free look-back on a moving strip. Shortening it trades
   availability for tighter pricing and reintroduces settlement-gap halts. Is
   96h the right point on that curve, or should the server's
   `validity_window_secs` come down instead?
10. **The shipped `oil-token-projection-npv-dca.rain` cannot parse as written**
   (§4): its `#bbl-remaining-per-token` `conditions` takes 23 inputs, above the
   parser's 15-input ceiling (`LibParseState.sol:408`, `OpcodeIOOverflow`). Since
   that strategy is believed live, either it was never deployed in this form or
   the deployed Base parser differs from the interpreter source read here.
   **Needs an on-chain check** — pair it with open question 1's parse call.

## 10. Provenance of every external source used

| Source | How obtained |
|---|---|
| `albion.dex@origin/feat/curve-npv-strategy:src/lib/strategies/oil-token-curve-npv-{dca,limit}.rain` | `git -C wt-thin-ui fetch origin feat/curve-npv-strategy` + `git show`. Byte-identical to the copies under `albion.dex/.claude/worktrees/curve-npv/`. |
| Design spec §16 | `git -C wt-thin-ui show origin/docs/curve-oracle-spec-v4:docs/superpowers/specs/2026-07-03-curve-npv-oracle-strategy-design.md` |
| Design spec §1–15 | `/Users/alastairong/Albion/albion.dex/docs/superpowers/specs/2026-07-03-curve-npv-oracle-strategy-design.md` |
| Oracle frame contract | `/Users/alastairong/Albion/albion.oracle-server/README.md`, `src/oracle.rs` |
| Live frame + strip | `GET https://albion-oracle-mrflki6foq-ey.a.run.app/context/v1/brent`, `/strip`, `/status` (2026-07-30) |
| ST0x signed-context precedent | `strategy/st0x-oracle-limit-v4.rain`, `strategy/settings.yaml` — recovered from `albion.oracle-server` git history (`git cat-file -p 6fb425c186b88fcb6c42550735b82649329b88cf` / `655bf99491fa78e8654aa8e25dcbd6fb1cd44743`); `st0x-oracle-limit-v4.rain` also still present at `ST0x-Technology/st0x-oracle-server@main`. |
| Word definitions | `/Users/alastairong/Albion/albion.rest.api/lib/rain.orderbook/lib/rain.interpreter/src/lib/op/LibAllStandardOps.sol`, `.../op/logic/LibOpConditions.sol`, and `/Users/alastairong/Albion/albion.rest.api/lib/rain.orderbook/src/lib/LibOrderBookSubParser.sol`, `src/lib/LibOrderBook.sol` |
| Wressle data | `albion.rewards/schemas/example.wressle.json`, `albion.rewards/output/*/0x{f836…,1d57…}/metadata.json`, `albion.dex/static/token_terms/0x{f836…,1d57…}.md`, `albion.dex/src/lib/services/deploymentArgs.ts` |
