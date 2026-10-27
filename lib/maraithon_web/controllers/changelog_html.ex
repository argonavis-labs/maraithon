defmodule MaraithonWeb.ChangelogHTML do
  use MaraithonWeb, :html

  embed_templates "changelog_html/*"

  @doc """
  Format a Date as "May 8, 2026" — calm, consumer-grade.
  """
  def format_day(nil), do: ""

  def format_day(%Date{} = date) do
    months =
      ~w(January February March April May June July August September October November December)

    month = Enum.at(months, date.month - 1) || ""
    "#{month} #{date.day}, #{date.year}"
  end

  def relative_day(nil), do: ""

  def relative_day(%Date{} = date) do
    today = Date.utc_today()

    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      n when n > 0 and n < 7 -> "#{n} days ago"
      n when n >= 7 and n < 14 -> "Last week"
      _ -> nil
    end
  end
end
