# frozen_string_literal: true

# The pre-deploy audit for the integrating apps' own accounts: formula fields
# are refused for everyone from this release on, and internal webhooks now get
# the production outbound rules. The audit lists both, reads nothing it
# should not print, and writes nothing.
RSpec.describe ReleaseInternalAudit do
  let(:internal) { create(:account, :internal) }
  let(:customer) { create(:account) }

  def template_with_formula(account, archived: false)
    template = create(:template, account:, author: create(:user, account:), name: 'Invoice with totals')
    fields = template.fields
    fields.last['preferences'] = { 'formula' => "{{#{fields.first['uuid']}}} + 1" }
    template.update_columns(fields:, archived_at: archived ? Time.current : nil)

    template
  end

  # Saved without the save-time validator: these rows exist because the old
  # code accepted them, which is exactly what the audit is for.
  def webhook(account, url)
    create(:webhook_url, account:, url: 'https://example.com/hooks').tap { |w| w.update_columns(url:) }
  end

  it 'lists internal templates that carry a formula field, and no customer ones' do
    listed = template_with_formula(internal)
    archived = template_with_formula(internal, archived: true)
    create(:template, account: internal, author: create(:user, account: internal))
    template_with_formula(customer)

    result = described_class.call

    expect(result.formula_templates).to contain_exactly(
      have_attributes(account_id: internal.id, template_id: listed.id, name: 'Invoice with totals',
                      formula_fields: 1, archived: false),
      have_attributes(template_id: archived.id, archived: true)
    )
  end

  it 'lists internal webhook URLs the production rules refuse, by account and host only' do
    webhook(internal, 'http://va-claims.example.com/hooks/esign?token=query-secret')
    webhook(internal, 'https://user:pass@localhost/hooks')
    webhook(internal, 'https://10.0.0.8/hooks')
    webhook(internal, 'https://app.internal.example/hooks')
    webhook(internal, 'https://api.example.com:8443/hooks')
    webhook(internal, 'https://good.example.com/hooks')
    webhook(customer, 'http://customer.example.com/hooks')
    allow(OutboundAddress).to receive(:resolve).and_call_original
    allow(OutboundAddress).to receive(:resolve).with('app.internal.example').and_return([IPAddr.new('10.1.2.3')])
    allow(OutboundAddress).to receive(:resolve).with('good.example.com').and_return([IPAddr.new('93.184.215.14')])

    result = described_class.call

    expect(result.refused_webhooks.map { |w| [w.account_id, w.host, w.reason] }).to contain_exactly(
      [internal.id, 'va-claims.example.com', 'not HTTPS on port 443'],
      [internal.id, 'localhost', 'localhost'],
      [internal.id, '10.0.0.8', 'private or internal network address'],
      [internal.id, 'app.internal.example', 'private or internal network address'],
      [internal.id, 'api.example.com', 'not HTTPS on port 443']
    )

    report = described_class.report(result)

    expect(report).to include("account #{internal.id} webhook", 'host va-claims.example.com: not HTTPS on port 443')
    expect(report).not_to include('query-secret', 'user:pass', '/hooks', 'token')
  end

  it 'says so when a host does not resolve from the rehearsal machine' do
    webhook(internal, 'https://only-resolves-on-render.example/hooks')
    allow(OutboundAddress).to receive(:resolve).and_return([])

    expect(described_class.call.refused_webhooks.map(&:reason))
      .to eq(['host does not resolve from here (re-check from the production shell)'])
  end

  it 'never writes to the database' do
    template_with_formula(internal)
    webhook(internal, 'http://va-claims.example.com/hooks')
    allow(described_class).to receive(:formula_templates).and_wrap_original do |original|
      internal.touch

      original.call
    end

    expect { described_class.call }.to raise_error(ActiveRecord::ReadOnlyError)
  end

  describe 'rake release:internal_audit' do
    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('release:internal_audit')
      Rake::Task['release:internal_audit'].reenable
    end

    it 'passes quietly when nothing needs a decision' do
      webhook(internal, 'https://good.example.com/hooks')

      expect { Rake::Task['release:internal_audit'].invoke }.to output(/none.*none/m).to_stdout
    end

    it 'prints the findings and exits non-zero' do
      template_with_formula(internal)

      expect { Rake::Task['release:internal_audit'].invoke }
        .to raise_error(SystemExit).and output(/Invoice with totals/).to_stdout.and output(/1 finding/).to_stderr
    end
  end
end
