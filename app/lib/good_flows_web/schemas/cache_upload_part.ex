defmodule GoodFlowsWeb.Schemas.CacheUploadPart do
  @moduledoc "OpenAPI schema for one presigned part PUT of a multipart cache reservation."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CacheUploadPart",
    description: """
    PUT part `number` to `url` with exactly `headers` and no
    `Authorization`. The headers are signed into the URL, so the store
    rejects a part whose length or MD5 differs (`400 BadDigest`) or that
    omits them (signature error).
    """,
    type: :object,
    required: [:number, :url, :headers],
    properties: %{
      number: %Schema{type: :integer, minimum: 1, maximum: 10_000},
      url: %Schema{type: :string, format: :uri},
      headers: %Schema{
        type: :object,
        required: ["content-length", "content-md5"],
        properties: %{
          "content-length" => %Schema{type: :string},
          "content-md5" => %Schema{type: :string, description: "Base64 of the part's MD5"}
        }
      }
    }
  })
end
