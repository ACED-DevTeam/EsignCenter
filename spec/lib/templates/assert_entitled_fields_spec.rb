# frozen_string_literal: true

# The baseline-relative check must not be fooled by identities: a template does
# not validate uuid uniqueness, so an incoming set could reuse a legacy
# conditional field's uuid on a second item and pass both as "unchanged".
RSpec.describe Templates::AssertEntitledFields, type: :lib do
  let(:free_account) { create(:account) }
  let(:author) { create(:user, account: free_account) }
  # Built while paid: two fields already carry conditions.
  let(:template) do
    template = create(:template, account: free_account, author:)
    fields = template.fields.deep_dup
    fields[1]['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'not_empty' }]
    fields.last['conditions'] = [{ 'field_uuid' => fields.first['uuid'], 'action' => 'empty' }]
    template.update!(fields:)

    template
  end

  def check(fields, schema: template.schema, account: free_account)
    described_class.call(account, fields, schema:, baseline: template)
  end

  def expect_refusal(feature, &)
    expect(&).to raise_error(Entitlements::UpgradeRequired) { |error| expect(error.feature).to eq(feature) }
  end

  it 'lets a routine re-save through when the legacy conditions are unchanged' do
    fields = template.fields.deep_dup
    fields.first['name'] = 'Renamed'

    expect(check(fields)).to be(true)
  end

  it 'lets a save that removes one of the two conditional fields through' do
    fields = template.fields.deep_dup
    fields.delete_at(1)

    expect(check(fields)).to be(true)
  end

  it 'refuses two incoming items reusing one legacy conditional uuid, even with identical conditions' do
    fields = template.fields.deep_dup
    fields << fields.last.deep_dup.merge('name' => 'Twin')

    expect_refusal(:conditional_logic) { check(fields) }
  end

  it 'refuses a duplicate that replaces a legitimately removed conditional field (same count as the baseline)' do
    fields = template.fields.deep_dup
    fields.delete_at(1)
    fields << fields.last.deep_dup.merge('name' => 'Twin')

    expect_refusal(:conditional_logic) { check(fields) }
  end

  it 'never matches a field against a document that shares its identifier (namespaced keys)' do
    schema = template.schema.deep_dup
    schema.first['conditions'] = [{ 'field_uuid' => template.fields.first['uuid'], 'action' => 'not_empty' }]
    template.update!(schema:)

    fields = template.fields.deep_dup
    fields << { 'uuid' => schema.first['attachment_uuid'], 'name' => 'Impostor', 'type' => 'text',
                'submitter_uuid' => fields.first['submitter_uuid'], 'conditions' => schema.first['conditions'] }

    expect_refusal(:conditional_logic) { check(fields, schema:) }
    expect(check(template.fields, schema:)).to be(true)
  end

  it 'applies the same identity rules to formulas (hidden for everyone)' do
    internal_account = create(:account, :internal)
    formula_template = create(:template, account: internal_account, author: create(:user, account: internal_account))
    fields = formula_template.fields.deep_dup
    fields.last['preferences'] = { 'formula' => "{{#{fields.first['uuid']}}} + 1" }
    formula_template.update!(fields:)

    expect(described_class.call(internal_account, fields, schema: formula_template.schema,
                                                          baseline: formula_template)).to be(true)

    fields << fields.last.deep_dup.merge('name' => 'Twin')

    expect_refusal(:formulas) do
      described_class.call(internal_account, fields, schema: formula_template.schema, baseline: formula_template)
    end
  end
end
