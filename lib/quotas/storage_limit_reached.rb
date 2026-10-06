# frozen_string_literal: true

module Quotas
  # Raised by Quotas::Storage.assert_available! when an upload would take the
  # billing account past its storage cap. Its own file so Zeitwerk finds the
  # constant from a class-level `rescue_from` under lazy loading. `message`
  # is the English explanation (API callers); `localized_message` the same
  # in the current locale.
  class StorageLimitReached < StandardError
    attr_reader :used, :limit, :incoming

    def initialize(used:, limit:, incoming:)
      @used = used
      @limit = limit
      @incoming = incoming

      super(Storage.message_for(used:, limit:, locale: :en))
    end

    def localized_message
      Storage.message_for(used:, limit:)
    end
  end
end
