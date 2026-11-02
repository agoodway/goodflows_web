# GoodFlows

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Sprite pools: package the transfer helper before `mix release`

Sprite pools install the `gf-transfer` helper (the Rust crate in
`../sprite-transfer`) into every pool member. The release must contain the
packaged binaries and their manifest in `priv/gf-transfer/` (gitignored), so
build them **before** `mix release`:

```sh
rustup target add x86_64-unknown-linux-musl aarch64-unknown-linux-musl
../sprite-transfer/scripts/package.sh        # writes priv/gf-transfer/
MIX_ENV=prod mix release
```

A production node with `POOLS_ENABLED=true` (the default) and a missing or
invalid `priv/gf-transfer/manifest.json` refuses to boot; set
`POOLS_ENABLED=false` to run without pools. In dev and test such a node only
logs an error and disables pools. See `../sprite-transfer/README.md`
("Packaging, release and deploy order") for the details, and
`../docs/pool-protocol.md` for the client protocol.

`mix precommit` builds the helper's debug binary (`cargo build`), so the
transfer tests run against it; it does not run the crate's own checks
(`cargo test`, `cargo fmt --check`, `cargo clippy`).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
