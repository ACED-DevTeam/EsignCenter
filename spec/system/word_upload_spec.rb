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
end
