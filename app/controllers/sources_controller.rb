# frozen_string_literal: true

class SourcesController < ApplicationController
  def index
    @sources = Source.order(publication_year: :asc)
    @sources = case params[:corpus]
               when "included" then @sources.included
               when "excluded" then @sources.excluded
               else @sources
               end
    @corpus_filter = params[:corpus]
    # Count of recipes that are failed and still considered a recipe (not_a_recipe: false)
    @failed_recipe_counts = Recipe.unscoped
      .where(source_id: @sources.select(:id))
      .where(extraction_status: "failed")
      .where(not_a_recipe: false)
      .group(:source_id)
      .count
  end

  def show
    @source = Source.find(params[:id])
    @recipes = @source.recipes.order(:title)
  end

  def update
    @source = Source.find(params[:id])
    if @source.update(source_params)
      redirect_back fallback_location: source_path(@source), notice: "Source updated."
    else
      @recipes = @source.recipes.order(:title)
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
