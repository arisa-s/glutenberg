# frozen_string_literal: true

class Source < ApplicationRecord
  PROVIDERS = %w[gutenberg internet_archive other].freeze

  has_many :recipes, dependent: :destroy

  validates :title, presence: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :external_id, uniqueness: { scope: :provider }, allow_nil: true
  validates :publication_year,
            numericality: { only_integer: true, greater_than: 1400, less_than: 2100 },
            allow_nil: true

  # Provider scopes
  scope :from_gutenberg, -> { where(provider: 'gutenberg') }
  scope :from_internet_archive, -> { where(provider: 'internet_archive') }

  # Corpus scopes
  scope :included, -> { where(included_in_corpus: true) }
  scope :excluded, -> { where(included_in_corpus: false) }

  # Temporal scopes
  scope :by_year, ->(year) { where(publication_year: year) }
  scope :by_decade, ->(start_year) { where(publication_year: start_year...(start_year + 10)) }
  scope :by_period, ->(start_year, end_year) { where(publication_year: start_year..end_year) }

  # Organization scopes
  scope :by_country, ->(country) { where(region_country: country) }
  scope :by_city, ->(city) { where(region_city: city) }

  def decade
    return nil unless publication_year

    (publication_year / 10) * 10
  end

  def period_label(period_size = 10)
    return nil unless publication_year

    decade_start = (publication_year / period_size) * period_size
    "#{decade_start}-#{decade_start + period_size - 1}"
  end
end
