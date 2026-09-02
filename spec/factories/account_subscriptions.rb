# frozen_string_literal: true

FactoryBot.define do
  factory :account_subscription do
    account
    access_state { 'active' }
    status { 'manual' }

    transient do
      seats { 1 }
    end

    quantity { seats }
  end
end
