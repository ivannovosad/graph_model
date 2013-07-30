require 'spec_helper'

describe Term do

  describe "create" do
    it "creates a term" do
      term = Term.create title: "Test"
      expect(term.title).to eql "Test"
    end
  end
end