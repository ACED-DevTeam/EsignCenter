# frozen_string_literal: true

# Put environment variables back the way an example found them. Declare the
# keys once per example group — `stash_env 'APP_URL', 'HOST'` — and whatever
# the group's hooks or examples do to them is restored afterwards, including
# when the example fails. `clear: true` also empties them before the example.
module EnvStash
  def stash_env(*keys, clear: false)
    around do |example|
      original_values = keys.index_with { |key| ENV.fetch(key, nil) }
      keys.each { |key| ENV.delete(key) } if clear

      example.run
    ensure
      original_values.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end
  end
end

RSpec.configure { |config| config.extend(EnvStash) }
