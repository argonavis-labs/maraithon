defmodule Maraithon.Tools.PathPolicyTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.PathPolicy

  @test_dir Path.join(System.tmp_dir!(), "maraithon_path_policy_test")

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "allowed.txt"), "ok")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  test "allows paths in configured roots" do
    file_path = Path.join(@test_dir, "allowed.txt")
    assert {:ok, resolved} = PathPolicy.resolve_allowed_path(file_path)
    assert String.ends_with?(resolved, "allowed.txt")
  end

  test "allows normal content paths in configured roots" do
    file_path = Path.join(@test_dir, "allowed.txt")
    assert {:ok, resolved} = PathPolicy.resolve_content_path(file_path)
    assert String.ends_with?(resolved, "allowed.txt")
    assert PathPolicy.visible_content_path?(file_path)
  end

  test "rejects hidden and credential-shaped content paths" do
    blocked_paths = [
      Path.join(@test_dir, ".env"),
      Path.join(@test_dir, ".ssh/id_ed25519"),
      Path.join(@test_dir, "config/secrets.yml"),
      Path.join(@test_dir, "private.pem"),
      Path.join(@test_dir, "credentials.json"),
      Path.join(@test_dir, "id_rsa")
    ]

    for path <- blocked_paths do
      assert {:error, "path is not available to the assistant"} =
               PathPolicy.resolve_content_path(path)

      refute PathPolicy.visible_content_path?(path)
    end
  end

  test "rejects paths outside configured roots" do
    assert {:error, "path is outside allowed roots"} =
             PathPolicy.resolve_allowed_path("/etc/passwd")
  end

  test "rejects symlink paths that can escape allowed roots" do
    symlink = Path.join(@test_dir, "escape_link")
    File.ln_s!("/etc/passwd", symlink)

    assert {:error, "path is outside allowed roots"} =
             PathPolicy.resolve_allowed_path(symlink)
  end
end
