defmodule GoodFlowsWeb.Api.V1.StoredChangeControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Repo
  alias GoodFlows.StoredChanges.{Change, Version}
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx, do: %{project: project_fixture(ctx.account)}

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)
  @source %{"commit" => @sha_a, "branch" => "feat/login", "dirty" => false}

  defp changes_path(ctx, suffix \\ ""),
    do: "/api/v1/projects/#{ctx.project.slug}/changes#{suffix}"

  defp change_md(id, fields \\ %{}) do
    fields =
      Map.merge(
        %{"format" => "goodflows-change/1", "id" => id, "status" => "approved"},
        fields
      )

    yaml =
      fields
      |> Enum.reject(fn {_key, value} -> value == :omit end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{yaml_value(value)}" end)

    "---\n#{yaml}\n---\n\n## Why\n\nBecause.\n"
  end

  defp yaml_value(list) when is_list(list), do: "[" <> Enum.join(list, ", ") <> "]"
  defp yaml_value(value), do: value

  defp qa_md(change, extra \\ "") do
    """
    ---
    format: qa-scenarios/2
    source: intent
    change: "#{change}"
    specs: uncommitted
    review: null
    scenarios:
      - id: 1
        name: "Log in"
        priority: must
    #{extra}---

    # QA

    ### 1. Log in (Must)
    """
  end

  defp files(id \\ "add-login", fields \\ %{}) do
    %{
      "change.md" => change_md(id, fields),
      "qa-scenarios.md" => qa_md(id),
      "specs/login/spec.md" => "## ADDED Requirements\n\n### Requirement: Log in\nRefs: D1\n"
    }
  end

  defp push_change(conn, ctx, files, source \\ @source),
    do: post_json(conn, changes_path(ctx), %{"files" => files, "source" => source})

  defp versions_count, do: Repo.aggregate(Version, :count)

  def query_sent(_event, _measurements, _metadata, {test, id}),
    do: if(self() == test, do: send(test, {id, :query}))

  # Counts the Repo queries `fun` runs in this process.
  defp count_queries(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(id, [:good_flows, :repo, :query], &__MODULE__.query_sent/4, {test, id})

    try do
      fun.()

      Stream.repeatedly(fn -> receive do: ({^id, :query} -> 1), after: (0 -> nil) end)
      |> Enum.take_while(& &1)
      |> length()
    after
      :telemetry.detach(id)
    end
  end

  defp events(ctx, type) do
    ctx.sk_conn
    |> get("/api/v1/projects/#{ctx.project.slug}/events")
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.filter(&(&1["type"] == type))
  end

  describe "push" do
    test "the first push stores version 1 with its source and records an event", ctx do
      created = ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)
      assert_schema(created, "StoredChangePushResponse", ApiSpec.spec())

      assert %{
               "change_id" => "add-login",
               "version" => 1,
               "status" => "approved",
               "replaced_version" => nil,
               "duplicate" => false,
               "source" => @source
             } = created["data"]

      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      assert created["data"]["pushed_by"] == %{"user_id" => owner.user_id}

      assert [%{"number" => nil, "data" => %{"change_id" => "add-login", "version" => 1}}] =
               events(ctx, "change_pushed")

      changed = Map.put(files(), "change.md", change_md("add-login") <> "More.\n")
      nulls = %{"commit" => nil, "branch" => nil, "dirty" => true}

      assert %{"data" => %{"version" => 2, "replaced_version" => 1, "source" => ^nulls}} =
               ctx.sk_conn |> push_change(ctx, changed, nulls) |> json_response(201)

      stored = Repo.get_by!(Version, version: 2)
      assert {stored.commit, stored.branch, stored.dirty} == {nil, nil, true}
    end

    test "a second push names the replaced version and only it is latest", ctx do
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)
      changed = Map.put(files(), "qa-scenarios.md", qa_md("add-login") <> "One more line.\n")

      assert %{"data" => %{"version" => 2, "replaced_version" => 1}} =
               ctx.sk_conn |> push_change(ctx, changed) |> json_response(201)

      list = ctx.sk_conn |> get(changes_path(ctx, "/add-login/versions")) |> json_response(200)
      assert_schema(list, "StoredChangeVersionListResponse", ApiSpec.spec())

      assert [%{"version" => 2, "latest" => true}, %{"version" => 1, "latest" => false}] =
               list["data"]
    end

    test "an identical push stores nothing and keeps the first source", ctx do
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)
      other = %{@source | "commit" => @sha_b}

      duplicate = ctx.sk_conn |> push_change(ctx, files(), other) |> json_response(200)
      assert_schema(duplicate, "StoredChangePushResponse", ApiSpec.spec())

      assert %{
               "duplicate" => true,
               "version" => 1,
               "replaced_version" => 1,
               "source" => %{"commit" => @sha_a}
             } = duplicate["data"]

      assert versions_count() == 1
      assert length(events(ctx, "change_pushed")) == 1

      fewer = Map.delete(files(), "specs/login/spec.md")

      assert %{"data" => %{"version" => 2}} =
               ctx.sk_conn |> push_change(ctx, fewer) |> json_response(201)
    end

    test "a bad change.md or intent set is refused", ctx do
      assert %{"errors" => %{"files.change.md" => _}} =
               ctx.sk_conn
               |> push_change(ctx, Map.delete(files(), "change.md"))
               |> json_response(422)

      for {fields, field} <- [
            {%{"format" => "goodflows-change/2"}, "format"},
            {%{"status" => "done"}, "status"},
            {%{"id" => "Add_Login"}, "id"},
            {%{"id" => String.duplicate("a", 65)}, "id"},
            {%{"id" => "-login"}, "id"}
          ] do
        bad = Map.put(files(), "change.md", change_md("add-login", fields))

        errors =
          ctx.sk_conn |> push_change(ctx, bad) |> json_response(422) |> Map.fetch!("errors")

        assert Map.has_key?(errors, "files.change.md.#{field}"), inspect({field, errors})
      end

      not_yaml = Map.put(files(), "change.md", "# no front matter\n")

      assert %{"errors" => %{"files.change.md" => _}} =
               ctx.sk_conn |> push_change(ctx, not_yaml) |> json_response(422)

      other_change = Map.put(files(), "qa-scenarios.md", qa_md("add-logout"))

      assert %{"errors" => %{"files.qa-scenarios.md.change" => _}} =
               ctx.sk_conn |> push_change(ctx, other_change) |> json_response(422)

      diff_set =
        Map.put(
          files(),
          "qa-scenarios.md",
          String.replace(qa_md("add-login"), "source: intent", "source: diff")
        )

      assert %{"errors" => errors} =
               ctx.sk_conn |> push_change(ctx, diff_set) |> json_response(422)

      assert Enum.any?(Map.keys(errors), &String.starts_with?(&1, "files.qa-scenarios.md"))

      broken = Map.put(files(), "qa-scenarios.md", qa_md("add-login", "run: {}\n"))

      assert %{"errors" => %{"files.qa-scenarios.md" => _}} =
               ctx.sk_conn |> push_change(ctx, broken) |> json_response(422)

      assert Repo.aggregate(Change, :count) == 0
      assert versions_count() == 0
      assert events(ctx, "change_pushed") == []
    end

    test "a push failing only CLI validate rules is stored with its well-formed fields", ctx do
      fields = %{
        "size" => "huge",
        "door" => "one_way",
        "capabilities" => ["stored-changes", "review/answers"],
        "depends_on" => ["add-auth"]
      }

      body =
        files("add-login", fields)
        |> Map.put("specs/login/spec.md", "## ADDED Requirements\n\n### Requirement: No refs\n")

      assert %{
               "data" => %{
                 "size" => nil,
                 "door" => "one_way",
                 "capabilities" => ["stored-changes", "review/answers"],
                 "depends_on" => ["add-auth"]
               }
             } = ctx.sk_conn |> push_change(ctx, body) |> json_response(201)

      malformed = %{
        "size" => "small",
        "door" => "both",
        "capabilities" => ["ok", "Bad_Name"],
        "depends_on" => "add-auth"
      }

      assert %{
               "data" => %{
                 "size" => "small",
                 "door" => nil,
                 "capabilities" => nil,
                 "depends_on" => nil
               }
             } =
               ctx.sk_conn
               |> push_change(ctx, files("add-other", malformed))
               |> json_response(201)

      missing = files("add-third", %{"status" => "proposed"})

      assert %{"data" => %{"size" => nil, "door" => nil, "capabilities" => nil}} =
               ctx.sk_conn |> push_change(ctx, missing) |> json_response(201)
    end

    test "unknown paths are refused, naming them, and nested spec paths are stored", ctx do
      for path <- [
            "notes.txt",
            "specs/spec.md",
            "specs/Login/spec.md",
            "specs/login/other.md",
            "specs/-login/spec.md",
            "specs/login//spec.md",
            "../change.md",
            "specs/" <> String.duplicate("a", 510) <> "/spec.md"
          ] do
        errors =
          ctx.sk_conn
          |> push_change(ctx, Map.put(files(), path, "text"))
          |> json_response(422)
          |> Map.fetch!("errors")

        assert Enum.any?(errors, fn {key, messages} ->
                 String.starts_with?(key, "files.") and
                   String.contains?(key <> Enum.join(messages), String.slice(path, 0, 40))
               end),
               inspect({path, errors})
      end

      assert %{"errors" => %{"files.specs/login/spec.md" => [message]}} =
               ctx.sk_conn
               |> push_change(ctx, Map.put(files(), "specs/login/spec.md", "a\u0000b"))
               |> json_response(422)

      assert message =~ "U+0000"
      assert versions_count() == 0

      nested = Map.put(files(), "specs/review/answers/spec.md", "## Nested\n")
      ctx.sk_conn |> push_change(ctx, nested) |> json_response(201)

      shown = ctx.sk_conn |> get(changes_path(ctx, "/add-login")) |> json_response(200)

      assert %{"path" => "specs/review/answers/spec.md", "text" => "## Nested\n"} in shown[
               "data"
             ]["files"]
    end

    test "too many files or bytes are refused", ctx do
      many =
        Enum.reduce(1..101, files(), fn i, acc -> Map.put(acc, "specs/cap-#{i}/spec.md", "x") end)

      assert %{"errors" => %{"files" => [message]}} =
               ctx.sk_conn |> push_change(ctx, many) |> json_response(422)

      assert message =~ "100"

      base = %{"change.md" => change_md("add-login")}
      filler = 2_097_152 - byte_size(base["change.md"])
      text = String.duplicate("\"\\\n", div(filler, 3)) <> String.duplicate("x", rem(filler, 3))

      over = Map.put(base, "specs/big/spec.md", text <> "x")

      assert %{"errors" => %{"files" => [message]}} =
               ctx.sk_conn |> push_change(ctx, over) |> json_response(422)

      assert message =~ "2097152"
      assert versions_count() == 0

      exact = Map.put(base, "specs/big/spec.md", text)
      assert ctx.sk_conn |> push_change(ctx, exact) |> json_response(201)

      huge = ~s({"files": {"change.md": ") <> String.duplicate("x", 16 * 1024 * 1024) <> ~s("}})
      assert ctx.sk_conn |> post_json(changes_path(ctx), huge) |> json_response(413)
      assert versions_count() == 1
    end

    test "a malformed source or an extra key is refused", ctx do
      for body <- [
            %{"files" => files()},
            %{"files" => files(), "source" => %{@source | "dirty" => "yes"}},
            %{"files" => files(), "source" => %{@source | "commit" => "xyz"}},
            %{"files" => files(), "source" => Map.put(@source, "remote", "origin")},
            %{
              "files" => files(),
              "source" => %{@source | "branch" => String.duplicate("b", 300)}
            },
            %{"files" => files(), "source" => %{@source | "branch" => ""}},
            %{"files" => files(), "source" => %{@source | "branch" => "a\tb"}},
            %{"files" => files(), "source" => %{@source | "branch" => "a\u007Fb"}},
            %{"files" => files(), "source" => %{@source | "branch" => "a\u0085b"}},
            %{"files" => files(), "source" => @source, "id" => "add-login"},
            %{"files" => [], "source" => @source},
            %{"files" => %{"change.md" => 1}, "source" => @source}
          ] do
        assert ctx.sk_conn |> post_json(changes_path(ctx), body) |> json_response(422),
               inspect(body)
      end

      assert versions_count() == 0
    end

    test "an archived change takes no further pushes", ctx do
      archived = files("add-login", %{"status" => "archived"})

      assert %{"data" => %{"status" => "archived", "version" => 1}} =
               ctx.sk_conn |> push_change(ctx, archived) |> json_response(201)

      assert %{"errors" => %{"detail" => detail}} =
               ctx.sk_conn |> push_change(ctx, files()) |> json_response(409)

      assert detail =~ "add-login"

      assert ctx.sk_conn
             |> push_change(ctx, Map.put(files(), "notes.txt", "x"))
             |> json_response(422)

      assert %{"data" => %{"duplicate" => true, "version" => 1}} =
               ctx.sk_conn |> push_change(ctx, archived) |> json_response(200)

      assert versions_count() == 1
    end
  end

  describe "reads" do
    test "the list pages newest first and filters by status", ctx do
      ctx.sk_conn |> push_change(ctx, files("a", %{"status" => "proposed"})) |> json_response(201)
      ctx.sk_conn |> push_change(ctx, files("b", %{"status" => "proposed"})) |> json_response(201)
      ctx.sk_conn |> push_change(ctx, files("c", %{"status" => "approved"})) |> json_response(201)

      page = ctx.sk_conn |> get(changes_path(ctx, "?limit=2")) |> json_response(200)
      assert_schema(page, "StoredChangeListResponse", ApiSpec.spec())
      assert Enum.map(page["data"], & &1["change_id"]) == ["c", "b"]
      assert [%{"version" => 1, "status" => "approved", "last_pushed_at" => _} | _] = page["data"]
      assert is_binary(page["next_cursor"])

      rest =
        ctx.sk_conn
        |> get(changes_path(ctx, "?limit=2&cursor=#{page["next_cursor"]}"))
        |> json_response(200)

      assert Enum.map(rest["data"], & &1["change_id"]) == ["a"]
      assert rest["next_cursor"] == nil

      approved = ctx.sk_conn |> get(changes_path(ctx, "?status=approved")) |> json_response(200)
      assert Enum.map(approved["data"], & &1["change_id"]) == ["c"]

      for query <- ["?status=done", "?limit=0", "?limit=201", "?cursor=nope"] do
        assert ctx.sk_conn |> get(changes_path(ctx, query)) |> json_response(422), query
      end
    end

    test "each listed change carries its linked change requests, for both key types", ctx do
      for id <- ~w(a b c), do: ctx.sk_conn |> push_change(ctx, files(id)) |> json_response(201)

      [a1, a2] =
        for branch <- ~w(feat/a1 feat/a2),
            do:
              create_cr(ctx.sk_conn, ctx.project.slug, %{
                "change_id" => "a",
                "source_branch" => branch
              })

      b1 =
        create_cr(ctx.sk_conn, ctx.project.slug, %{
          "change_id" => "b",
          "source_branch" => "feat/b"
        })

      ctx.sk_conn |> post_json(cr_path(ctx.project.slug, b1["number"], "/close"), %{})

      # Closing a1 after a2 exists rewrites a1's row after a2's, so the rows
      # are no longer stored in number order and only an ORDER BY keeps them.
      ctx.sk_conn |> post_json(cr_path(ctx.project.slug, a1["number"], "/close"), %{})

      # The same change id in another project of the account is not a link.
      other = project_fixture(ctx.account)
      create_cr(ctx.sk_conn, other.slug, %{"change_id" => "a", "source_branch" => "feat/other"})

      for conn <- [ctx.sk_conn, ctx.pk_conn] do
        page = conn |> get(changes_path(ctx)) |> json_response(200)
        assert_schema(page, "StoredChangeListResponse", ApiSpec.spec())

        assert Map.new(page["data"], &{&1["change_id"], &1["change_requests"]}) == %{
                 "a" => [
                   %{"number" => a1["number"], "state" => "closed"},
                   %{"number" => a2["number"], "state" => "draft"}
                 ],
                 "b" => [%{"number" => b1["number"], "state" => "closed"}],
                 "c" => []
               }
      end

      ctx.sk_conn |> get(changes_path(ctx)) |> json_response(200)
      one_row = count_queries(fn -> ctx.sk_conn |> get(changes_path(ctx, "?limit=1")) end)
      three_rows = count_queries(fn -> ctx.sk_conn |> get(changes_path(ctx, "?limit=3")) end)
      assert one_row == three_rows
    end

    test "a change is read with its files and linked change requests", ctx do
      cr = create_cr(ctx.sk_conn, ctx.project.slug, %{"change_id" => "add-login"})
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)

      shown = ctx.sk_conn |> get(changes_path(ctx, "/add-login")) |> json_response(200)
      assert_schema(shown, "StoredChangeResponse", ApiSpec.spec())
      data = shown["data"]

      assert %{"change_id" => "add-login", "version" => 1, "status" => "approved"} = data
      assert data["change_requests"] == [%{"number" => cr["number"], "state" => "draft"}]

      assert Enum.sort_by(data["files"], & &1["path"]) ==
               files()
               |> Enum.map(fn {path, text} -> %{"path" => path, "text" => text} end)
               |> Enum.sort_by(& &1["path"])

      assert %{"errors" => %{"detail" => detail}} =
               ctx.sk_conn |> get(changes_path(ctx, "/unknown")) |> json_response(404)

      assert detail =~ "No stored change unknown in this project"
    end

    test "an older version is read with its own status and the latest status", ctx do
      ctx.sk_conn
      |> push_change(ctx, files("add-login", %{"status" => "proposed"}))
      |> json_response(201)

      ctx.sk_conn
      |> push_change(ctx, files("add-login", %{"status" => "archived"}))
      |> json_response(201)

      shown = ctx.sk_conn |> get(changes_path(ctx, "/add-login/versions/1")) |> json_response(200)
      assert_schema(shown, "StoredChangeVersionResponse", ApiSpec.spec())

      assert %{"version" => 1, "status" => "proposed", "latest_status" => "archived"} =
               shown["data"]

      assert %{"path" => "change.md", "text" => change_md("add-login", %{"status" => "proposed"})} in shown[
               "data"
             ]["files"]

      for {path, expected} <- [
            {"/add-login/versions/3", "add-login has no version 3"},
            {"/add-login/versions/x", "add-login has no version x"},
            {"/nope/versions/1", "No stored change nope in this project"}
          ] do
        assert %{"errors" => %{"detail" => detail}} =
                 ctx.sk_conn |> get(changes_path(ctx, path)) |> json_response(404)

        assert detail =~ expected, path
      end

      assert ctx.sk_conn |> get(changes_path(ctx, "/nope/versions")) |> json_response(404)
    end

    test "a public key lists without the pusher and cannot read file text", ctx do
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)

      assert %{"data" => [%{"change_id" => "add-login"} = listed]} =
               ctx.pk_conn |> get(changes_path(ctx)) |> json_response(200)

      refute Map.has_key?(listed, "files")

      public = ctx.pk_conn |> get(changes_path(ctx, "/add-login/versions")) |> json_response(200)
      assert_schema(public, "StoredChangeVersionListResponse", ApiSpec.spec())
      assert [%{"pushed_by" => nil} = version] = public["data"]
      assert Enum.sort(Map.keys(version)) == ~w(latest pushed_at pushed_by source status version)

      assert %{"data" => [%{"pushed_by" => %{"user_id" => _}}]} =
               ctx.sk_conn |> get(changes_path(ctx, "/add-login/versions")) |> json_response(200)

      for path <- ["/add-login", "/add-login/versions/1", "/unknown", "/unknown/versions/1"] do
        assert %{"errors" => %{"detail" => detail}} =
                 ctx.pk_conn |> get(changes_path(ctx, path)) |> json_response(403),
               path

        assert detail =~ "Public (pk_) keys cannot read a stored change or one of its versions"
        assert detail =~ "use a private (sk_) key"
        refute detail =~ "unknown"
      end

      changed = Map.put(files(), "change.md", change_md("add-login") <> "x")
      assert ctx.pk_conn |> push_change(ctx, changed) |> json_response(403)
      assert ctx.pk_conn |> delete(changes_path(ctx, "/add-login")) |> json_response(403)
      assert ctx.other_conn |> get(changes_path(ctx)) |> json_response(404)
      assert ctx.member_sk_conn |> push_change(ctx, changed) |> json_response(201)
      assert versions_count() == 2
    end
  end

  describe "delete" do
    test "is refused while a change request links the change", ctx do
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)
      cr = create_cr(ctx.sk_conn, ctx.project.slug, %{"change_id" => "add-login"})
      ctx.sk_conn |> post_json(cr_path(ctx.project.slug, cr["number"], "/close"), %{})

      refused = ctx.sk_conn |> delete(changes_path(ctx, "/add-login")) |> json_response(409)
      assert_schema(refused, "StoredChangeLinkedResponse", ApiSpec.spec())

      assert refused["errors"]["change_requests"] == [
               %{"number" => cr["number"], "state" => "closed"}
             ]

      assert refused["errors"]["detail"] =~ "#{cr["number"]}"
      assert ctx.sk_conn |> get(changes_path(ctx, "/add-login/versions/1")) |> json_response(200)
      assert events(ctx, "change_deleted") == []
    end

    test "removes every version and the id starts over", ctx do
      ctx.sk_conn |> push_change(ctx, files("add-logout")) |> json_response(201)
      changed = Map.put(files("add-logout"), "verification.md", "# Verified\n")
      ctx.sk_conn |> push_change(ctx, changed) |> json_response(201)

      assert ctx.sk_conn |> delete(changes_path(ctx, "/add-logout")) |> response(204) == ""

      assert %{"errors" => %{"detail" => detail}} =
               ctx.sk_conn |> delete(changes_path(ctx, "/add-logout")) |> json_response(404)

      assert detail =~ "No stored change add-logout in this project"
      assert ctx.sk_conn |> get(changes_path(ctx, "/add-logout")) |> json_response(404)
      assert ctx.sk_conn |> get(changes_path(ctx, "/add-logout/versions/1")) |> json_response(404)
      assert versions_count() == 0

      assert [%{"number" => nil, "data" => %{"change_id" => "add-logout"}}] =
               events(ctx, "change_deleted")

      assert %{"data" => %{"version" => 1, "replaced_version" => nil}} =
               ctx.sk_conn |> push_change(ctx, files("add-logout")) |> json_response(201)
    end

    test "stored changes block project deletion", ctx do
      ctx.sk_conn |> push_change(ctx, files()) |> json_response(201)
      project_path = "/api/v1/projects/#{ctx.project.slug}"

      assert %{"errors" => %{"detail" => detail}} =
               ctx.sk_conn |> delete(project_path) |> json_response(409)

      assert detail =~ "stored changes"
      assert ctx.sk_conn |> get(changes_path(ctx, "/add-login")) |> json_response(200)

      ctx.sk_conn |> delete(changes_path(ctx, "/add-login")) |> response(204)
      assert ctx.sk_conn |> delete(project_path) |> response(204)
    end
  end

  test "OpenAPI describes every stored-change route", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")
    base = "/api/v1/projects/{project}/changes"

    for {path, verb, params, statuses} <- [
          {base, "post", ~w(project), ~w(200 201 400 401 403 404 406 408 409 413 415 422)},
          {base, "get", ~w(project limit cursor status), ~w(200 401 403 404 422)},
          {base <> "/{change_id}", "get", ~w(project change_id), ~w(200 401 403 404)},
          {base <> "/{change_id}", "delete", ~w(project change_id), ~w(204 401 403 404 409)},
          {base <> "/{change_id}/versions", "get", ~w(project change_id limit cursor),
           ~w(200 401 403 404 422)},
          {base <> "/{change_id}/versions/{n}", "get", ~w(project change_id n),
           ~w(200 401 403 404)}
        ] do
      op = paths[path][verb]
      assert op, "#{verb} #{path}"
      names = Enum.map(op["parameters"], & &1["name"])
      assert Enum.sort(names) == Enum.sort(params), "#{verb} #{path}"

      for status <- statuses,
          do: assert(Map.has_key?(op["responses"], status), "#{verb} #{path} #{status}")

      if verb == "post", do: assert(op["requestBody"]["required"])
    end
  end
end
