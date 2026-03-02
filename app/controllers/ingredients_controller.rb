# frozen_string_literal: true

class IngredientsController < ApplicationController
  PER_PAGE = 50

  def index
    base = Ingredient.unscoped
                     .includes(:substitutions, ingredient_group: { recipe: :source })
                     .order(:product)

    base = base.where(product: params[:product]) if params[:product].present?
    base = base.where(foundation_food_category: params[:category]) if params[:category].present?
    base = base.where("product ILIKE ?", "%#{params[:search]}%") if params[:search].present?

    @total_count = base.count
    @total_pages = [1, (@total_count.to_f / PER_PAGE).ceil].max
    @page = [[1, params[:page].to_i].max, @total_pages].min
    @ingredients = base.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)

    @unique_products = Ingredient.unscoped.distinct.count(:product)
    @categories = Ingredient.unscoped
                            .where.not(foundation_food_category: [nil, ''])
                            .distinct
                            .pluck(:foundation_food_category)
                            .sort
  end
end
