# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    account
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    password { 'password' }
    role { User::ADMIN_ROLE }
    email { Faker::Internet.email }

    trait :admin do
      role { User::ADMIN_ROLE }
    end

    trait :editor do
      role { User::EDITOR_ROLE }
    end

    trait :viewer do
      role { User::VIEWER_ROLE }
    end
  end
end
