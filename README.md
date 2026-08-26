# NameGender Ruby

```sh
gem install namegender
```

```ruby
client = NameGender::Client.new("YOUR_API_KEY")
result = client.name("Ayşe", country: "TR")
puts result["gender"]
```
