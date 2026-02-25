Rails.application.routes.draw do
  root "sources#index"

  resources :sources, only: [:index, :show, :update] do
    member do
      post :bulk_retry_failed_extractions
    end
    resources :recipes, only: [:show, :update] do
      member do
        post :retry_extraction
        post :split_and_reextract
      end
    end
  end

  resources :ingredients, only: [:index]

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check
end
