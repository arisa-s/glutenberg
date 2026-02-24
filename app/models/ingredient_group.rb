# frozen_string_literal: true

class IngredientGroup < ApplicationRecord
  belongs_to :recipe
  has_many :ingredients, dependent: :destroy
end
