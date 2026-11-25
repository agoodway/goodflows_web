# GoodFlows

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:7654`](http://localhost:7654) from your browser.

To run in production, see [Run in production with Docker](#run-in-production-with-docker).

## Run in production with Docker

The [Dockerfile](Dockerfile) builds a release image. The image holds no settings. The release reads them all from environment variables and refuses to start when a required one is missing.

```sh
docker build -t goodflows .
```

### Required environment variables

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | PostgreSQL URL in the form `ecto://USER:PASS@HOST/DATABASE`. |
| `SECRET_KEY_BASE` | Signs and encrypts cookies. Generate with `openssl rand -base64 48`. |
| `CLOAK_KEY` | Base64 of a 32-byte key. It encrypts the Sprites tokens stored in the database, so keep the same value for the life of that database. Generate with `openssl rand -base64 32`. |
| `RELEASE_COOKIE` | Erlang distribution cookie. Anyone who knows it and can reach a node's distribution port can run code on that node. Use the same value on every node of a cluster. Generate with `openssl rand -hex 32`. |
| `POSTMARK_API_KEY` | Postmark API token. Registration sends a sign-in link by email, so new users cannot get in until mail works. |
| `MAILER_FROM_EMAIL` | Sender address for that mail. |

### Defaults to override in a container

The server starts without these, but the defaults do not suit most Docker setups.

| Variable | Default | Set it to |
| --- | --- | --- |
| `PHX_HOST` | `example.com` | The public hostname, without a scheme. Links in emails and redirects point to `https://PHX_HOST`. |
| `RELEASE_NODE` | `good_flows@<hostname>` | A node name that stays the same across restarts, such as `good_flows@127.0.0.1` for a single node. Docker gives every new container a new hostname, and `bin/good_flows rpc` cannot connect to a node under that default name. In a cluster, give each node a unique name whose host part the other nodes can resolve. |
| `ECTO_SSL` | `true` | `false` when PostgreSQL does not offer TLS. Otherwise the connection fails with `ssl not available`. |
| `PORT` | `4000` | The HTTP port to listen on. |

### Example

Put the variables in an env file. Write the values without quotes, because Docker passes them to the container as written.

```sh
PHX_HOST=flows.example.com
DATABASE_URL=ecto://goodflows:password@db.internal/goodflows
ECTO_SSL=false
SECRET_KEY_BASE=
CLOAK_KEY=
RELEASE_COOKIE=
RELEASE_NODE=good_flows@127.0.0.1
POSTMARK_API_KEY=
MAILER_FROM_EMAIL=noreply@example.com
```

Run the migrations, then start the server. Run the migrations again before you start a new version.

```sh
docker run --rm --env-file goodflows.env goodflows /app/bin/migrate
docker run -d --env-file goodflows.env -p 4000:4000 goodflows
```

### PostgreSQL and TLS

The migrations create the `citext`, `pg_trgm` and `pgcrypto` extensions, so the database user must be allowed to create them.

The server listens on plain HTTP. It redirects every request to `https://PHX_HOST` unless the request's host is `localhost` or `127.0.0.1`. Put a proxy in front that terminates TLS and sets `X-Forwarded-Proto: https`.

### Optional settings

[.env.sample](.env.sample) describes the optional variables: `POOL_SIZE`, `ECTO_IPV6`, `DNS_CLUSTER_QUERY`, `CORS_ORIGINS`, `SENTRY_DSN`, `MAILER_FROM_NAME`, the upload limits and the remote cache storage (`CACHE_S3_*`). Its values are development defaults, so do not use it as the production env file.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
