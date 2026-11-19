defmodule GoodFlows.Caches.CacheAccessTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Projects.Project

  @project %Project{id: "p1", default_branch: "main"}
  @other %Project{id: "p2", default_branch: "main"}

  defp key(type, scope \\ nil, project_id \\ "p1"),
    do: %ApiKey{type: type, scope: scope, project_id: project_id}

  defp access(api_key, scope, mode, project \\ @project),
    do: ApiKey.cache_access(api_key, project, scope, mode)

  defp precheck(api_key, raw_scope, mode, project \\ @project),
    do: ApiKey.precheck_cache_access(api_key, project, raw_scope, mode)

  test "sk_ keys read and write any scope" do
    sk = %ApiKey{type: :private}

    for scope <- [nil, "main", "feature/login"], do: assert(access(sk, scope, :read) == :ok)
    for scope <- ["main", "feature/login"], do: assert(access(sk, scope, :write) == :ok)
  end

  test "pk_ keys get no cache access" do
    pk = %ApiKey{type: :public}

    for scope <- [nil, "main"], mode <- [:read, :write] do
      assert access(pk, scope, mode) == {:error, :forbidden}
    end
  end

  test "an unbound read key reads any scope and writes none" do
    ck = key(:cache_read)

    for scope <- [nil, "main", "feature/other"], do: assert(access(ck, scope, :read) == :ok)
    assert access(ck, "main", :write) == {:error, :forbidden}
    assert access(ck, "feature/login", :write) == {:error, :forbidden}
  end

  test "an unbound read-write key reads and writes any scope" do
    ck = key(:cache_write)

    for scope <- [nil, "main", "pr-43"], do: assert(access(ck, scope, :read) == :ok)
    for scope <- ["main", "pr-43"], do: assert(access(ck, scope, :write) == :ok)
    assert access(ck, nil, :write) == {:error, :forbidden}
  end

  test "a bound read-write key reads its scope, the default branch, or no scope; writes only its scope" do
    ck = key(:cache_write, "feature/login")

    for scope <- [nil, "feature/login", "main"], do: assert(access(ck, scope, :read) == :ok)
    assert access(ck, "feature/other", :read) == {:error, :forbidden}

    assert access(ck, "feature/login", :write) == :ok
    assert access(ck, "main", :write) == {:error, :forbidden}
    assert access(%{ck | scope: "pr-42"}, "pr-43", :write) == {:error, :forbidden}
  end

  test "a bound read key reads like a bound key and never writes" do
    ck = key(:cache_read, "feature/login")

    for scope <- [nil, "feature/login", "main"], do: assert(access(ck, scope, :read) == :ok)
    assert access(ck, "feature/other", :read) == {:error, :forbidden}
    assert access(ck, "feature/login", :write) == {:error, :forbidden}
  end

  test "a key bound to the default branch reads only that scope" do
    ck = key(:cache_read, "main")

    for scope <- [nil, "main"], do: assert(access(ck, scope, :read) == :ok)
    assert access(ck, "feature/login", :read) == {:error, :forbidden}

    writer = key(:cache_write, "main")
    assert access(writer, "main", :write) == :ok
  end

  test "the default branch comes from the project" do
    ck = key(:cache_read, "feature/login")
    trunk = %{@project | default_branch: "trunk"}

    assert access(ck, "trunk", :read, trunk) == :ok
    assert access(ck, "main", :read, trunk) == {:error, :forbidden}
  end

  test "a cache key on another project is refused" do
    for type <- [:cache_read, :cache_write], mode <- [:read, :write] do
      assert access(key(type), "main", mode, @other) == {:error, :forbidden}
    end
  end

  test "can_write?/1 stays true only for private keys" do
    assert ApiKey.can_write?(%ApiKey{type: :private})

    for type <- [:public, :cache_read, :cache_write] do
      refute ApiKey.can_write?(%ApiKey{type: type})
    end
  end

  test "cache tokens start with ck_ and keep the 12-character lookup prefix" do
    for type <- [:cache_read, :cache_write] do
      token = ApiKey.generate_token(type)
      assert "ck_" <> _ = token
      assert String.length(ApiKey.token_prefix(token)) == 12
    end
  end

  describe "precheck_cache_access/4" do
    test "an unbound read key may read but never write, whatever the scope" do
      ck = key(:cache_read)
      assert precheck(ck, "main\n", :read) == :ok
      assert precheck(ck, "main", :write) == {:error, :forbidden}
      assert precheck(ck, nil, :write) == {:error, :forbidden}
    end

    test "an unbound read-write key passes with any raw scope, left for validation" do
      ck = key(:cache_write)
      for scope <- ["main", "main\n", "", 42, nil], do: assert(precheck(ck, scope, :write) == :ok)
    end

    test "a bound key is checked exactly on the raw scope" do
      ck = key(:cache_write, "feature/login")
      assert precheck(ck, "feature/login", :write) == :ok
      assert precheck(ck, "main", :read) == :ok
      assert precheck(ck, nil, :read) == :ok
      assert precheck(ck, nil, :write) == {:error, :forbidden}
      assert precheck(ck, 42, :write) == {:error, :forbidden}
      assert precheck(ck, ["feature/login"], :read) == {:error, :forbidden}
    end

    test "sk_, pk_ and other-project keys follow cache_access/4" do
      assert precheck(%ApiKey{type: :private}, 42, :write) == :ok
      assert precheck(%ApiKey{type: :public}, "main", :read) == {:error, :forbidden}
      assert precheck(key(:cache_write), "main", :write, @other) == {:error, :forbidden}
    end
  end
end
