# frozen_string_literal: true

class IngredientsController < ApplicationController
  def index
    @ingredients = Ingredient.unscoped
                             .includes(:substitutions, ingredient_group: { recipe: :source })
                             .order(:product)

    # Optional filters
    @ingredients = @ingredients.where(product: params[:product]) if params[:product].present?
    @ingredients = @ingredients.where(foundation_food_category: params[:category]) if params[:category].present?

    if params[:search].present?
      @ingredients = @ingredients.where("product ILIKE ?", "%#{params[:search]}%")
    end

    @total_count = @ingredients.count
    @unique_products = Ingredient.unscoped.distinct.count(:product)
    @categories = Ingredient.unscoped
                            .where.not(foundation_food_category: [nil, ''])
                            .distinct
                            .pluck(:foundation_food_category)
                            .sort
  end
end
