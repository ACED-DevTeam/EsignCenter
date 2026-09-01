# frozen_string_literal: true

require Rails.root.join('db/migrate/20260901090600_backfill_globally_resolved_encrypted_configs.rb')

# Before de-globalization the mail interceptor sent EVERY account's mail
# through the lowest account's pinned SMTP row, and the timeserver lookup fell
# back to the lowest account's timestamp_server_url row. Both reads are now
# per-account, so the migration must copy those two rows to every pre-existing
# non-testing account that lacks its own — and nothing else — so that a deploy
# onto a host with no SMTP_* / TIMESERVER_URL env changes nobody's behavior.
RSpec.describe BackfillGloballyResolvedEncryptedConfigs do
  # The lowest-id account is the one the pre-change global fallbacks pointed at.
  # A third, row-less account makes the source choice observable: it must
  # receive the lowest account's row, never the second account's.
  let!(:source_account) { create(:account) }
  let!(:other_account) { create(:account) }
  let!(:third_account) { create(:account) }

  let(:source_smtp_value) do
    {
      'host' => 'smtp.source.example',
      'port' => '587',
      'username' => 'source-token',
      'password' => 'source-token',
      'from_email' => 'noreply@source.example',
      'authentication' => 'plain'
    }
  end

  def run_backfill
    ActiveRecord::Migration.suppress_messages { BackfillGloballyResolvedEncryptedConfigs.new.up }
  end

  def smtp_row(account)
    EncryptedConfig.find_by(account:, key: EncryptedConfig::EMAIL_SMTP_KEY)
  end

  def timeserver_row(account)
    EncryptedConfig.find_by(account:, key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)
  end

  def stored_ciphertext(config)
    ActiveRecord::Base.connection.select_value("SELECT value FROM encrypted_configs WHERE id = #{config.id.to_i}")
  end

  before do
    create(:encrypted_config, account: source_account,
                              key: EncryptedConfig::EMAIL_SMTP_KEY, value: source_smtp_value)
  end

  it 'treats the first created account as the pre-change global fallback source' do
    expect(Account.minimum(:id)).to eq(source_account.id)
  end

  it 'copies the SMTP row to an account that has none, decryptable and usable' do
    run_backfill

    copied = smtp_row(other_account)

    expect(copied).to be_present
    expect(copied.value).to eq(source_smtp_value)
    # Raw ciphertext copy — byte-identical to the source row's stored value.
    expect(stored_ciphertext(copied)).to eq(stored_ciphertext(smtp_row(source_account)))

    result = MailConfigs.resolve(other_account)

    expect(result.source).to eq(:account)
    expect(result.smtp[:address]).to eq('smtp.source.example')
    expect(result.from).to include('noreply@source.example')
  end

  it 'leaves an own SMTP pin untouched and copies the lowest account\'s row, not that pin, to a row-less account' do
    own_value = source_smtp_value.merge('host' => 'smtp.other.example', 'from_email' => 'noreply@other.example')
    own_pin = create(:encrypted_config, account: other_account,
                                        key: EncryptedConfig::EMAIL_SMTP_KEY, value: own_value)

    # Only the row-less third account gains a row.
    expect { run_backfill }.to change(EncryptedConfig, :count).by(1)

    expect(own_pin.reload.value).to eq(own_value)
    expect(MailConfigs.resolve(other_account).smtp[:address]).to eq('smtp.other.example')

    copied = smtp_row(third_account)

    expect(stored_ciphertext(copied)).to eq(stored_ciphertext(smtp_row(source_account)))
    expect(stored_ciphertext(copied)).not_to eq(stored_ciphertext(own_pin))
    expect(MailConfigs.resolve(third_account).smtp[:address]).to eq('smtp.source.example')
  end

  it 'skips testing accounts, which inherit their parent pin at runtime' do
    testing_child = create(:account)
    other_account.testing_accounts << testing_child

    run_backfill

    expect(testing_child.reload.encrypted_configs).to be_empty
    expect(smtp_row(other_account)).to be_present
    expect(MailConfigs.resolve(testing_child).smtp[:address]).to eq('smtp.source.example')
  end

  it 'copies the lowest account\'s own timeserver row to every row-less account' do
    create(:encrypted_config, account: source_account,
                              key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                              value: 'http://timestamp.source.example')

    run_backfill

    [other_account, third_account].each do |account|
      copied = timeserver_row(account)

      expect(copied).to be_present
      expect(copied.value).to eq('http://timestamp.source.example')
    end
  end

  # Unlike SMTP, the old timeserver fallback read only the lowest account's own
  # row: when that account had none, nobody inherited a later account's row.
  it 'copies no timeserver row when the lowest account has none, even if a later account does' do
    later_pin = create(:encrypted_config, account: other_account,
                                          key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY,
                                          value: 'http://timestamp.other.example')

    expect { run_backfill }.not_to change(EncryptedConfig.where(key: EncryptedConfig::TIMESTAMP_SERVER_URL_KEY), :count)

    expect(timeserver_row(source_account)).to be_nil
    expect(timeserver_row(third_account)).to be_nil
    expect(later_pin.reload.value).to eq('http://timestamp.other.example')
  end

  it 'copies only the two globally resolved keys' do
    create(:encrypted_config, account: source_account,
                              key: EncryptedConfig::APP_URL_KEY, value: 'https://source.example')

    run_backfill

    expect(other_account.encrypted_configs.pluck(:key)).to contain_exactly(EncryptedConfig::EMAIL_SMTP_KEY)
    expect(described_class::GLOBALLY_RESOLVED_KEYS)
      .to contain_exactly(EncryptedConfig::EMAIL_SMTP_KEY, EncryptedConfig::TIMESTAMP_SERVER_URL_KEY)
  end

  it 'is idempotent' do
    run_backfill

    expect { run_backfill }.not_to change(EncryptedConfig, :count)
    expect(EncryptedConfig.where(key: EncryptedConfig::EMAIL_SMTP_KEY).count).to eq(3)
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
