# frozen_string_literal: true

describe Submitters::SubmitValues do
  let(:account) { create(:account, timezone: 'UTC', locale: 'en-US') }
  let(:author) { create(:user, account:) }
  let(:submitter_uuid) { SecureRandom.uuid }
  let(:template) { create(:template, account:, author:) }

  before do
    template.update!(
      submitters: [{ 'name' => 'Claimant', 'uuid' => submitter_uuid }],
      fields: [
        auto_date_cell('signed-month', 'Signed Month', 'MM', 2),
        auto_date_cell('signed-day', 'Signed Day', 'DD', 2),
        auto_date_cell('signed-year', 'Signed Year', 'YYYY', 4)
      ]
    )
  end

  def auto_date_cell(uuid, name, format, cells)
    {
      'uuid' => uuid,
      'submitter_uuid' => submitter_uuid,
      'name' => name,
      'type' => 'cells',
      'readonly' => true,
      'required' => false,
      'default_value' => '{{date}}',
      'preferences' => { 'format' => format },
      'areas' => [
        {
          'x' => 0.1,
          'y' => 0.1,
          'w' => 0.02 * cells,
          'h' => 0.02,
          'cell_w' => 0.02,
          'page' => 0,
          'attachment_uuid' => SecureRandom.uuid
        }
      ]
    }
  end

  it 'formats auto-date defaults for cells as comb-ready date chunks' do
    submission = create(:submission, :with_submitters, template:, created_by_user: author)
    submitter = submission.submitters.first

    travel_to Time.zone.parse('2026-06-20 12:00:00 UTC') do
      values = described_class.merge_default_values(submitter)

      expect(values).to include(
        'signed-month' => '06',
        'signed-day' => '20',
        'signed-year' => '2026'
      )
    end
  end
end
