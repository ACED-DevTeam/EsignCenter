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

  # Carried over from the Session 6 security stage. The "this has already been
  # signed" page looked up whatever address the URL carried and answered either
  # 200 with the template's name and the exact completion date, or a 404 — so
  # anybody holding the public share link could ask it, one address at a time,
  # whether a given person had signed a given document and when. The document
  # itself was never exposed; the leak is existence and date, which for a
  # signature is the sensitive part.
  describe 'the completed page of a share link' do
    # One required text field, so the examples below can complete the form the
    # way a real signer does (SigningHelpers#complete!) rather than stamping
    # completed_at on a row by hand: the proof this page now asks for is minted
    # on the real completion path, so the examples have to walk it.
    let(:template) { create(:template, account:, author: user, shared_link: true, only_field_types: %w[text]) }

    let!(:signer) do
      create(:submitter, submission: create(:submission, template:, created_by_user: user, source: 'link'),
                         email: 'signed@example.com', uuid: submitter_uuid(template),
                         ip: '127.0.0.1', completed_at: Time.current)
    end

    # The page is drawn under the visitor's browser locale, so the date is
    # formatted the way that locale writes it rather than the way the default
    # one does.
    def completion_date(submitter = signer)
      I18n.with_locale(:'en-GB') { I18n.l(submitter.completed_at.to_date, format: :long) }
    end

    # One signer's whole journey in one browser: start the document from the
    # share link and complete it there. That completion is where the proof
    # comes from now — the signer's own signing session — so it is what every
    # example below that expects to be recognised has to do first.
    def sign_it!(email)
      put "/d/#{template.slug}", params: { submitter: { email: } }

      complete!(Submitter.order(:id).last)
    end

    # The address is echoed back into the "email me a copy" button, so it is
    # blanked before the two answers are compared: everything else about them
    # has to be identical.
    def page_for(email)
      get "/d/#{template.slug}/completed", params: { email: }

      [response.status, response.body.gsub(email, 'ADDRESS')]
    end

    it 'answers a stranger the same way whether or not the address completed it' do
      status, body = page_for('signed@example.com')

      expect([status, body]).to eq(page_for('nobody-here@example.com'))
      expect(status).to eq(200)
      expect(body).to include(I18n.t('completed_documents_are_private'))
      expect(body).not_to include(CGI.escapeHTML(template.name))
      expect(body).not_to include(completion_date)
    end

    # The legitimate return visit, which is what the fix must not break: the
    # signer completed the document in THIS browser, so this browser is the one
    # holding the proof, and typing the address they signed with brings their
    # own page back.
    it 'still shows the signer who just completed it their own page' do
      mine = sign_it!('fresh@example.com')

      put "/d/#{template.slug}", params: { submitter: { email: 'fresh@example.com' } }

      expect(response).to redirect_to("/d/#{template.slug}/completed?email=fresh%40example.com")

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(template.name))
      expect(response.body).to include(completion_date(mine))
      # The resubmit affordance is still there for them.
      expect(response.body).to include(I18n.t('resubmit'))
    end

    # Review 8. The other accepted proof was an IP MATCH: submit an address to
    # the share link, and if the completed submitter it found had been signed
    # from the same remote address, the visitor was handed the marker on the
    # way past and read the document's name and the day it was signed off the
    # page they were redirected to. An IP address is not an identity — an
    # office, a household, a hotel, a school, a carrier's NAT or a VPN exit put
    # hundreds of unrelated people behind one of them — so typing a colleague's
    # email from the desk next to theirs was enough to learn what they had
    # signed and when.
    it 'refuses a visitor who only shares the signer\'s IP address' do
      # Exactly the old proof, and nothing more: the signer completed from
      # 127.0.0.1 and so does this request.
      expect(signer.ip).to eq('127.0.0.1')

      put "/d/#{template.slug}", params: { submitter: { email: 'signed@example.com' } }

      expect(response).to redirect_to("/d/#{template.slug}/completed?email=signed%40example.com")

      follow_redirect!

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('completed_documents_are_private'))
      expect(response.body).not_to include(CGI.escapeHTML(template.name))
      expect(response.body).not_to include(completion_date)
      expect(response.body).not_to include(I18n.t('resubmit'))
      # And still indistinguishable from an address that never completed
      # anything: the walk past #update leaves nothing behind either.
      expect(page_for('signed@example.com')).to eq(page_for('nobody-here@example.com'))
    end

    # And the marker is a marker for the document it was earned on: it does not
    # become a key for asking about anybody else who used the same link.
    it 'does not let the marker be spent on another signer\'s address' do
      other = create(:submitter, submission: create(:submission, template:, created_by_user: user, source: 'link'),
                                 email: 'someone-else@example.com', uuid: submitter_uuid(template),
                                 ip: '10.9.9.9', completed_at: Time.current)

      sign_it!('fresh@example.com')

      get "/d/#{template.slug}/completed", params: { email: other.email }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('completed_documents_are_private'))
      expect(response.body).not_to include(CGI.escapeHTML(template.name))

      # Nor about the signer whose IP this browser happens to share.
      get "/d/#{template.slug}/completed", params: { email: signer.email }

      expect(response.body).to include(I18n.t('completed_documents_are_private'))
      expect(response.body).not_to include(CGI.escapeHTML(template.name))
    end

    # Two documents from one browser: the marker holds a short list, so
    # finishing a second one does not turn the first back into a stranger.
    it 'keeps recognising the first of two documents signed in the same browser' do
      first = sign_it!('first@example.com')
      sign_it!('second@example.com')

      get "/d/#{template.slug}/completed", params: { email: 'first@example.com' }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(template.name))
      expect(response.body).to include(completion_date(first))
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
