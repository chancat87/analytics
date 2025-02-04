defmodule Plausible.Google.ApiTest do
  use Plausible.DataCase, async: true
  use Plausible.Test.Support.HTTPMocker

  alias Plausible.Google.Api
  alias Plausible.Imported.UniversalAnalytics

  import ExUnit.CaptureLog
  import Mox
  setup :verify_on_exit!

  setup [:create_user, :create_new_site]

  @refresh_token_body Jason.decode!(File.read!("fixture/ga_refresh_token.json"))

  @full_report_mock [
                      "fixture/ga_report_imported_visitors.json",
                      "fixture/ga_report_imported_sources.json",
                      "fixture/ga_report_imported_pages.json",
                      "fixture/ga_report_imported_entry_pages.json",
                      "fixture/ga_report_imported_exit_pages.json",
                      "fixture/ga_report_imported_locations.json",
                      "fixture/ga_report_imported_devices.json",
                      "fixture/ga_report_imported_browsers.json",
                      "fixture/ga_report_imported_operating_systems.json"
                    ]
                    |> Enum.map(&File.read!/1)
                    |> Enum.map(&Jason.decode!/1)

  @tag :slow
  test "imports page views from Google Analytics", %{site: site} do
    mock_http_with("google_analytics_import#1.json")

    view_id = "54297898"
    date_range = Date.range(~D[2011-01-01], ~D[2022-07-19])

    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    auth = {"***", "refresh_token", future}

    {:ok, buffer} = Plausible.Imported.Buffer.start_link()

    persist_fn = fn table, rows ->
      records = UniversalAnalytics.from_report(rows, site.id, _import_id = 123, table)
      Plausible.Imported.Buffer.insert_many(buffer, table, records)
    end

    assert :ok == Plausible.Google.Api.import_analytics(date_range, view_id, auth, persist_fn)

    Plausible.Imported.Buffer.flush(buffer)
    Plausible.Imported.Buffer.stop(buffer)

    assert 1_495_150 == Plausible.Stats.Clickhouse.imported_pageview_count(site)
  end

  @tag :slow
  test "import_analytics/4 refreshes OAuth token when needed", %{site: site} do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    auth = {"redacted_access_token", "redacted_refresh_token", DateTime.to_iso8601(past)}
    range = Date.range(~D[2020-01-01], ~D[2020-02-02])

    expect(Plausible.HTTPClient.Mock, :post, fn "https://www.googleapis.com/oauth2/v4/token",
                                                headers,
                                                body ->
      assert [{"content-type", "application/x-www-form-urlencoded"}] == headers

      assert %{
               grant_type: :refresh_token,
               redirect_uri: "http://localhost:8000/auth/google/callback",
               refresh_token: "redacted_refresh_token"
             } = body

      {:ok, %Finch.Response{status: 200, body: @refresh_token_body}}
    end)

    for report <- @full_report_mock do
      expect(Plausible.HTTPClient.Mock, :post, fn _url, headers, _body, _opts ->
        assert [{"Authorization", "Bearer 1/fFAGRNJru1FTz70BzhT3Zg"}] == headers
        {:ok, %Finch.Response{status: 200, body: report}}
      end)
    end

    {:ok, buffer} = Plausible.Imported.Buffer.start_link()

    persist_fn = fn table, rows ->
      records = UniversalAnalytics.from_report(rows, site.id, _import_id = 123, table)
      Plausible.Imported.Buffer.insert_many(buffer, table, records)
    end

    assert :ok == Plausible.Google.Api.import_analytics(range, "123551", auth, persist_fn)

    Plausible.Imported.Buffer.flush(buffer)
    Plausible.Imported.Buffer.stop(buffer)
  end

  describe "fetch_and_persist/4" do
    @ok_response Jason.decode!(File.read!("fixture/ga_batch_report.json"))
    @no_report_response Jason.decode!(File.read!("fixture/ga_report_empty_rows.json"))

    @tag :slow
    test "will fetch and persist import data from Google Analytics" do
      request = %Plausible.Google.ReportRequest{
        dataset: "imported_exit_pages",
        view_id: "123",
        date_range: Date.range(~D[2022-01-01], ~D[2022-02-01]),
        dimensions: ["ga:date", "ga:exitPagePath"],
        metrics: ["ga:users", "ga:exits"],
        access_token: "fake-token",
        page_token: nil,
        page_size: 10_000
      }

      expect(
        Plausible.HTTPClient.Mock,
        :post,
        fn
          "https://analyticsreporting.googleapis.com/v4/reports:batchGet",
          [{"Authorization", "Bearer fake-token"}],
          %{
            reportRequests: [
              %{
                dateRanges: [%{endDate: ~D[2022-02-01], startDate: ~D[2022-01-01]}],
                dimensions: [
                  %{histogramBuckets: [], name: "ga:date"},
                  %{histogramBuckets: [], name: "ga:exitPagePath"}
                ],
                hideTotals: true,
                hideValueRanges: true,
                metrics: [%{expression: "ga:users"}, %{expression: "ga:exits"}],
                orderBys: [%{fieldName: "ga:date", sortOrder: "DESCENDING"}],
                pageSize: 10000,
                pageToken: nil,
                viewId: "123"
              }
            ]
          },
          [receive_timeout: 60_000] ->
            {:ok, %Finch.Response{status: 200, body: @ok_response}}
        end
      )

      assert :ok =
               Api.fetch_and_persist(request,
                 sleep_time: 0,
                 persist_fn: fn dataset, row ->
                   assert dataset == "imported_exit_pages"
                   assert length(row) == 1479

                   :ok
                 end
               )
    end

    test "retries HTTP request up to 5 times before raising the last error" do
      expect(
        Plausible.HTTPClient.Mock,
        :post,
        5,
        fn
          "https://analyticsreporting.googleapis.com/v4/reports:batchGet",
          _,
          _,
          [receive_timeout: 60_000] ->
            Enum.random([
              {:error, %Mint.TransportError{reason: :nxdomain}},
              {:error, %{reason: %Finch.Response{status: 500}}}
            ])
        end
      )

      request = %Plausible.Google.ReportRequest{
        view_id: "123",
        date_range: Date.range(~D[2022-01-01], ~D[2022-02-01]),
        dimensions: ["ga:date"],
        metrics: ["ga:users"],
        access_token: "fake-token",
        page_token: nil,
        page_size: 10_000
      }

      assert {:error, :request_failed} =
               Api.fetch_and_persist(request,
                 sleep_time: 0,
                 persist_fn: fn _dataset, _rows -> :ok end
               )
    end

    test "does not fail when report does not have rows key" do
      expect(
        Plausible.HTTPClient.Mock,
        :post,
        fn
          "https://analyticsreporting.googleapis.com/v4/reports:batchGet",
          _,
          _,
          [receive_timeout: 60_000] ->
            {:ok, %Finch.Response{status: 200, body: @no_report_response}}
        end
      )

      request = %Plausible.Google.ReportRequest{
        dataset: "imported_exit_pages",
        view_id: "123",
        date_range: Date.range(~D[2022-01-01], ~D[2022-02-01]),
        dimensions: ["ga:date", "ga:exitPagePath"],
        metrics: ["ga:users", "ga:exits"],
        access_token: "fake-token",
        page_token: nil,
        page_size: 10_000
      }

      assert :ok ==
               Api.fetch_and_persist(request,
                 sleep_time: 0,
                 persist_fn: fn dataset, rows ->
                   assert dataset == "imported_exit_pages"
                   assert rows == []

                   :ok
                 end
               )
    end
  end

  describe "fetch_stats/3 errors" do
    setup %{user: user, site: site} do
      insert(:google_auth,
        user: user,
        site: site,
        property: "sc-domain:dummy.test",
        expires: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
      )

      :ok
    end

    test "returns generic google_auth_error on 401/403", %{site: site} do
      expect(
        Plausible.HTTPClient.Mock,
        :post,
        fn
          "https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Adummy.test/searchAnalytics/query",
          [{"Authorization", "Bearer 123"}],
          %{
            dimensionFilterGroups: %{},
            dimensions: ["query"],
            endDate: "2022-01-05",
            rowLimit: 5,
            startDate: "2022-01-01"
          } ->
            {:error, %{reason: %Finch.Response{status: Enum.random([401, 403])}}}
        end
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      assert {:error, "google_auth_error"} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end

    test "returns whatever error code google returns on API client error", %{site: site} do
      expect(
        Plausible.HTTPClient.Mock,
        :post,
        fn
          "https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Adummy.test/searchAnalytics/query",
          _,
          _ ->
            {:error, %{reason: %Finch.Response{status: 400, body: %{"error" => "some_error"}}}}
        end
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      assert {:error, "some_error"} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end

    test "returns generic HTTP error and logs it", %{site: site} do
      expect(
        Plausible.HTTPClient.Mock,
        :post,
        fn
          "https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Adummy.test/searchAnalytics/query",
          _,
          _ ->
            {:error, Finch.Error.exception(:some_reason)}
        end
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      log =
        capture_log(fn ->
          assert {:error, "failed_to_list_stats"} =
                   Plausible.Google.Api.fetch_stats(site, query, 5)
        end)

      assert log =~ "Google Analytics: failed to list stats: %Finch.Error{reason: :some_reason}"
    end
  end

  describe "fetch_stats/3 with VCR cassetes" do
    test "returns name and visitor count", %{user: user, site: site} do
      mock_http_with("google_analytics_stats.json")

      insert(:google_auth,
        user: user,
        site: site,
        property: "sc-domain:dummy.test",
        expires: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      assert {:ok,
              [
                %{name: ["keyword1", "keyword2"], visitors: 25},
                %{name: ["keyword3", "keyword4"], visitors: 15}
              ]} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end

    test "returns next page when page argument is set", %{user: user, site: site} do
      mock_http_with("google_analytics_stats#with_page.json")

      insert(:google_auth,
        user: user,
        site: site,
        property: "sc-domain:dummy.test",
        expires: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
      )

      query = %Plausible.Stats.Query{
        filters: %{"page" => 5},
        date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])
      }

      assert {:ok,
              [
                %{name: ["keyword1", "keyword2"], visitors: 25},
                %{name: ["keyword3", "keyword4"], visitors: 15}
              ]} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end

    test "defaults first page when page argument is not set", %{user: user, site: site} do
      mock_http_with("google_analytics_stats#without_page.json")

      insert(:google_auth,
        user: user,
        site: site,
        property: "sc-domain:dummy.test",
        expires: NaiveDateTime.add(NaiveDateTime.utc_now(), 3600)
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      assert {:ok,
              [
                %{name: ["keyword1", "keyword2"], visitors: 25},
                %{name: ["keyword3", "keyword4"], visitors: 15}
              ]} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end

    test "returns error when token refresh fails", %{user: user, site: site} do
      mock_http_with("google_analytics_auth#invalid_grant.json")

      insert(:google_auth,
        user: user,
        site: site,
        property: "sc-domain:dummy.test",
        access_token: "*****",
        refresh_token: "*****",
        expires: NaiveDateTime.add(NaiveDateTime.utc_now(), -3600)
      )

      query = %Plausible.Stats.Query{date_range: Date.range(~D[2022-01-01], ~D[2022-01-05])}

      assert {:error, "invalid_grant"} = Plausible.Google.Api.fetch_stats(site, query, 5)
    end
  end

  test "list_views/1 returns view IDs grouped by hostname" do
    expect(
      Plausible.HTTPClient.Mock,
      :get,
      fn url, _headers ->
        assert url ==
                 "https://www.googleapis.com/analytics/v3/management/accounts/~all/webproperties/~all/profiles"

        response = "fixture/ga_list_views.json" |> File.read!() |> Jason.decode!()
        {:ok, %Finch.Response{status: 200, body: response}}
      end
    )

    assert {:ok,
            %{
              "one.test" => [{"57238190 - one.test", "57238190"}],
              "two.test" => [{"54460083 - two.test", "54460083"}]
            }} == Plausible.Google.Api.list_views("access_token")
  end

  test "list_views/1 returns authentication_failed when request fails with HTTP 403" do
    expect(
      Plausible.HTTPClient.Mock,
      :get,
      fn _url, _headers ->
        {:error, %Plausible.HTTPClient.Non200Error{reason: %{status: 403, body: %{}}}}
      end
    )

    assert {:error, :authentication_failed} == Plausible.Google.Api.list_views("access_token")
  end

  test "list_views/1 returns authentication_failed when request fails with HTTP 401" do
    expect(
      Plausible.HTTPClient.Mock,
      :get,
      fn _url, _headers ->
        {:error, %Plausible.HTTPClient.Non200Error{reason: %{status: 401, body: %{}}}}
      end
    )

    assert {:error, :authentication_failed} == Plausible.Google.Api.list_views("access_token")
  end

  test "list_views/1 returns error when request fails with HTTP 500" do
    expect(
      Plausible.HTTPClient.Mock,
      :get,
      fn _url, _headers ->
        {:error, %Plausible.HTTPClient.Non200Error{reason: %{status: 500, body: "server error"}}}
      end
    )

    assert {:error, :unknown} == Plausible.Google.Api.list_views("access_token")
  end
end
