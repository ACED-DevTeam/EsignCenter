# frozen_string_literal: true

FactoryBot.define do
  factory :account_invite do
    account
    email { Faker::Internet.email }
    role { User::ADMIN_ROLE }
    expires_at { BillingLifecycle::INVITE_TOKEN_DAYS.days.from_now }

    # A row with no token could never be accepted, so every built invite has
    # one — the raw value stays readable on this object (invite.raw_token) and
    # only its digest is stored, exactly as the real flow does it.
    after(:build, &:generate_token)

    trait :expired do
      expires_at { 1.hour.ago }
    end
  end
end
