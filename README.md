# GenderScope Ruby

```sh
gem install genderscope
```

```ruby
client = GenderScope::Client.new("YOUR_API_KEY")
result = client.name("Ayşe", country: "TR")
puts result["gender"]
```
