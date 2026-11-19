defmodule GoodFlowsWeb.Schemas.CacheUploadParts do
  @moduledoc "OpenAPI schema for the `parts` of a multipart cache reservation."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheUploadParts",
    description: """
    Upload the archive as parts of `size` bytes (the last part holds the
    rest). `md5` lists the padded base64 MD5 (24 characters, 16 bytes) of
    every part in order; it must have `ceil(reservation size / size)`
    entries, at most 10,000. Exactly these two keys; anything else is `422`
    on `parts`.
    """,
    type: :object,
    required: [:size, :md5],
    additionalProperties: false,
    properties: %{
      size: %Schema{type: :integer, minimum: 5_242_880, maximum: 5_368_709_120},
      md5: %Schema{
        type: :array,
        minItems: 1,
        maxItems: 10_000,
        items: %Schema{type: :string, minLength: 24, maxLength: 24, format: :byte}
      }
    },
    example: %{
      "size" => 16_777_216,
      "md5" => ["1B2M2Y8AsgTpgAmY7PhCfg==", "1B2M2Y8AsgTpgAmY7PhCfg=="]
    }
  })
end
