defmodule GoodFlowsWeb.ProjectLiveTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GoodFlows.Accounts
  alias GoodFlows.Projects
  alias GoodFlows.SpryFixtures

  setup :register_and_log_in_user

  setup %{user: user} do
    account = account_fixture()
    account_user = account_user_fixture(account, user, :admin)

    %{
      account: account,
      account_user: account_user,
      path: ~p"/dashboard/accounts/#{account.id}/projects"
    }
  end

  test "creates a project from the empty state", %{conn: conn, path: path, account: account} do
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#projects-empty")

    view |> element("#empty-new-project-btn") |> render_click()

    view
    |> form("#create-project-form", project: %{slug: "web-app", default_branch: "trunk"})
    |> render_submit()

    assert {:ok, project} = Projects.get_project(account, "web-app")
    assert project.default_branch == "trunk"
    assert has_element?(view, "#projects-#{project.id}", "web-app")
    refute has_element?(view, "#create-project-modal")
    refute has_element?(view, "#projects-empty")
  end

  test "keeps the dialog open on an invalid or taken slug", %{
    conn: conn,
    path: path,
    account: account
  } do
    SpryFixtures.project_fixture(account, slug: "taken")
    {:ok, view, _html} = live(conn, path)
    view |> element("#new-project-btn") |> render_click()

    view |> form("#create-project-form", project: %{slug: "Bad Slug"}) |> render_submit()
    assert has_element?(view, "#project_slug-error-0", "must be 1 to 64 bytes")

    view |> form("#create-project-form", project: %{slug: "taken"}) |> render_submit()
    assert has_element?(view, "#project_slug-error-0", "has already been taken")

    assert has_element?(view, "#create-project-modal")
    assert [%{slug: "taken"}] = Projects.list_projects(account)
  end

  test "edits only the default branch", %{conn: conn, path: path, account: account} do
    project = SpryFixtures.project_fixture(account, slug: "api")
    {:ok, view, _html} = live(conn, path)

    view |> element("#edit-#{project.id}") |> render_click()

    view |> form("#edit-project-form", project: %{default_branch: ""}) |> render_submit()
    assert has_element?(view, "#project_default_branch-error-0", "can't be blank")
    assert {:ok, %{default_branch: "main"}} = Projects.get_project(account, "api")

    render_submit(view, "update_project", %{
      "project" => %{"default_branch" => "develop", "slug" => "renamed"}
    })

    assert {:ok, %{default_branch: "develop"}} = Projects.get_project(account, "api")
    assert {:error, :not_found} = Projects.get_project(account, "renamed")
    assert has_element?(view, "#projects-#{project.id}", "develop")
    refute has_element?(view, "#edit-project-modal")
  end

  test "deletes a project after confirmation", %{conn: conn, path: path, account: account} do
    project = SpryFixtures.project_fixture(account)
    {:ok, view, _html} = live(conn, path)

    view |> element("#delete-#{project.id}") |> render_click()
    view |> element("#delete-confirm-modal-confirm") |> render_click()

    assert Projects.list_projects(account) == []
    refute has_element?(view, "#projects-#{project.id}")
    assert has_element?(view, "#projects-empty")
  end

  test "explains why a project with recipes can't be deleted", %{
    conn: conn,
    path: path,
    account: account
  } do
    project = SpryFixtures.project_fixture(account)
    SpryFixtures.recipe_fixture(project)
    {:ok, view, _html} = live(conn, path)

    view |> element("#delete-#{project.id}") |> render_click()
    view |> element("#delete-confirm-modal-confirm") |> render_click()

    assert has_element?(view, "#flash-error", "still has recipes")
    assert has_element?(view, "#projects-#{project.id}")
    assert {:ok, _} = Projects.get_project(account, project.slug)
  end

  test "does not reach another account's projects", %{conn: conn, path: path} do
    other = SpryFixtures.project_fixture(account_fixture(), slug: "theirs")
    {:ok, view, _html} = live(conn, path)

    refute has_element?(view, "#projects-#{other.id}")
    render_click(view, "edit_project", %{"slug" => "theirs"})
    render_click(view, "confirm_delete", %{"slug" => "theirs"})
    refute has_element?(view, "#edit-project-modal")
    refute has_element?(view, "#delete-confirm-modal")
  end

  test "a member sees projects but cannot change them", %{conn: conn, user: user} do
    account = account_fixture()
    account_user_fixture(account, user, :member)
    project = SpryFixtures.project_fixture(account, slug: "shared")
    {:ok, view, _html} = live(conn, ~p"/dashboard/accounts/#{account.id}/projects")

    assert has_element?(view, "#projects-#{project.id}", "shared")
    assert has_element?(view, "#projects-read-only")
    refute has_element?(view, "#new-project-btn")
    refute has_element?(view, "#edit-#{project.id}")
    refute has_element?(view, "#delete-#{project.id}")

    render_click(view, "show_create_modal", %{})
    render_submit(view, "create_project", %{"project" => %{"slug" => "sneaky"}})
    render_click(view, "confirm_delete", %{"slug" => "shared"})
    render_click(view, "delete_project", %{})

    refute has_element?(view, "#create-project-modal")
    assert [%{slug: "shared"}] = Projects.list_projects(account)
  end

  test "a role lowered after the page loads stops the change", %{
    conn: conn,
    path: path,
    account: account,
    account_user: account_user
  } do
    project = SpryFixtures.project_fixture(account)
    {:ok, view, _html} = live(conn, path)

    view |> element("#delete-#{project.id}") |> render_click()
    {:ok, _} = Accounts.update_account_user_role(account_user, :member)
    view |> element("#delete-confirm-modal-confirm") |> render_click()

    assert has_element?(view, "#flash-error", "Only account owners and admins")
    assert {:ok, _} = Projects.get_project(account, project.slug)
    refute has_element?(view, "#delete-#{project.id}")
    assert has_element?(view, "#projects-read-only")
  end

  test "saving a project deleted while its edit dialog is open shows an error", %{
    conn: conn,
    path: path,
    account: account
  } do
    project = SpryFixtures.project_fixture(account, slug: "gone")
    {:ok, view, _html} = live(conn, path)

    view |> element("#edit-#{project.id}") |> render_click()
    :ok = Projects.delete_project(account, project)
    view |> form("#edit-project-form", project: %{default_branch: "trunk"}) |> render_submit()

    assert has_element?(view, "#flash-error", "no longer exists")
    refute has_element?(view, "#edit-project-modal")
    refute has_element?(view, "#projects-#{project.id}")
  end

  test "the list stays visible when projects were added in another session", %{
    conn: conn,
    path: path,
    account: account
  } do
    {:ok, view, _html} = live(conn, path)
    elsewhere = SpryFixtures.project_fixture(account, slug: "elsewhere")

    view |> element("#empty-new-project-btn") |> render_click()
    view |> form("#create-project-form", project: %{slug: "here"}) |> render_submit()
    {:ok, here} = Projects.get_project(account, "here")

    view |> element("#delete-#{here.id}") |> render_click()
    view |> element("#delete-confirm-modal-confirm") |> render_click()

    assert has_element?(view, "#projects-#{elsewhere.id}")
    refute has_element?(view, "#projects-empty")
  end

  test "each slug links to the project's change requests", %{
    conn: conn,
    path: path,
    account: account
  } do
    project = SpryFixtures.project_fixture(account, slug: "web")
    {:ok, view, _html} = live(conn, path)

    target = ~p"/dashboard/accounts/#{account.id}/projects/web/change-requests"
    assert has_element?(view, ~s(#change-requests-#{project.id}[href="#{target}"]), "web")

    assert {:error, {:live_redirect, %{to: ^target}}} =
             view |> element("#change-requests-#{project.id}") |> render_click()
  end
end
