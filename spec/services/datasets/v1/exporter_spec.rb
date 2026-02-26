# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::V1::Exporter do
  describe ".slice_for" do
    it "returns 'early' for years 1740-1819" do
      expect(described_class.slice_for(1740)).to eq("early")
      expect(described_class.slice_for(1800)).to eq("early")
      expect(described_class.slice_for(1819)).to eq("early")
    end

    it "returns 'victorian' for years 1820-1869" do
      expect(described_class.slice_for(1820)).to eq("victorian")
      expect(described_class.slice_for(1850)).to eq("victorian")
      expect(described_class.slice_for(1869)).to eq("victorian")
    end

    it "returns 'late' for years 1870-1929" do
      expect(described_class.slice_for(1870)).to eq("late")
      expect(described_class.slice_for(1900)).to eq("late")
      expect(described_class.slice_for(1929)).to eq("late")
    end

    it "returns 'out_of_range' for years outside 1740-1929" do
      expect(described_class.slice_for(1600)).to eq("out_of_range")
      expect(described_class.slice_for(1950)).to eq("out_of_range")
      expect(described_class.slice_for(2020)).to eq("out_of_range")
    end

    it "returns 'out_of_range' for nil" do
      expect(described_class.slice_for(nil)).to eq("out_of_range")
    end

    it "handles exact boundaries correctly" do
      expect(described_class.slice_for(1739)).to eq("out_of_range")
      expect(described_class.slice_for(1740)).to eq("early")
      expect(described_class.slice_for(1819)).to eq("early")
      expect(described_class.slice_for(1820)).to eq("victorian")
      expect(described_class.slice_for(1869)).to eq("victorian")
      expect(described_class.slice_for(1870)).to eq("late")
      expect(described_class.slice_for(1929)).to eq("late")
      expect(described_class.slice_for(1930)).to eq("out_of_range")
    end
  end
end
