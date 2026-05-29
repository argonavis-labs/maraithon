defmodule MaraithonWeb.CoreComponentsTest do
  use MaraithonWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MaraithonWeb.CoreComponents

  test "flash_group renders atom keyed error flash" do
    html = render_component(&CoreComponents.flash_group/1, flash: %{error: "Visible error"})

    assert html =~ "Visible error"
  end

  test "flash_group renders string keyed error flash" do
    html = render_component(&CoreComponents.flash_group/1, flash: %{"error" => "Visible error"})

    assert html =~ "Visible error"
  end
end
