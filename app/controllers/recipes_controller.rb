# frozen_string_literal: true

class RecipesController < ApplicationController
  def show
    @source = Source.find(params[:source_id])
    @recipe = @source.recipes.unscoped
                     .includes(ingredient_groups: :ingredients, instruction_groups: :instructions)
                     .find(params[:id])
  end

  def update
    @source = Source.find(params[:source_id])
    @recipe = @source.recipes.unscoped.find(params[:id])
    if @recipe.update(recipe_params)
      redirect_to source_recipe_path(@source, @recipe), notice: "Recipe updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  def retry_extraction
    @source = Source.find(params[:source_id])
    @recipe = @source.recipes.unscoped.find(params[:id])

    if @recipe.input_text.blank?
      redirect_to source_recipe_path(@source, @recipe), alert: "Cannot retry: no input text saved for this recipe."
      return
    end

    Extraction::CreateRecipeService.call(
      source: @source,
      text: @recipe.input_text,
      recipe: @recipe,
      input_type: @recipe.input_type,
      page_number: @recipe.page_number,
      raw_section_header: @recipe.raw_section_header
    )
    redirect_to source_recipe_path(@source, @recipe), notice: "Extraction retried. Status: #{@recipe.reload.extraction_status}."
  rescue StandardError => e
    path = (@source && @recipe) ? source_recipe_path(@source, @recipe) : source_path(params[:source_id])
    redirect_to path, alert: "Retry failed: #{e.message}"
  end

  def split_and_reextract
    @source = Source.find(params[:source_id])
    @recipe = @source.recipes.unscoped.find(params[:id])

    if @recipe.input_text.blank?
      redirect_to source_recipe_path(@source, @recipe), alert: "Cannot split: no input text saved for this recipe."
      return
    end

    result = Extraction::SplitAndReextractService.call(recipe: @recipe)

    if result[:split]
      count = result[:new_recipes].size
      redirect_to source_path(@source), notice: "Split into #{count} recipes. Original marked as not-a-recipe."
    else
      redirect_to source_recipe_path(@source, @recipe), alert: "No split performed: #{result[:reason]}"
    end
  rescue StandardError => e
    path = (@source && @recipe) ? source_recipe_path(@source, @recipe) : source_path(params[:source_id])
    redirect_to path, alert: "Split failed: #{e.message}"
  end

  private

  def recipe_params
    params.require(:recipe).permit(:not_a_recipe, :input_text, :notes)
  end
end
