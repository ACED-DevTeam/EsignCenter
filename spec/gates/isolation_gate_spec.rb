# frozen_string_literal: true

require 'rake'

Rails.application.load_tasks unless Rake::Task.task_defined?('gates:isolation')

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Isolation gate' do
  describe 'Gates.isolation_violations' do
    it 'catches a config finder with key: anywhere in the arguments and no account scope' do
      finders = %w[find_by find_by! exists? where order pluck find_or_initialize_by
                   find_or_create_by find_or_create_by! create_or_find_by create_or_find_by! first_or_initialize]

      finders.each do |finder|
        [
          "AccountConfig.#{finder}(key: 'x')",
          "EncryptedConfig.#{finder}(value: true, key: 'x')",
          "AccountConfig.#{finder}(\n  value: true,\n  key: AccountConfig::FORCE_MFA\n)",
          "AccountConfig . #{finder}( key: EncryptedConfig::EMAIL_SMTP_KEY, value: helper(1) )"
        ].each do |snippet|
          expect(Gates.isolation_violations("#{snippet}\n", 'lib/probe.rb')).to have_attributes(size: 1), snippet
        end
      end
    end

    it 'accepts account-scoped finders whatever the argument order' do
      [
        "AccountConfig.find_by(account: account, key: 'x')",
        "AccountConfig.exists?(value: true,\n  account_id: current_user.account_id,\n  key: AccountConfig::FORCE_MFA)",
        "EncryptedConfig.where(key: 'x', account:)",
        "EncryptedConfig.find_or_create_by!(key: 'x', account_id: account.id)",
        "current_account.account_configs.find_or_initialize_by(key: 'x')",
        "AccountConfig.where(account: current_account, key: 'x').first_or_initialize(value: 'single')"
      ].each do |snippet|
        expect(Gates.isolation_violations("#{snippet}\n", 'lib/probe.rb')).to be_empty, snippet
      end
    end

    it 'catches no-argument enumerations of the config tables' do
      %w[first take all pluck(:value) find_each each].each do |call|
        expect(Gates.isolation_violations("AccountConfig.#{call}\n", 'lib/probe.rb')).to have_attributes(size: 1), call
        expect(Gates.isolation_violations("EncryptedConfig.#{call} { }\n", 'lib/probe.rb')).to have_attributes(size: 1)
      end
    end

    it 'catches first-account and account-one shortcuts' do
      ['Account.order(:id).first', 'Account.first', 'Account.minimum(:id)', 'account_id == 1', 'account==1',
       'scope.order(:account_id)'].each do |snippet|
        expect(Gates.isolation_violations("#{snippet}\n", 'app/models/probe.rb')).to have_attributes(size: 1), snippet
      end
    end

    it 'reports each occurrence with its line number' do
      content = "ok = AccountConfig.find_by(account:, key: 'x')\nbad = AccountConfig.find_by(key: 'x')\n"

      expect(Gates.isolation_violations(content, 'lib/probe.rb'))
        .to eq(["lib/probe.rb:2: bad = AccountConfig.find_by(key: 'x')"])
    end

    it 'exempts an allowlisted snippet only in its own file' do
      snippet = "AccountConfig.where(key: 'fulltext_search', value: true)"

      expect(Gates.isolation_violations("legacy = #{snippet}\n", 'lib/tasks/operator.rake')).to be_empty
      expect(Gates.isolation_violations("legacy = #{snippet}\n", 'lib/tasks/other.rake'))
        .to eq(["lib/tasks/other.rake:1: legacy = #{snippet}"])
    end

    it 'fails a line that carries an allowlisted snippet plus a second unscoped lookup' do
      line = "legacy = AccountConfig.where(key: 'fulltext_search', value: true) || AccountConfig.find_by(key: 'x')"

      expect(Gates.isolation_violations("#{line}\n", 'lib/tasks/operator.rake'))
        .to eq(["lib/tasks/operator.rake:1: #{line}"])
    end

    it 'does not exempt a rewritten version of the allowlisted snippet' do
      line = "AccountConfig.where(key: 'fulltext_search', value: false)"

      expect(Gates.isolation_violations("#{line}\n", 'lib/tasks/operator.rake'))
        .to eq(["lib/tasks/operator.rake:1: #{line}"])
    end

    it 'keeps the allowlist to the two reasoned operator-config pins' do
      expect(Gates::ISOLATION_ALLOWLIST.map { |entry| entry.fetch(:file) })
        .to contain_exactly('lib/tasks/operator.rake', 'lib/storage_config_guard.rb')
      expect(Gates::ISOLATION_ALLOWLIST).to all(include(:reason))
      expect(Gates::ISOLATION_ALLOWLIST.map { |entry| entry.fetch(:reason) }).to all(be_present)
    end
  end

  describe 'Gates.spec_violations' do
    # Assembled at runtime: the metadata form itself is banned in this file too.
    let(:metadata_line) { "it 'x', #{['multitenant:', 'true'].join(' ')} do" }
    let(:stubs) do
      [
        "allow(Docuseal).to receive(:multitenant?)\n  .and_return(true)",
        'allow(Docuseal).to receive(:multitenant?).and_return(false)',
        'allow(Docuseal).to receive_messages(multitenant?: true)',
        "stub_const('Docuseal::MULTITENANT', true)",
        "ENV['MULTITENANT'] = 'true'"
      ]
    end

    it 'bans multitenant example metadata in every spec except rails_helper' do
      expect(Gates.spec_violations("#{metadata_line}\n", 'spec/requests/probe_spec.rb'))
        .to eq(["spec/requests/probe_spec.rb:1: #{metadata_line}"])
      expect(Gates.spec_violations("#{metadata_line}\n", 'spec/rails_helper.rb')).to be_empty
    end

    it 'bans every spelling of a multitenancy stub in golden specs, split lines included' do
      stubs.each do |stub|
        expect(Gates.spec_violations("#{stub}\n", 'spec/golden/probe_spec.rb')).not_to be_empty, stub
      end
    end

    it 'reports the golden ban on the line that carries the mention' do
      content = "before do\n  allow(Docuseal).to receive(:multitenant?)\n    .and_return(false)\nend\n"

      expect(Gates.spec_violations(content, 'spec/golden/probe_spec.rb'))
        .to eq(['spec/golden/probe_spec.rb:2: allow(Docuseal).to receive(:multitenant?)'])
    end

    it 'leaves multitenancy stubs alone outside spec/golden' do
      stubs.each do |stub|
        expect(Gates.spec_violations("#{stub}\n", 'spec/requests/probe_spec.rb')).to be_empty, stub
      end
    end
  end

  describe 'the current tree' do
    it 'passes the isolation gate' do
      expect(Gates.isolation_failures).to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass
