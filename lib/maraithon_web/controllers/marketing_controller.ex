defmodule MaraithonWeb.MarketingController do
  @moduledoc """
  Public-facing static pages: privacy, terms, support, login.
  Required for App Store reviewer trust and parity with iOS app metadata.
  """
  use MaraithonWeb, :controller

  def privacy(conn, _params) do
    render(conn, :privacy, page_title: "Privacy policy — Maraithon")
  end

  def terms(conn, _params) do
    render(conn, :terms, page_title: "Terms of service — Maraithon")
  end

  def support(conn, _params) do
    render(conn, :support, page_title: "Support — Maraithon")
  end
end
