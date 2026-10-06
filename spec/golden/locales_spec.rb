# frozen_string_literal: true

# Plural forms carry the same placeholders as English (review 2, L7).
#
# A pluralized string is the one shape where a translator can silently drop an
# interpolation and nothing complains: I18n ignores a placeholder a translation
# does not use, so `one: "one seat"` renders a sentence with the number missing
# rather than raising. That is exactly what had happened to the Arabic seat and
# signer counts — a billing summary and a signer count that read as unfinished
# sentences to the only readers who would ever see them.
#
# The rule is per FORM, not per key: a locale's `one` is measured against
# English's `one` (English's own reads "1 action", where the numeral is in the
# words), and a form English does not have — Arabic's `zero`, `two`, `few`,
# `many` — is measured against English's `other`.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Locale plural forms' do
  def placeholder_pattern
    /%\{(\w+)\}/
  end

  def translations
    @translations ||= YAML.load_file(Rails.root.join('config/locales/i18n.yml'), aliases: true)
  end

  def placeholders(text)
    text.to_s.scan(placeholder_pattern).flatten.to_set
  end

  # Every English key whose value is a plural hash.
  def plural_keys
    translations.fetch('en').select { |_key, value| value.is_a?(Hash) && (value.keys & %w[one other]).size == 2 }.keys
  end

  it 'has plural keys to check at all' do
    expect(plural_keys).not_to be_empty
  end

  it 'never drops a placeholder English carries, in any locale or any form' do
    english = translations.fetch('en')

    missing = translations.except('en').flat_map do |locale, block|
      plural_keys.flat_map do |key|
        forms = block[key]

        next [] if forms.nil?

        forms.filter_map do |form, text|
          wanted = placeholders(english.fetch(key)[form] || english.fetch(key)['other'])
          lost = wanted - placeholders(text)

          "#{locale}.#{key}.#{form} is missing #{lost.to_a.map { |name| "%{#{name}}" }.join(', ')}" if lost.any?
        end
      end
    end

    expect(missing).to eq([])
  end
end
# rubocop:enable RSpec/DescribeClass
