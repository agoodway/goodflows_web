defmodule GoodFlowsWeb.Schemas.StoredChangePushRequest do
  @moduledoc "OpenAPI schema: a stored change push."
  require OpenApiSpex

  alias GoodFlowsWeb.Schemas.StoredChangeSource
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StoredChangePushRequest",
    description: """
    The files of a `goodflows/changes/<id>/` directory and where they were pushed from.
    `files` maps each path to its text: `change.md` (required), `qa-scenarios.md`,
    `verification.md` and `specs/<capability>/spec.md` (`<capability>` one or more
    `/`-separated segments matching `[a-z0-9][a-z0-9-]*`), each path at most 512 bytes,
    at most 100 files and 2,097,152 bytes of text, and no U+0000. The change id is read
    from `change.md`'s front matter.
    """,
    type: :object,
    required: [:files, :source],
    additionalProperties: false,
    properties: %{
      files: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
      source: StoredChangeSource
    }
  })
end
