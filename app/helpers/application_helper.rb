# frozen_string_literal: true

module ApplicationHelper
  def highlight_product(original_string, product)
    return original_string if original_string.blank? || product.blank?

    escaped = Regexp.escape(product)
    highlighted = original_string.sub(/(#{escaped})/i) do
      content_tag(:span, Regexp.last_match(1), class: "product-highlight")
    end

    highlighted.html_safe
  end
end
