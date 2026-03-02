# frozen_string_literal: true

module ApplicationHelper
  def readonly_mode?
    Rails.env.production?
  end

  def highlight_product(original_string, product, link: false)
    return original_string if original_string.blank? || product.blank?

    escaped = Regexp.escape(product)
    highlighted = original_string.sub(/(#{escaped})/i) do
      span = content_tag(:span, Regexp.last_match(1), class: "product-highlight")
      if link
        link_to(span, ingredients_path(product: product), class: "product-highlight-link")
      else
        span
      end
    end

    highlighted.html_safe
  end
end
