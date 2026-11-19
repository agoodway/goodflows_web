defmodule GoodFlowsWeb.Schemas.CacheEntry do
  @moduledoc "OpenAPI schema for a committed cache entry (a lookup or commit hit)."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  @hex64 %Schema{type: :string, pattern: "^[0-9a-f]{64}$"}

  @doc "A 64-character lowercase hex string schema."
  @spec hex64() :: Schema.t()
  def hex64, do: @hex64

  OpenApiSpex.schema(%{
    title: "CacheEntry",
    description: """
    A committed cache entry. `scope` says which scope matched. `created_at`
    is the commit time. `download_url` is a presigned GET that expires at
    `download_url_expires_at`; fetch it without an `Authorization` header.
    In list responses the download fields are absent.
    """,
    type: :object,
    required: [:key, :partial, :name, :scope, :size, :sha256, :created_at],
    properties: %{
      key: @hex64,
      partial: @hex64,
      name: %Schema{type: :string},
      scope: %Schema{type: :string},
      size: %Schema{type: :integer, minimum: 1},
      sha256: @hex64,
      created_at: %Schema{type: :string, format: :"date-time"},
      download_url: %Schema{type: :string, format: :uri},
      download_url_expires_at: %Schema{type: :string, format: :"date-time"}
    },
    example: %{
      "key" => String.duplicate("a", 64),
      "partial" => String.duplicate("b", 64),
      "name" => "deps",
      "scope" => "main",
      "size" => 52_428_800,
      "sha256" => String.duplicate("c", 64),
      "created_at" => "2026-11-16T12:00:00Z",
      "download_url" => "https://bucket.example/caches/…?X-Amz-Signature=…",
      "download_url_expires_at" => "2026-11-16T12:15:00Z"
    }
  })
end
