# frozen_string_literal: true

require_relative '../../../../../../config/application'
Rails.application.config.logger = ActiveSupport::Logger.new(File.join(__dir__, 'sec8-scratch', 'rails.log'))
