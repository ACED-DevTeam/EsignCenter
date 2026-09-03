# frozen_string_literal: true

RSpec.describe 'Start form authorization', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, shared_link: true) }

  def submitter_uuid(template)
    template.submitters.first['uuid']
  end

  def redirected_slug
    response.headers['Location'].to_s[%r{/s/([^/?]+)}, 1]
  end

  describe 'a pending invitation the sender emailed to somebody else' do
    let(:invited_submission) { create(:submission, template:, created_by_user: user, source: 'invite') }
    let!(:invited_submitter) do
      create(:submitter, submission: invited_submission, email: 'victim@example.com', name: 'Victim',
                         uuid: submitter_uuid(template))
    end

    # An invited submitter that has never opened its link has no IP yet, so the
    # ip: [nil, remote_ip] filter matches every visitor: knowing the address
    # was all it took to be handed that person's signing link.
    it 'is not handed to a visitor who types the invited address into the share link' do
      expect do
        put "/d/#{template.slug}", params: { submitter: { email: 'victim@example.com' } }
      end.to change(Submission, :count).by(1)

      expect(redirected_slug).not_to eq invited_submitter.slug
      expect(invited_submitter.reload.ip).to be_nil
      expect(invited_submitter.ua).to be_nil
      expect(invited_submission.reload.submitters.count).to eq 1
      expect(Submission.order(:id).last.source).to eq 'link'
    end

    # Same takeover through the Resubmit door: the resubmit slug fixes the
    # email, so a second document sent to that address was adoptable too.
    it 'is not handed to the holder of another completed document with the same address' do
      done = create(:submitter, submission: create(:submission, template:, created_by_user: user, source: 'invite'),
                                email: 'victim@example.com', name: 'Someone Else',
                                uuid: submitter_uuid(template), completed_at: Time.current)

      expect do
        put '/resubmit_form', params: { resubmit: done.slug }
      end.to change(Submission, :count).by(1)

      expect(redirected_slug).not_to eq invited_submitter.slug
      expect(invited_submitter.reload.ip).to be_nil
      expect(invited_submitter.name).to eq 'Victim'
      expect(invited_submission.reload.submitters.count).to eq 1
    end

    context 'when the template is not shared' do
      let(:template) { create(:template, account:, author: user, shared_link: false) }

      it 'is not handed to the holder of another completed document with the same address' do
        done = create(:submitter, submission: create(:submission, template:, created_by_user: user, source: 'invite'),
                                  email: 'victim@example.com', uuid: submitter_uuid(template),
                                  completed_at: Time.current)

        expect do
          put '/resubmit_form', params: { resubmit: done.slug }
        end.to change(Submission, :count).by(1)

        expect(redirected_slug).not_to eq invited_submitter.slug
        expect(invited_submitter.reload.ip).to be_nil
      end

      it 'is not reachable at all without a document of one\'s own' do
        expect do
          put "/d/#{template.slug}", params: { submitter: { email: 'victim@example.com' } }
        end.not_to change(Submitter, :count)

        expect(response).to redirect_to("/d/#{template.slug}")
        expect(invited_submitter.reload.ip).to be_nil
      end
    end
  end

  describe 'a resubmit slug from a different template' do
    let(:private_template) { create(:template, account:, author: user, shared_link: false) }

    let(:other_account) { create(:account) }
    let(:other_user) { create(:user, account: other_account) }
    let(:other_template) { create(:template, account: other_account, author: other_user, shared_link: true) }
    let(:outsider_submitter) do
      create(:submitter, submission: create(:submission, template: other_template, created_by_user: other_user),
                         email: 'outsider@example.com', uuid: submitter_uuid(other_template),
                         completed_at: Time.current)
    end

    # The slug is the credential for its own document only: it must not be
    # usable as a key to the start form of a template it has nothing to do
    # with.
    it 'does not open a private template it does not belong to' do
      outsider_submitter

      expect do
        expect do
          put "/d/#{private_template.slug}", params: { resubmit: outsider_submitter.slug }
        end.to raise_error(ActionController::RoutingError)
      end.not_to change(Submission, :count)

      expect(private_template.submissions.count).to eq 0
    end
  end

  describe 'the flows this door exists for' do
    it 'starts a new document from the share link' do
      expect do
        put "/d/#{template.slug}", params: { submitter: { email: 'john@example.com' } }
      end.to change(Submission, :count).by(1)

      submitter = Submitter.order(:id).last

      expect(response).to redirect_to("/s/#{submitter.slug}")
      expect(submitter.email).to eq 'john@example.com'
      expect(submitter.ip).to eq '127.0.0.1'
      expect(submitter.submission.source).to eq 'link'
    end

    # Coming back to the same link with the same address resumes the document
    # already started rather than piling up a second one.
    it 'resumes the document the same visitor already started' do
      put "/d/#{template.slug}", params: { submitter: { email: 'john@example.com' } }

      started = Submitter.order(:id).last

      expect do
        put "/d/#{template.slug}", params: { submitter: { email: 'john@example.com' } }
      end.not_to change(Submission, :count)

      expect(response).to redirect_to("/s/#{started.slug}")
    end

    # D73: the Resubmit button on a signer's completed page starts a fresh
    # document that joins the family of the one it corrects.
    it 'lets a signer resubmit their own completed document' do
      origin = create(:submission, template:, created_by_user: user, source: 'invite')
      submitter = create(:submitter, submission: origin, email: 'john@example.com', name: 'John Doe',
                                     uuid: submitter_uuid(template), completed_at: Time.current)

      expect do
        put '/resubmit_form', params: { resubmit: submitter.slug }
      end.to change(Submission, :count).by(1)

      copy = Submission.order(:id).last

      expect(copy.resubmitted_from_id).to eq origin.id
      expect(copy.lineage_root_id).to eq origin.id
      expect(copy.template_id).to eq template.id
      expect(copy.submitters.first.email).to eq 'john@example.com'
      expect(copy.submitters.first.name).to eq 'John Doe'
      expect(response).to redirect_to("/s/#{copy.submitters.first.slug}")
    end

    # The copy is a link document, so a second click of Resubmit finds the one
    # already waiting instead of creating another.
    it 'does not create a second copy when the signer resubmits twice' do
      submitter = create(:submitter, submission: create(:submission, template:, created_by_user: user,
                                                                     source: 'invite'),
                                     email: 'john@example.com', uuid: submitter_uuid(template),
                                     completed_at: Time.current)

      put '/resubmit_form', params: { resubmit: submitter.slug }

      copy_slug = redirected_slug

      expect do
        put '/resubmit_form', params: { resubmit: submitter.slug }
      end.not_to change(Submission, :count)

      expect(redirected_slug).to eq copy_slug
    end

    it 'lets the sender sign their own private template' do
      private_template = create(:template, account:, author: user, shared_link: false)

      sign_in(user)

      expect do
        put "/d/#{private_template.slug}", params: { selfsign: true }
      end.to change(Submission, :count).by(1)

      submitter = Submitter.order(:id).last

      expect(submitter.email).to eq user.email
      expect(response).to redirect_to("/s/#{submitter.slug}")
    end

    it 'lets an invited signer open their own invitation' do
      invited = create(:submitter, submission: create(:submission, template:, created_by_user: user, source: 'invite'),
                                   email: 'victim@example.com', uuid: submitter_uuid(template))

      get "/s/#{invited.slug}"

      expect(response).to have_http_status(:ok)
    end
  end
end
