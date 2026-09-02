# frozen_string_literal: true

# "Report this document": a signer who thinks a document is phishing, spam
# or an impersonation tells the operator, anonymously, from the signing
# page. A report is an AbuseFlag (kind document_report, one row per report)
# on the account that sent the document, plus an operator alert. No login,
# no CAPTCHA — the per-IP and per-document rate limits are the brake.
class ReportsController < ApplicationController
  layout 'form'

  REASONS = %w[phishing spam impersonation other].freeze
  REPORTS_PER_IP_PER_HOUR = 5
  REPORTS_PER_SUBMITTER_PER_HOUR = 3
  DETAILS_LIMIT = 2000

  skip_before_action :maybe_redirect_to_setup
  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale
  before_action :load_submitter

  def new; end

  def create
    rate_limit!

    reason = params[:reason].to_s

    unless REASONS.include?(reason)
      @error = I18n.t('report_choose_reason')

      return render :new, status: :unprocessable_content
    end

    submission = @submitter.submission
    details = params[:details].to_s.strip.first(DETAILS_LIMIT)

    flag = AbuseFlags.record!(submission.account, 'document_report', subject: submission,
                                                                     details: report_details(reason, details))

    OperatorAlert.deliver(subject: "Document reported (#{reason}) on account #{submission.account_id}",
                          body: alert_body(flag, submission, reason, details))

    render :submitted
  rescue RateLimit::LimitApproached
    @error = I18n.t('too_many_reports')

    render :new, status: :too_many_requests
  end

  private

  def load_submitter
    @submitter = Submitter.find_by(slug: params[:slug])

    raise ActionController::RoutingError, I18n.t('not_found') unless @submitter
  end

  def rate_limit!
    RateLimit.call("document-report-ip-#{request.remote_ip}", limit: REPORTS_PER_IP_PER_HOUR, ttl: 1.hour)
    RateLimit.call("document-report-submitter-#{@submitter.slug}", limit: REPORTS_PER_SUBMITTER_PER_HOUR, ttl: 1.hour)
  end

  def report_details(reason, details)
    { reason:, details:, ip: request.remote_ip, submitter_slug: @submitter.slug,
      reporter_ua: request.user_agent.to_s.first(300) }
  end

  def alert_body(flag, submission, reason, details)
    "A signer reported a document.\n" \
      "Account: #{submission.account_id} (#{submission.account.name})\n" \
      "Submission: #{submission.id}, template: #{submission.template&.name}\n" \
      "Reason: #{reason}\nDetails: #{details.presence || '(none)'}\n" \
      "Abuse flag: #{flag.id}"
  end
end
