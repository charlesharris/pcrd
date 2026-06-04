class Agent < ApplicationRecord
  belongs_to :user
  has_many   :listings, dependent: :nullify

  validates :commission_rate, numericality: { greater_than_or_equal_to: 0, less_than: 1 }
end
