# frozen_string_literal: true

module Api
  class ActiveStorageBlobsProxyController < ApiBaseController
    include ActiveStorage::Streaming

    skip_before_action :authenticate_user!
    skip_authorization_check

    before_action :set_cors_headers
    before_action :set_noindex_headers
    before_action :set_security_headers

    def show
      blob_uuid, purp, exp = ApplicationRecord.signed_id_verifier.verified(params[:signed_uuid])

      if blob_uuid.blank? || purp != 'blob'
        ErrorReport.error('Blob not found')

        return head :not_found
      end

      blob = ActiveStorage::Blob.find_by!(uuid: blob_uuid)

      if Submitters::DANGEROUS_EXTENSIONS.include?(blob.filename.extension.to_s.downcase)
        ErrorReport.error('Dangerous extension')

        return head :unprocessable_content
      end

      attachment = blob.attachments.take

      @record = attachment.record
      @record = @record.record if @record.is_a?(ActiveStorage::Attachment)

      authorization_check!(attachment, @record, exp)

      set_private_cache_headers if never_cache?(@record)

      if request.headers['Range'].present?
        send_blob_byte_range_data blob, request.headers['Range']
      elsif never_cache?(@record)
        serve_blob(blob)
      else
        http_cache_forever(public: true) { serve_blob(blob) }
      end
    end

    private

    def serve_blob(blob)
      response.headers['Accept-Ranges'] = 'bytes'

      if request.head?
        response.headers['Content-Type'] = blob.content_type_for_serving
        head :ok
      else
        send_blob_stream blob, disposition: params[:disposition]
      end

      response.headers['Content-Length'] = blob.byte_size.to_s
    end

    # An account export archive is a copy of an ENTIRE account in one file
    # (Session 8 phase D), and `http_cache_forever public: true` tells every
    # shared cache between us and the browser that it may keep a copy and hand
    # it to anybody who asks for the same URL — outliving both the ten-minute
    # link and the seven-day file (review 2, H5). Nothing else served through
    # this door is that: a signed document or a page image is one record, and
    # caching those is the reason this controller is fast. So the rule is
    # scoped to exactly the archives.
    def never_cache?(record)
      record.is_a?(AccountExport)
    end

    def set_private_cache_headers
      response.headers['Cache-Control'] = 'private, no-store'
      response.headers['Pragma'] = 'no-cache'
    end

    def authorization_check!(attachment, record, exp)
      return if attachment.name == 'logo'
      return if exp.to_i >= Time.current.to_i
      return if current_user && current_ability.can?(:read, record)

      if exp.blank?
        configs = record.account.account_configs.where(key: [AccountConfig::DOWNLOAD_LINKS_AUTH_KEY,
                                                             AccountConfig::DOWNLOAD_LINKS_EXPIRE_KEY])

        require_auth = configs.any? { |c| c.key == AccountConfig::DOWNLOAD_LINKS_AUTH_KEY && c.value }
        require_ttl = configs.none? { |c| c.key == AccountConfig::DOWNLOAD_LINKS_EXPIRE_KEY && c.value == false }

        return if !require_ttl && !require_auth
      end

      raise CanCan::AccessDenied
    end
  end
end
