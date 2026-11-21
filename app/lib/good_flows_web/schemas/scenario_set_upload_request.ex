defmodule GoodFlowsWeb.Schemas.ScenarioSetUploadRequest do
  @moduledoc "OpenAPI schema: A scenario set upload: the raw `qa-scenarios/2` Markdown file and one section digest per scenario."
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ScenarioSetUploadRequest",
    description:
      "A scenario set upload: the raw `qa-scenarios/2` Markdown file and one section digest per scenario.",
    type: :object,
    required: [:content, :sections],
    additionalProperties: false,
    properties: %{
      content: %Schema{
        type: :string,
        description: "The set file, byte for byte. Only its YAML front matter is read."
      },
      sections: %Schema{
        type: :array,
        maxItems: 200,
        items: %Schema{
          type: :object,
          required: [:id, :sha256],
          additionalProperties: false,
          properties: %{
            id: %Schema{
              oneOf: [%Schema{type: :integer, minimum: 1}, %Schema{type: :string}],
              description: "Scenario ID, compared in string form"
            },
            sha256: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"}
          }
        }
      }
    }
  })
end
