# frozen_string_literal: true

class SourcesController < ApplicationController
  PER_PAGE = 50

  def index
    @sources = Source.order(publication_year: :asc)
    @sources = case params[:corpus]
               when "included" then @sources.included
               when "excluded" then @sources.excluded
               else @sources
               end
    @corpus_filter = params[:corpus]
    source_ids = @sources.select(:id)
    # Single query: failed recipe counts per source
    @failed_recipe_counts = Recipe.unscoped
      .where(source_id: source_ids)
      .where(extraction_status: "failed")
      .where(not_a_recipe: false)
      .group(:source_id)
      .count
    # Single query: recipe counts per source (avoids N+1 on source.recipes.count)
    @recipe_counts = Recipe.where(source_id: source_ids).group(:source_id).count
  end

  def show
    @source = Source.find(params[:id])
    page = [1, params[:page].to_i].max
    @recipes_total = @source.recipes.count
    @recipes_total_pages = [1, (@recipes_total.to_f / PER_PAGE).ceil].max
    @recipes_page = page
    @recipes = @source.recipes.order(:title).limit(PER_PAGE).offset((page - 1) * PER_PAGE).to_a
    @failed_with_text_count = @source.recipes.unscoped
      .where(extraction_status: "failed")
      .where.not(input_text: [nil, ""])
      .count

    return if @recipes.empty?

    recipe_ids = @recipes.map(&:id)
    @ingredient_counts = Ingredient.joins(ingredient_group: :recipe)
      .where(ingredient_groups: { recipe_id: recipe_ids })
      .group("ingredient_groups.recipe_id")
      .count
    @instruction_counts = Instruction.joins(instruction_group: :recipe)
      .where(instruction_groups: { recipe_id: recipe_ids })
      .group("instruction_groups.recipe_id")
      .count
  end

  def update
    @source = Source.find(params[:id])
    if @source.update(source_params)
      redirect_back fallback_location: source_path(@source), notice: "Source updated."
    else
      @recipes_total = @source.recipes.count
      @recipes_total_pages = [1, (@recipes_total.to_f / PER_PAGE).ceil].max
      @recipes_page = 1
      @recipes = @source.recipes.order(:title).limit(PER_PAGE).to_a
      @failed_with_text_count = @source.recipes.unscoped.where(extraction_status: "failed").where.not(input_text: [nil, ""]).count
      recipe_ids = @recipes.map(&:id)
      @ingredient_counts = recipe_ids.any? ? Ingredient.joins(ingredient_group: :recipe).where(ingredient_groups: { recipe_id: recipe_ids }).group("ingredient_groups.recipe_id").count : {}
      @instruction_counts = recipe_ids.any? ? Instruction.joins(instruction_group: :recipe).where(instruction_groups: { recipe_id: recipe_ids }).group("instruction_groups.recipe_id").count : {}
      render :show, status: :unprocessable_entity
    end
  end

  def bulk_retry_failed_extractions
    @source = Source.find(params[:id])
    failed = @source.recipes.where(extraction_status: "failed").where.not(input_text: [nil, ""])

    if failed.none?
      redirect_to source_path(@source), notice: "No failed chunks with input text to retry."
      return
    end

    success_count = 0
    error_count = 0

    failed.find_each do |recipe|
      Extraction::CreateRecipeService.call(
        source: @source,
        text: recipe.input_text,
        recipe: recipe,
        input_type: recipe.input_type,
        page_number: recipe.page_number,
        raw_section_header: recipe.raw_section_header
      )
      success_count += 1 if recipe.reload.extraction_status == "success"
    rescue StandardError
      error_count += 1
    end

    notice = "Bulk retry: #{success_count} succeeded, #{failed.count - success_count - error_count} still failed"
    notice += ", #{error_count} errors" if error_count.positive?
    redirect_to source_path(@source), notice: notice
  end

  private

  def source_params
    params.require(:source).permit(:notes, :included_in_corpus)
  end
end
