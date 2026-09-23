# frozen_string_literal: true

class TemplatesCloneController < ApplicationController
  load_and_authorize_resource :template, instance_name: :base_template

  # Raised by Templates::Clone while a Word document of the original is still
  # converting or failed to convert.
  rescue_from Templates::DocumentsNotReady do |e|
    redirect_back(fallback_location: root_path, alert: e.message)
  end

  def new
    authorize!(:create, Template)

    @template = Template.new(name: "#{@base_template.name} (#{I18n.t('clone')})")
  end

  def create
    ActiveRecord::Associations::Preloader.new(
      records: [@base_template],
      associations: [{ schema_documents: :preview_images_attachments }]
    ).call

    @template = Templates::Clone.call(@base_template, author: current_user,
                                                      name: params.dig(:template, :name),
                                                      folder_name: params[:folder_name])

    authorize!(:create, @template)

    if clone_into_other_account?
      @template.account_id = params[:account_id]
      @template.author = true_user if true_user.account_id == @template.account_id
      @template.folder = @template.account.default_template_folder if @template.account_id != current_account.id
    else
      @template.account = current_account
    end

    Templates.maybe_assign_access(@template)

    if @template.save
      Templates::CloneAttachments.call(template: @template, original_template: @base_template)

      SearchEntries.enqueue_reindex(@template)

      WebhookUrls.enqueue_events(@template, 'template.created')

      maybe_redirect_to_template(@template)
    else
      render turbo_stream: turbo_stream.replace(:modal, partial: 'templates_clone/form'), status: :unprocessable_content
    end
  end

  private

  # A support session clones inside the customer's account only: true_ability
  # is the OPERATOR's, so honouring account_id here would let a support
  # session copy the customer's documents out to the operator account.
  def clone_into_other_account?
    params[:account_id].present? && !support_impersonation? &&
      true_ability.can?(:manage, Account.find(params[:account_id]))
  end

  def maybe_redirect_to_template(template)
    if template.account == current_account
      redirect_to(edit_template_path(template))
    else
      redirect_back(fallback_location: root_path, notice: I18n.t('template_has_been_cloned'))
    end
  end
end
