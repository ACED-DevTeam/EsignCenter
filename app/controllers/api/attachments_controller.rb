# frozen_string_literal: true

module Api
  class AttachmentsController < ActionController::API
    include ActionController::Cookies
    include ActiveStorage::SetCurrent
    # This door has its own ActionController::API base — no Devise, no
    # Pretender — but it does honour the session cookie, and it is keyed on a
    # submitter slug rather than on who is asking. That is enough for a
    # support session to reach it, so it gets the rule too (review batch 2).
    include SupportImpersonationSessionRefusal

    COOKIE_STORE_LIMIT = 10

    def create
      @submitter = Submitter.find_by!(slug: params[:submitter_slug])

      unless can_upload?(@submitter)
        return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
      end

      file = params[:file]

      if params[:type].in?(%w[initials signature])
        image = ImageUtils.load_vips(file.read, content_type: file.content_type)

        if ImageUtils.blank?(image)
          ErrorReport.error("Empty signature: #{@submitter.id}")

          return render json: { error: "#{params[:type]} is empty" }, status: :unprocessable_content
        end

        if ImageUtils.error?(image)
          ErrorReport.error("Error signature: #{@submitter.id}")

          return render json: { error: "#{params[:type]} error, try to sign on another device" },
                        status: :unprocessable_content
        end

        metadata = { analyzed: true, identified: true, width: image.width, height: image.height }
      end

      attachment = Submitters.create_attachment!(@submitter, file, metadata:)

      if params[:remember_signature] == 'true' && @submitter.email.present?
        cookies.encrypted[:signature_uuids] = build_new_cookie_signatures_json(@submitter, attachment)
      end

      render json: attachment.as_json(only: %i[uuid created_at], methods: %i[url filename content_type])
    rescue Submitters::MaliciousFileExtension => e
      ErrorReport.error(e)

      render json: { error: e.message }, status: :unprocessable_content
    end

    def can_upload?(submitter)
      !submitter.declined_at? &&
        !submitter.completed_at? &&
        !submitter.submission.archived_at? &&
        !submitter.submission.expired? &&
        !submitter.submission.template&.archived_at? &&
        !submitter.account.archived_at?
    end

    def build_new_cookie_signatures_json(submitter, attachment)
      values =
        begin
          JSON.parse(cookies.encrypted[:signature_uuids].presence || '{}')
        rescue JSON::ParserError
          {}
        end

      values[submitter.email] = attachment.uuid

      values = values.to_a.last(COOKIE_STORE_LIMIT).to_h if values.size > COOKIE_STORE_LIMIT

      values.to_json
    end
  end
end
