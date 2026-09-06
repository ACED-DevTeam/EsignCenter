# frozen_string_literal: true

# Inviting the next party, from the signing form and from an
# `invite_via_field` value — two writers, one rule each.
#
# 1. The `invite_party` event names the party that was INVITED. Both writers
#    used to store the inviter's own uuid, which is already the event's
#    submitter: the audit trail and the events page look the invited party up
#    by that uuid (`invited_submitter`), found the inviter or nobody, and the
#    line either named the wrong person or vanished.
#
# 2. A submission never holds two people in one role. The uuid is the role, so
#    two rows sharing a submission and a uuid mean one signer with a link
#    nobody will use. The Ruby check ("is this uuid already here?") could not
#    stop two requests arriving together; the unique index on
#    `submitters (submission_id, uuid)` can.
RSpec.describe 'Inviting the next party', type: :request do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, :admin, account:) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text], submitter_count: 2) }

  # The first signer invites the second by email on the last step.
  let(:template_with_invite) do
    template.tap do |t|
      submitters = t.submitters.deep_dup
      submitters[1]['invite_by_uuid'] = submitters[0]['uuid']
      t.update!(submitters:)
    end
  end

  let(:submission) { create(:submission, template: template_with_invite, created_by_user: admin) }

  let!(:submitter) do
    create(:submitter, submission:, account:, uuid: template_with_invite.submitters.first['uuid'],
                       email: 'first@example.com', sent_at: Time.current)
  end
  let(:second_uuid) { template_with_invite.submitters.second['uuid'] }

  def consent_params(submitter)
    { esign_consent: 'true',
      esign_consent_version: EsignConsent::VERSION,
      esign_consent_locale: EsignConsent.rendered_locale,
      esign_consent_locale_token: EsignConsent.locale_token(submitter, EsignConsent.rendered_locale),
      esign_consent_sender_digest: EsignConsent.sender_digest(submitter) }
  end

  def invite!(email: 'second@example.com', uuid: second_uuid)
    submitter.update!(values: { text_field['uuid'] => 'Jane' })

    post "/s/#{submitter.slug}/invite",
         params: { submission: { submitters: [{ uuid:, email: }] } }.merge(consent_params(submitter))
  end

  def text_field
    fields = submission.template_fields.presence || template_with_invite.fields

    fields.find { |f| f['type'] == 'text' && f['submitter_uuid'] == submitter.uuid }
  end

  def invite_events
    submitter.submission_events.where(event_type: 'invite_party')
  end

  describe 'the invite form' do
    it 'stores the invited party uuid on the event, not the inviter own' do
      invite!

      expect(response).to have_http_status(:ok)

      invited = submission.submitters.reload.find { |s| s.uuid == second_uuid }

      expect(invited.email).to eq('second@example.com')
      expect(invite_events.sole.data['uuid']).to eq(second_uuid)
      expect(invite_events.sole.data['uuid']).not_to eq(submitter.uuid)
    end

    # The audit trail resolves the invited party by that uuid, so the wrong
    # one is not a cosmetic difference: the line is silently dropped.
    it 'lets the events page name the party that was invited' do
      invite!

      sign_in(admin)
      get "/submissions/#{submission.id}/events"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('second@example.com')
    end
  end

  describe 'a party invited through a field value' do
    let(:template_with_invite) do
      template.tap do |t|
        submitters = t.submitters.deep_dup
        fields = t.fields.deep_dup
        email_field = fields.find { |f| f['submitter_uuid'] == submitters[0]['uuid'] }
        submitters[1]['invite_via_field_uuid'] = email_field['uuid']
        t.update!(submitters:, fields:)
      end
    end

    it 'stores the invited party uuid too' do
      put "/s/#{submitter.slug}", params: { completed: 'true',
                                            values: { text_field['uuid'] => 'second@example.com' },
                                            **consent_params(submitter) }

      expect(response).to have_http_status(:ok)
      expect(submission.submitters.reload.find { |s| s.uuid == second_uuid }&.email).to eq('second@example.com')
      expect(invite_events.sole.data['uuid']).to eq(second_uuid)
    end

    # Two signers can race to invite the same party through their own field
    # values. The check ("is this uuid already here?") is not a lock, so the
    # loser reaches the insert and the unique index refuses it — which used to
    # come back to the signer as a 500 on the signing page, the one place the
    # product cannot afford one (review 2, H4). The invite form's door already
    # answered a refusal; this one now answers the same.
    it 'answers the signer who loses the race with a refusal, not a server error' do
      raced = false

      allow(Submissions).to receive(:normalize_email).and_wrap_original do |original, value|
        unless raced
          raced = true
          submission.submitters.create!(uuid: second_uuid, email: 'raced@example.com', account_id: account.id)
        end

        original.call(value)
      end

      put "/s/#{submitter.slug}", params: { completed: 'true',
                                            values: { text_field['uuid'] => 'second@example.com' },
                                            **consent_params(submitter) }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('party_already_invited')

      # Nothing of the refused completion survives: the signer presses again
      # and, with the party now on record, finishes.
      expect(submitter.reload.completed_at).to be_nil
      expect(submitter.submission_events.where(event_type: 'complete_form')).to be_empty
    end
  end

  # An invite request is one request: it adds the parties AND completes the
  # signer who invited them. The completion is where the consent and the
  # required fields are checked, so a refusal has to take the invitees with it
  # — otherwise the recipients are added for good and the signer's corrected
  # retry is ignored, because the role is already occupied (review 2, H1).
  describe 'an invite the completion then refuses' do
    it 'leaves no invited party, no event and no completion behind' do
      submitter.update!(values: { text_field['uuid'] => 'Jane' })

      post "/s/#{submitter.slug}/invite",
           params: { submission: { submitters: [{ uuid: second_uuid, email: 'typo@example.com' }] } }
                     .merge(consent_params(submitter), esign_consent_locale_token: 'not-a-real-token')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('esign_consent_locale_invalid')

      expect(submission.submitters.reload.map(&:uuid)).not_to include(second_uuid)
      expect(submission.submitters.pluck(:email)).not_to include('typo@example.com')
      expect(invite_events).to be_empty
      expect(submitter.reload.completed_at).to be_nil
    end

    # The point of taking them back: the retry has to be able to name a
    # different address for the same party.
    it 'lets the corrected retry through' do
      submitter.update!(values: { text_field['uuid'] => 'Jane' })

      post "/s/#{submitter.slug}/invite",
           params: { submission: { submitters: [{ uuid: second_uuid, email: 'typo@example.com' }] } }
                     .merge(consent_params(submitter), esign_consent_locale_token: 'not-a-real-token')

      expect(response).to have_http_status(:unprocessable_content)

      invite!(email: 'second@example.com')

      expect(response).to have_http_status(:ok)
      expect(submission.submitters.reload.find { |s| s.uuid == second_uuid }.email).to eq('second@example.com')
      expect(invite_events.sole.data['uuid']).to eq(second_uuid)
    end
  end

  # The refusals the invite form can meet that have nothing to do with a value
  # (review 2, product 6 / L5). They used to be a bare 422 with no body, which
  # the page turned into a browser alert reading "Value is invalid" — a
  # sentence that describes none of them.
  describe 'a refusal the page has to be able to explain' do
    it 'names the reason when the document is no longer accepting signatures' do
      submitter.update!(completed_at: Time.current)

      post "/s/#{submitter.slug}/invite",
           params: { submission: { submitters: [{ uuid: second_uuid, email: 'second@example.com' }] } }
                     .merge(consent_params(submitter))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('document_no_longer_accepting')
    end
  end

  describe 'two people in one role' do
    it 'is refused by the database, not by a check the next request can slip past' do
      submission.submitters.create!(uuid: second_uuid, email: 'second@example.com', account_id: account.id)

      expect do
        submission.submitters.create!(uuid: second_uuid, email: 'someone.else@example.com', account_id: account.id)
      end.to raise_error(ActiveRecord::RecordNotUnique)

      expect(submission.submitters.reload.count { |s| s.uuid == second_uuid }).to eq(1)
    end

    # What the race looked like from outside: the second request is answered
    # with a refusal and leaves nothing behind, rather than adding a second
    # signer for a role already taken.
    #
    # The race has to be driven where it really happens — inside the invite
    # transaction, against a signer who has NOT completed yet. Inviting first
    # and posting again completes the signer, so the second request is turned
    # away by `can_invite?` with `document_no_longer_accepting` before it ever
    # reaches an INSERT, and the RecordNotUnique door goes untested (review
    # 10, B-F2). So the colliding row is inserted from inside the transaction,
    # the way the `invite_via_field` sibling above does it: the winner lands
    # between this request's check and its own insert.
    it 'answers the losing invite request with a refusal and writes nothing' do
      before_count = submission.submitters.reload.count
      raced = false

      allow(Submissions).to receive(:normalize_email).and_wrap_original do |original, value|
        unless raced
          raced = true
          submission.submitters.create!(uuid: second_uuid, email: 'raced@example.com', account_id: account.id)
        end

        original.call(value)
      end

      invite!(email: 'third@example.com')

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to eq('party_already_invited')

      # Nothing of the refused request survives — not the party it tried to
      # invite, not the event, not the inviter's own completion.
      expect(submission.submitters.reload.count).to eq(before_count)
      expect(submission.submitters.pluck(:email)).not_to include('third@example.com')
      expect(invite_events).to be_empty
      expect(submitter.reload.completed_at).to be_nil
    end
  end
end
