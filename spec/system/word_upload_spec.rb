# frozen_string_literal: true

RSpec.describe 'Word upload' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }
  let(:docx_path) { Rails.root.join('spec/fixtures/fieldtags.docx') }
  let(:docx_type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }

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

  # fieldtags.docx converts without an AcroForm, so detection is stubbed at
  # Templates::FindAcroFields; see spec/golden/docx_spec.rb.
  def stub_found_fields
    allow(Templates::FindAcroFields).to receive(:call) do |_pdf, attachment, _data|
      [{ 'uuid' => SecureRandom.uuid, 'name' => 'Full name', 'type' => 'text', 'required' => true,
         'areas' => [{ 'attachment_uuid' => attachment.uuid, 'page' => 0,
                       'x' => 0.1, 'y' => 0.1, 'w' => 0.3, 'h' => 0.05 }] }]
    end
  end

  # The conversion finished while nobody had the builder open: the fields it
  # found are still merged — on the next mount — instead of being lost.
  it 'adds the fields found in the Word file when the builder is opened after the conversion finished' do
    stub_found_fields

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

  # "Remove" on the keep-or-remove prompt must take only the fields found in
  # the Word file: a field that already lived on another document stays.
  it 'removes only the fields found in the Word file when Remove is chosen, keeping the other document fields' do
    stub_found_fields

    template = create(:template, account:, author: user, only_field_types: %w[text])
    pdf_uuid = template.schema.sole['attachment_uuid']
    expect(template.fields.sole).to include('name' => 'First Name')

    # The builder's add-document flow, minus the browser: store the Word
    # file, list it in the schema, let the job convert it while nobody is
    # looking.
    docx = ActionDispatch::Http::UploadedFile.new(tempfile: File.open(docx_path), filename: 'fieldtags.docx',
                                                  type: docx_type)
    documents, = Templates::CreateAttachments.call(template, { files: [docx] }, extract_fields: true)
    template.update!(schema: template.schema + documents.map { |d| Templates::CreateAttachments.schema_item(d) })

    Sidekiq::Worker.drain_all

    word_uuid = documents.sole.uuid
    template.reload
    expect(template.schema.find { |item| item['attachment_uuid'] == word_uuid }).to include('pending_fields' => true)
    expect(template.fields.sole).to include('name' => 'First Name')

    visit edit_template_path(template)

    prompt = find('.alert', text: 'Keep or remove them?', wait: 20)
    expect(page).to have_content('Full name', wait: 20)
    expect(page).to have_content('First Name')

    within(prompt) { click_button 'Remove' }

    expect(page).to have_no_css('.alert', text: 'Keep or remove them?')
    expect(page).to have_content('First Name')
    expect(page).to have_no_content('Full name')

    deadline = 10.seconds.from_now
    sleep 0.2 until template.reload.fields.none? { |f| f['name'] == 'Full name' } || Time.current > deadline

    template.reload
    expect(template.fields.pluck('name')).to eq(['First Name'])
    expect(template.fields.sole['areas'].sole['attachment_uuid']).to eq(pdf_uuid)
    expect(template.schema.pluck('attachment_uuid')).to eq([pdf_uuid, word_uuid])
    expect(template.schema.find { |item| item['attachment_uuid'] == word_uuid }).not_to have_key('pending_fields')
  end
end
