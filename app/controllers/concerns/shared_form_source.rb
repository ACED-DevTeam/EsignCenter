# frozen_string_literal: true

# Share forms opened by the embed SDK (or directly in an iframe) use the API
# allowance. Carry the marker through form posts and email verification; an
# existing signing session is never found by the anonymous share-form lookup.
module SharedFormSource
  extend ActiveSupport::Concern

  included do
    helper_method :shared_form_source
  end

  private

  # Public share forms deliberately accept embedding from any site. Private
  # template pages retain SAMEORIGIN, including owner-only previews; private
  # signing sessions keep their separate configured-origin policy.
  def set_share_embed_frame_headers
    return unless @template.shared_link? && shared_form_source == 'embed'

    response.headers.delete('X-Frame-Options')
    request.content_security_policy&.frame_ancestors('*')
  end

  def notify_api_share_pause(reason)
    return unless reason == :api_completions && !sender_viewing?

    Quotas.notify_share_link_pause!(@template.account, reason)
  end

  def shared_form_source
    return @resubmit_submitter.submission.source if @resubmit_submitter

    params[:embed] == '1' || request.headers['Sec-Fetch-Dest'] == 'iframe' ? 'embed' : 'link'
  end
end
