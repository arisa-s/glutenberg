# frozen_string_literal: true

require "rails_helper"

RSpec.describe Datasets::V1::Tokenizer do
  describe ".call" do
    it "prefers product over original_string" do
      result = described_class.call(product: "Butter", original_string: "2 oz fresh butter")
      expect(result).to eq("butter")
    end

    it "falls back to original_string when product is blank" do
      result = described_class.call(product: "", original_string: "a pinch of salt")
      expect(result).to eq("a pinch of salt")
    end

    it "falls back to original_string when product is nil" do
      result = described_class.call(product: nil, original_string: "Sugar")
      expect(result).to eq("sugar")
    end

    it "returns nil when both are nil" do
      result = described_class.call(product: nil, original_string: nil)
      expect(result).to be_nil
    end

    it "returns nil when result is blank after normalization" do
      result = described_class.call(product: "!!!", original_string: nil)
      expect(result).to be_nil
    end
  end

  describe ".normalize" do
    it "downcases" do
      expect(described_class.normalize("FLOUR")).to eq("flour")
    end

    it "strips surrounding whitespace" do
      expect(described_class.normalize("  sugar  ")).to eq("sugar")
    end

    it "replaces punctuation with space" do
      expect(described_class.normalize("salt & pepper")).to eq("salt pepper")
    end

    it "collapses multiple spaces" do
      expect(described_class.normalize("brown   sugar")).to eq("brown sugar")
    end

    it "preserves hyphens" do
      expect(described_class.normalize("self-raising flour")).to eq("self-raising flour")
    end

    it "preserves French accented characters" do
      expect(described_class.normalize("café")).to eq("café")
      expect(described_class.normalize("crème fraîche")).to eq("crème fraîche")
      expect(described_class.normalize("garçon")).to eq("garçon")
    end

    it "does not merge words across spaces" do
      expect(described_class.normalize("tomato can")).to eq("tomato can")
    end

    it "handles mixed punctuation and accents" do
      expect(described_class.normalize("  Beurre (salé)!  ")).to eq("beurre salé")
    end

    it "returns nil for blank input" do
      expect(described_class.normalize("")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end
end
