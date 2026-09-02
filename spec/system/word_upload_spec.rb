# frozen_string_literal: true

RSpec.describe 'Word upload' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }
  let(:docx_path) { Rails.root.join('spec/fixtures/fieldtags.docx') }

  before do
    sign_in(user)
    RateLimit.store.clear
    WordConverter.reset!
  end

  after do
    RateLimit.store.clear
  end

  it 'shows the converting card in the builder and swaps the converted pages in without a reload' do
    visit root_path

    find('#upload_template', visible: false).attach_file(docx_path)

    expect(page).to have_css('.converting-document', text: 'Converting Word document')

    template = Template.last
    expect(page).to have_current_path(edit_template_path(template))
    expect(page).to have_css('.converting-document', text: 'fieldtags.docx')
    expect(page).to have_no_css('#pages_container img')

    page.execute_script('window.__esignNoReload = true')

    # The conversion job runs here, in the test process, with the real LibreOffice.
    Sidekiq::Worker.drain_all

    expect(page).to have_no_css('.converting-document', wait: 20)
    expect(page).to have_css('#pages_container img', wait: 20)
    expect(page.evaluate_script('window.__esignNoReload')).to be(true)

    attachment = template.documents.sole.reload
    expect(attachment.content_type).to eq('application/pdf')
    expect(template.reload.schema.sole).not_to have_key('converting')
  end

  # The conversion finished while nobody had the builder open: the fields it
  # found are still merged — on the next mount — instead of being lost.
  # (fieldtags.docx converts without an AcroForm, so detection is stubbed at
  # Templates::FindAcroFields; see spec/golden/docx_spec.rb.)
  it 'adds the fields found in the Word file when the builder is opened after the conversion finished' do
    allow(Templates::FindAcroFields).to receive(:call) do |_pdf, attachment, _data|
      [{ 'uuid' => SecureRandom.uuid, 'name' => 'Full name', 'type' => 'text', 'required' => true,
         'areas' => [{ 'attachment_uuid' => attachment.uuid, 'page' => 0,
                       'x' => 0.1, 'y' => 0.1, 'w' => 0.3, 'h' => 0.05 }] }]
    end

    visit root_path
    find('#upload_template', visible: false).attach_file(docx_path)

    expect(page).to have_css('.converting-document', text: 'Converting Word document')

    template = Template.last

    # Leave the builder before the job runs: nothing polls, nobody merges.
    visit root_path
    expect(page).to have_no_css('.converting-document')

    Sidekiq::Worker.drain_all

    template.reload
    expect(template.schema.sole).to include('pending_fields' => true)
    expect(template.fields).to be_blank

    visit edit_template_path(template)

    expect(page).to have_css('#pages_container img', wait: 20)
    expect(page).to have_content('Full name', wait: 20)

    deadline = 10.seconds.from_now
    sleep 0.2 until template.reload.fields.any? { |f| f['name'] == 'Full name' } || Time.current > deadline

    field = template.reload.fields.find { |f| f['name'] == 'Full name' }
    expect(field).to be_present
    expect(field['areas'].sole['attachment_uuid']).to eq(template.schema.sole['attachment_uuid'])
    expect(template.schema.sole).not_to have_key('pending_fields')
  end
end
