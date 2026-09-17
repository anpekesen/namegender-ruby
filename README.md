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
