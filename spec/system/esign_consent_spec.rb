# frozen_string_literal: true

RSpec.describe 'ESIGN consent in the signing form' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }

  # Text inputs in the signing form carry the field uuid as their id.
  def fill_first_name(template, value)
    find_by_id(template_field(template, 'First Name')['uuid']).set(value)
  end

  context 'when signing through a share link' do
    let(:template) { create(:template, shared_link: true, account:, author:, only_field_types: %w[text]) }

    it 'requires the consent checkbox before completing and records the event' do
      visit start_form_path(slug: template.slug)

      fill_in 'Email', with: 'signer@example.com'
      click_button 'Start'

      expect(page).to have_css('submission-form[data-esign-consent]', visible: :all)
      expect(page).to have_unchecked_field('esign_consent')
      expect(page).to have_css('#submit_form_button[disabled]')

      click_button 'Electronic Signature Disclosure'

      within('dialog#esign_disclosure_modal[open]') do
        expect(page).to have_content('Electronic Records and Signatures Disclosure')
        expect(page).to have_content("Version #{EsignConsent::VERSION}")
        # D77 A: the sender is named, with an address, instead of "the sender".
        expect(page).to have_content("This document was sent by #{account.name}")
        expect(page).to have_content(author.email)

        click_button 'Close'
      end

      expect(page).not_to have_css('dialog#esign_disclosure_modal[open]')

      fill_first_name(template, 'Jane')

      # v3: the PDF link is offered, not required. The disclosure asks the
      # signer to confirm, by ticking the box, that they can open the document
      # as a PDF — so the box ticks straight away, and the event says the link
      # was offered and not followed.
      expect(page).to have_css('#esign_consent_view_pdf')
      expect(page).to have_no_css('#esign_consent[aria-disabled]')
      expect(page).to have_css('#esign_consent:not([aria-describedby])')

      check 'esign_consent'

      expect(page).to have_css('#submit_form_button:not([disabled])')

      find('#submit_form_button').click

      expect(page).to have_content('Form has been completed!')

      submitter = Submitter.last
      event = submitter.submission_events.find_by(event_type: 'esign_consent')

      expect(submitter.completed_at).to be_present
      expect(event.data).to include('version' => EsignConsent::VERSION, 'pdf_opened' => false,
                                    'self_signing' => false,
                                    'sender_name' => account.name, 'sender_email' => author.email)
      expect(event.data['ip']).to be_present
      expect(event.data['ua']).to be_present
    end
  end

  context 'when the signer has already consented' do
    let(:template) { create(:template, account:, author:, only_field_types: %w[text date]) }
    let(:submission) { create(:submission, template:) }
    let(:submitter) do
      create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:, email: 'robin@example.com')
    end

    it 'shows the checkbox once, then never again for that signer' do
      visit submit_form_path(slug: submitter.slug)

      expect(page).to have_unchecked_field('esign_consent')
      expect(page).to have_css('#submit_form_button[disabled]')

      fill_first_name(template, 'Jane')
      # Following the optional link is still recorded, as the page's own claim.
      find_by_id('esign_consent_view_pdf').click
      check 'esign_consent'
      click_button 'next'

      expect(page).to have_field('Birthday')
      expect(page).not_to have_css('#esign_consent')
      expect(submitter.submission_events.where(event_type: 'esign_consent').sole.data)
        .to include('pdf_opened' => true)

      visit submit_form_path(slug: submitter.slug)

      expect(page).to have_field('Birthday')
      expect(page).not_to have_css('#esign_consent')
      expect(page).to have_css('#submit_form_button:not([disabled])')
    end
  end

  context 'when previewing a template form (dry run, never posts)' do
    let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }

    it 'renders the checkbox and gates completion the same way' do
      sign_in(author)

      visit template_form_path(template)

      expect(page).to have_css('submission-form[data-esign-consent]', visible: :all)

      find('#expand_form_button').click

      expect(page).to have_unchecked_field('esign_consent')
      expect(page).to have_css('#submit_form_button[disabled]')

      # The preview's link answers off the template (its signer is never saved).
      expect(page).to have_css("#esign_consent_view_pdf[href='/templates/#{template.id}/form_document.pdf']")

      find_by_id('esign_consent_view_pdf').click
      check 'esign_consent'

      expect(page).to have_css('#submit_form_button:not([disabled])')
      expect(SubmissionEvent.count).to eq(0)
    end
  end
end
