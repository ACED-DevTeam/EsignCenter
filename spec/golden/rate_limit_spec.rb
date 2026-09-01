# frozen_string_literal: true

RSpec.describe 'Rate limiting and durable account counters', type: :request do
  before do
    RateLimit.store.clear
  end

  after do
    RateLimit.store.clear
  end

  describe RateLimit do
    it 'is enabled in the test environment' do
      expect(described_class.call('x', limit: 2, ttl: 1.minute)).to be(true)
      expect(described_class.call('x', limit: 2, ttl: 1.minute)).to be(true)

      expect { described_class.call('x', limit: 2, ttl: 1.minute) }
        .to raise_error(RateLimit::LimitApproached)
    end
  end

  describe AccountCounters do
    context 'with concurrent database connections' do
      self.use_transactional_tests = false

      it 'increments atomically' do
        account = create(:account)
        threads = Array.new(5) do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              10.times { described_class.increment!(account.id, 'atomic') }
            end
          end
        end

        threads.each(&:join)
        threads.each(&:value)

        expect(described_class.value(account.id, 'atomic')).to eq(50)
      ensure
        account&.destroy!
      end

      # The conflict branch stamps updated_at with the database clock, which
      # inside a wrapping test transaction would equal the insert's stamp —
      # so this runs against real, committed statements.
      it 'moves updated_at on every increment while created_at stays put' do
        account = create(:account)

        described_class.increment!(account.id, 'touched')
        counter = AccountCounter.find_by!(account_id: account.id, key: 'touched')

        expect(counter.updated_at).to eq(counter.created_at)

        described_class.increment!(account.id, 'touched')
        counter.reload

        expect(counter.value).to eq(2)
        expect(counter.updated_at).to be > counter.created_at
      ensure
        account&.destroy!
      end
    end

    it 'isolates values by period' do
      account = create(:account)

      expect(described_class.value(account.id, 'documents', period: '2026-08')).to eq(0)
      expect(described_class.increment!(account.id, 'documents', period: '2026-08', by: 2)).to eq(2)
      expect(described_class.increment!(account.id, 'documents', period: '2026-08', by: 3)).to eq(5)
      expect(described_class.increment!(account.id, 'documents', period: '2026-09', by: 4)).to eq(4)

      expect(described_class.value(account.id, 'documents', period: '2026-08')).to eq(5)
      expect(described_class.value(account.id, 'documents', period: '2026-09')).to eq(4)
    end

    it 'formats monthly periods in UTC' do
      time = Time.new(2026, 9, 1, 0, 30, 0, '+02:00')

      expect(described_class.month_period(time)).to eq('2026-08')
    end

    it 'does not reset the submission count when submissions are deleted' do
      account = create(:account)
      user = create(:user, account:)
      template = create(:template, account:, author: user, attachment_count: 0)

      first_submission = create(:submission, template:, created_by_user: user)
      expect(described_class.value(account.id, 'submissions_created')).to eq(1)

      first_submission.destroy!
      expect(described_class.value(account.id, 'submissions_created')).to eq(1)

      create(:submission, template:, created_by_user: user)
      expect(described_class.value(account.id, 'submissions_created')).to eq(2)
    end

    it 'deletes counter rows when their account is destroyed' do
      account = create(:account)
      described_class.increment!(account.id, 'documents')

      expect do
        account.destroy!
      end.to change { AccountCounter.where(account_id: account.id).count }.from(1).to(0)
    end
  end

  describe 'POST /settings/reveal_access_token' do
    it 'refuses the fifth request within one minute using the shared store' do
      user = create(:user)
      sign_in(user)

      4.times do
        post settings_reveal_access_token_path, params: { password: 'password' }

        expect(response).to have_http_status(:ok)
      end

      post settings_reveal_access_token_path, params: { password: 'password' }

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
