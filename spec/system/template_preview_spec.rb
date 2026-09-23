# frozen_string_literal: true

RSpec.describe 'An embedded template preview' do
  let(:account) { create(:account, :internal) }
  let(:author) { create(:user, account:) }
  let!(:template) { create(:template, account:, author:, only_field_types: %w[text]) }

  def signing_record_counts
    [Submission, Submitter, SubmissionEvent, CompletedSubmitter, WebhookEvent, WebhookAttempt]
      .map(&:count)
  end

  def mount_preview
    # A same-origin host page keeps the browser test entirely local. The
    # request suite separately checks the configured frame-ancestors origin.
    visit new_user_session_path
    host = URI(page.current_url)
    origin = "#{host.scheme}://#{host.host}:#{host.port}"
    session = TemplatePreviewSessions::Create.call(
      user: author, attrs: { template_id: template.id, embed_origin: origin }
    )
    path = embed_template_preview_path(token: session.token)

    page.execute_script(<<~JS, path)
      const frame = document.createElement('iframe')
      frame.id = 'template_preview'
      frame.title = 'Document preview'
      frame.src = arguments[0]
      // Keep the iframe's fixed-bottom form inside the browser viewport.
      // A taller iframe makes its controls live below the host page fold.
      frame.style.cssText = 'display:block;width:100%;height:calc(100vh - 20px);border:0'
      document.body.replaceChildren(frame)
    JS

    path
  end

  def save_launch_evidence(name)
    directory = Rails.root.join('tmp/launch-review')
    directory.mkpath
    page.driver.browser.screenshot(path: directory.join(name).to_s)
  end

  it 'opens the consent PDF and completes a dry run without signing records or write requests' do
    counts_before = signing_record_counts
    template_before = template.attributes
    preview_path = mount_preview
    browser = page.driver.browser
    existing_targets = browser.command('Target.getTargets').fetch('targetInfos').pluck('targetId')
    pdf_target = nil

    within_frame('template_preview') do
      expect(page).to have_css('submission-form[data-dry-run="true"]')
      find('#expand_form_button').click
      expect(page).to have_css('#submit_form_button[disabled]')
      expect(page).to have_css("#esign_consent_view_pdf[href='#{preview_path}/document']")
      find_by_id(template.fields.sole.fetch('uuid')).set('Preview Only')

      save_launch_evidence('template-preview-before-consent.png')
      find_by_id('esign_consent_view_pdf').click
    end

    # Cuprite's window list includes Chromium's PDF/iframe targets. Opening one
    # PDF can therefore add several handles, and attaching to the PDF extension
    # as an HTML page can stall. Inspect the new top-level document target
    # without switching into its viewer; the real link click still opens it.
    eventually do
      pdf_target = browser.command('Target.getTargets').fetch('targetInfos').find do |target|
        target['type'] == 'page' && existing_targets.exclude?(target['targetId']) &&
          URI(target['url']).path == "#{preview_path}/document"
      end
      expect(pdf_target).to be_present
    end
    browser.command('Target.closeTarget', targetId: pdf_target.fetch('targetId'))

    # Check the bytes as well as browser navigation, directly through the
    # preview token without issuing a separately reusable blob URL.
    api = ActionDispatch::Integration::Session.new(Rails.application)
    api.get "#{preview_path}/document"
    expect(api.response).to have_http_status(:ok)
    expect(api.response.media_type).to eq('application/pdf')
    expect(api.response.headers['Cache-Control']).to include('private', 'no-store')
    expect(api.response.headers['Location']).to be_nil
    expect(api.response.body).to start_with('%PDF')

    within_frame('template_preview') do
      page.execute_script(<<~JS)
        window.previewWriteRequests = []
        const originalFetch = window.fetch
        window.fetch = function (input, options = {}) {
          const method = (options.method || input.method || 'GET').toUpperCase()
          if (!['GET', 'HEAD'].includes(method)) window.previewWriteRequests.push(method)
          return originalFetch.apply(this, arguments)
        }
      JS
      check 'esign_consent'
      expect(page).to have_css('#submit_form_button:not([disabled])')
      find('#submit_form_button').click
      expect(page).to have_content('Form has been completed!')
      save_launch_evidence('template-preview-completed.png')
      expect(page.evaluate_script('window.previewWriteRequests')).to eq([])
    end

    expect(signing_record_counts).to eq(counts_before)
    expect(template.reload.attributes).to eq(template_before)
    expect(account.reload.account_subscription).to be_nil
  end
end
