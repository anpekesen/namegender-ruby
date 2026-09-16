# NameGender Ruby

```sh
gem install namegender
```

```ruby
client = NameGender::Client.new("YOUR_API_KEY")
result = client.name("Ayşe", country: "TR")
puts result["gender"]
```

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
