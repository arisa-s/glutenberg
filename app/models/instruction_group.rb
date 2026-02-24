# frozen_string_literal: true

class InstructionGroup < ApplicationRecord
  belongs_to :recipe
  has_many :instructions, dependent: :destroy
end
