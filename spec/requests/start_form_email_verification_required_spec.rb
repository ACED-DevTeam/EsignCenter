# frozen_string_literal: true

RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe 'Shared form email verification notice', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, shared_link: true) }

  it 'explains that an emailed invitation is required when email 2FA is enabled' do
    template.update_column(:preferences, { 'require_email_2fa' => true })

    get "/d/#{template.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Email invitation required')
    expect(response.body).to include(
      'This form requires an emailed invitation because email verification is enabled.'
    )
    expect(response.body).to include('The sender can turn off &quot;Require email 2FA&quot;')
  end

  context 'when the template is not shared' do
    let(:template) { create(:template, account:, author: user, shared_link: false) }

    before { template.update_column(:preferences, { 'require_email_2fa' => true }) }

    # The notice is only for shared templates: a private one must not confirm
    # it exists (or name itself) to a stranger.
    it 'is a 404 for an anonymous visitor' do
      expect { get "/d/#{template.slug}" }.to raise_error(ActionController::RoutingError)
    end

    it 'shows the owner the private page, not the verification notice' do
      sign_in(user)

      get "/d/#{template.slug}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('share_link_is_currently_disabled'))
      expect(response.body).not_to include('Email invitation required')
    end
  end

  describe 'writes through the share link' do
    def enqueued_jobs_count
      Sidekiq::Queues.jobs_by_queue.values.sum(&:size)
    end

    def expect_refusal_page
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include('Email invitation required')
      expect(response.body).not_to include('name="submitter[email]"')
    end

    context 'when email 2FA is enabled' do
      before { template.update_column(:preferences, { 'require_email_2fa' => true }) }

      # The page is not just a notice: submitting one's own email is refused
      # before a submitter is looked up or built, so nothing is created,
      # nothing is mailed and no job is queued.
      it 'refuses PUT /d/:slug without creating anything' do
        expect do
          put "/d/#{template.slug}", params: { submitter: { email: 'stranger@example.com' } }
        end.to not_change(Submission, :count)
          .and(not_change(Submitter, :count))
          .and(not_change(ActionMailer::Base.deliveries, :count))
          .and(not_change { enqueued_jobs_count })

        expect_refusal_page
      end

      it 'refuses the OTP verification step through the same door' do
        expect do
          put "/d/#{template.slug}", params: { submitter: { email: 'stranger@example.com' }, one_time_code: '123456' }
        end.to not_change(Submitter, :count).and(not_change { enqueued_jobs_count })

        expect_refusal_page
      end

      it 'answers a non-HTML PUT with a bare 403' do
        expect do
          put "/d/#{template.slug}", params: { submitter: { email: 'stranger@example.com' } }.to_json,
                                     headers: { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' }
        end.to not_change(Submitter, :count).and(not_change { enqueued_jobs_count })

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to be_empty
      end

      it 'refuses the completed lookup as well' do
        get "/d/#{template.slug}/completed", params: { email: 'stranger@example.com' }

        expect_refusal_page
      end

      it 'refuses a resubmit of a link-source submission through the share link' do
        submission = create(:submission, :with_submitters, template:, created_by_user: user, source: :link)
        submitter = submission.submitters.sole
        submitter.update!(completed_at: Time.current)

        expect do
          put '/resubmit_form', params: { resubmit: submitter.slug }
        end.to not_change(Submitter, :count).and(not_change { enqueued_jobs_count })

        expect_refusal_page
      end

      # Only the anonymous link start is closed. The sender signing their own
      # template and an invited signer resubmitting are not that flow.
      describe 'flows that are not the anonymous link start' do
        it 'lets the signed-in sender sign it themselves (selfsign)' do
          sign_in(user)

          expect do
            put "/d/#{template.slug}", params: { selfsign: true }
          end.to change(Submission, :count).by(1).and(change(Submitter, :count).by(1))

          submitter = Submitter.last

          expect(response).to redirect_to("/s/#{submitter.slug}")
          expect(submitter.email).to eq(user.email)
          expect(submitter.submission.template).to eq(template)
        end

        it 'lets an invited signer resubmit through their own slug' do
          submission = create(:submission, :with_submitters, template:, created_by_user: user, source: :invite)
          invited = submission.submitters.sole
          invited.update!(email: 'invited@example.com', completed_at: Time.current)

          expect do
            put '/resubmit_form', params: { resubmit: invited.slug }
          end.to change(Submitter, :count).by(1)

          resubmitted = Submitter.last

          expect(response).to redirect_to("/s/#{resubmitted.slug}")
          expect(resubmitted).not_to eq(invited)
          expect(resubmitted.email).to eq('invited@example.com')
          expect(resubmitted.submission.template).to eq(template)
        end

        # The selfsign door is the sender's, not a stranger's: without a
        # session the same PUT (and the sender's own email typed into the
        # form) is still the anonymous link start and stays refused.
        it 'still refuses the anonymous PUT, selfsign param or not' do
          expect do
            put "/d/#{template.slug}", params: { selfsign: true }
          end.to not_change(Submission, :count)
            .and(not_change(Submitter, :count))
            .and(not_change(ActionMailer::Base.deliveries, :count))
            .and(not_change { enqueued_jobs_count })

          expect_refusal_page

          expect do
            put "/d/#{template.slug}", params: { submitter: { email: user.email } }
          end.to not_change(Submission, :count)
            .and(not_change(Submitter, :count))
            .and(not_change(ActionMailer::Base.deliveries, :count))
            .and(not_change { enqueued_jobs_count })

          expect_refusal_page
        end

        # A signed-in user with no rights over the template is not the sender either.
        it 'refuses a signed-in user who cannot manage the template' do
          other_account = create(:account)
          sign_in(create(:user, account: other_account))

          expect do
            put "/d/#{template.slug}", params: { submitter: { email: 'stranger@example.com' } }
          end.to not_change(Submitter, :count).and(not_change { enqueued_jobs_count })

          expect_refusal_page
        end
      end

      it 'keeps the 404 for a non-shared template' do
        template.update!(shared_link: false)

        put "/d/#{template.slug}", params: { submitter: { email: 'stranger@example.com' } }

        expect(response).to redirect_to("/d/#{template.slug}")
        expect(Submitter.count).to eq(0)
      end
    end

    it 'still creates a link submission for a shared template without email 2FA' do
      expect do
        put "/d/#{template.slug}", params: { submitter: { email: 'signer@example.com' } }
      end.to change(Submission, :count).by(1).and(change(Submitter, :count).by(1))

      submitter = Submitter.last

      expect(response).to redirect_to("/s/#{submitter.slug}")
      expect(submitter.email).to eq('signer@example.com')
      expect(submitter.submission.source).to eq('link')
    end
  end

  it 'still renders the normal shared form when email 2FA is disabled' do
    get "/d/#{template.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="submitter[email]"')
    expect(response.body).not_to include('Email invitation required')
  end
end
