# NameGender Ruby

```sh
gem install namegender
```

```ruby
client = NameGender::Client.new("YOUR_API_KEY")
result = client.name("Ayşe", country: "TR")
puts result["gender"], result["probability"], result["sample_size"]
```

## Options and response

`name`, `email`, `username` and `bulk` accept `country:`, `ai_fallback:` and
`best_guess:`:

```ruby
result = client.name("Andrea", country: "IT", best_guess: true)
```

A result carries `query`, `name`, `first_name`, `middle_name`, `last_name`, `name_type`, `gender`, `country`, `probability`,
`sample_size`, `took_ms`, `source`, `confidence` and `matched_as`, alongside
`credits_charged`, `credits_remaining`, `data_version` and `request_id`.
Success is the HTTP status: any non-2xx response raises `NameGender::Error`
with `status` and `body` (`{"error", "message", "request_id", "docs"}`).
Branch on `body["error"]`, not on the message.

## Country distribution

Which countries a name is recorded in. This is not a country-of-origin or
ethnicity inference: `registrations` is counted volume, comparable only among
the countries that publish counted birth statistics, and `attested_in` is
presence with no weight attached. Show `basis["note"]` next to any percentage.

```ruby
result = client.countries("Mehmet", limit: 10)
result["registrations"].each { |r| puts "#{r["country"]} #{r["share"]}%" }
puts result["attested_in"].join(", ")
```

## File jobs

Upload a CSV or XLSX file (up to 100 MB and 1,000,000 rows) and get it back
with gender columns added. One credit per row, charged only if the job
completes.

```ruby
job = client.batches.create(
  "customers.csv",             # a path, a binary String (with filename:) or an IO
  name_column: "first_name",   # required to start
  country_column: "country"    # optional: a country code per row
)

done = client.batches.wait(job["id"]) { |j| puts j["progress"] }
raise done["error"]["code"] if done["status"] == "failed"

client.batches.download(done["id"], "customers-gender.csv")
```

`name_column` is required to start: a guessed column that turns out to be
wrong would spend credits on the wrong data. To see the columns and the cost
first, upload with `start: false`, read `job["inspection"]`, then call
`client.batches.start(job["id"], name_column: ...)`.

`create` sends an `Idempotency-Key` and retries network errors and 502/503/504
with the same key, so a retry never opens a second job. Pass your own
`idempotency_key:` to keep that guarantee across your own retries.

`wait` returns a failed job rather than raising; branch on
`job["error"]["code"]`. `cancel` returns the credit of a job that has not
started, and deletes a finished one. `list(limit:, page:)` includes jobs
started from the dashboard. Up to three jobs can be queued or running at once;
a fourth is refused with `429 too_many_batches`.

The result appends `gender`, `probability`, `sample_size`, `country`, `source`,
`matched_as`, `first_name`, `middle_name`, `last_name` and `name_type` to every
row. A CSV result starts with a UTF-8 byte order mark; read it with
`File.read(path, encoding: "bom|utf-8")`.

## Webhooks

Add an endpoint under Webhooks in the dashboard, and NameGender sends a signed
`POST` to it when a file job completes or fails, and when credits are about to
run out (`credits.low`) or have run out (`credits.depleted`, checked hourly).
`NameGender::Webhooks.verify` checks the signature and the timestamp, and
returns the event.

```ruby
require "sinatra"
require "namegender"

post "/namegender" do
  begin
    event = NameGender::Webhooks.verify(
      request.body.read,   # the raw body, not a parsed params hash (request.raw_post in Rails)
      request.env["HTTP_NAMEGENDER_SIGNATURE"],
      ENV.fetch("NAMEGENDER_WEBHOOK_SECRET")
    )
  rescue NameGender::WebhookVerificationError
    halt 400
  end

  if event["type"] == "batch.completed"
    job = event["data"]["object"]   # the job, as batches.get returns it
    # ...
  end
  204
end
```

The signature covers the exact bytes sent: parsing the JSON and serialising it
again changes them, and the check fails. Answer quickly and do slow work
afterwards. Anything other than a 2xx within 10 seconds is retried, up to 8
attempts over about 45 hours. Use `event["id"]` (also the `NameGender-Event-Id`
header) to ignore a delivery you have already handled: a retry carries the same
id, and order is not guaranteed.
