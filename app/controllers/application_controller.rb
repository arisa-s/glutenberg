class ApplicationController < ActionController::Base
  before_action :enforce_readonly!, unless: -> { Rails.env.development? || Rails.env.test? }

  private

  def enforce_readonly!
    return if request.get? || request.head?

    head :forbidden
  end
end
