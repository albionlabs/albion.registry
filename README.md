# albion.registry

Albion Labs token + strategy registry for Raindex, consumed by
[`albion.rest.api`](https://github.com/albionlabs/albion.rest.api) and
[`albion.dex`](https://github.com/albionexchange/albion.dex).
Same format as [st0x.registry](https://github.com/ST0x-Technology/st0x.registry).

## Layout

- `registry` — the registry index. First line is the URL of the shared
  `settings.yaml`; each subsequent line is `<key> <url>` pointing at a
  dotrain strategy in `src/`. **Every URL is pinned to a commit SHA** —
  after changing any referenced file, commit, then update the pinned SHAs
  and commit again.
- `settings.yaml` — shared Raindex settings (version 6): Base network RPCs,
  orderbook subgraph, the Raindex orderbook deployment on Base, local-db
  sync configuration, and `using-tokens-from` pointing at the token list.
- `token-lists/base.json` — Albion token list (Uniswap Token List format):
  the tokenized royalty assets plus USDC (the settlement token — required so
  the REST API's swap endpoints accept it as an input/output token).
- `src/*.rain` — dotrain strategies (with optional `.md` descriptions).
- `scripts/` + `.github/workflows/` — build a self-contained
  `data:` URI of the registry (optionally injecting private RPC URLs from the
  `PRIVATE_BASE_RPC_URLS` secret) and PUT it to a running API's
  `/admin/registry` endpoint. Secrets:
  `ALBION_REST_API_URL` / `ALBION_REST_API_ADMIN_KEY_ID` /
  `ALBION_REST_API_ADMIN_SECRET` (production) and the `STAGING_`-prefixed
  equivalents.

## How the API consumes it

`albion.rest.api` is started with `registry_url` pointing at the raw
`registry` file (or a `data:` URI built by the workflows). At boot it fetches
`settings.yaml` and every strategy, merges them, and builds a Raindex client
whose orderbook address, RPCs, subgraph, and curated token set all come from
here. The registry can be hot-swapped on a running server via
`PUT /admin/registry`.
