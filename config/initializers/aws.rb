# frozen_string_literal: true

Rails.application.config.after_initialize do
  if Rails.env.development? && defined?(Aws)
    Aws.config.update(
      ssl_verify_peer: false
    )
  end
end
